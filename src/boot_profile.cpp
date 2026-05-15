#include "boot_profile.h"

#include <Arduino.h>
#include <cstring>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>

// Fixed-size storage in BSS. No heap alloc, no PSRAM dependency, lives
// from very early in setup() (before PSRAM is even probed) all the way
// through normal device runtime.
static BootPhase s_entries[BOOT_PROFILE_CAPACITY];
static size_t s_count = 0;

// portMUX serialises the (name copy + millis read + count bump) trio.
// bootProfileMark can fire from setup() (Core 1, no other tasks) and
// from a Lua coroutine after init, so the lock-free path is incorrect.
// The critical section is tiny -- a 32-byte memcpy and one increment --
// so blocking interrupts briefly is fine.
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;

void bootProfileMark(const char* name) {
    if (name == nullptr) return;

    // Snapshot millis() outside the critical section to keep the lock
    // window as short as possible. The few microseconds of skew between
    // the timestamp and the actual append don't matter at boot-timeline
    // resolution.
    uint32_t now = millis();

    portENTER_CRITICAL(&s_mux);
    if (s_count < BOOT_PROFILE_CAPACITY) {
        BootPhase& slot = s_entries[s_count];
        // Manual strncpy to avoid the wide-string warnings on some
        // toolchains and guarantee the NUL terminator.
        size_t i = 0;
        while (i < sizeof(slot.name) - 1 && name[i] != '\0') {
            slot.name[i] = name[i];
            ++i;
        }
        slot.name[i] = '\0';
        slot.millis = now;
        ++s_count;
    }
    portEXIT_CRITICAL(&s_mux);
}

const BootPhase* bootProfileEntries(size_t* outCount) {
    if (outCount) {
        portENTER_CRITICAL(&s_mux);
        *outCount = s_count;
        portEXIT_CRITICAL(&s_mux);
    }
    return s_entries;
}
