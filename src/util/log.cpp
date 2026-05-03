#include "log.h"

#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <string.h>

namespace {

// 16 KiB of recent log lines. ~250 lines at the typical 60 chars/line
// budget, which is plenty to capture a boot run plus a screen or two
// of post-boot activity. Sized so a single GET /logs response fits in
// one chunked Lua string buffer on the host side without paging.
constexpr size_t LOG_BUF_SIZE = 16 * 1024;

char     g_buf[LOG_BUF_SIZE];
size_t   g_head  = 0;   // next write position
size_t   g_count = 0;   // bytes currently stored, capped at LOG_BUF_SIZE
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
