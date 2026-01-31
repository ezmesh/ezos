#include "keyboard.h"
#include <Arduino.h>

// Volatile counters for trackball interrupt mode
static volatile int16_t tb_int_up = 0;
static volatile int16_t tb_int_down = 0;
static volatile int16_t tb_int_left = 0;
static volatile int16_t tb_int_right = 0;
static volatile bool tb_int_click = false;
static volatile uint32_t tb_int_click_time = 0;

// ISR functions for trackball (must be in IRAM for ESP32)
static void IRAM_ATTR ISR_trackball_up() {
    tb_int_up++;
}

static void IRAM_ATTR ISR_trackball_down() {
    tb_int_down++;
}

static void IRAM_ATTR ISR_trackball_left() {
    tb_int_left++;
}

static void IRAM_ATTR ISR_trackball_right() {
    tb_int_right++;
}

static void IRAM_ATTR ISR_trackball_click() {
    tb_int_click = true;
    tb_int_click_time = millis();
}

// T-Deck keyboard key codes
// The keyboard controller sends single bytes for key events
// Upper bit (0x80) indicates key release, lower 7 bits are the key code

// Special key codes from T-Deck keyboard
namespace KeyCodes {
    constexpr uint8_t KEY_NONE       = 0x00;

    // Arrow keys and navigation
    constexpr uint8_t KEY_UP         = 0xB5;
    constexpr uint8_t KEY_DOWN       = 0xB6;
    constexpr uint8_t KEY_LEFT       = 0xB4;
    constexpr uint8_t KEY_RIGHT      = 0xB7;

    // Control keys
    constexpr uint8_t KEY_ENTER      = 0x0D;  // Carriage return
    constexpr uint8_t KEY_BACKSPACE  = 0x08;
    constexpr uint8_t KEY_TAB        = 0x09;
    constexpr uint8_t KEY_ESCAPE     = 0x1B;
    constexpr uint8_t KEY_DELETE     = 0x7F;

    // Modifier keys (reported as key codes when pressed)
    constexpr uint8_t KEY_SHIFT      = 0x81;
    constexpr uint8_t KEY_CTRL       = 0x82;
    constexpr uint8_t KEY_ALT        = 0x83;
    constexpr uint8_t KEY_FN         = 0x84;

    // Special function keys
    constexpr uint8_t KEY_SPEAKER    = 0x85;
    constexpr uint8_t KEY_MIC        = 0x86;

    // Key release flag
    constexpr uint8_t KEY_RELEASE    = 0x80;
}

// Keyboard commands (from T-Deck keyboard firmware)
namespace KBCommands {
    constexpr uint8_t CMD_BRIGHTNESS = 0x01;
    constexpr uint8_t CMD_MODE_RAW = 0x03;     // Raw mode - sends matrix state
    constexpr uint8_t CMD_MODE_NORMAL = 0x04;  // Disable raw mode (return to normal)
}

Keyboard::Keyboard() : _wire(nullptr) {
}

