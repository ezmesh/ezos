#include "remote_control.h"
#include "../hardware/keyboard.h"
#include "../hardware/display.h"
#include "../lua/lua_runtime.h"
#include "../config.h"
#include <lua.hpp>

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
            // Frame has been rendered, send the captured data
            static char jsonBuffer[32768];  // Larger buffer for primitives
            size_t len = 0;

            if (_captureMode == CaptureMode::TEXT) {
                len = display->getCapturedTextJSON(jsonBuffer, sizeof(jsonBuffer));
                display->setTextCaptureEnabled(false);
            } else if (_captureMode == CaptureMode::PRIMITIVES) {
                len = display->getCapturedPrimitivesJSON(jsonBuffer, sizeof(jsonBuffer));
                display->setPrimitiveCaptureEnabled(false);
            }

            sendResponse(RemoteStatus::OK, (const uint8_t*)jsonBuffer, len);
            _waitingForFrame = false;
            _captureMode = CaptureMode::NONE;
        } else if (millis() - _frameWaitStart > FRAME_WAIT_TIMEOUT_MS) {
            // Timeout waiting for frame
            if (_captureMode == CaptureMode::TEXT) {
                display->setTextCaptureEnabled(false);
            } else if (_captureMode == CaptureMode::PRIMITIVES) {
                display->setPrimitiveCaptureEnabled(false);
            }
            sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Timeout", 7);
            _waitingForFrame = false;
            _captureMode = CaptureMode::NONE;
        }
        // Don't process new commands while waiting
        return;
    }

    // Timeout incomplete commands to prevent state machine corruption from noise/garbage
    if (_state != State::WAIT_CMD && millis() - _lastByteTime > CMD_TIMEOUT_MS) {
        _state = State::WAIT_CMD;
    }

    // Process all available serial data
    while (Serial.available()) {
        uint8_t byte = Serial.read();
        _lastByteTime = millis();

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

        case RemoteCmd::WAIT_FRAME_PRIMITIVES:
            handleWaitFramePrimitives();
            break;

        case RemoteCmd::LUA_EXEC:
            handleLuaExec(payload, len);
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
    _captureMode = CaptureMode::TEXT;
    _waitingForFrame = true;
    _frameWaitStart = millis();
    // Response will be sent when frame is flushed (in update())
}

void RemoteControl::handleWaitFramePrimitives() {
    if (!display) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"No display", 10);
        return;
    }

    // Enable primitive capture and wait for next frame
    display->setPrimitiveCaptureEnabled(true);
    _captureMode = CaptureMode::PRIMITIVES;
    _waitingForFrame = true;
    _frameWaitStart = millis();
    // Response will be sent when frame is flushed (in update())
}

// Forward declaration for recursive table serialization
static size_t serializeLuaValue(lua_State* L, int index, char* buf, size_t maxSize, int depth);

static size_t serializeLuaTable(lua_State* L, int index, char* buf, size_t maxSize, int depth) {
    if (depth > 5) {
        return snprintf(buf, maxSize, "\"<nested>\"");
    }

    size_t pos = 0;

    // Check if array-like (sequential integer keys starting at 1)
    bool isArray = true;
    int arrayLen = 0;

    lua_pushnil(L);
    while (lua_next(L, index) != 0) {
        if (!lua_isinteger(L, -2)) {
            isArray = false;
            lua_pop(L, 2);
            break;
        }
        lua_Integer key = lua_tointeger(L, -2);
        if (key != arrayLen + 1) {
            isArray = false;
            lua_pop(L, 2);
            break;
        }
        arrayLen++;
        lua_pop(L, 1);
    }

    if (isArray && arrayLen > 0) {
        buf[pos++] = '[';
        for (int i = 1; i <= arrayLen && pos < maxSize - 50; i++) {
            if (i > 1) buf[pos++] = ',';
            lua_rawgeti(L, index, i);
            pos += serializeLuaValue(L, lua_gettop(L), buf + pos, maxSize - pos, depth + 1);
            lua_pop(L, 1);
        }
        buf[pos++] = ']';
    } else {
        buf[pos++] = '{';
        bool first = true;

        lua_pushnil(L);
        while (lua_next(L, index) != 0 && pos < maxSize - 100) {
            if (!first) buf[pos++] = ',';
            first = false;

            // Key (convert to string)
            buf[pos++] = '"';
            if (lua_type(L, -2) == LUA_TSTRING) {
                const char* key = lua_tostring(L, -2);
                while (*key && pos < maxSize - 50) {
                    buf[pos++] = *key++;
                }
            } else if (lua_isinteger(L, -2)) {
                pos += snprintf(buf + pos, maxSize - pos, "%lld", (long long)lua_tointeger(L, -2));
            }
            buf[pos++] = '"';
            buf[pos++] = ':';

            // Value
            pos += serializeLuaValue(L, lua_gettop(L), buf + pos, maxSize - pos, depth + 1);
            lua_pop(L, 1);
        }
        buf[pos++] = '}';
    }

    return pos;
}

