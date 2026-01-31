#pragma once

#include <Arduino.h>
#include <cstdint>

// Remote control protocol commands
namespace RemoteCmd {
    constexpr uint8_t PING = 0x01;
    constexpr uint8_t SCREENSHOT = 0x02;
    constexpr uint8_t KEY_CHAR = 0x03;
    constexpr uint8_t KEY_SPECIAL = 0x04;
    constexpr uint8_t SCREEN_INFO = 0x05;
    constexpr uint8_t WAIT_FRAME_TEXT = 0x06;       // Wait for frame and return rendered text
    constexpr uint8_t LUA_EXEC = 0x07;              // Execute Lua code and return result
    constexpr uint8_t WAIT_FRAME_PRIMITIVES = 0x08; // Wait for frame and return draw primitives
}

// Response status codes
namespace RemoteStatus {
    constexpr uint8_t OK = 0x00;
    constexpr uint8_t ERROR = 0x01;
}

// Special key codes for remote control (matching protocol spec)
namespace RemoteSpecialKey {
    constexpr uint8_t UP = 0x01;
    constexpr uint8_t DOWN = 0x02;
    constexpr uint8_t LEFT = 0x03;
    constexpr uint8_t RIGHT = 0x04;
    constexpr uint8_t ENTER = 0x05;
    constexpr uint8_t ESCAPE = 0x06;
    constexpr uint8_t TAB = 0x07;
    constexpr uint8_t BACKSPACE = 0x08;
    constexpr uint8_t DELETE_KEY = 0x09;
    constexpr uint8_t HOME = 0x0A;
    constexpr uint8_t END = 0x0B;
}

// Modifier bit flags
namespace RemoteModifier {
    constexpr uint8_t SHIFT = 0x01;
    constexpr uint8_t CTRL = 0x02;
    constexpr uint8_t ALT = 0x04;
    constexpr uint8_t FN = 0x08;
}

class RemoteControl {
public:
    static RemoteControl& instance();

    // Called from main loop to process incoming serial commands
    void update();

private:
    RemoteControl() = default;

    // Command handlers
    void processCommand(uint8_t cmd, const uint8_t* payload, uint16_t len);
    void sendResponse(uint8_t status, const uint8_t* data, uint16_t len);

    void handlePing();
    void handleScreenshot();
    void handleKeyChar(uint8_t ch, uint8_t modifiers);
    void handleKeySpecial(uint8_t special, uint8_t modifiers);
    void handleScreenInfo();
    void handleWaitFrameText();
    void handleWaitFramePrimitives();
    void handleLuaExec(const uint8_t* code, uint16_t len);

    // Frame capture state
    enum class CaptureMode { NONE, TEXT, PRIMITIVES };
    CaptureMode _captureMode = CaptureMode::NONE;
    bool _waitingForFrame = false;
    uint32_t _frameWaitStart = 0;
    static constexpr uint32_t FRAME_WAIT_TIMEOUT_MS = 2000;

    // Command parsing state machine
    enum class State { WAIT_CMD, WAIT_LEN1, WAIT_LEN2, WAIT_PAYLOAD };
    State _state = State::WAIT_CMD;
    uint8_t _cmd = 0;
    uint16_t _payloadLen = 0;
    uint16_t _payloadPos = 0;
    uint8_t _payload[4096];  // Larger buffer for Lua code execution

    // Timeout for incomplete commands (resets state machine if no data received)
    uint32_t _lastByteTime = 0;
    static constexpr uint32_t CMD_TIMEOUT_MS = 100;
};
