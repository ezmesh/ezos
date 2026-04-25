#include "remote_control.h"
#include "../hardware/keyboard.h"
#include "../hardware/display.h"
#include "../lua/lua_runtime.h"
#include "../config.h"
#include <lua.hpp>
#include <LittleFS.h>

// Miniz deflate compressor from LovyanGFX
extern "C" size_t tdefl_compress_mem_to_mem(
    void *pOut_buf, size_t out_buf_len,
    const void *pSrc_buf, size_t src_buf_len, int flags);

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
            // Timeout waiting for frame - no Lua rendering loop is active
            if (_captureMode == CaptureMode::TEXT) {
                display->setTextCaptureEnabled(false);
            } else if (_captureMode == CaptureMode::PRIMITIVES) {
                display->setPrimitiveCaptureEnabled(false);
            }

            // If there's a boot error, return it instead of a generic timeout
            const char* lastError = LuaRuntime::instance().getLastError();
            if (lastError && lastError[0] != '\0') {
                // Build a JSON response with the escaped error string
                static char errJson[2048];
                size_t pos = 0;
                const char* prefix = "[{\"x\":0,\"y\":0,\"color\":63488,\"text\":\"Boot script failed!\"},{\"x\":0,\"y\":20,\"color\":65535,\"text\":\"";
                size_t prefixLen = strlen(prefix);
                memcpy(errJson, prefix, prefixLen);
                pos = prefixLen;

                // JSON-escape the error message
                for (const char* p = lastError; *p && pos < sizeof(errJson) - 10; p++) {
                    char c = *p;
                    if (c == '"' || c == '\\') {
                        errJson[pos++] = '\\';
                        errJson[pos++] = c;
                    } else if (c == '\n') {
                        errJson[pos++] = '\\';
                        errJson[pos++] = 'n';
                    } else if (c == '\r') {
                        errJson[pos++] = '\\';
                        errJson[pos++] = 'r';
                    } else if (c == '\t') {
                        errJson[pos++] = '\\';
                        errJson[pos++] = 't';
                    } else {
                        errJson[pos++] = c;
                    }
                }

                const char* suffix = "\"}]";
                memcpy(errJson + pos, suffix, 3);
                pos += 3;

                sendResponse(RemoteStatus::OK, (const uint8_t*)errJson, pos);
            } else {
                sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Timeout", 7);
            }
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

        case RemoteCmd::WRITE_FILE:
            handleFileWrite(payload, len);
            break;

        case RemoteCmd::READ_FILE:
            handleFileRead(payload, len);
            break;

        case RemoteCmd::WRITE_AT:
            handleWriteAt(payload, len);
            break;

        default:
            sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Unknown command", 15);
            break;
    }
}

void RemoteControl::sendResponse(uint8_t status, const uint8_t* data, uint32_t len) {
    // Response header: [STATUS:1][LEN:4] (little-endian)
    Serial.write(status);
    Serial.write(len & 0xFF);
    Serial.write((len >> 8) & 0xFF);
    Serial.write((len >> 16) & 0xFF);
    Serial.write((len >> 24) & 0xFF);

    // Send payload in chunks to avoid serial buffer overflows
    if (len > 0 && data != nullptr) {
        size_t sent = 0;
        while (sent < len) {
            size_t chunk = min((size_t)512, len - sent);
            Serial.write(data + sent, chunk);
            sent += chunk;
            Serial.flush();  // Wait for chunk to transmit
        }
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

    int w = display->getWidth();
    int h = display->getHeight();

    // Build BMP file in PSRAM: header (54 bytes) + pixel data (w*h*3 bytes, bottom-up)
    size_t rowBytes = w * 3;
    // BMP rows are padded to 4-byte boundaries
    size_t rowPadded = (rowBytes + 3) & ~3;
    size_t pixelDataSize = rowPadded * h;
    size_t fileSize = 54 + pixelDataSize;

    uint8_t* bmp = (uint8_t*)ps_malloc(fileSize);
    if (!bmp) bmp = (uint8_t*)malloc(fileSize);
    if (!bmp) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Out of memory", 13);
        return;
    }
    memset(bmp, 0, 54);

    // BMP header
    bmp[0] = 'B'; bmp[1] = 'M';
    *(uint32_t*)(bmp + 2) = fileSize;
    *(uint32_t*)(bmp + 10) = 54;  // pixel data offset
    // DIB header (BITMAPINFOHEADER)
    *(uint32_t*)(bmp + 14) = 40;  // header size
    *(int32_t*)(bmp + 18) = w;
    *(int32_t*)(bmp + 22) = h;    // positive = bottom-up
    *(uint16_t*)(bmp + 26) = 1;   // planes
    *(uint16_t*)(bmp + 28) = 24;  // bits per pixel
    *(uint32_t*)(bmp + 34) = pixelDataSize;

    // Convert RGB565 framebuffer to BGR888 (BMP uses BGR, bottom-up row order)
    for (int y = 0; y < h; y++) {
        uint8_t* row = bmp + 54 + (h - 1 - y) * rowPadded;  // bottom-up
        for (int x = 0; x < w; x++) {
            uint16_t color = display->getBuffer().readPixel(x, y);
            uint8_t r = ((color >> 11) & 0x1F) << 3; r |= r >> 5;
            uint8_t g = ((color >> 5) & 0x3F) << 2;  g |= g >> 6;
            uint8_t b = (color & 0x1F) << 3;          b |= b >> 5;
            row[x * 3]     = b;  // BMP stores BGR
            row[x * 3 + 1] = g;
            row[x * 3 + 2] = r;
        }
    }

    sendResponse(RemoteStatus::OK, bmp, fileSize);
    free(bmp);
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

void RemoteControl::handleFileWrite(const uint8_t* payload, uint16_t len) {
    // Payload: [path_len:2 LE][path:path_len][file_data:remaining]
    // Path uses /fs/ prefix which maps to LittleFS root.
    if (len < 3) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Payload too short", 17);
        return;
    }

    uint16_t pathLen = payload[0] | ((uint16_t)payload[1] << 8);
    if (pathLen == 0 || pathLen > 256 || 2 + pathLen > len) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Invalid path length", 19);
        return;
    }

    char rawPath[257];
    memcpy(rawPath, payload + 2, pathLen);
    rawPath[pathLen] = '\0';

    // Strip /fs prefix to get the LittleFS-relative path
    const char* fsPath = rawPath;
    if (strncmp(rawPath, "/fs/", 4) == 0) {
        fsPath = rawPath + 3;  // "/fs/foo/bar" -> "/foo/bar"
    }

    const uint8_t* fileData = payload + 2 + pathLen;
    uint16_t dataLen = len - 2 - pathLen;

    // Create parent directories
    String pathStr(fsPath);
    for (int i = 1; i < (int)pathStr.length(); i++) {
        if (pathStr[i] == '/') {
            String dir = pathStr.substring(0, i);
            if (!LittleFS.exists(dir)) {
                LittleFS.mkdir(dir);
            }
        }
    }

    // Write file to LittleFS
    auto f = LittleFS.open(fsPath, "w");
    if (!f) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Cannot open file", 16);
        return;
    }

    size_t written = f.write(fileData, dataLen);
    f.close();

    char resp[32];
    int respLen = snprintf(resp, sizeof(resp), "%u", (unsigned)written);
    sendResponse(RemoteStatus::OK, (const uint8_t*)resp, respLen);
}

