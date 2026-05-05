#include "log.h"

#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <string.h>
#include <stdio.h>
#include <LittleFS.h>

namespace {

// 16 KiB of recent log lines. ~250 lines at the typical 60 chars/line
// budget, which is plenty to capture a boot run plus a screen or two
// of post-boot activity. Sized so a single GET /logs response fits in
// one chunked Lua string buffer on the host side without paging.
constexpr size_t LOG_BUF_SIZE = 16 * 1024;

char     g_buf[LOG_BUF_SIZE];
size_t   g_head  = 0;   // next write position
size_t   g_count = 0;   // bytes currently stored, capped at LOG_BUF_SIZE
// Cumulative byte counters for the streaming drain API. uint64_t
// would still take ~9 trillion years to wrap at any plausible log
// rate, so no overflow handling needed.
uint64_t g_total   = 0;  // every byte ever appended
uint64_t g_drained = 0;  // bytes already returned by drain()
SemaphoreHandle_t g_mutex = nullptr;

void ensure_init() {
    if (!g_mutex) {
        g_mutex = xSemaphoreCreateMutex();
    }
}

// Append raw bytes to the ring buffer. Caller already holds the mutex.
void append_raw(const char* data, size_t n) {
    if (n >= LOG_BUF_SIZE) {
        // Single line is bigger than our entire buffer -- keep only the
        // tail so we don't end up looping the same line over itself.
        data += (n - LOG_BUF_SIZE);
        n = LOG_BUF_SIZE;
    }

    size_t first = LOG_BUF_SIZE - g_head;
    if (n <= first) {
        memcpy(g_buf + g_head, data, n);
        g_head = (g_head + n) % LOG_BUF_SIZE;
    } else {
        memcpy(g_buf + g_head, data, first);
        memcpy(g_buf, data + first, n - first);
        g_head = n - first;
    }
    g_count = (g_count + n > LOG_BUF_SIZE) ? LOG_BUF_SIZE : g_count + n;
    g_total += n;
}

} // namespace

void log_buffer_appendf(const char* prefix, const char* fmt, ...) {
    ensure_init();

    char line[256];
    int  hlen = prefix ? snprintf(line, sizeof(line), "%s", prefix) : 0;
    if (hlen < 0) hlen = 0;
    if ((size_t)hlen >= sizeof(line) - 1) hlen = sizeof(line) - 1;

    va_list args;
    va_start(args, fmt);
    int blen = vsnprintf(line + hlen, sizeof(line) - hlen - 1, fmt, args);
    va_end(args);
    if (blen < 0) blen = 0;

    size_t total = hlen + blen;
    if (total >= sizeof(line) - 1) total = sizeof(line) - 1;
    line[total] = '\n';
    total += 1;

    if (g_mutex && xSemaphoreTake(g_mutex, pdMS_TO_TICKS(20)) == pdTRUE) {
        append_raw(line, total);
        xSemaphoreGive(g_mutex);
    } else {
        // Best-effort write without the lock. Two concurrent appends
        // can interleave bytes, but losing log fidelity under
        // contention is preferable to dropping the line entirely.
        append_raw(line, total);
    }
}

size_t log_buffer_drain(char* out, size_t cap) {
    ensure_init();
    if (cap == 0) return 0;

    size_t n = 0;
    if (g_mutex && xSemaphoreTake(g_mutex, pdMS_TO_TICKS(50)) == pdTRUE) {
        // Bytes the producer has written that we haven't yet emitted.
        uint64_t pending = g_total - g_drained;
        if (pending == 0) {
            xSemaphoreGive(g_mutex);
            return 0;
        }
        // Bytes still actually present in the ring. If the producer
        // wrote faster than we've been draining and bytes have
        // already rolled out the back, fast-forward the cursor to
        // the oldest still-present byte -- we accept losing the gap
        // rather than re-emitting older data.
        uint64_t available = (uint64_t)g_count;
        if (pending > available) {
            g_drained = g_total - available;
            pending   = available;
        }

        n = (pending < (uint64_t)cap) ? (size_t)pending : cap;
        // Ring layout: g_count valid bytes ending at g_head. The
        // first byte of valid data sits at (g_head - g_count) mod
        // LOG_BUF_SIZE; we want to start `skip` bytes into that
        // window where skip = drained-bytes already past the oldest
        // available byte.
        size_t skip = (size_t)(g_drained - (g_total - g_count));
        size_t tail_start =
            (g_head + LOG_BUF_SIZE - g_count + skip) % LOG_BUF_SIZE;
        size_t first = LOG_BUF_SIZE - tail_start;
        if (n <= first) {
            memcpy(out, g_buf + tail_start, n);
        } else {
            memcpy(out, g_buf + tail_start, first);
            memcpy(out + first, g_buf, n - first);
        }
        g_drained += n;
        xSemaphoreGive(g_mutex);
    }
    return n;
}

