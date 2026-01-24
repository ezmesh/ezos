// tdeck.screen module bindings
// Provides screen navigation and management

#include "../lua_bindings.h"
#include "../lua_screen.h"
#include "../../tui/tui.h"

// External references
extern TUI* tui;

// @lua tdeck.screen.push(screen)
// @brief Push a new screen onto the stack
// @param screen Screen table with render/handle_key methods
LUA_FUNCTION(l_screen_push) {
    LUA_CHECK_ARGC(L, 1);
    luaL_checktype(L, 1, LUA_TTABLE);

    if (!tui) {
        return luaL_error(L, "TUI not initialized");
    }

    // Push the table to top and create LuaScreen from it
    lua_pushvalue(L, 1);
    LuaScreen* screen = new LuaScreen(L);

    tui->push(screen);
    return 0;
}

// @lua tdeck.screen.pop()
// @brief Pop current screen and return to previous
LUA_FUNCTION(l_screen_pop) {
    if (tui) {
        tui->pop();
    }
    return 0;
}

// @lua tdeck.screen.replace(screen)
// @brief Replace current screen without stack growth
// @param screen Screen table with render/handle_key methods
LUA_FUNCTION(l_screen_replace) {
    LUA_CHECK_ARGC(L, 1);
    luaL_checktype(L, 1, LUA_TTABLE);

    if (!tui) {
        return luaL_error(L, "TUI not initialized");
    }

    lua_pushvalue(L, 1);
    LuaScreen* screen = new LuaScreen(L);

    tui->replace(screen);
    return 0;
}

// @lua tdeck.screen.invalidate()
// @brief Mark screen for redraw
LUA_FUNCTION(l_screen_invalidate) {
    if (tui) {
        tui->invalidate();
    }
    return 0;
}

// @lua tdeck.screen.set_battery(percent)
// @brief Update status bar battery indicator
// @param percent Battery percentage (0-100)
LUA_FUNCTION(l_screen_set_battery) {
    LUA_CHECK_ARGC(L, 1);
    int percent = luaL_checkinteger(L, 1);
    percent = constrain(percent, 0, 100);
    if (tui) {
        tui->updateBattery(percent);
    }
    return 0;
}

// @lua tdeck.screen.set_radio(ok, bars)
// @brief Update status bar radio indicator
// @param ok true if radio is working
// @param bars Signal strength (0-4 bars)
LUA_FUNCTION(l_screen_set_radio) {
    LUA_CHECK_ARGC(L, 2);
    bool ok = lua_toboolean(L, 1);
    int bars = luaL_checkinteger(L, 2);
    bars = constrain(bars, 0, 4);
    if (tui) {
        tui->updateRadio(ok, bars);
    }
    return 0;
}

// @lua tdeck.screen.set_node_count(count)
// @brief Update status bar node count
// @param count Number of known mesh nodes
LUA_FUNCTION(l_screen_set_node_count) {
    LUA_CHECK_ARGC(L, 1);
    int count = luaL_checkinteger(L, 1);
    if (tui) {
        tui->updateNodeCount(count);
    }
    return 0;
}

// @lua tdeck.screen.set_node_id(short_id)
// @brief Update status bar node ID display
// @param short_id Short node ID string
LUA_FUNCTION(l_screen_set_node_id) {
    LUA_CHECK_ARGC(L, 1);
    const char* id = luaL_checkstring(L, 1);
    if (tui) {
        tui->updateNodeId(id);
    }
    return 0;
}

// @lua tdeck.screen.set_unread(has_unread)
// @brief Update status bar unread indicator
// @param has_unread true if there are unread messages
LUA_FUNCTION(l_screen_set_unread) {
    LUA_CHECK_ARGC(L, 1);
    bool unread = lua_toboolean(L, 1);
    if (tui) {
        tui->setUnreadFlag(unread);
    }
    return 0;
}

// @lua tdeck.screen.is_empty() -> boolean
// @brief Check if screen stack is empty
// @return true if no screens on stack
LUA_FUNCTION(l_screen_is_empty) {
    bool empty = !tui || tui->isEmpty();
    lua_pushboolean(L, empty);
    return 1;
}

// @lua tdeck.screen.get_status() -> table
// @brief Get current status bar info
// @return Table with battery, radio_ok, signal_bars, node_count, has_unread, node_id
LUA_FUNCTION(l_screen_get_status) {
    if (!tui) {
        lua_newtable(L);
        return 1;
    }

    const StatusInfo& status = tui->getStatus();

    lua_newtable(L);

    lua_pushinteger(L, status.batteryPercent);
    lua_setfield(L, -2, "battery");

    lua_pushboolean(L, status.radioOk);
    lua_setfield(L, -2, "radio_ok");

    lua_pushinteger(L, status.signalBars);
    lua_setfield(L, -2, "signal_bars");

    lua_pushinteger(L, status.nodeCount);
    lua_setfield(L, -2, "node_count");

    lua_pushboolean(L, status.hasUnread);
    lua_setfield(L, -2, "has_unread");

    lua_pushstring(L, status.nodeIdShort);
    lua_setfield(L, -2, "node_id");

    return 1;
}

// Function table for tdeck.screen
static const luaL_Reg screen_funcs[] = {
    {"push",           l_screen_push},
    {"pop",            l_screen_pop},
    {"replace",        l_screen_replace},
    {"invalidate",     l_screen_invalidate},
    {"set_battery",    l_screen_set_battery},
    {"set_radio",      l_screen_set_radio},
    {"set_node_count", l_screen_set_node_count},
    {"set_node_id",    l_screen_set_node_id},
    {"set_unread",     l_screen_set_unread},
    {"is_empty",       l_screen_is_empty},
    {"get_status",     l_screen_get_status},
    {nullptr, nullptr}
};

// Register the screen module
void registerScreenModule(lua_State* L) {
    lua_register_module(L, "screen", screen_funcs);
    Serial.println("[LuaRuntime] Registered tdeck.screen");
}
