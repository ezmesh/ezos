#include "remote_control.h"
#include "../hardware/keyboard.h"
#include "../hardware/display.h"
#include "../config.h"

// External references to hardware instances
extern Display* display;
extern Keyboard* keyboard;

RemoteControl& RemoteControl::instance() {
    static RemoteControl instance;
    return instance;
}

void RemoteControl::update() {
    // Check if we're waiting for a frame to be rendered
    if (_waitingForFrame) {
        if (display && display->hasFrameBeenFlushed()) {
            // Frame has been rendered, send the captured text
            static char jsonBuffer[8192];
            size_t len = display->getCapturedTextJSON(jsonBuffer, sizeof(jsonBuffer));
            display->setTextCaptureEnabled(false);
            sendResponse(RemoteStatus::OK, (const uint8_t*)jsonBuffer, len);
            _waitingForFrame = false;
        } else if (millis() - _frameWaitStart > FRAME_WAIT_TIMEOUT_MS) {
            // Timeout waiting for frame
            display->setTextCaptureEnabled(false);
            sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Timeout", 7);
            _waitingForFrame = false;
        }
        // Don't process new commands while waiting
        return;
    }

    // Process all available serial data
    while (Serial.available()) {
        uint8_t byte = Serial.read();

        switch (_state) {
            case State::WAIT_CMD:
                _cmd = byte;
                _state = State::WAIT_LEN1;
                break;

            case State::WAIT_LEN1:
                _payloadLen = byte;
                _state = State::WAIT_LEN2;
                break;

            case State::WAIT_LEN2:
                _payloadLen |= (uint16_t)byte << 8;
                if (_payloadLen == 0) {
                    // No payload, process command immediately
                    processCommand(_cmd, nullptr, 0);
                    _state = State::WAIT_CMD;
                } else if (_payloadLen > sizeof(_payload)) {
                    // Payload too large, send error and reset
                    sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Payload too large", 17);
                    _state = State::WAIT_CMD;
                } else {
                    _payloadPos = 0;
                    _state = State::WAIT_PAYLOAD;
                }
                break;

            case State::WAIT_PAYLOAD:
                _payload[_payloadPos++] = byte;
                if (_payloadPos >= _payloadLen) {
                    processCommand(_cmd, _payload, _payloadLen);
                    _state = State::WAIT_CMD;
                }
                break;
        }
    }
}

void RemoteControl::processCommand(uint8_t cmd, const uint8_t* payload, uint16_t len) {
    switch (cmd) {
        case RemoteCmd::PING:
            handlePing();
            break;

        case RemoteCmd::SCREENSHOT:
            handleScreenshot();
            break;

        case RemoteCmd::KEY_CHAR:
            if (len >= 2) {
                handleKeyChar(payload[0], payload[1]);
            } else {
                sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Invalid payload", 15);
            }
            break;

        case RemoteCmd::KEY_SPECIAL:
            if (len >= 2) {
                handleKeySpecial(payload[0], payload[1]);
            } else {
                sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Invalid payload", 15);
            }
            break;

        case RemoteCmd::SCREEN_INFO:
            handleScreenInfo();
            break;

        case RemoteCmd::WAIT_FRAME_TEXT:
            handleWaitFrameText();
            break;

        default:
            sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Unknown command", 15);
            break;
    }
}

void RemoteControl::sendResponse(uint8_t status, const uint8_t* data, uint16_t len) {
    // Send response header: [STATUS:1][LEN:2]
    Serial.write(status);
    Serial.write(len & 0xFF);
    Serial.write((len >> 8) & 0xFF);

    // Send payload
    if (len > 0 && data != nullptr) {
        Serial.write(data, len);
    }
}

void RemoteControl::handlePing() {
    const uint8_t pong[] = {'P', 'O', 'N', 'G'};
    sendResponse(RemoteStatus::OK, pong, 4);
}

