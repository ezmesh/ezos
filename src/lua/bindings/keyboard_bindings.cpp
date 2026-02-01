// ez.keyboard module bindings
// Provides keyboard input functions

#include "../lua_bindings.h"
#include "../../hardware/keyboard.h"

// @module ez.keyboard
// @brief Physical keyboard and trackball input handling
// @description
// Reads input from the T-Deck's QWERTY keyboard and trackball. Supports
// key events with modifiers (shift, ctrl, alt, fn), special keys (arrows,
// enter, escape), and trackball movement/click. The keyboard is polled
// during the main loop; use read() to get pending key events.
// @end

// External reference to the global keyboard instance
extern Keyboard* keyboard;

// Helper to push a KeyEvent as a Lua table
static void pushKeyEvent(lua_State* L, KeyEvent key) {
    lua_newtable(L);

    // Character (as string)
    if (key.character != 0) {
        char str[2] = {key.character, '\0'};
        lua_pushstring(L, str);
    } else {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "character");

    // Special key name
    const char* specialName = nullptr;
    switch (key.special) {
        case SpecialKey::NONE:      break;
        case SpecialKey::UP:        specialName = "UP"; break;
        case SpecialKey::DOWN:      specialName = "DOWN"; break;
        case SpecialKey::LEFT:      specialName = "LEFT"; break;
        case SpecialKey::RIGHT:     specialName = "RIGHT"; break;
        case SpecialKey::ENTER:     specialName = "ENTER"; break;
        case SpecialKey::ESCAPE:    specialName = "ESCAPE"; break;
        case SpecialKey::TAB:       specialName = "TAB"; break;
        case SpecialKey::BACKSPACE: specialName = "BACKSPACE"; break;
        case SpecialKey::DELETE:    specialName = "DELETE"; break;
        case SpecialKey::HOME:      specialName = "HOME"; break;
        case SpecialKey::END:       specialName = "END"; break;
        case SpecialKey::SHIFT:     specialName = "SHIFT"; break;
        case SpecialKey::CTRL:      specialName = "CTRL"; break;
        case SpecialKey::ALT:       specialName = "ALT"; break;
        case SpecialKey::FN:        specialName = "FN"; break;
        case SpecialKey::SPEAKER:   specialName = "SPEAKER"; break;
        case SpecialKey::MIC:       specialName = "MIC"; break;
    }
    if (specialName) {
        lua_pushstring(L, specialName);
    } else {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "special");

    // Modifier flags
    lua_pushboolean(L, key.shift);
    lua_setfield(L, -2, "shift");

    lua_pushboolean(L, key.ctrl);
    lua_setfield(L, -2, "ctrl");

    lua_pushboolean(L, key.alt);
    lua_setfield(L, -2, "alt");

    lua_pushboolean(L, key.fn);
    lua_setfield(L, -2, "fn");

    lua_pushboolean(L, key.valid);
    lua_setfield(L, -2, "valid");
}

// @lua ez.keyboard.available() -> boolean
// @brief Check if a key is waiting
// @description Non-blocking check if a key event is ready to be read. Use in
// your main loop to poll for input before calling read(). Returns true if at
// least one key event is queued.
// @return true if a key is available to read
// @example
// if ez.keyboard.available() then
//     local key = ez.keyboard.read()
//     if key.character then
//         print("Pressed:", key.character)
//     elseif key.special then
//         print("Special key:", key.special)
//     end
// end
// @end
LUA_FUNCTION(l_keyboard_available) {
    bool avail = keyboard && keyboard->available();
    lua_pushboolean(L, avail);
    return 1;
}

// @lua ez.keyboard.read() -> table
// @brief Read next key event (non-blocking)
// @description Returns the next key event from the queue. The returned table
// contains: character (string or nil), special (special key name or nil), and
// modifier flags (shift, ctrl, alt, fn, valid). Returns nil if no key waiting.
// @return Key event table with character, special, shift, ctrl, alt, fn, valid fields, or nil
// @example
// local key = ez.keyboard.read()
// if key then
//     if key.special == "ENTER" then
//         submit_form()
//     elseif key.character and key.ctrl then
//         -- Ctrl+key shortcut
//         handle_shortcut(key.character)
//     end
// end
// @end
LUA_FUNCTION(l_keyboard_read) {
    if (!keyboard) {
        lua_pushnil(L);
        return 1;
    }

    KeyEvent key = keyboard->read();
    if (!key.valid) {
        lua_pushnil(L);
        return 1;
    }

    pushKeyEvent(L, key);
    return 1;
}

