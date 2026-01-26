// tdeck.keyboard module bindings
// Provides keyboard input functions

#include "../lua_bindings.h"
#include "../../hardware/keyboard.h"

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

// @lua tdeck.keyboard.available() -> boolean
// @brief Check if a key is waiting
// @return true if a key is available to read
LUA_FUNCTION(l_keyboard_available) {
    bool avail = keyboard && keyboard->available();
    lua_pushboolean(L, avail);
    return 1;
}

// @lua tdeck.keyboard.read() -> table
// @brief Read next key event (non-blocking)
// @return Key event table or nil if no key available
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

// @lua tdeck.keyboard.read_blocking(timeout_ms) -> table
// @brief Read key with optional timeout (blocking)
// @param timeout_ms Timeout in milliseconds (0 = forever)
// @return Key event table or nil on timeout
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

// @lua tdeck.keyboard.is_shift_held() -> boolean
// @brief Check if Shift is currently held
// @return true if Shift is held
LUA_FUNCTION(l_keyboard_is_shift_held) {
    bool held = keyboard && keyboard->isShiftHeld();
    lua_pushboolean(L, held);
    return 1;
}

// @lua tdeck.keyboard.is_ctrl_held() -> boolean
// @brief Check if Ctrl is currently held
// @return true if Ctrl is held
LUA_FUNCTION(l_keyboard_is_ctrl_held) {
    bool held = keyboard && keyboard->isCtrlHeld();
    lua_pushboolean(L, held);
    return 1;
}

// @lua tdeck.keyboard.is_alt_held() -> boolean
// @brief Check if Alt is currently held
// @return true if Alt is held
LUA_FUNCTION(l_keyboard_is_alt_held) {
    bool held = keyboard && keyboard->isAltHeld();
    lua_pushboolean(L, held);
    return 1;
}

// @lua tdeck.keyboard.is_fn_held() -> boolean
// @brief Check if Fn is currently held
// @return true if Fn is held
LUA_FUNCTION(l_keyboard_is_fn_held) {
    bool held = keyboard && keyboard->isFnHeld();
    lua_pushboolean(L, held);
    return 1;
}

// @lua tdeck.keyboard.has_trackball() -> boolean
// @brief Check if device has trackball
// @return true if trackball is available
LUA_FUNCTION(l_keyboard_has_trackball) {
    bool has = keyboard && keyboard->hasTrackball();
    lua_pushboolean(L, has);
    return 1;
}

// @lua tdeck.keyboard.get_trackball_sensitivity() -> integer
// @brief Get trackball sensitivity level
// @return Sensitivity value
LUA_FUNCTION(l_keyboard_get_trackball_sensitivity) {
    int sens = keyboard ? keyboard->getTrackballSensitivity() : 2;
    lua_pushinteger(L, sens);
    return 1;
}

// @lua tdeck.keyboard.set_trackball_sensitivity(value)
// @brief Set trackball sensitivity level
// @param value Sensitivity value
LUA_FUNCTION(l_keyboard_set_trackball_sensitivity) {
    LUA_CHECK_ARGC(L, 1);
    int value = luaL_checkinteger(L, 1);
    if (keyboard) {
        keyboard->setTrackballSensitivity(value);
    }
    return 0;
}

// @lua tdeck.keyboard.get_adaptive_scrolling() -> boolean
// @brief Check if adaptive scrolling is enabled
// @return true if adaptive scrolling is on
LUA_FUNCTION(l_keyboard_get_adaptive_scrolling) {
    bool enabled = keyboard && keyboard->getAdaptiveScrolling();
    lua_pushboolean(L, enabled);
    return 1;
}

// @lua tdeck.keyboard.set_adaptive_scrolling(enabled)
// @brief Enable or disable adaptive scrolling
// @param enabled true to enable, false to disable
LUA_FUNCTION(l_keyboard_set_adaptive_scrolling) {
    LUA_CHECK_ARGC(L, 1);
    bool enabled = lua_toboolean(L, 1);
    if (keyboard) {
        keyboard->setAdaptiveScrolling(enabled);
    }
    return 0;
}

// @lua tdeck.keyboard.get_tick_scrolling() -> boolean
// @brief Check if tick-based scrolling is enabled
// @return true if tick-based scrolling is on
LUA_FUNCTION(l_keyboard_get_tick_scrolling) {
    bool enabled = keyboard && keyboard->getTickBasedScrolling();
    lua_pushboolean(L, enabled);
    return 1;
}

// @lua tdeck.keyboard.set_tick_scrolling(enabled)
// @brief Enable or disable tick-based scrolling (smoother, fixed-rate scroll events)
// @param enabled true to enable, false to disable
LUA_FUNCTION(l_keyboard_set_tick_scrolling) {
    LUA_CHECK_ARGC(L, 1);
    bool enabled = lua_toboolean(L, 1);
    if (keyboard) {
        keyboard->setTickBasedScrolling(enabled);
    }
    return 0;
}

// @lua tdeck.keyboard.get_scroll_tick_interval() -> integer
// @brief Get scroll tick interval in milliseconds
// @return Interval in milliseconds (20-500)
LUA_FUNCTION(l_keyboard_get_scroll_tick_interval) {
    int interval = keyboard ? keyboard->getScrollTickInterval() : 100;
    lua_pushinteger(L, interval);
    return 1;
}

// @lua tdeck.keyboard.set_scroll_tick_interval(interval_ms)
// @brief Set scroll tick interval (how often scroll events are emitted)
// @param interval_ms Interval in milliseconds (20-500)
LUA_FUNCTION(l_keyboard_set_scroll_tick_interval) {
    LUA_CHECK_ARGC(L, 1);
    int interval = luaL_checkinteger(L, 1);
    if (keyboard) {
        keyboard->setScrollTickInterval(interval);
    }
    return 0;
}