size_t log_buffer_snapshot(char* out, size_t cap) {
    ensure_init();
    if (cap == 0) return 0;

    size_t n = 0;
    if (g_mutex && xSemaphoreTake(g_mutex, pdMS_TO_TICKS(50)) == pdTRUE) {
        n = g_count < cap ? g_count : cap;
        // Skip past anything we'll truncate. The "older entries" we
        // drop here come from the start of the ring -- we still want
        // the newest `cap` bytes when the buffer is bigger than `cap`.
        size_t skip = (g_count > n) ? (g_count - n) : 0;
        size_t tail_start = (g_head + LOG_BUF_SIZE - g_count + skip) % LOG_BUF_SIZE;

        size_t first = LOG_BUF_SIZE - tail_start;
        if (n <= first) {
            memcpy(out, g_buf + tail_start, n);
        } else {
            memcpy(out, g_buf + tail_start, first);
            memcpy(out + first, g_buf, n - first);
        }
        xSemaphoreGive(g_mutex);
    }
    return n;
}

void log_panic_flush(const char* reason) {
    // The Lua flusher won't run again before the device tips over,
    // so pull the whole ring from RAM to flash here. Best-effort:
    // any failure (LittleFS not mounted yet, mutex held by the
    // panicking task, disk full) just no-ops -- there's nothing
    // sensible to do besides eating the loss.
    ensure_init();
    if (!reason) reason = "?";

    // 16 KiB ring + a small header line. Static so we don't need a
    // heap alloc that might already be wedged on the panic path,
    // and don't pay the loopTask stack cost (10 KiB ceiling).
    static char buf[LOG_BUF_SIZE];
    size_t n = 0;

    // Use a short timeout; if the producer task is wedged we give
    // up rather than hanging the shutdown. The mutex is only held
    // for low-microsecond memcpys in normal operation, so any
    // failure to acquire here is a strong signal we're in deep
    // trouble.
    if (g_mutex && xSemaphoreTake(g_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
        n = g_count;
        size_t tail_start = (g_head + LOG_BUF_SIZE - g_count) % LOG_BUF_SIZE;
        size_t first = LOG_BUF_SIZE - tail_start;
        if (n <= first) {
            memcpy(buf, g_buf + tail_start, n);
        } else {
            memcpy(buf, g_buf + tail_start, first);
            memcpy(buf + first, g_buf, n - first);
        }
        xSemaphoreGive(g_mutex);
    }

    // Mount-check via the public API. LittleFS.begin() is idempotent
    // -- if main.cpp already ran it, this returns immediately; if
    // somehow it didn't (rare path: crash during init), we still
    // get a working FS.
    if (!LittleFS.begin(false)) return;

    // Make sure /logs exists. mkdir on an existing dir is a no-op.
    LittleFS.mkdir("/logs");

    File f = LittleFS.open("/logs/system.log", "a");
    if (!f) return;

    char marker[96];
    int mlen = snprintf(marker, sizeof(marker),
        "==== panic flush %s ms=%lu ====\n",
        reason, (unsigned long)millis());
    if (mlen > 0) {
        f.write((const uint8_t*)marker, (size_t)mlen);
    }
    if (n > 0) {
        f.write((const uint8_t*)buf, n);
        // Make sure the last line is newline-terminated so the
        // shell `logs` command and the screen viewer don't glue
        // unrelated lines together when reading back.
        if (buf[n - 1] != '\n') {
            f.write((const uint8_t*)"\n", 1);
        }
    }
    f.close();
}