// @lua ez.keyboard.read_blocking(timeout_ms) -> table
// @brief Read key with optional timeout (blocking)
// @description Waits for a key press, blocking until a key is pressed or the
// timeout expires. Use for simple input prompts or games that need to wait
// for user input. A timeout of 0 means wait forever.
// @param timeout_ms Timeout in milliseconds (0 = wait forever)
// @return Key event table, or nil on timeout
// @example
// print("Press any key to continue...")
// local key = ez.keyboard.read_blocking(5000)  -- Wait up to 5 seconds
// if key then
//     print("You pressed a key!")
// else
//     print("Timeout - no key pressed")
// end
// @end
LUA_FUNCTION(l_keyboard_read_blocking) {
    uint32_t timeout = luaL_optintegerdefault(L, 1, 0);

    if (!keyboard) {
        lua_pushnil(L);
        return 1;
    }

    KeyEvent key = keyboard->readBlocking(timeout);
    if (!key.valid) {
        lua_pushnil(L);
        return 1;
    }

    pushKeyEvent(L, key);
    return 1;
}

// @lua ez.keyboard.is_shift_held() -> boolean
// @brief Check if Shift is currently held
// @description Returns the current state of the Shift key. Use for modifier
// combinations or to check if text should be uppercase.
// @return true if Shift is currently held down
// @example
// if ez.keyboard.is_shift_held() then
//     print("Shift is held")
// end
// @end
LUA_FUNCTION(l_keyboard_is_shift_held) {
    bool held = keyboard && keyboard->isShiftHeld();
    lua_pushboolean(L, held);
    return 1;
}

// @lua ez.keyboard.is_ctrl_held() -> boolean
// @brief Check if Ctrl is currently held
// @description Returns the current state of the Control key. Use for keyboard
// shortcuts like Ctrl+C, Ctrl+V.
// @return true if Ctrl is currently held down
// @example
// if ez.keyboard.is_ctrl_held() then
//     print("Ctrl is held")
// end
// @end
LUA_FUNCTION(l_keyboard_is_ctrl_held) {
    bool held = keyboard && keyboard->isCtrlHeld();
    lua_pushboolean(L, held);
    return 1;
}

// @lua ez.keyboard.is_alt_held() -> boolean
// @brief Check if Alt is currently held
// @description Returns the current state of the Alt key. Use for alternate
// character input or keyboard shortcuts.
// @return true if Alt is currently held down
// @example
// if ez.keyboard.is_alt_held() then
//     print("Alt is held")
// end
// @end
LUA_FUNCTION(l_keyboard_is_alt_held) {
    bool held = keyboard && keyboard->isAltHeld();
    lua_pushboolean(L, held);
    return 1;
}

// @lua ez.keyboard.is_fn_held() -> boolean
// @brief Check if Fn is currently held
// @description Returns the current state of the Function key. The Fn key provides
// access to special characters and function key combinations.
// @return true if Fn is currently held down
// @example
// if ez.keyboard.is_fn_held() then
//     print("Fn is held - function layer active")
// end
// @end
LUA_FUNCTION(l_keyboard_is_fn_held) {
    bool held = keyboard && keyboard->isFnHeld();
    lua_pushboolean(L, held);
    return 1;
}

// @lua ez.keyboard.has_trackball() -> boolean
// @brief Check if device has trackball
// @description Checks if the T-Deck has a working trackball. The T-Deck Plus
// includes a trackball for navigation. Returns false if trackball is not
// detected or not available on this hardware variant.
// @return true if trackball is available
// @example
// if ez.keyboard.has_trackball() then
//     print("Use trackball to navigate")
// else
//     print("Use arrow keys to navigate")
// end
// @end
LUA_FUNCTION(l_keyboard_has_trackball) {
    bool has = keyboard && keyboard->hasTrackball();
    lua_pushboolean(L, has);
    return 1;
}

// @lua ez.keyboard.get_trackball_sensitivity() -> integer
// @brief Get trackball sensitivity level
// @description Returns the current trackball sensitivity. Higher values mean
// more movement events per physical rotation. Default is 2.
// @return Sensitivity value (1-10, higher = more sensitive)
// @example
// local sens = ez.keyboard.get_trackball_sensitivity()
// print("Trackball sensitivity:", sens)
// @end
LUA_FUNCTION(l_keyboard_get_trackball_sensitivity) {
    int sens = keyboard ? keyboard->getTrackballSensitivity() : 2;
    lua_pushinteger(L, sens);
    return 1;
}

