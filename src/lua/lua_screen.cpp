#include "lua_screen.h"
#include "lua_bindings.h"

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

LuaScreen::LuaScreen(lua_State* L) : m_luaState(L), m_titleBuffer{0} {
    // Store reference to table on top of stack
    m_tableRef = luaL_ref(L, LUA_REGISTRYINDEX);
}

LuaScreen::LuaScreen(lua_State* L, int tableRef) : m_luaState(L), m_tableRef(tableRef), m_titleBuffer{0} {
}

LuaScreen::~LuaScreen() {
    if (m_luaState != nullptr && m_tableRef != LUA_NOREF) {
        luaL_unref(m_luaState, LUA_REGISTRYINDEX, m_tableRef);
    }
}

void LuaScreen::callMethod(const char* method) {
    if (m_luaState == nullptr || m_tableRef == LUA_NOREF) return;

    // Get the table
    lua_rawgeti(m_luaState, LUA_REGISTRYINDEX, m_tableRef);
    if (!lua_istable(m_luaState, -1)) {
        lua_pop(m_luaState, 1);
        return;
    }

    // Get the method
    lua_getfield(m_luaState, -1, method);
    if (!lua_isfunction(m_luaState, -1)) {
        lua_pop(m_luaState, 2);  // method and table
        return;
    }

    // Push self (the table)
    lua_pushvalue(m_luaState, -2);

    // Call method(self)
    if (lua_pcall(m_luaState, 1, 0, 0) != LUA_OK) {
        Serial.printf("[LuaScreen] Error in %s: %s\n", method, lua_tostring(m_luaState, -1));
        lua_pop(m_luaState, 1);
    }

    lua_pop(m_luaState, 1);  // Pop table
}

ScreenResult LuaScreen::callMethodWithResult(const char* method) {
    if (m_luaState == nullptr || m_tableRef == LUA_NOREF) return ScreenResult::CONTINUE;

    // Get the table
    lua_rawgeti(m_luaState, LUA_REGISTRYINDEX, m_tableRef);
    if (!lua_istable(m_luaState, -1)) {
        lua_pop(m_luaState, 1);
        return ScreenResult::CONTINUE;
    }

    // Get the method
    lua_getfield(m_luaState, -1, method);
    if (!lua_isfunction(m_luaState, -1)) {
        lua_pop(m_luaState, 2);
        return ScreenResult::CONTINUE;
    }

    // Push self (the table)
    lua_pushvalue(m_luaState, -2);

    // Call method(self) with 1 return value
    if (lua_pcall(m_luaState, 1, 1, 0) != LUA_OK) {
        Serial.printf("[LuaScreen] Error in %s: %s\n", method, lua_tostring(m_luaState, -1));
        lua_pop(m_luaState, 2);  // error and table
        return ScreenResult::CONTINUE;
    }

    // Get result
    ScreenResult result = ScreenResult::CONTINUE;
    if (lua_isstring(m_luaState, -1)) {
        result = parseScreenResult(lua_tostring(m_luaState, -1));
    }

    lua_pop(m_luaState, 2);  // result and table
    return result;
}

void LuaScreen::pushKeyEvent(KeyEvent key) {
    lua_newtable(m_luaState);

    // Character (as string)
    if (key.character != 0) {
        char str[2] = {key.character, '\0'};
        lua_pushstring(m_luaState, str);
    } else {
        lua_pushnil(m_luaState);
    }
    lua_setfield(m_luaState, -2, "character");

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
        lua_pushstring(m_luaState, specialName);
    } else {
        lua_pushnil(m_luaState);
    }
    lua_setfield(m_luaState, -2, "special");

    // Modifier flags
    lua_pushboolean(m_luaState, key.shift);
    lua_setfield(m_luaState, -2, "shift");

    lua_pushboolean(m_luaState, key.ctrl);
    lua_setfield(m_luaState, -2, "ctrl");

    lua_pushboolean(m_luaState, key.alt);
    lua_setfield(m_luaState, -2, "alt");

    lua_pushboolean(m_luaState, key.fn);
    lua_setfield(m_luaState, -2, "fn");

    lua_pushboolean(m_luaState, key.valid);
    lua_setfield(m_luaState, -2, "valid");
}

ScreenResult LuaScreen::parseScreenResult(const char* result) {
    if (result == nullptr) return ScreenResult::CONTINUE;

    if (strcmp(result, "pop") == 0 || strcmp(result, "POP") == 0) {
        return ScreenResult::POP;
    }
    if (strcmp(result, "push") == 0 || strcmp(result, "PUSH") == 0) {
        return ScreenResult::PUSH;
    }
    if (strcmp(result, "replace") == 0 || strcmp(result, "REPLACE") == 0) {
        return ScreenResult::REPLACE;
    }
    if (strcmp(result, "exit") == 0 || strcmp(result, "EXIT") == 0) {
        return ScreenResult::EXIT;
    }

    return ScreenResult::CONTINUE;
}

void LuaScreen::onEnter() {
    callMethod("on_enter");
    invalidate();
}

void LuaScreen::onExit() {
    callMethod("on_exit");
}

