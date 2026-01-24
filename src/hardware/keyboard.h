#pragma once

#include <cstdint>
#include <Wire.h>
#include "../config.h"

// Special keys that don't map to printable characters
enum class SpecialKey : uint8_t {
    NONE = 0,
    UP,
    DOWN,
    LEFT,
    RIGHT,
    ENTER,
    ESCAPE,
    TAB,
    BACKSPACE,
    DELETE,
    HOME,
    END,
    SHIFT,
    CTRL,
    ALT,
    FN,
    SPEAKER,    // Speaker/media key
    MIC         // Microphone key
};

// Keyboard event structure
struct KeyEvent {
    char character;         // ASCII character, or 0 if special key
    SpecialKey special;     // Special key type, or NONE if regular char
    bool shift;             // Shift modifier held
    bool ctrl;              // Ctrl modifier held
    bool alt;               // Alt modifier held
    bool fn;                // Fn modifier held
    bool valid;             // Whether this is a valid key event

    KeyEvent() : character(0), special(SpecialKey::NONE),
                 shift(false), ctrl(false), alt(false), fn(false), valid(false) {}

    // Check if this is a printable character
    bool isPrintable() const {
        return valid && character >= 32 && character < 127;
    }

    // Check if this is a special key
    bool isSpecial() const {
        return valid && special != SpecialKey::NONE;
    }

    // Static factory for invalid event
    static KeyEvent invalid() {
        return KeyEvent();
    }

    // Static factory for character event
    static KeyEvent fromChar(char c, bool shft = false, bool ctl = false, bool al = false, bool function = false) {
        KeyEvent e;
        e.character = c;
        e.special = SpecialKey::NONE;
        e.shift = shft;
        e.ctrl = ctl;
        e.alt = al;
        e.fn = function;
        e.valid = true;
        return e;
    }

    // Static factory for special key event
    static KeyEvent fromSpecial(SpecialKey key, bool shft = false, bool ctl = false, bool al = false, bool function = false) {
        KeyEvent e;
        e.character = 0;
        e.special = key;
        e.shift = shft;
        e.ctrl = ctl;
        e.alt = al;
        e.fn = function;
        e.valid = true;
        return e;
    }
};

class Keyboard {
public:
    Keyboard();
    ~Keyboard() = default;

    // Prevent copying
    Keyboard(const Keyboard&) = delete;
    Keyboard& operator=(const Keyboard&) = delete;

    // Initialization
    bool init();

    // Check if a key is available (non-blocking)
    bool available();

    // Read key event (non-blocking, returns invalid event if no key)
    KeyEvent read();

    // Blocking read with timeout (returns invalid if timeout)
    KeyEvent readBlocking(uint32_t timeoutMs = 0);  // 0 = wait forever

    // Get raw key code (for debugging)
    uint8_t readRaw();

    // Check modifier states
    bool isShiftHeld() const { return _shiftHeld; }
    bool isCtrlHeld() const { return _ctrlHeld; }
    bool isAltHeld() const { return _altHeld; }
    bool isFnHeld() const { return _fnHeld; }

    // Trackball state
    bool hasTrackball() const { return _trackballFound; }

    // Trackball sensitivity (1-10, lower = more sensitive)
    int8_t getTrackballSensitivity() const { return _trackballThreshold; }
    void setTrackballSensitivity(int8_t threshold) {
        if (threshold < 1) threshold = 1;
        if (threshold > 10) threshold = 10;
        _trackballThreshold = threshold;
    }

    // Adaptive scrolling (threshold loosens as you scroll continuously)
    bool getAdaptiveScrolling() const { return _adaptiveScrolling; }
    void setAdaptiveScrolling(bool enabled) { _adaptiveScrolling = enabled; }

    // Keyboard backlight control (0-255, 0 = off)
    uint8_t getBacklight() const { return _backlightLevel; }
    void setBacklight(uint8_t level);

private:
    TwoWire* _wire;
    bool _initialized = false;
    bool _trackballFound = false;
    uint8_t _trackballAddr = 0;

    // Modifier key states
    bool _shiftHeld = false;
    bool _ctrlHeld = false;
    bool _altHeld = false;
    bool _fnHeld = false;

    // Backlight state
    uint8_t _backlightLevel = 0;

    // Trackball accumulator for generating key events
    int8_t _trackballX = 0;
    int8_t _trackballY = 0;
    int8_t _trackballThreshold = 2;  // Movement threshold (1-10, lower = more sensitive)

    // Adaptive scrolling state
    bool _adaptiveScrolling = true;       // Enable adaptive threshold
    int8_t _lastScrollDir = 0;            // -1=up/left, 0=none, 1=down/right
    uint32_t _lastScrollTime = 0;         // Timestamp of last scroll event
    int8_t _adaptiveThreshold = 0;        // Current adaptive threshold (0 = use base)

    // Convert raw keycode to KeyEvent
    KeyEvent translateKeycode(uint8_t code);

    // Handle modifier key updates
    void updateModifiers(uint8_t code, bool pressed);

    // Read and process trackball
    KeyEvent readTrackball();
};