// @lua ez.keyboard.set_trackball_sensitivity(value)
// @brief Set trackball sensitivity level
// @description Adjusts how responsive the trackball is. Higher values generate
// more movement events for the same physical rotation. Use lower values for
// precision, higher for faster cursor movement.
// @param value Sensitivity value (1-10, higher = more sensitive)
// @example
// ez.keyboard.set_trackball_sensitivity(3)  -- Slightly faster
// @end
LUA_FUNCTION(l_keyboard_set_trackball_sensitivity) {
    LUA_CHECK_ARGC(L, 1);
    int value = luaL_checkinteger(L, 1);
    if (keyboard) {
        keyboard->setTrackballSensitivity(value);
    }
    return 0;
}

// @lua ez.keyboard.get_trackball_mode() -> string
// @brief Get current trackball input mode
// @description Returns how the trackball is read. "polling" reads on-demand
// in the main loop. "interrupt" uses hardware interrupts for lower latency.
// @return "polling" or "interrupt"
// @example
// print("Trackball mode:", ez.keyboard.get_trackball_mode())
// @end
LUA_FUNCTION(l_keyboard_get_trackball_mode) {
    const char* mode = "polling";
    if (keyboard && keyboard->getTrackballMode() == TrackballMode::INTERRUPT_DRIVEN) {
        mode = "interrupt";
    }
    lua_pushstring(L, mode);
    return 1;
}

// @lua ez.keyboard.set_trackball_mode(mode)
// @brief Set trackball input mode
// @description Sets how the trackball is read. "interrupt" mode provides lower
// latency but uses more CPU. "polling" mode is more power efficient.
// @param mode "polling" or "interrupt"
// @example
// ez.keyboard.set_trackball_mode("interrupt")  -- Lower latency
// @end
LUA_FUNCTION(l_keyboard_set_trackball_mode) {
    LUA_CHECK_ARGC(L, 1);
    const char* modeStr = luaL_checkstring(L, 1);

    TrackballMode mode = TrackballMode::POLLING;
    if (strcmp(modeStr, "interrupt") == 0) {
        mode = TrackballMode::INTERRUPT_DRIVEN;
    } else if (strcmp(modeStr, "polling") != 0) {
        return luaL_error(L, "Invalid mode: %s (expected 'polling' or 'interrupt')", modeStr);
    }

    if (keyboard) {
        keyboard->setTrackballMode(mode);
    }
    return 0;
}

// @lua ez.keyboard.get_backlight() -> integer
// @brief Get current keyboard backlight level
// @description Returns the current keyboard backlight brightness. The T-Deck has
// illuminated keys for use in low-light conditions.
// @return Backlight level (0-255, 0 = off, 255 = maximum brightness)
// @example
// local level = ez.keyboard.get_backlight()
// print("Backlight:", level)
// @end
LUA_FUNCTION(l_keyboard_get_backlight) {
    int level = keyboard ? keyboard->getBacklight() : 0;
    lua_pushinteger(L, level);
    return 1;
}

// @lua ez.keyboard.set_backlight(level)
// @brief Set keyboard backlight brightness
// @description Sets the keyboard backlight brightness. Higher values use more
// power. Set to 0 to turn off completely for battery saving.
// @param level Brightness level (0-255, 0 = off, 255 = max)
// @example
// ez.keyboard.set_backlight(128)  -- Half brightness
// ez.keyboard.set_backlight(0)    -- Turn off to save battery
// @end
LUA_FUNCTION(l_keyboard_set_backlight) {
    LUA_CHECK_ARGC(L, 1);
    int level = luaL_checkinteger(L, 1);
    if (level < 0) level = 0;
    if (level > 255) level = 255;
    if (keyboard) {
        keyboard->setBacklight(level);
    }
    return 0;
}

// @lua ez.keyboard.get_repeat_enabled() -> boolean
// @brief Check if key repeat is enabled
// @description Returns whether holding a key generates repeated key events.
// When enabled, holding a key generates events after an initial delay.
// @return true if key repeat is enabled
// @example
// if ez.keyboard.get_repeat_enabled() then
//     print("Key repeat is on")
// end
// @end
LUA_FUNCTION(l_keyboard_get_repeat_enabled) {
    bool enabled = keyboard && keyboard->getKeyRepeatEnabled();
    lua_pushboolean(L, enabled);
    return 1;
}

