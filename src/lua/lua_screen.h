#pragma once

#include "../tui/screen.h"
#include "lua_runtime.h"

// LuaScreen wraps a Lua table that implements the screen interface
// The Lua table should have methods: render(display), handle_key(key), on_enter(), on_exit()
class LuaScreen : public Screen {
public:
    // Create a LuaScreen from a Lua table on top of the stack
    // The table is removed from the stack and stored as a reference
    explicit LuaScreen(lua_State* L);

    // Create a LuaScreen from a registry reference
    LuaScreen(lua_State* L, int tableRef);

    ~LuaScreen() override;

    // Screen interface implementation
    void onEnter() override;
    void onExit() override;
    void onRefresh() override;
    void render(Display& display) override;
    ScreenResult handleKey(KeyEvent key) override;
    const char* getTitle() override;

    // Get the Lua table reference (for advanced usage)
    int getTableRef() const { return m_tableRef; }

private:
    lua_State* m_luaState;
    int m_tableRef;
    char m_titleBuffer[64];

    // Helper to push key event as Lua table
    void pushKeyEvent(KeyEvent key);

    // Helper to convert ScreenResult string to enum
    ScreenResult parseScreenResult(const char* result);

    // Call a method that returns nothing
    void callMethod(const char* method);

    // Call a method that returns a ScreenResult
    ScreenResult callMethodWithResult(const char* method);
};