bool Keyboard::init() {
    if (_initialized) {
        return true;
    }

    // Initialize I2C for keyboard - try default Wire first
    _wire = &Wire;
    _wire->begin(KB_I2C_SDA, KB_I2C_SCL, I2C_FREQ);
    _wire->setTimeout(50);  // 50ms timeout to prevent blocking on special keys like mic
    Serial.printf("Keyboard using Wire on SDA=%d, SCL=%d\n", KB_I2C_SDA, KB_I2C_SCL);

    // Configure interrupt pin if available
    if (KB_INT >= 0) {
        pinMode(KB_INT, INPUT_PULLUP);
    }

    // Check if keyboard responds
    _wire->beginTransmission(KB_I2C_ADDR);
    uint8_t error = _wire->endTransmission();

    if (error != 0) {
        Serial.printf("Keyboard not found at 0x%02X (error %d)\n", KB_I2C_ADDR, error);
        return false;
    }

    Serial.println("Keyboard initialized");

    // Scan I2C bus for all devices and probe them
    Serial.println("Scanning I2C bus for devices...");
    for (uint8_t addr = 1; addr < 127; addr++) {
        _wire->beginTransmission(addr);
        uint8_t scanError = _wire->endTransmission();
        if (scanError == 0) {
            Serial.printf("  I2C device at 0x%02X: ", addr);

            // Try to read some bytes from it
            _wire->requestFrom(addr, (uint8_t)8);
            uint8_t count = 0;
            while (_wire->available() && count < 8) {
                uint8_t b = _wire->read();
                Serial.printf("%02X ", b);
                count++;
            }
            if (count == 0) {
                Serial.print("(no data)");
            }
            Serial.println();
        }
    }

    // Check interrupt pin state
    Serial.printf("Keyboard INT pin (GPIO%d) state: %s\n", KB_INT, digitalRead(KB_INT) == LOW ? "LOW (active)" : "HIGH");

    // Initialize trackball GPIO pins (directly connected, active LOW)
    pinMode(TRACKBALL_UP, INPUT_PULLUP);
    pinMode(TRACKBALL_DOWN, INPUT_PULLUP);
    pinMode(TRACKBALL_LEFT, INPUT_PULLUP);
    pinMode(TRACKBALL_RIGHT, INPUT_PULLUP);
    pinMode(TRACKBALL_CLICK, INPUT_PULLUP);
    Serial.printf("Trackball GPIOs: UP=%d DOWN=%d LEFT=%d RIGHT=%d CLICK=%d\n",
                  TRACKBALL_UP, TRACKBALL_DOWN, TRACKBALL_LEFT, TRACKBALL_RIGHT, TRACKBALL_CLICK);

    _trackballFound = true;

    _initialized = true;
    return true;
}

bool Keyboard::available() {
    if (!_initialized) return false;

    // Check interrupt pin if available (active low)
    if (KB_INT >= 0) {
        return digitalRead(KB_INT) == LOW;
    }

    // Otherwise, try to read from I2C
    _wire->requestFrom((uint8_t)KB_I2C_ADDR, (uint8_t)1);
    if (_wire->available()) {
        // Peek at the data without consuming it
        // Note: This actually consumes the byte, so we need a different approach
        // For now, we'll just check if data is available
        return true;
    }

    return false;
}

uint8_t Keyboard::readRaw() {
    if (!_initialized) return 0;

    _wire->requestFrom((uint8_t)KB_I2C_ADDR, (uint8_t)1);
    if (_wire->available()) {
        return _wire->read();
    }
    return 0;
}

void Keyboard::injectEvent(const KeyEvent& event) {
    // Add event to circular queue (thread-safe with single producer)
    size_t nextHead = (_injectHead + 1) % INJECT_QUEUE_SIZE;
    if (nextHead != _injectTail) {
        _injectQueue[_injectHead] = event;
        _injectHead = nextHead;
    }
    // If queue is full, event is dropped
}