// @lua ez.keyboard.set_repeat_enabled(enabled)
// @brief Enable or disable key repeat
// @description Controls whether holding a key generates repeated key events.
// Useful for text editing and games. Disable for applications where only
// single presses should register.
// @param enabled true to enable, false to disable
// @example
// ez.keyboard.set_repeat_enabled(false)  -- Single press only
// @end
LUA_FUNCTION(l_keyboard_set_repeat_enabled) {
    LUA_CHECK_ARGC(L, 1);
    bool enabled = lua_toboolean(L, 1);
    if (keyboard) {
        keyboard->setKeyRepeatEnabled(enabled);
    }
    return 0;
}

// @lua ez.keyboard.get_repeat_delay() -> integer
// @brief Get initial delay before key repeat starts
// @description Returns how long a key must be held before repeat begins.
// Default is 400ms. Shorter delays make repeat start faster.
// @return Delay in milliseconds
// @example
// print("Repeat delay:", ez.keyboard.get_repeat_delay(), "ms")
// @end
LUA_FUNCTION(l_keyboard_get_repeat_delay) {
    int delay = keyboard ? keyboard->getKeyRepeatDelay() : 400;
    lua_pushinteger(L, delay);
    return 1;
}

// @lua ez.keyboard.set_repeat_delay(delay_ms)
// @brief Set initial delay before key repeat starts
// @description Sets how long a key must be held before repeat begins. Clamped
// to 50-2000ms range.
// @param delay_ms Delay in milliseconds (50-2000, default 400)
// @example
// ez.keyboard.set_repeat_delay(300)  -- Faster repeat start
// @end
LUA_FUNCTION(l_keyboard_set_repeat_delay) {
    LUA_CHECK_ARGC(L, 1);
    int delay = luaL_checkinteger(L, 1);
    if (delay < 50) delay = 50;
    if (delay > 2000) delay = 2000;
    if (keyboard) {
        keyboard->setKeyRepeatDelay(delay);
    }
    return 0;
}

// @lua ez.keyboard.get_repeat_rate() -> integer
// @brief Get key repeat rate (interval between repeats)
// @description Returns the interval between repeated key events while holding
// a key. Default is 50ms (20 repeats/second).
// @return Interval in milliseconds between repeat events
// @example
// print("Repeat rate:", ez.keyboard.get_repeat_rate(), "ms")
// @end
LUA_FUNCTION(l_keyboard_get_repeat_rate) {
    int rate = keyboard ? keyboard->getKeyRepeatRate() : 50;
    lua_pushinteger(L, rate);
    return 1;
}

// @lua ez.keyboard.set_repeat_rate(rate_ms)
// @brief Set key repeat rate (interval between repeats)
// @description Sets how fast keys repeat while held. Lower values = faster repeat.
// Clamped to 10-500ms range.
// @param rate_ms Interval in milliseconds (10-500, default 50)
// @example
// ez.keyboard.set_repeat_rate(30)  -- Faster repeat
// @end
LUA_FUNCTION(l_keyboard_set_repeat_rate) {
    LUA_CHECK_ARGC(L, 1);
    int rate = luaL_checkinteger(L, 1);
    if (rate < 10) rate = 10;
    if (rate > 500) rate = 500;
    if (keyboard) {
        keyboard->setKeyRepeatRate(rate);
    }
    return 0;
}


// @lua ez.keyboard.get_mode() -> string
// @brief Get current keyboard input mode
// @description Returns the keyboard processing mode. "normal" provides translated
// key events with character values. "raw" gives direct matrix access for custom
// key handling or chording.
// @return "normal" or "raw"
// @example
// print("Keyboard mode:", ez.keyboard.get_mode())
// @end
LUA_FUNCTION(l_keyboard_get_mode) {
    const char* mode = "normal";
    if (keyboard && keyboard->getMode() == KeyboardMode::RAW) {
        mode = "raw";
    }
    lua_pushstring(L, mode);
    return 1;
}

// @lua ez.keyboard.set_mode(mode) -> boolean
// @brief Set keyboard input mode
// @description Switches between normal and raw keyboard modes. Raw mode provides
// direct access to the key matrix for custom input handling, chording, or
// implementing custom keyboard layouts.
// @param mode "normal" for translated keys, "raw" for matrix access
// @return true if mode was set successfully
// @example
// ez.keyboard.set_mode("raw")
// local matrix = ez.keyboard.read_raw_matrix()
// ez.keyboard.set_mode("normal")
// @end
LUA_FUNCTION(l_keyboard_set_mode) {
    LUA_CHECK_ARGC(L, 1);
    const char* modeStr = luaL_checkstring(L, 1);

    KeyboardMode mode = KeyboardMode::NORMAL;
    if (strcmp(modeStr, "raw") == 0) {
        mode = KeyboardMode::RAW;
    } else if (strcmp(modeStr, "normal") != 0) {
        return luaL_error(L, "Invalid mode: %s (expected 'normal' or 'raw')", modeStr);
    }

    bool success = keyboard && keyboard->setMode(mode);
    lua_pushboolean(L, success);
    return 1;
}