void RemoteControl::handleScreenshot() {
    if (!display) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"No display", 10);
        return;
    }

    // Get RLE-compressed screenshot data
    size_t maxSize = 64 * 1024;  // 64KB buffer for RLE data
    uint8_t* buffer = (uint8_t*)malloc(maxSize);
    if (!buffer) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Out of memory", 13);
        return;
    }

    size_t size = display->getScreenshotRLE(buffer, maxSize);
    if (size == 0) {
        free(buffer);
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Screenshot failed", 17);
        return;
    }

    sendResponse(RemoteStatus::OK, buffer, size);
    free(buffer);
}

void RemoteControl::handleKeyChar(uint8_t ch, uint8_t modifiers) {
    if (!keyboard) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"No keyboard", 11);
        return;
    }

    // Create key event with modifiers
    bool shift = (modifiers & RemoteModifier::SHIFT) != 0;
    bool ctrl = (modifiers & RemoteModifier::CTRL) != 0;
    bool alt = (modifiers & RemoteModifier::ALT) != 0;
    bool fn = (modifiers & RemoteModifier::FN) != 0;

    KeyEvent event = KeyEvent::fromChar((char)ch, shift, ctrl, alt, fn);
    keyboard->injectEvent(event);

    sendResponse(RemoteStatus::OK, nullptr, 0);
}

void RemoteControl::handleKeySpecial(uint8_t special, uint8_t modifiers) {
    if (!keyboard) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"No keyboard", 11);
        return;
    }

    // Map remote special key code to SpecialKey enum
    SpecialKey key = SpecialKey::NONE;
    switch (special) {
        case RemoteSpecialKey::UP:        key = SpecialKey::UP; break;
        case RemoteSpecialKey::DOWN:      key = SpecialKey::DOWN; break;
        case RemoteSpecialKey::LEFT:      key = SpecialKey::LEFT; break;
        case RemoteSpecialKey::RIGHT:     key = SpecialKey::RIGHT; break;
        case RemoteSpecialKey::ENTER:     key = SpecialKey::ENTER; break;
        case RemoteSpecialKey::ESCAPE:    key = SpecialKey::ESCAPE; break;
        case RemoteSpecialKey::TAB:       key = SpecialKey::TAB; break;
        case RemoteSpecialKey::BACKSPACE: key = SpecialKey::BACKSPACE; break;
        case RemoteSpecialKey::DELETE_KEY: key = SpecialKey::DELETE; break;
        case RemoteSpecialKey::HOME:      key = SpecialKey::HOME; break;
        case RemoteSpecialKey::END:       key = SpecialKey::END; break;
        default:
            sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Unknown key", 11);
            return;
    }

    bool shift = (modifiers & RemoteModifier::SHIFT) != 0;
    bool ctrl = (modifiers & RemoteModifier::CTRL) != 0;
    bool alt = (modifiers & RemoteModifier::ALT) != 0;
    bool fn = (modifiers & RemoteModifier::FN) != 0;

    KeyEvent event = KeyEvent::fromSpecial(key, shift, ctrl, alt, fn);
    keyboard->injectEvent(event);

    sendResponse(RemoteStatus::OK, nullptr, 0);
}

void RemoteControl::handleScreenInfo() {
    if (!display) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"No display", 10);
        return;
    }

    // Build JSON response with screen info
    char json[128];
    int len = snprintf(json, sizeof(json),
        "{\"width\":%d,\"height\":%d,\"cols\":%d,\"rows\":%d}",
        display->getWidth(),
        display->getHeight(),
        display->getCols(),
        display->getRows()
    );

    sendResponse(RemoteStatus::OK, (const uint8_t*)json, len);
}

void RemoteControl::handleWaitFrameText() {
    if (!display) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"No display", 10);
        return;
    }

    // Enable text capture and wait for next frame
    display->setTextCaptureEnabled(true);
    _waitingForFrame = true;
    _frameWaitStart = millis();
    // Response will be sent when frame is flushed (in update())
}
