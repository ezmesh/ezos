#include "keyboard.h"
#include "keyboard_matrix.h"
#include <Arduino.h>
#include <cstring>

// Set to 1 to enable verbose keyboard debug logging
#define KB_DEBUG 0

#if KB_DEBUG
#define KB_LOG(...) Serial.printf(__VA_ARGS__)
#else
#define KB_LOG(...) ((void)0)
#endif

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

Keyboard::Keyboard() : _wire(nullptr) {}

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

    // Raw-matrix mode is engaged from boot.lua after services come up —
    // the C3 tends to NAK the mode-switch command this early after cold
    // boot. Until that call lands we stay in NORMAL mode and read()
    // returns nothing useful from the keyboard (trackball still works).
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

bool Keyboard::hasKeyActivity() const {
    // Check keyboard interrupt pin for activity
    // Note: KB_INT (GPIO 46) seems to always be LOW on T-Deck Plus, so we skip it
    // Only check trackball pins as wake sources
    bool tbClick = (digitalRead(TRACKBALL_CLICK) == LOW);
    bool tbUp = (digitalRead(TRACKBALL_UP) == LOW);
    bool tbDown = (digitalRead(TRACKBALL_DOWN) == LOW);
    bool tbLeft = (digitalRead(TRACKBALL_LEFT) == LOW);
    bool tbRight = (digitalRead(TRACKBALL_RIGHT) == LOW);

    return tbClick || tbUp || tbDown || tbLeft || tbRight;
}