// @lua ez.keyboard.read_raw_matrix() -> table|nil
// @brief Read raw key matrix state (only works in raw mode)
// @description Reads the complete keyboard matrix state. Returns 7 bytes, one per
// column, with each bit representing a row (1 = pressed). Only works when keyboard
// is in "raw" mode. Use for detecting multiple simultaneous key presses (chording).
// @return Table of 7 bytes (one per column, 7 bits = rows), or nil on error
// @example
// ez.keyboard.set_mode("raw")
// local matrix = ez.keyboard.read_raw_matrix()
// if matrix then
//     for col, val in ipairs(matrix) do
//         print("Column", col, "=", string.format("0x%02X", val))
//     end
// end
// @end
LUA_FUNCTION(l_keyboard_read_raw_matrix) {
    if (!keyboard) {
        lua_pushnil(L);
        return 1;
    }

    uint8_t matrix[Keyboard::MATRIX_COLS];
    if (!keyboard->readRawMatrix(matrix)) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);
    for (int col = 0; col < Keyboard::MATRIX_COLS; col++) {
        lua_pushinteger(L, matrix[col]);
        lua_rawseti(L, -2, col + 1);  // Lua arrays are 1-indexed
    }
    return 1;
}

// @lua ez.keyboard.is_key_pressed(col, row) -> boolean
// @brief Check if a specific matrix key is pressed (raw mode)
// @description Checks if a specific key at the given matrix position is pressed.
// Works in raw mode. The T-Deck keyboard is a 5x7 matrix (columns 0-4, rows 0-6).
// @param col Column index (0-4)
// @param row Row index (0-6)
// @return true if key at position is pressed
// @example
// -- Check if specific matrix position is pressed
// if ez.keyboard.is_key_pressed(2, 3) then
//     print("Key at col 2, row 3 is pressed")
// end
// @end
LUA_FUNCTION(l_keyboard_is_key_pressed) {
    LUA_CHECK_ARGC(L, 2);
    int col = luaL_checkinteger(L, 1);
    int row = luaL_checkinteger(L, 2);

    bool pressed = keyboard && keyboard->isKeyPressed(col, row);
    lua_pushboolean(L, pressed);
    return 1;
}

// @lua ez.keyboard.get_raw_matrix_bits() -> integer
// @brief Get full matrix state as 64-bit integer (raw mode)
// @description Returns the entire keyboard matrix state as a single 64-bit integer.
// Each column occupies 7 bits. Efficient for comparing entire keyboard state or
// implementing chord detection.
// @return 49-bit value (7 cols × 7 rows), bits 0-6 = col 0, bits 7-13 = col 1, etc.
// @example
// local bits = ez.keyboard.get_raw_matrix_bits()
// if bits ~= 0 then
//     print("Some keys are pressed")
// end
// @end
LUA_FUNCTION(l_keyboard_get_raw_matrix_bits) {
    uint64_t bits = keyboard ? keyboard->getRawMatrixBits() : 0;
    // Lua 5.4 supports 64-bit integers, but we need to be careful
    lua_pushinteger(L, (lua_Integer)bits);
    return 1;
}

// @lua ez.keyboard.read_raw_code() -> integer|nil
// @brief Read raw key code byte directly from I2C (no translation)
// @description Reads the raw byte from the keyboard I2C controller without any
// translation. Useful for debugging or implementing custom keyboard handling.
// Returns nil if no key data is available.
// @return Raw byte (0x00-0xFF) or nil if no key available
// @example
// local code = ez.keyboard.read_raw_code()
// if code then
//     print("Raw key code:", string.format("0x%02X", code))
// end
// @end
LUA_FUNCTION(l_keyboard_read_raw_code) {
    if (!keyboard) {
        lua_pushnil(L);
        return 1;
    }

    uint8_t code = keyboard->readRaw();
    if (code == 0) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushinteger(L, code);
    return 1;
}

