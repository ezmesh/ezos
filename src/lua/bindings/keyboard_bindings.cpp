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
    {"get_backlight",            l_keyboard_get_backlight},
    {"set_backlight",            l_keyboard_set_backlight},
    {nullptr, nullptr}
};

// Register the keyboard module
void registerKeyboardModule(lua_State* L) {
    lua_register_module(L, "keyboard", keyboard_funcs);
    Serial.println("[LuaRuntime] Registered tdeck.keyboard");
}
