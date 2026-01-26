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

// Keyboard input mode
enum class KeyboardMode : uint8_t {
    NORMAL = 0,  // Keyboard firmware processes keys, sends character codes
    RAW = 1      // Keyboard sends raw matrix state, host processes keys
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

    // Keyboard mode (normal vs raw)
    KeyboardMode getMode() const { return _mode; }
    bool setMode(KeyboardMode mode);

    // Raw mode functions - only valid when mode is RAW
    // T-Deck keyboard is 5 columns × 7 rows
    // Space is at [0][5], Mic is at [0][6]
    static constexpr uint8_t MATRIX_COLS = 5;
    static constexpr uint8_t MATRIX_ROWS = 7;

    // Read raw matrix state (7 bytes, one per column, bits = rows)
    // Returns true if successful, fills matrix array
    bool readRawMatrix(uint8_t matrix[MATRIX_COLS]);

    // Check if a specific key is pressed in raw mode (col 0-6, row 0-6)
    bool isKeyPressed(uint8_t col, uint8_t row);

    // Get the full matrix as a 64-bit value for easy Lua access
    // Bits 0-6 = col 0, bits 7-13 = col 1, etc. (7 bits per column)
    uint64_t getRawMatrixBits();

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

    // Tick-based scrolling (accumulates movement and emits on fixed clock)
    bool getTickBasedScrolling() const { return _tickBasedScrolling; }
    void setTickBasedScrolling(bool enabled) { _tickBasedScrolling = enabled; }

    uint16_t getScrollTickInterval() const { return _scrollTickInterval; }
    void setScrollTickInterval(uint16_t intervalMs) {
        if (intervalMs < 20) intervalMs = 20;
        if (intervalMs > 500) intervalMs = 500;
        _scrollTickInterval = intervalMs;
    }

    // Key repeat settings
    bool getKeyRepeatEnabled() const { return _keyRepeatEnabled; }
    void setKeyRepeatEnabled(bool enabled) { _keyRepeatEnabled = enabled; }

    uint16_t getKeyRepeatDelay() const { return _keyRepeatDelay; }
    void setKeyRepeatDelay(uint16_t delayMs) { _keyRepeatDelay = delayMs; }

    uint16_t getKeyRepeatRate() const { return _keyRepeatRate; }
    void setKeyRepeatRate(uint16_t rateMs) { _keyRepeatRate = rateMs; }

    // Keyboard backlight control (0-255, 0 = off)
    uint8_t getBacklight() const { return _backlightLevel; }
    void setBacklight(uint8_t level);

private:
    TwoWire* _wire;
    bool _initialized = false;
    bool _trackballFound = false;
    uint8_t _trackballAddr = 0;

    // Keyboard mode
    KeyboardMode _mode = KeyboardMode::NORMAL;

    // Cached raw matrix state (updated on each read in raw mode)
    uint8_t _rawMatrix[MATRIX_COLS] = {0};

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

    // Tick-based scrolling state
    bool _tickBasedScrolling = false;     // Emit events on fixed clock instead of immediately
    uint16_t _scrollTickInterval = 100;   // Interval between scroll ticks (ms)
    uint32_t _lastScrollTick = 0;         // Timestamp of last scroll tick
    int8_t _pendingScrollX = 0;           // Accumulated X movement for tick
    int8_t _pendingScrollY = 0;           // Accumulated Y movement for tick

    // Key repeat state
    bool _keyRepeatEnabled = true;        // Enable key repeat
    uint16_t _keyRepeatDelay = 400;       // Initial delay before repeat starts (ms)
    uint16_t _keyRepeatRate = 50;         // Interval between repeats (ms)
    uint8_t _heldKeyCode = 0;             // Currently held key code (0 = none)
    uint32_t _keyPressTime = 0;           // When the key was first pressed
    uint32_t _lastRepeatTime = 0;         // When last repeat was generated
    bool _repeatStarted = false;          // Has repeat started for current key

    // Convert raw keycode to KeyEvent
    KeyEvent translateKeycode(uint8_t code);

    // Handle modifier key updates
    void updateModifiers(uint8_t code, bool pressed);

    // Read and process trackball
    KeyEvent readTrackball();
};