static size_t serializeLuaValue(lua_State* L, int index, char* buf, size_t maxSize, int depth) {
    size_t pos = 0;

    int type = lua_type(L, index);
    switch (type) {
        case LUA_TNIL:
            pos = snprintf(buf, maxSize, "null");
            break;

        case LUA_TBOOLEAN:
            pos = snprintf(buf, maxSize, lua_toboolean(L, index) ? "true" : "false");
            break;

        case LUA_TNUMBER:
            if (lua_isinteger(L, index)) {
                pos = snprintf(buf, maxSize, "%lld", (long long)lua_tointeger(L, index));
            } else {
                pos = snprintf(buf, maxSize, "%g", lua_tonumber(L, index));
            }
            break;

        case LUA_TSTRING: {
            const char* str = lua_tostring(L, index);
            buf[pos++] = '"';
            while (*str && pos < maxSize - 10) {
                char c = *str++;
                if (c == '"' || c == '\\') {
                    buf[pos++] = '\\';
                    buf[pos++] = c;
                } else if (c == '\n') {
                    buf[pos++] = '\\';
                    buf[pos++] = 'n';
                } else if (c == '\r') {
                    buf[pos++] = '\\';
                    buf[pos++] = 'r';
                } else if (c == '\t') {
                    buf[pos++] = '\\';
                    buf[pos++] = 't';
                } else if ((unsigned char)c < 32) {
                    pos += snprintf(buf + pos, maxSize - pos, "\\u%04x", (unsigned char)c);
                } else {
                    buf[pos++] = c;
                }
            }
            buf[pos++] = '"';
            break;
        }

        case LUA_TTABLE:
            pos = serializeLuaTable(L, index, buf, maxSize, depth);
            break;

        case LUA_TFUNCTION:
            pos = snprintf(buf, maxSize, "\"<function>\"");
            break;

        default:
            pos = snprintf(buf, maxSize, "\"<%s>\"", lua_typename(L, type));
            break;
    }

    return pos;
}

void RemoteControl::handleLuaExec(const uint8_t* code, uint16_t len) {
    LuaRuntime& lua = LuaRuntime::instance();

    if (!lua.isInitialized()) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Lua not initialized", 19);
        return;
    }

    if (len == 0) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Empty code", 10);
        return;
    }

    lua_State* L = lua.getState();

    // Load the code as a chunk with "return " prefix to capture expression results
    // First try as expression (return <code>), then as statement
    String wrappedCode = "return " + String((const char*)code, len);

    int loadResult = luaL_loadbuffer(L, wrappedCode.c_str(), wrappedCode.length(), "=remote");
    if (loadResult != LUA_OK) {
        // Expression failed, try as raw statement
        lua_pop(L, 1);
        loadResult = luaL_loadbuffer(L, (const char*)code, len, "=remote");
    }

    if (loadResult != LUA_OK) {
        // Compilation error
        const char* err = lua_tostring(L, -1);
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)err, strlen(err));
        lua_pop(L, 1);
        return;
    }

    // Execute the chunk
    int callResult = lua_pcall(L, 0, LUA_MULTRET, 0);

    if (callResult != LUA_OK) {
        // Runtime error
        const char* err = lua_tostring(L, -1);
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)err, strlen(err));
        lua_pop(L, 1);
        return;
    }

    // Convert result(s) to JSON
    int nresults = lua_gettop(L);

    if (nresults == 0) {
        // No return value
        sendResponse(RemoteStatus::OK, (const uint8_t*)"null", 4);
        return;
    }

    // Build JSON result (single value or array for multiple)
    static char resultBuf[4096];
    size_t pos = 0;

    if (nresults > 1) {
        resultBuf[pos++] = '[';
    }

    for (int i = 1; i <= nresults && pos < sizeof(resultBuf) - 100; i++) {
        if (i > 1) {
            resultBuf[pos++] = ',';
        }
        pos += serializeLuaValue(L, i, resultBuf + pos, sizeof(resultBuf) - pos, 0);
    }

    if (nresults > 1) {
        resultBuf[pos++] = ']';
    }

    lua_pop(L, nresults);
    sendResponse(RemoteStatus::OK, (const uint8_t*)resultBuf, pos);
}