KeyEvent Keyboard::read() {
    if (!_initialized) {
        return KeyEvent::invalid();
    }

    // Remote-control injections (from the USB protocol) take precedence.
    if (_injectTail != _injectHead) {
        KeyEvent event = _injectQueue[_injectTail];
        _injectTail = (_injectTail + 1) % INJECT_QUEUE_SIZE;
        return event;
    }

    // Drain any events queued from the previous matrix scan before
    // sampling again — a chord press produces multiple rising edges in
    // a single scan and we only return one per read() call.
    KeyEvent queued;
    if (popEvent(queued)) return queued;

    // Scan the matrix for new edges when we're actually in raw mode.
    // If the keyboard firmware didn't accept raw mode at boot we fall
    // through to trackball handling only — character input is unavail-
    // able in that case, which is noisy but self-healing after a
    // re-flash of the C3.
    if (_mode == KeyboardMode::RAW) {
        scanMatrix();
        if (popEvent(queued)) return queued;
    }

    // Trackball handling - supports both polling and interrupt modes
    uint32_t now = millis();

    // Click is debounced via direct GPIO polling in BOTH modes. On some T-Decks
    // the click pin gets stuck LOW or bounces, and the raw ISR flag fires ENTER
    // multiple times (opens+closes menus). Holding for >=30ms and re-asserting
    // INPUT_PULLUP while held matches the original polling-only fix.
    static bool clickHeld = false;
    static uint32_t clickStartTime = 0;
    static bool clickFired = false;

    bool click = (digitalRead(TRACKBALL_CLICK) == LOW);
    bool clickEvent = false;
    if (click) {
        pinMode(TRACKBALL_CLICK, INPUT_PULLUP);
        if (!clickHeld) {
            clickHeld = true;
            clickStartTime = now;
            clickFired = false;
        } else if (!clickFired && (now - clickStartTime) >= 30) {
            clickFired = true;
            clickEvent = true;
        }
    } else {
        clickHeld = false;
        clickFired = false;
    }

    if (_trackballMode == TrackballMode::INTERRUPT_DRIVEN) {
        // Interrupt mode: read from volatile counters set by ISRs
        // Atomically read and reset counters
        noInterrupts();
        int16_t intUp = tb_int_up;
        int16_t intDown = tb_int_down;
        int16_t intLeft = tb_int_left;
        int16_t intRight = tb_int_right;
        tb_int_up = 0;
        tb_int_down = 0;
        tb_int_left = 0;
        tb_int_right = 0;
        interrupts();

        if (clickEvent) {
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

        bool up = (digitalRead(TRACKBALL_UP) == LOW);
        bool down = (digitalRead(TRACKBALL_DOWN) == LOW);
        bool left = (digitalRead(TRACKBALL_LEFT) == LOW);
        bool right = (digitalRead(TRACKBALL_RIGHT) == LOW);

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

        if (clickEvent) {
            return KeyEvent::fromSpecial(SpecialKey::ENTER, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
        }

        // Accumulate trackball movement (only on edges)
        if (upEdge) _trackballY--;
        if (downEdge) _trackballY++;
        if (leftEdge) _trackballX--;
        if (rightEdge) _trackballX++;
    }

    // Generate directional keys when threshold reached
    if (_trackballY <= -_trackballThreshold) {
        _trackballY = 0;
        return KeyEvent::fromSpecial(SpecialKey::UP, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballY >= _trackballThreshold) {
        _trackballY = 0;
        return KeyEvent::fromSpecial(SpecialKey::DOWN, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballX <= -_trackballThreshold) {
        _trackballX = 0;
        return KeyEvent::fromSpecial(SpecialKey::LEFT, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballX >= _trackballThreshold) {
        _trackballX = 0;
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

    // Generate key events when threshold is reached
    if (_trackballY <= -_trackballThreshold) {
        _trackballY = 0;
        _trackballX = 0;
        return KeyEvent::fromSpecial(SpecialKey::UP, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballY >= _trackballThreshold) {
        _trackballY = 0;
        _trackballX = 0;
        return KeyEvent::fromSpecial(SpecialKey::DOWN, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballX <= -_trackballThreshold) {
        _trackballX = 0;
        _trackballY = 0;
        return KeyEvent::fromSpecial(SpecialKey::LEFT, _shiftHeld, _ctrlHeld, _altHeld, _fnHeld);
    }
    if (_trackballX >= _trackballThreshold) {
        _trackballX = 0;
        _trackballY = 0;
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
    KB_LOG("Modifier: code=0x%02X pressed=%d\n", code, pressed);
    switch (code) {
        case KeyCodes::KEY_SHIFT:
            _shiftHeld = pressed;
            break;
        case KeyCodes::KEY_CTRL:
            _ctrlHeld = pressed;
            break;
        case KeyCodes::KEY_ALT:
            _altHeld = pressed;
            break;
        case KeyCodes::KEY_FN:
            _fnHeld = pressed;
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

    // Issue the mode-switch command and trust the keyboard to honour
    // it. We used to do a verify read here, but the C3's first post-
    // switch read sometimes returns only partial bytes (it was still
    // finishing the mode change), and treating that as failure left
    // the host stuck in NORMAL even though the C3 had actually moved
    // to RAW. Scans that happen before the C3 is truly ready just
    // return no edges — the next scan self-heals.
    _wire->beginTransmission(KB_I2C_ADDR);
    _wire->write(cmd);
    uint8_t error = _wire->endTransmission();
    if (error != 0) {
        Serial.printf("[Keyboard] Mode switch wire error %d\n", error);
        return false;
    }

    _mode = mode;
    memset(_rawMatrix, 0, sizeof(_rawMatrix));
    memset(_prevMatrix, 0, sizeof(_prevMatrix));

    // Short settling delay so the first caller-initiated read after
    // this doesn't race with the C3's mode swap.
    delay(10);
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

    if (mode == TrackballMode::INTERRUPT_DRIVEN) {
        // Reset interrupt counters
        tb_int_up = 0;
        tb_int_down = 0;
        tb_int_left = 0;
        tb_int_right = 0;
        tb_int_click = false;

        // Attach directional interrupts only. Click is handled via debounced
        // polling in both modes because the stuck-pin workaround re-asserts
        // INPUT_PULLUP, which would disable an attached interrupt on ESP32.
        attachInterrupt(digitalPinToInterrupt(TRACKBALL_UP), ISR_trackball_up, FALLING);
        attachInterrupt(digitalPinToInterrupt(TRACKBALL_DOWN), ISR_trackball_down, FALLING);
        attachInterrupt(digitalPinToInterrupt(TRACKBALL_LEFT), ISR_trackball_left, FALLING);
        attachInterrupt(digitalPinToInterrupt(TRACKBALL_RIGHT), ISR_trackball_right, FALLING);

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

// ---------------------------------------------------------------------------
// Matrix-based key scanner.
// ---------------------------------------------------------------------------
//
// Runs every read() that finds the event queue empty. Samples the 5-byte
// matrix, diffs against _prevMatrix to find rising edges, looks each edge
// up in the keymap (applying Shift/Sym layer as needed), and queues a
// KeyEvent per press. Modifier bits update state only — they don't emit
// their own events.

// Build a KeyEvent for the character or special key at (col, row) given
// the current modifier/layer state. Returns an invalid event if the
// position is a modifier or unused.
static KeyEvent eventForPosition(uint8_t col, uint8_t row,
                                 bool shift, bool alt, bool sym,
                                 bool ctrl, bool fn) {
    if (kb_matrix::isModifierPosition(col, row)) return KeyEvent::invalid();
    if (col == kb_matrix::ENTER_COL && row == kb_matrix::ENTER_ROW)
        return KeyEvent::fromSpecial(SpecialKey::ENTER, shift, ctrl, alt, fn);
    if (col == kb_matrix::BACKSPACE_COL && row == kb_matrix::BACKSPACE_ROW)
        return KeyEvent::fromSpecial(SpecialKey::BACKSPACE, shift, ctrl, alt, fn);
    char c = sym ? kb_matrix::SYM[col][row] : kb_matrix::BASE[col][row];
    if (!c) return KeyEvent::invalid();
    if (shift && c >= 'a' && c <= 'z') c = c - 'a' + 'A';
    return KeyEvent::fromChar(c, shift, ctrl, alt, fn);
}

void Keyboard::scanMatrix() {
    uint8_t matrix[MATRIX_COLS];
    if (!readRawMatrix(matrix)) return;

    // Track modifier / layer state from the freshly-sampled bits.
    bool shift = (matrix[kb_matrix::SHIFT1_COL] & (1 << kb_matrix::SHIFT1_ROW)) != 0
              || (matrix[kb_matrix::SHIFT2_COL] & (1 << kb_matrix::SHIFT2_ROW)) != 0;
    bool alt   = (matrix[kb_matrix::ALT_COL]    & (1 << kb_matrix::ALT_ROW))    != 0;
    bool sym   = (matrix[kb_matrix::SYM_COL]    & (1 << kb_matrix::SYM_ROW))    != 0;
    _shiftHeld = shift;
    _altHeld   = alt;
    _symHeld   = sym;

    // Rising-edge bits per column: new AND NOT previous.
    for (uint8_t col = 0; col < kb_matrix::COLS; col++) {
        uint8_t rising = matrix[col] & ~_prevMatrix[col];
        if (rising == 0) continue;

        for (uint8_t row = 0; row < kb_matrix::ROWS; row++) {
            if ((rising & (1 << row)) == 0) continue;
            KeyEvent evt = eventForPosition(col, row, shift, alt, sym,
                                            _ctrlHeld, _fnHeld);
            if (!evt.valid) continue;
            pushEvent(evt);

            // Start/replace repeat tracking with this key.
            _heldCol         = col;
            _heldRow         = row;
            _heldPressTime   = millis();
            _heldLastRepeat  = _heldPressTime;
            _heldRepeating   = false;
        }
    }

    // Repeat: if the tracked key is still down, fire synthetic press
    // events on the delay/rate schedule. If it's released, drop tracking.
    if (_heldCol >= 0) {
        bool stillHeld = (matrix[_heldCol] & (1 << _heldRow)) != 0;
        if (!stillHeld) {
            _heldCol = -1;
            _heldRepeating = false;
        } else if (_keyRepeatEnabled) {
            uint32_t now = millis();
            if (!_heldRepeating) {
                if (now - _heldPressTime >= _keyRepeatDelay) {
                    _heldRepeating = true;
                    _heldLastRepeat = now;
                    pushEvent(eventForPosition(_heldCol, _heldRow,
                                               shift, alt, sym,
                                               _ctrlHeld, _fnHeld));
                }
            } else if (now - _heldLastRepeat >= _keyRepeatRate) {
                _heldLastRepeat = now;
                pushEvent(eventForPosition(_heldCol, _heldRow,
                                           shift, alt, sym,
                                           _ctrlHeld, _fnHeld));
            }
        }
    }

    // Snapshot for next scan.
    memcpy(_prevMatrix, matrix, kb_matrix::COLS);
}

bool Keyboard::pushEvent(const KeyEvent& e) {
    uint8_t next = (_eventHead + 1) % MATRIX_EVENT_QUEUE;
    if (next == _eventTail) return false;  // queue full — drop
    _eventQueue[_eventHead] = e;
    _eventHead = next;
    return true;
}

bool Keyboard::popEvent(KeyEvent& out) {
    if (_eventTail == _eventHead) return false;
    out = _eventQueue[_eventTail];
    _eventTail = (_eventTail + 1) % MATRIX_EVENT_QUEUE;
    return true;
}

bool Keyboard::isHeld(char c) {
    // Find the character's matrix position in either layer. Case-insensitive
    // for alpha keys so is_held('w') and is_held('W') both work.
    char lc = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    for (uint8_t col = 0; col < kb_matrix::COLS; col++) {
        for (uint8_t row = 0; row < kb_matrix::ROWS; row++) {
            char k = kb_matrix::BASE[col][row];
            if (!k) k = kb_matrix::SYM[col][row];
            if (k && k == lc) {
                return (_prevMatrix[col] & (1 << row)) != 0;
            }
        }
    }
    return false;
}
