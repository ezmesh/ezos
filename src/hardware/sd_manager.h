// Shared SD-card mount manager.
//
// The Arduino SD wrapper is global state and is touched from multiple
// places: the Lua bindings on Core 1 (synchronous file I/O), the
// AsyncIO worker on Core 0 (READ/WRITE/RLE_READ_RGB565/etc), and the
// USB MSC subsystem when it polls availability or recovers from a
// host-side desync.
//
// Without coordination two failure modes appear:
//   1. Whichever module unmounts (SD.end() + SD.begin()) leaves the
//      others' "I have a valid mount" cache lying. Subsequent calls
//      that short-circuit on that cache (e.g. initSD()'s sticky flag)
//      report success while the actual fs::FS is half-torn-down.
//   2. SD.end() pulled out from under a File handle that another core
//      is mid-read on tears down FATFS structures and the next read
//      either silently corrupts, panics, or trips the watchdog.
//
// This header centralises the lifecycle so every caller goes through
// the same lock + same remount entry point.

#pragma once

#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <FS.h>

namespace SDManager {

// Lazy lazy: the first call constructs the mutex and (on first
// success) calls SD.begin(). Subsequent calls are cheap. Safe to call
// from either core.
bool ensureMounted();

// Force an unmount + remount. Used when an open() returned nullptr
// despite ensureMounted() having reported success: USB MSC can leave
// the wrapper's FATFS state out of sync with the card and only a full
// SD.end() + SD.begin() re-synchronises it. Returns false if the card
// is genuinely gone.
bool remount();

// Cheap "is the wrapper currently in a believed-mounted state". Used
// by isSDAvailable()-style probes that don't want to trigger a remount
// on every call. NOT a guarantee that the next open() succeeds; that's
// what openWithRetry()'s retry path is for.
bool isMounted();

// Acquire / release the SD mutex around any touch of the SD object
// (SD.open, SD.exists, SD.cardType, SD.end, SD.begin, etc). Reentrancy:
// the mutex is recursive, so a caller can hold it across a nested
// helper that also locks. portMAX_DELAY is the only timeout exposed --
// every SD op is short and serialised, so a timed wait would just
// trade one bug for another.
void lock();
void unlock();

// RAII wrapper -- prefer this over manual lock/unlock so early returns
// don't strand the mutex held.
struct ScopedLock {
    ScopedLock();
    ~ScopedLock();
    ScopedLock(const ScopedLock&) = delete;
    ScopedLock& operator=(const ScopedLock&) = delete;
};

// Open a file with one transparent remount-on-failure retry. Used by
// every SD-touching consumer (storage_bindings LUA_FUNCTIONs, the
// AsyncIO worker on Core 0, copy_file, etc) so a USB-MSC-induced
// FATFS desync auto-recovers on the very next call instead of
// hard-failing until the next reboot.
//
// CALLER must hold the SD lock (via ScopedLock) for SD paths so the
// open and the subsequent read/write/close all run under one
// continuous mutex. The recursive mutex would let nested locking
// work, but holding one scope per LUA_FUNCTION / per worker request
// keeps the lock-window obvious in the call site. Pass nullptr or
// a non-SD fs to skip the retry entirely (the helper still does the
// initial open so callers don't need to branch).
File openWithRetry(fs::FS* fs, const char* path, const char* mode);

}  // namespace SDManager