void LuaScreen::onRefresh() {
    callMethod("on_refresh");
}

void LuaScreen::render(Display& display) {
    if (m_luaState == nullptr || m_tableRef == LUA_NOREF) return;

    // Get the table
    lua_rawgeti(m_luaState, LUA_REGISTRYINDEX, m_tableRef);
    if (!lua_istable(m_luaState, -1)) {
        lua_pop(m_luaState, 1);
        return;
    }

    // Get render method
    lua_getfield(m_luaState, -1, "render");
    if (!lua_isfunction(m_luaState, -1)) {
        lua_pop(m_luaState, 2);
        return;
    }

    // Push self (the table)
    lua_pushvalue(m_luaState, -2);

    // For the display argument, we pass the tdeck.display module directly
    // since it already operates on the global display
    lua_getglobal(m_luaState, "tdeck");
    lua_getfield(m_luaState, -1, "display");
    lua_remove(m_luaState, -2);  // Remove tdeck table

    // Call render(self, display)
    if (lua_pcall(m_luaState, 2, 0, 0) != LUA_OK) {
        Serial.printf("[LuaScreen] Error in render: %s\n", lua_tostring(m_luaState, -1));
        lua_pop(m_luaState, 1);
    }

    lua_pop(m_luaState, 1);  // Pop table

    // Render all overlays (if Overlays global is available)
    lua_getglobal(m_luaState, "Overlays");
    if (lua_istable(m_luaState, -1)) {
        lua_getfield(m_luaState, -1, "render_all");
        if (lua_isfunction(m_luaState, -1)) {
            // Get display module for argument
            lua_getglobal(m_luaState, "tdeck");
            lua_getfield(m_luaState, -1, "display");
            lua_remove(m_luaState, -2);  // Remove tdeck table

            if (lua_pcall(m_luaState, 1, 0, 0) != LUA_OK) {
                Serial.printf("[LuaScreen] Error in Overlays.render_all: %s\n", lua_tostring(m_luaState, -1));
                lua_pop(m_luaState, 1);
            }
        } else {
            lua_pop(m_luaState, 1);  // Pop non-function
        }
    }
    lua_pop(m_luaState, 1);  // Pop Overlays table or nil
}

ScreenResult LuaScreen::handleKey(KeyEvent key) {
    if (m_luaState == nullptr || m_tableRef == LUA_NOREF) return ScreenResult::CONTINUE;

    // Get the table
    lua_rawgeti(m_luaState, LUA_REGISTRYINDEX, m_tableRef);
    if (!lua_istable(m_luaState, -1)) {
        lua_pop(m_luaState, 1);
        return ScreenResult::CONTINUE;
    }

    // Get handle_key method
    lua_getfield(m_luaState, -1, "handle_key");
    if (!lua_isfunction(m_luaState, -1)) {
        lua_pop(m_luaState, 2);
        return ScreenResult::CONTINUE;
    }

    // Push self
    lua_pushvalue(m_luaState, -2);

    // Push key event table
    pushKeyEvent(key);

    // Call handle_key(self, key)
    if (lua_pcall(m_luaState, 2, 1, 0) != LUA_OK) {
        Serial.printf("[LuaScreen] Error in handle_key: %s\n", lua_tostring(m_luaState, -1));
        lua_pop(m_luaState, 2);  // error and table
        return ScreenResult::CONTINUE;
    }

    // Get result
    ScreenResult result = ScreenResult::CONTINUE;
    if (lua_isstring(m_luaState, -1)) {
        result = parseScreenResult(lua_tostring(m_luaState, -1));
    }

    lua_pop(m_luaState, 2);  // result and table
    return result;
}

const char* LuaScreen::getTitle() {
    if (m_luaState == nullptr || m_tableRef == LUA_NOREF) {
        return "Lua Screen";
    }

    // Get the table
    lua_rawgeti(m_luaState, LUA_REGISTRYINDEX, m_tableRef);
    if (!lua_istable(m_luaState, -1)) {
        lua_pop(m_luaState, 1);
        return "Lua Screen";
    }

    // First try get_title() method
    lua_getfield(m_luaState, -1, "get_title");
    if (lua_isfunction(m_luaState, -1)) {
        lua_pushvalue(m_luaState, -2);  // Push self
        if (lua_pcall(m_luaState, 1, 1, 0) == LUA_OK && lua_isstring(m_luaState, -1)) {
            strncpy(m_titleBuffer, lua_tostring(m_luaState, -1), sizeof(m_titleBuffer) - 1);
            lua_pop(m_luaState, 2);  // result and table
            return m_titleBuffer;
        }
        lua_pop(m_luaState, 1);  // Pop error or non-string result
    } else {
        lua_pop(m_luaState, 1);  // Pop non-function
    }

    // Fall back to title property
    lua_getfield(m_luaState, -1, "title");
    if (lua_isstring(m_luaState, -1)) {
        strncpy(m_titleBuffer, lua_tostring(m_luaState, -1), sizeof(m_titleBuffer) - 1);
        lua_pop(m_luaState, 2);  // title and table
        return m_titleBuffer;
    }

    lua_pop(m_luaState, 2);  // title and table
    return "Lua Screen";
}