void RemoteControl::handleFileRead(const uint8_t* payload, uint16_t len) {
    // Payload: [path_len:2 LE][path][offset:4 LE][length:4 LE]
    if (len < 10) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Payload too short", 17);
        return;
    }

    uint16_t pathLen = payload[0] | ((uint16_t)payload[1] << 8);
    if (pathLen == 0 || pathLen > 256 || 2 + pathLen + 8 > len) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Invalid path", 12);
        return;
    }

    char rawPath[257];
    memcpy(rawPath, payload + 2, pathLen);
    rawPath[pathLen] = '\0';

    const char* fsPath = rawPath;
    if (strncmp(rawPath, "/fs/", 4) == 0) fsPath = rawPath + 3;

    const uint8_t* meta = payload + 2 + pathLen;
    uint32_t offset = meta[0] | (meta[1] << 8) | (meta[2] << 16) | (meta[3] << 24);
    uint32_t readLen = meta[4] | (meta[5] << 8) | (meta[6] << 16) | (meta[7] << 24);

    // Cap read to payload buffer size
    if (readLen > sizeof(_payload)) readLen = sizeof(_payload);

    auto f = LittleFS.open(fsPath, "r");
    if (!f) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"File not found", 14);
        return;
    }

    if (offset > 0) f.seek(offset);
    size_t got = f.read(_payload, readLen);
    f.close();

    sendResponse(RemoteStatus::OK, _payload, got);
}

void RemoteControl::handleWriteAt(const uint8_t* payload, uint16_t len) {
    // Payload: [path_len:2 LE][path][offset:4 LE][data]
    if (len < 7) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Payload too short", 17);
        return;
    }

    uint16_t pathLen = payload[0] | ((uint16_t)payload[1] << 8);
    if (pathLen == 0 || pathLen > 256 || 2 + pathLen + 4 > len) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Invalid path", 12);
        return;
    }

    char rawPath[257];
    memcpy(rawPath, payload + 2, pathLen);
    rawPath[pathLen] = '\0';

    const char* fsPath = rawPath;
    if (strncmp(rawPath, "/fs/", 4) == 0) fsPath = rawPath + 3;

    const uint8_t* meta = payload + 2 + pathLen;
    uint32_t offset = meta[0] | (meta[1] << 8) | (meta[2] << 16) | (meta[3] << 24);

    const uint8_t* fileData = meta + 4;
    uint16_t dataLen = len - 2 - pathLen - 4;

    // Open for read+write without truncating
    auto f = LittleFS.open(fsPath, "r+");
    if (!f) {
        sendResponse(RemoteStatus::ERROR, (const uint8_t*)"Cannot open file", 16);
        return;
    }

    f.seek(offset);
    size_t written = f.write(fileData, dataLen);
    f.close();

    char resp[32];
    int respLen = snprintf(resp, sizeof(resp), "%u", (unsigned)written);
    sendResponse(RemoteStatus::OK, (const uint8_t*)resp, respLen);
}