KeyEvent Keyboard::read() {
    if (!_initialized) {
        return KeyEvent::invalid();
    }

    // First check inject queue for remote control events
    if (_injectTail != _injectHead) {
        KeyEvent event = _injectQueue[_injectTail];
        _injectTail = (_injectTail + 1) % INJECT_QUEUE_SIZE;
        return event;
    }

    // Then check for key press (direct read from keyboard I2C)
    _wire->requestFrom((uint8_t)KB_I2C_ADDR, (uint8_t)1);
    if (_wire->available()) {
        uint8_t code = _wire->read();
        if (code != 0) {
            // Debug: log all non-zero keyboard codes
            Serial.printf("[KB] I2C code: 0x%02X\n", code);

            bool isRelease = (code & 0x80) != 0;
            uint8_t keyCode = code & 0x7F;

            // Track held key for repeat (excluding modifiers)
            if (keyCode < KeyCodes::KEY_SHIFT || keyCode > KeyCodes::KEY_FN) {
                if (isRelease) {
                    // Key released - stop repeat
                    if (_heldKeyCode == keyCode) {
                        _heldKeyCode = 0;
                        _repeatStarted = false;
                    }
                } else {
                    // New key pressed - start tracking
                    _heldKeyCode = keyCode;
                    _keyPressTime = millis();
                    _lastRepeatTime = 0;
                    _repeatStarted = false;
                }
            }

            KeyEvent evt = translateKeycode(code);
            if (evt.valid) {
                Serial.printf("[KB] Event: special=%d char='%c'\n",
                              evt.special, evt.character ? evt.character : '?');
            }
            return evt;
        }
    }

    // Check for key repeat (if a key is held and repeat is enabled)
    if (_keyRepeatEnabled && _heldKeyCode != 0) {
        uint32_t now = millis();
        uint32_t elapsed = now - _keyPressTime;

        if (!_repeatStarted) {
            // Check if we've passed the initial delay
            if (elapsed >= _keyRepeatDelay) {
                _repeatStarted = true;
                _lastRepeatTime = now;
                // Generate repeat event
                return translateKeycode(_heldKeyCode);
            }
        } else {
            // We're in repeat mode - check rate
            if (now - _lastRepeatTime >= _keyRepeatRate) {
                _lastRepeatTime = now;
                return translateKeycode(_heldKeyCode);
            }
        }
    }

    // Trackball handling - supports both polling and interrupt modes
    uint32_t now = millis();

    if (_trackballMode == TrackballMode::INTERRUPT_DRIVEN) {
        // Interrupt mode: read from volatile counters set by ISRs
        // Atomically read and reset counters
        noInterrupts();
        int16_t intUp = tb_int_up;
        int16_t intDown = tb_int_down;
        int16_t intLeft = tb_int_left;
        int16_t intRight = tb_int_right;
        bool intClick = tb_int_click;
        tb_int_up = 0;
        tb_int_down = 0;
        tb_int_left = 0;
        tb_int_right = 0;
        tb_int_click = false;
        interrupts();

        // Handle click from interrupt
        if (intClick) {
            return KeyEvent::fromSpecial(SpecialKey::ENTER, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        }

        // Accumulate trackball movement from interrupt counters
        _trackballY -= intUp;
        _trackballY += intDown;
        _trackballX -= intLeft;
        _trackballX += intRight;
    } else {
        // Polling mode: read GPIO pins directly
        // Initialize last* from actual GPIO state on first call to avoid spurious edges at boot
        static bool firstPoll = true;
        static bool lastUp = false, lastDown = false, lastLeft = false, lastRight = false;
        static bool clickHeld = false;
        static uint32_t clickStartTime = 0;
        static bool clickFired = false;

        bool up = (digitalRead(TRACKBALL_UP) == LOW);
        bool down = (digitalRead(TRACKBALL_DOWN) == LOW);
        bool left = (digitalRead(TRACKBALL_LEFT) == LOW);
        bool right = (digitalRead(TRACKBALL_RIGHT) == LOW);
        bool click = (digitalRead(TRACKBALL_CLICK) == LOW);

        // On first poll, just record state without detecting edges
        if (firstPoll) {
            firstPoll = false;
            lastUp = up;
            lastDown = down;
            lastLeft = left;
            lastRight = right;
            // Don't generate any events on first poll
            return KeyEvent::invalid();
        }

        // Detect edges for scroll (transitions from HIGH to LOW)
        bool upEdge = up && !lastUp;
        bool downEdge = down && !lastDown;
        bool leftEdge = left && !lastLeft;
        bool rightEdge = right && !lastRight;

        // Save current state for next edge detection
        lastUp = up;
        lastDown = down;
        lastLeft = left;
        lastRight = right;

        // Handle click (30ms debounce)
        if (click) {
            // Re-enable pullup in case it got disabled
            pinMode(TRACKBALL_CLICK, INPUT_PULLUP);
            if (!clickHeld) {
                clickHeld = true;
                clickStartTime = now;
                clickFired = false;
            } else if (!clickFired && (now - clickStartTime) >= 30) {
                clickFired = true;
                return KeyEvent::fromSpecial(SpecialKey::ENTER, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
            }
        } else {
            clickHeld = false;
            clickFired = false;
        }

        // Accumulate trackball movement (only on edges)
        if (upEdge) _trackballY--;
        if (downEdge) _trackballY++;
        if (leftEdge) _trackballX--;
        if (rightEdge) _trackballX++;
    }

    // Calculate effective threshold with adaptive scrolling
    // Adaptive mode: threshold loosens (decreases) when scrolling continuously in same direction
    int8_t effectiveThreshold = _trackballThreshold;
    if (_adaptiveScrolling && _adaptiveThreshold > 0) {
        effectiveThreshold = _adaptiveThreshold;
    }

    // Helper to update adaptive state after a scroll event
    auto updateAdaptive = [this](int8_t dir) {
        uint32_t now = millis();
        if (_adaptiveScrolling) {
            // If same direction and within 500ms, loosen threshold
            if (dir == _lastScrollDir && (now - _lastScrollTime) < 500) {
                // Reduce threshold down to minimum of 1
                if (_adaptiveThreshold == 0) {
                    _adaptiveThreshold = _trackballThreshold;
                }
                if (_adaptiveThreshold > 1) {
                    _adaptiveThreshold--;
                }
            } else {
                // Direction changed or timeout - reset to base threshold
                _adaptiveThreshold = _trackballThreshold;
            }
            _lastScrollDir = dir;
            _lastScrollTime = now;
        }
    };

    // Generate directional keys when threshold reached
    if (_trackballY <= -effectiveThreshold) {
        _trackballY = 0;
        updateAdaptive(-1);  // Up direction
        return KeyEvent::fromSpecial(SpecialKey::UP, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballY >= effectiveThreshold) {
        _trackballY = 0;
        updateAdaptive(1);   // Down direction
        return KeyEvent::fromSpecial(SpecialKey::DOWN, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballX <= -effectiveThreshold) {
        _trackballX = 0;
        updateAdaptive(-1);  // Left direction
        return KeyEvent::fromSpecial(SpecialKey::LEFT, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballX >= effectiveThreshold) {
        _trackballX = 0;
        updateAdaptive(1);   // Right direction
        return KeyEvent::fromSpecial(SpecialKey::RIGHT, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }

    return KeyEvent::invalid();
}

KeyEvent Keyboard::readTrackball() {
    // T-Deck Plus trackball is integrated with keyboard at 0x55
    // Try reading from keyboard with register 0x01 for trackball data
    static uint32_t lastDebug = 0;
    static uint32_t readCount = 0;
    bool shouldDebug = (readCount < 30) || (millis() - lastDebug > 2000);

    // Method 1: Write register address first, then read
    _wire->beginTransmission(KB_I2C_ADDR);
    _wire->write(0x01);  // Trackball register
    _wire->endTransmission(false);  // Don't release bus

    _wire->requestFrom((uint8_t)KB_I2C_ADDR, (uint8_t)5);

    uint8_t bytesAvail = _wire->available();

    if (bytesAvail == 0) {
        if (shouldDebug) {
            Serial.printf("Trackball from KB: no bytes\n");
            lastDebug = millis();
            readCount++;
        }
        return KeyEvent::invalid();
    }

    uint8_t data[8] = {0};
    uint8_t i = 0;
    while (_wire->available() && i < 8) {
        data[i++] = _wire->read();
    }

    // Check if any non-zero data
    bool hasData = false;
    for (uint8_t j = 0; j < bytesAvail; j++) {
        if (data[j] != 0) hasData = true;
    }

    if (shouldDebug || hasData) {
        Serial.printf("Trackball KB reg: got %d bytes: ", bytesAvail);
        for (uint8_t j = 0; j < bytesAvail && j < 8; j++) {
            Serial.printf("%02X ", data[j]);
        }
        Serial.println();
        lastDebug = millis();
        readCount++;
    }

    if (bytesAvail < 5) {
        return KeyEvent::invalid();
    }

    uint8_t left = data[0];
    uint8_t right = data[1];
    uint8_t up = data[2];
    uint8_t down = data[3];
    uint8_t click = data[4];

    // Accumulate movement
    _trackballX += (int8_t)right - (int8_t)left;
    _trackballY += (int8_t)down - (int8_t)up;

    // Handle click as Enter
    if (click) {
        return KeyEvent::fromSpecial(SpecialKey::ENTER, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }

    // Calculate effective threshold with adaptive scrolling
    int8_t effectiveThreshold = _trackballThreshold;
    if (_adaptiveScrolling && _adaptiveThreshold > 0) {
        effectiveThreshold = _adaptiveThreshold;
    }

    // Helper to update adaptive state after a scroll event
    auto updateAdaptive = [this](int8_t dir) {
        uint32_t now = millis();
        if (_adaptiveScrolling) {
            if (dir == _lastScrollDir && (now - _lastScrollTime) < 500) {
                if (_adaptiveThreshold == 0) {
                    _adaptiveThreshold = _trackballThreshold;
                }
                if (_adaptiveThreshold > 1) {
                    _adaptiveThreshold--;
                }
            } else {
                _adaptiveThreshold = _trackballThreshold;
            }
            _lastScrollDir = dir;
            _lastScrollTime = now;
        }
    };

    // Generate key events when threshold is reached
    if (_trackballY <= -effectiveThreshold) {
        _trackballY = 0;
        _trackballX = 0;
        updateAdaptive(-1);
        return KeyEvent::fromSpecial(SpecialKey::UP, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballY >= effectiveThreshold) {
        _trackballY = 0;
        _trackballX = 0;
        updateAdaptive(1);
        return KeyEvent::fromSpecial(SpecialKey::DOWN, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballX <= -effectiveThreshold) {
        _trackballX = 0;
        _trackballY = 0;
        updateAdaptive(-1);
        return KeyEvent::fromSpecial(SpecialKey::LEFT, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballX >= effectiveThreshold) {
        _trackballX = 0;
        _trackballY = 0;
        updateAdaptive(1);
        return KeyEvent::fromSpecial(SpecialKey::RIGHT, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }

    return KeyEvent::invalid();
}

KeyEvent Keyboard::readBlocking(uint32_t timeoutMs) {
    uint32_t start = millis();

    while (true) {
        KeyEvent event = read();
        if (event.valid) {
            return event;
        }

        // Check timeout (0 means wait forever)
        if (timeoutMs > 0 && (millis() - start) >= timeoutMs) {
            return KeyEvent::invalid();
        }

        delay(10);  // Small delay to prevent busy-waiting
    }
}

void Keyboard::updateModifiers(uint8_t code, bool pressed) {
    Serial.printf("Modifier: code=0x%02X pressed=%d\n", code, pressed);
    switch (code) {
        case KeyCodes::KEY_SHIFT:
            _shiftHeld = pressed;
            Serial.printf("  -> SHIFT=%d\n", _shiftHeld);
            break;
        case KeyCodes::KEY_CTRL:
            _ctrlHeld = pressed;
            Serial.printf("  -> CTRL=%d\n", _ctrlHeld);
            break;
        case KeyCodes::KEY_ALT:
            _altHeld = pressed;
            Serial.printf("  -> ALT=%d\n", _altHeld);
            break;
        case KeyCodes::KEY_FN:
            _fnHeld = pressed;
            Serial.printf("  -> FN=%d\n", _fnHeld);
            break;
        default:
            Serial.printf("  -> UNKNOWN modifier\n");
            break;
    }
}

KeyEvent Keyboard::translateKeycode(uint8_t code) {
    // Check for key release
    bool isRelease = (code & KeyCodes::KEY_RELEASE) != 0;
    uint8_t keyCode = code & 0x7F;

    // Handle modifier key state tracking
    if (keyCode >= KeyCodes::KEY_SHIFT && keyCode <= KeyCodes::KEY_FN) {
        updateModifiers(keyCode, !isRelease);
        // Don't generate event for modifier key changes
        return KeyEvent::invalid();
    }

    // Only generate events on key press, not release
    if (isRelease) {
        return KeyEvent::invalid();
    }

    // Map special keys
    switch (code) {
        case KeyCodes::KEY_UP:
            return KeyEvent::fromSpecial(SpecialKey::UP, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        case KeyCodes::KEY_DOWN:
            return KeyEvent::fromSpecial(SpecialKey::DOWN, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        case KeyCodes::KEY_LEFT:
            return KeyEvent::fromSpecial(SpecialKey::LEFT, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        case KeyCodes::KEY_RIGHT:
            return KeyEvent::fromSpecial(SpecialKey::RIGHT, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        case KeyCodes::KEY_ENTER:
            return KeyEvent::fromSpecial(SpecialKey::ENTER, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        case KeyCodes::KEY_BACKSPACE:
            return KeyEvent::fromSpecial(SpecialKey::BACKSPACE, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        case KeyCodes::KEY_TAB:
            return KeyEvent::fromSpecial(SpecialKey::TAB, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        case KeyCodes::KEY_ESCAPE:
            return KeyEvent::fromSpecial(SpecialKey::ESCAPE, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        case KeyCodes::KEY_DELETE:
            return KeyEvent::fromSpecial(SpecialKey::DELETE, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        case KeyCodes::KEY_SPEAKER:
            return KeyEvent::fromSpecial(SpecialKey::SPEAKER, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        case KeyCodes::KEY_MIC:
            return KeyEvent::fromSpecial(SpecialKey::MIC, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }

    // Regular printable characters
    if (code >= 32 && code < 127) {
        char c = static_cast<char>(code);

        // Apply shift modifier for letters
        if (_shiftHeld && c >= 'a' && c <= 'z') {
            c = c - 'a' + 'A';  // Convert to uppercase
        }

        return KeyEvent::fromChar(c, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }

    // Unknown key code
    return KeyEvent::invalid();
}

void Keyboard::setBacklight(uint8_t level) {
    if (!_initialized || !_wire) return;

    _backlightLevel = level;

    // Send brightness command to keyboard controller
    _wire->beginTransmission(KB_I2C_ADDR);
    _wire->write(KBCommands::CMD_BRIGHTNESS);
    _wire->write(level);
    uint8_t error = _wire->endTransmission();

    if (error != 0) {
        Serial.printf("[Keyboard] Backlight set failed (error %d)\n", error);
    } else {
        Serial.printf("[Keyboard] Backlight set to %d\n", level);
    }
}

bool Keyboard::setMode(KeyboardMode mode) {
    if (!_initialized || !_wire) return false;

    uint8_t cmd = (mode == KeyboardMode::RAW) ? KBCommands::CMD_MODE_RAW : KBCommands::CMD_MODE_NORMAL;

    _wire->beginTransmission(KB_I2C_ADDR);
    _wire->write(cmd);
    uint8_t error = _wire->endTransmission();

    if (error != 0) {
        Serial.printf("[Keyboard] Mode switch failed (error %d)\n", error);
        return false;
    }

    // Verify raw mode actually works by trying a test read
    if (mode == KeyboardMode::RAW) {
        delay(10);  // Give keyboard time to switch modes

        // Try to read matrix data
        _wire->requestFrom((uint8_t)KB_I2C_ADDR, (uint8_t)MATRIX_COLS);
        uint8_t available = _wire->available();

        // Drain any data
        while (_wire->available()) {
            _wire->read();
        }

        if (available == 0) {
            Serial.println("[Keyboard] Raw mode not supported by keyboard firmware");
            // The keyboard doesn't support raw mode - stay in normal mode
            _mode = KeyboardMode::NORMAL;
            return false;
        }
    }

    _mode = mode;

    // Clear cached matrix state when switching modes
    memset(_rawMatrix, 0, sizeof(_rawMatrix));

    return true;
}

bool Keyboard::readRawMatrix(uint8_t matrix[MATRIX_COLS]) {
    if (!_initialized || !_wire) return false;

    // Request data from keyboard
    _wire->requestFrom((uint8_t)KB_I2C_ADDR, (uint8_t)MATRIX_COLS);

    // Read whatever bytes are available, fill rest with zeros
    uint8_t available = _wire->available();
    if (available == 0) {
        return false;
    }

    for (uint8_t col = 0; col < MATRIX_COLS; col++) {
        if (col < available) {
            matrix[col] = _wire->read();
        } else {
            matrix[col] = 0;
        }
        _rawMatrix[col] = matrix[col];
    }

    return true;
}

bool Keyboard::isKeyPressed(uint8_t col, uint8_t row) {
    if (col >= MATRIX_COLS || row >= MATRIX_ROWS) return false;

    // Use cached matrix state
    return (_rawMatrix[col] & (1 << row)) != 0;
}

uint64_t Keyboard::getRawMatrixBits() {
    uint64_t bits = 0;

    // Read fresh matrix data
    uint8_t matrix[MATRIX_COLS];
    if (!readRawMatrix(matrix)) {
        return 0;
    }

    // Pack into 64-bit value: bits 0-6 = col 0, bits 7-13 = col 1, etc. (7 bits per column)
    for (uint8_t col = 0; col < MATRIX_COLS; col++) {
        bits |= ((uint64_t)(matrix[col] & 0x7F)) << (col * 7);
    }

    return bits;
}

void Keyboard::setTrackballMode(TrackballMode mode) {
    if (!_initialized || !_trackballFound) return;
    if (mode == _trackballMode) return;

    // Detach any existing interrupts first
    detachInterrupt(TRACKBALL_UP);
    detachInterrupt(TRACKBALL_DOWN);
    detachInterrupt(TRACKBALL_LEFT);
    detachInterrupt(TRACKBALL_RIGHT);
    detachInterrupt(TRACKBALL_CLICK);

    if (mode == TrackballMode::INTERRUPT_DRIVEN) {
        // Reset interrupt counters
        tb_int_up = 0;
        tb_int_down = 0;
        tb_int_left = 0;
        tb_int_right = 0;
        tb_int_click = false;

        // Attach interrupts (falling edge = button pressed, active low)
        attachInterrupt(digitalPinToInterrupt(TRACKBALL_UP), ISR_trackball_up, FALLING);
        attachInterrupt(digitalPinToInterrupt(TRACKBALL_DOWN), ISR_trackball_down, FALLING);
        attachInterrupt(digitalPinToInterrupt(TRACKBALL_LEFT), ISR_trackball_left, FALLING);
        attachInterrupt(digitalPinToInterrupt(TRACKBALL_RIGHT), ISR_trackball_right, FALLING);
        attachInterrupt(digitalPinToInterrupt(TRACKBALL_CLICK), ISR_trackball_click, FALLING);

        Serial.println("[Keyboard] Trackball mode: INTERRUPT");
    } else {
        // Polling mode - interrupts already detached above
        Serial.println("[Keyboard] Trackball mode: POLLING");
    }

    // Reset trackball accumulators
    _trackballX = 0;
    _trackballY = 0;

    _trackballMode = mode;
}