// @lua ez.keyboard.has_key_activity() -> boolean
// @brief Check if keyboard interrupt pin indicates key activity
// @description Checks the hardware interrupt pin to detect if any key is pressed.
// More efficient than reading the full matrix - useful for wake detection or
// quick polling before more expensive operations.
// @return true if a key press is detected via hardware interrupt pin
// @example
// -- Quick check before reading keys
// if ez.keyboard.has_key_activity() then
//     local key = ez.keyboard.read()
// end
// @end
LUA_FUNCTION(l_keyboard_has_key_activity) {
    bool activity = keyboard && keyboard->hasKeyActivity();
    lua_pushboolean(L, activity);
    return 1;
}

// @lua ez.keyboard.get_pin_states() -> string
// @brief Debug function to get raw GPIO pin states for wake detection
// @description Returns a string showing the current state of all keyboard and
// trackball GPIO pins. Useful for debugging hardware issues or wake-from-sleep
// detection. Values are 1 (pressed/active low) or 0 (released).
// @return String: "KB_INT=X TB_UP=X TB_DOWN=X TB_LEFT=X TB_RIGHT=X TB_CLICK=X"
// @example
// print(ez.keyboard.get_pin_states())
// -- Output: "KB_INT=0 TB_UP=0 TB_DOWN=0 TB_LEFT=0 TB_RIGHT=0 TB_CLICK=0"
// @end
LUA_FUNCTION(l_keyboard_get_pin_states) {
    char buf[128];
    snprintf(buf, sizeof(buf), "KB_INT=%d TB_UP=%d TB_DOWN=%d TB_LEFT=%d TB_RIGHT=%d TB_CLICK=%d",
             (KB_INT >= 0 && digitalRead(KB_INT) == LOW) ? 1 : 0,
             digitalRead(TRACKBALL_UP) == LOW ? 1 : 0,
             digitalRead(TRACKBALL_DOWN) == LOW ? 1 : 0,
             digitalRead(TRACKBALL_LEFT) == LOW ? 1 : 0,
             digitalRead(TRACKBALL_RIGHT) == LOW ? 1 : 0,
             digitalRead(TRACKBALL_CLICK) == LOW ? 1 : 0);
    lua_pushstring(L, buf);
    return 1;
}

// Function table for ez.keyboard
static const luaL_Reg keyboard_funcs[] = {
    {"available",                l_keyboard_available},
    {"read",                     l_keyboard_read},
    {"read_blocking",            l_keyboard_read_blocking},
    {"is_shift_held",            l_keyboard_is_shift_held},
    {"is_ctrl_held",             l_keyboard_is_ctrl_held},
    {"is_alt_held",              l_keyboard_is_alt_held},
    {"is_fn_held",               l_keyboard_is_fn_held},
    {"has_trackball",            l_keyboard_has_trackball},
    {"get_trackball_sensitivity", l_keyboard_get_trackball_sensitivity},
    {"set_trackball_sensitivity", l_keyboard_set_trackball_sensitivity},
    {"get_trackball_mode",       l_keyboard_get_trackball_mode},
    {"set_trackball_mode",       l_keyboard_set_trackball_mode},
    {"get_backlight",            l_keyboard_get_backlight},
    {"set_backlight",            l_keyboard_set_backlight},
    {"get_repeat_enabled",       l_keyboard_get_repeat_enabled},
    {"set_repeat_enabled",       l_keyboard_set_repeat_enabled},
    {"get_repeat_delay",         l_keyboard_get_repeat_delay},
    {"set_repeat_delay",         l_keyboard_set_repeat_delay},
    {"get_repeat_rate",          l_keyboard_get_repeat_rate},
    {"set_repeat_rate",          l_keyboard_set_repeat_rate},
    // Raw mode functions
    {"get_mode",                 l_keyboard_get_mode},
    {"set_mode",                 l_keyboard_set_mode},
    {"read_raw_matrix",          l_keyboard_read_raw_matrix},
    {"read_raw_code",            l_keyboard_read_raw_code},
    {"is_key_pressed",           l_keyboard_is_key_pressed},
    {"get_raw_matrix_bits",      l_keyboard_get_raw_matrix_bits},
    {"has_key_activity",         l_keyboard_has_key_activity},
    {"get_pin_states",           l_keyboard_get_pin_states},
    {nullptr, nullptr}
};

// Register the keyboard module
void registerKeyboardModule(lua_State* L) {
    lua_register_module(L, "keyboard", keyboard_funcs);
    Serial.println("[LuaRuntime] Registered ez.keyboard");
}
