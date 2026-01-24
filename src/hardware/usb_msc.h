#pragma once

#include <Arduino.h>

// USB Mass Storage Class for SD Card
// Allows the T-Deck to appear as a USB drive for file transfer

class SDCardUSB {
public:
    // Initialize USB MSC (call once at startup)
    static bool init();

    // Start MSC mode - device appears as USB drive
    // Warning: This takes over USB, serial monitor will disconnect
    static bool start();

    // Stop MSC mode and return to normal operation
    static void stop();

    // Check if MSC mode is active
    static bool isActive();

    // Check if SD card is available for MSC
    static bool isSDAvailable();

private:
    static bool _initialized;
    static bool _active;
};