// @lua tdeck.keyboard.get_backlight() -> integer
// @brief Get current keyboard backlight level
// @return Backlight level (0-255, 0 = off)
LUA_FUNCTION(l_keyboard_get_backlight) {
    int level = keyboard ? keyboard->getBacklight() : 0;
    lua_pushinteger(L, level);
    return 1;
}

// @lua tdeck.keyboard.set_backlight(level)
// @brief Set keyboard backlight brightness
// @param level Brightness level (0-255, 0 = off)
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

// @lua tdeck.keyboard.get_repeat_enabled() -> boolean
// @brief Check if key repeat is enabled
// @return true if key repeat is enabled
LUA_FUNCTION(l_keyboard_get_repeat_enabled) {
    bool enabled = keyboard && keyboard->getKeyRepeatEnabled();
    lua_pushboolean(L, enabled);
    return 1;
}

// @lua tdeck.keyboard.set_repeat_enabled(enabled)
// @brief Enable or disable key repeat
// @param enabled true to enable, false to disable
LUA_FUNCTION(l_keyboard_set_repeat_enabled) {
    LUA_CHECK_ARGC(L, 1);
    bool enabled = lua_toboolean(L, 1);
    if (keyboard) {
        keyboard->setKeyRepeatEnabled(enabled);
    }
    return 0;
}

// @lua tdeck.keyboard.get_repeat_delay() -> integer
// @brief Get initial delay before key repeat starts
// @return Delay in milliseconds
LUA_FUNCTION(l_keyboard_get_repeat_delay) {
    int delay = keyboard ? keyboard->getKeyRepeatDelay() : 400;
    lua_pushinteger(L, delay);
    return 1;
}

// @lua tdeck.keyboard.set_repeat_delay(delay_ms)
// @brief Set initial delay before key repeat starts
// @param delay_ms Delay in milliseconds (typically 200-800)
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

// @lua tdeck.keyboard.get_repeat_rate() -> integer
// @brief Get key repeat rate (interval between repeats)
// @return Rate in milliseconds
LUA_FUNCTION(l_keyboard_get_repeat_rate) {
    int rate = keyboard ? keyboard->getKeyRepeatRate() : 50;
    lua_pushinteger(L, rate);
    return 1;
}

// @lua tdeck.keyboard.set_repeat_rate(rate_ms)
// @brief Set key repeat rate (interval between repeats)
// @param rate_ms Rate in milliseconds (typically 20-100)
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


// @lua tdeck.keyboard.get_mode() -> string
// @brief Get current keyboard input mode
// @return "normal" or "raw"
LUA_FUNCTION(l_keyboard_get_mode) {
    const char* mode = "normal";
    if (keyboard && keyboard->getMode() == KeyboardMode::RAW) {
        mode = "raw";
    }
    lua_pushstring(L, mode);
    return 1;
}

// @lua tdeck.keyboard.set_mode(mode) -> boolean
// @brief Set keyboard input mode
// @param mode "normal" or "raw"
// @return true if mode was set successfully
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

// @lua tdeck.keyboard.read_raw_matrix() -> table|nil
// @brief Read raw key matrix state (only works in raw mode)
// @return Table of 7 bytes (one per column, 7 bits = rows), or nil on error
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

// @lua tdeck.keyboard.is_key_pressed(col, row) -> boolean
// @brief Check if a specific matrix key is pressed (raw mode)
// @param col Column index (0-4)
// @param row Row index (0-6)
// @return true if key is pressed
LUA_FUNCTION(l_keyboard_is_key_pressed) {
    LUA_CHECK_ARGC(L, 2);
    int col = luaL_checkinteger(L, 1);
    int row = luaL_checkinteger(L, 2);

    bool pressed = keyboard && keyboard->isKeyPressed(col, row);
    lua_pushboolean(L, pressed);
    return 1;
}

// @lua tdeck.keyboard.get_raw_matrix_bits() -> integer
// @brief Get full matrix state as 64-bit integer (raw mode)
// @return 49-bit value (7 cols × 7 rows), bits 0-6 = col 0, bits 7-13 = col 1, etc.
LUA_FUNCTION(l_keyboard_get_raw_matrix_bits) {
    uint64_t bits = keyboard ? keyboard->getRawMatrixBits() : 0;
    // Lua 5.4 supports 64-bit integers, but we need to be careful
    lua_pushinteger(L, (lua_Integer)bits);
    return 1;
}

// @lua tdeck.keyboard.read_raw_code() -> integer|nil
// @brief Read raw key code byte directly from I2C (no translation)
// @return Raw byte (0x00-0xFF) or nil if no key available
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

// Function table for tdeck.keyboard
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
    {"get_adaptive_scrolling",   l_keyboard_get_adaptive_scrolling},
    {"set_adaptive_scrolling",   l_keyboard_set_adaptive_scrolling},
    {"get_tick_scrolling",       l_keyboard_get_tick_scrolling},
    {"set_tick_scrolling",       l_keyboard_set_tick_scrolling},
    {"get_scroll_tick_interval", l_keyboard_get_scroll_tick_interval},
    {"set_scroll_tick_interval", l_keyboard_set_scroll_tick_interval},
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
    {nullptr, nullptr}
};

// Register the keyboard module
void registerKeyboardModule(lua_State* L) {
    lua_register_module(L, "keyboard", keyboard_funcs);
    Serial.println("[LuaRuntime] Registered tdeck.keyboard");
}
