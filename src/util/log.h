#pragma once

#include <Arduino.h>

// Log prefix that remote control can filter out
// All log messages should start with this prefix followed by tag and message
// Format: #LOG#[Tag] message
// Example: #LOG#[Storage] Reading file: /test.txt

// Enable/disable logging at compile time
#ifndef LOG_ENABLED
#define LOG_ENABLED 1
#endif

#if LOG_ENABLED
    #define LOG(tag, fmt, ...) Serial.printf("#LOG#[" tag "] " fmt "\n", ##__VA_ARGS__)
    #define LOG_RAW(fmt, ...) Serial.printf("#LOG#" fmt "\n", ##__VA_ARGS__)
#else
    #define LOG(tag, fmt, ...) ((void)0)
    #define LOG_RAW(fmt, ...) ((void)0)
#endif
