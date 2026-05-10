#include "sd_manager.h"
#include "../config.h"

#include <Arduino.h>
#include <SD.h>
#include <SPI.h>

namespace SDManager {

// Recursive mutex: callers may legitimately hold the lock across a
// helper that also locks (e.g. openLocked -> remount on retry). Built
// once on first use; FreeRTOS doesn't expose a constexpr SemaphoreHandle
// initialiser, so lazy construction in ensureLockExists() is the
// idiomatic pattern.
static SemaphoreHandle_t g_mutex = nullptr;
static bool g_mounted = false;
static bool g_spiBegun = false;

static void ensureLockExists() {
    // The first caller wins. After this returns the mutex pointer is
    // stable, so the rest of the API can read g_mutex without a fence.
    // Concurrent first-callers would race here, but the only way to
    // reach SDManager before any other code is from setup(), which
    // runs single-threaded -- by the time the AsyncIO worker on Core 0
    // pulls its first request the lock has long been created.
    if (!g_mutex) {
        g_mutex = xSemaphoreCreateRecursiveMutex();
    }
}

void lock() {
    ensureLockExists();
    xSemaphoreTakeRecursive(g_mutex, portMAX_DELAY);
}

void unlock() {
    xSemaphoreGiveRecursive(g_mutex);
}

ScopedLock::ScopedLock()  { lock(); }
ScopedLock::~ScopedLock() { unlock(); }

bool isMounted() {
    // No lock taken: this is a hint, not a guarantee. Callers that need
    // certainty should ensureMounted() (which locks) before opening.
    return g_mounted;
}

bool ensureMounted() {
    ScopedLock lk;
    if (g_mounted) return true;

    if (!g_spiBegun) {
        SPI.begin(SD_SCLK, SD_MISO, SD_MOSI, SD_CS);
        g_spiBegun = true;
    }

    if (SD.begin(SD_CS)) {
        g_mounted = true;
        Serial.println("[SDManager] SD card mounted");
        return true;
    }

    Serial.println("[SDManager] SD card not available");
    return false;
}

bool remount() {
    ScopedLock lk;
    if (g_mounted) {
        SD.end();
        g_mounted = false;
    }
    if (SD.begin(SD_CS)) {
        g_mounted = true;
        Serial.println("[SDManager] SD card remounted");
        return true;
    }
    Serial.println("[SDManager] SD card remount failed");
    return false;
}

File openWithRetry(fs::FS* fs, const char* path, const char* mode) {
    File f = fs->open(path, mode);
    if (f) return f;
    if (fs == &SD && remount()) {
        f = fs->open(path, mode);
    }
    return f;
}

}  // namespace SDManager
