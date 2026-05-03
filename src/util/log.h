#pragma once

#include <Arduino.h>
#include <stdarg.h>
#include <stddef.h>

// Log prefix that remote control can filter out
// All log messages should start with this prefix followed by tag and message
// Format: #LOG#[Tag] message
// Example: #LOG#[Storage] Reading file: /test.txt

// Enable/disable logging at compile time
#ifndef LOG_ENABLED
#define LOG_ENABLED 1
#endif

// Append a formatted line to the in-memory ring buffer that backs the
// dev-server /logs endpoint. Always called with the printf-style args
// alongside Serial.printf so the on-device buffer mirrors what shows up
// on the USB console.
void log_buffer_appendf(const char* prefix, const char* fmt, ...);

// Copy the current buffer into `out` (newest entries last). Returns the
// number of bytes written; never exceeds `cap`. Lives behind a mutex so
// HTTP handlers can pull it without racing the formatter.
size_t log_buffer_snapshot(char* out, size_t cap);

#if LOG_ENABLED
    // Tee every LOG call to both Serial and the ring buffer. The
    // do/while wrapping keeps the macro safe in `if` statements.
    //
    // The log_buffer_appendf path is gated on LOG_TO_BUFFER so we
    // can flip the in-memory tee off when investigating tasks that
    // can't tolerate the per-call mutex (e.g. the OTA upload-handler
    // hot loop). Default-on so /logs continues to work for normal
    // diagnostics.
    #ifndef LOG_TO_BUFFER
    #define LOG_TO_BUFFER 1
    #endif
    #if LOG_TO_BUFFER
        #define LOG(tag, fmt, ...) do {                               \
            Serial.printf("#LOG#[" tag "] " fmt "\n", ##__VA_ARGS__); \
            log_buffer_appendf("[" tag "] ", fmt, ##__VA_ARGS__);     \
        } while (0)
        #define LOG_RAW(fmt, ...) do {                                \
            Serial.printf("#LOG#" fmt "\n", ##__VA_ARGS__);           \
            log_buffer_appendf("", fmt, ##__VA_ARGS__);               \
        } while (0)
    #else
        #define LOG(tag, fmt, ...) \
            Serial.printf("#LOG#[" tag "] " fmt "\n", ##__VA_ARGS__)
        #define LOG_RAW(fmt, ...) \
            Serial.printf("#LOG#" fmt "\n", ##__VA_ARGS__)
    #endif
#else
    #define LOG(tag, fmt, ...) ((void)0)
    #define LOG_RAW(fmt, ...) ((void)0)
#endif
