#pragma once

#include <Arduino.h>
#include <Wire.h>
#include <stdint.h>

// Goodix GT911 capacitive touch driver for the LilyGo T-Deck Plus.
//
// The GT911 lives on the same I2C bus as the keyboard (Wire on SDA=18,
// SCL=8). Its reset line is tied to the board-wide power rail rather
// than a dedicated GPIO, so we can't drive the address-select dance
// from firmware -- the address is fixed at 0x5D on this board.
//
// 16-bit register addressing, big-endian on the wire. Status byte at
// 0x814E carries the data-ready flag (bit 7) and the touch count
// (bits 0..3); after we've read the points we MUST write 0 back to
// 0x814E or the controller never refreshes the buffer.
//
// The driver is poll-based: read() probes the status byte and, if data
// is ready, copies up to 5 points out and clears the buffer flag.
// `available()` is a cheap check (single I2C transaction) so callers
// can skip the per-frame point copy when the panel is idle.

class Touch {
public:
    static constexpr uint8_t MAX_POINTS = 5;

    struct Point {
        uint8_t  id;     // GT911 track id (0..15)
        uint16_t x;      // pixels, 0..319 (raw, no rotation applied)
        uint16_t y;      // pixels, 0..239
        uint16_t size;   // GT911 contact size (signal strength proxy)
    };

    bool init();
    bool ready() const { return _ok; }

    // Returns the number of points currently down (0..MAX_POINTS) and
    // fills `out` with them. Returns -1 when the controller has no
    // fresh sample queued (the buffer-ready flag is clear); callers
    // that need to track lift transitions must skip processing on -1
    // because the GT911 alternates "no new data" frames with real
    // sample frames -- treating -1 the same as "0 fingers down" would
    // generate spurious release events mid-drag. Clears the buffer
    // flag only when a fresh sample was consumed.
    int read(Point* out);

    // True if the GT911 has flagged "buffer ready" since we last read.
    // Cheap (single 3-byte I2C exchange) so it's safe to call once per
    // frame to gate the more expensive read().
    bool available();

    const char* productId() const     { return _productId; }
    uint16_t    firmwareVersion() const { return _fwVersion; }

private:
    bool      _ok        = false;
    uint8_t   _addr      = 0;        // resolved I2C address (0x14 or 0x5D)
    char      _productId[5] = {0};   // 4 ASCII chars + null
    uint16_t  _fwVersion = 0;

    bool readReg16(uint16_t reg, uint8_t* buf, size_t len);
    bool writeReg16(uint16_t reg, const uint8_t* buf, size_t len);
    bool clearStatus();
};

// Global instance, initialised in main.cpp after the keyboard has
// brought up the shared Wire bus.
extern Touch* touch;
