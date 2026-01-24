#pragma once

// Lua binding helper macros and utilities
// Provides consistent patterns for registering C functions with Lua

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

#include <Arduino.h>

// Helper macro to define a Lua C function
#define LUA_FUNCTION(name) static int name(lua_State* L)

// Helper to check argument count
#define LUA_CHECK_ARGC(L, expected) \
    if (lua_gettop(L) < expected) { \
        return luaL_error(L, "Expected %d arguments, got %d", expected, lua_gettop(L)); \
    }

// Helper to check argument count with range
#define LUA_CHECK_ARGC_RANGE(L, min, max) \
    do { \
        int argc = lua_gettop(L); \
        if (argc < min || argc > max) { \
            return luaL_error(L, "Expected %d-%d arguments, got %d", min, max, argc); \
        } \
    } while(0)

// Get integer argument with default value
inline lua_Integer luaL_optintegerdefault(lua_State* L, int idx, lua_Integer def) {
    return lua_isnoneornil(L, idx) ? def : luaL_checkinteger(L, idx);
}

// Get number argument with default value
inline lua_Number luaL_optnumberdefault(lua_State* L, int idx, lua_Number def) {
    return lua_isnoneornil(L, idx) ? def : luaL_checknumber(L, idx);
}

// Register a module function table to tdeck.modulename
inline void lua_register_module(lua_State* L, const char* name, const luaL_Reg* funcs) {
    // Get the tdeck table
    lua_getglobal(L, "tdeck");

    // Create new table for the module
    lua_newtable(L);

    // Register functions into the module table
    luaL_setfuncs(L, funcs, 0);

    // Set tdeck.modulename = module table
    lua_setfield(L, -2, name);

    // Pop the tdeck table
    lua_pop(L, 1);
}

// Add a constant integer to the table on top of stack
inline void lua_set_const_int(lua_State* L, const char* name, lua_Integer value) {
    lua_pushinteger(L, value);
    lua_setfield(L, -2, name);
}

// Add a constant number to the table on top of stack
inline void lua_set_const_number(lua_State* L, const char* name, lua_Number value) {
    lua_pushnumber(L, value);
    lua_setfield(L, -2, name);
}

// Add a constant string to the table on top of stack
inline void lua_set_const_string(lua_State* L, const char* name, const char* value) {
    lua_pushstring(L, value);
    lua_setfield(L, -2, name);
}

// Add a constant boolean to the table on top of stack
inline void lua_set_const_bool(lua_State* L, const char* name, bool value) {
    lua_pushboolean(L, value);
    lua_setfield(L, -2, name);
}

// Helper to create a userdata with metatable
template<typename T>
T* lua_newuserdata_mt(lua_State* L, const char* mtname) {
    T* ptr = static_cast<T*>(lua_newuserdata(L, sizeof(T)));
    luaL_setmetatable(L, mtname);
    return ptr;
}

// Helper to get userdata with type check
template<typename T>
T* lua_checkuserdata(lua_State* L, int idx, const char* mtname) {
    return static_cast<T*>(luaL_checkudata(L, idx, mtname));
}

// Helper to create a metatable with __index pointing to itself
inline void lua_create_class_metatable(lua_State* L, const char* name, const luaL_Reg* methods) {
    luaL_newmetatable(L, name);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, methods, 0);
    lua_pop(L, 1);
}

// Helper to add a read-only property getter to a module
// Usage: Add a __index metamethod to intercept property access
class LuaModuleBuilder {
public:
    LuaModuleBuilder(lua_State* L, const char* moduleName)
        : L(L), name(moduleName) {
        // Get tdeck table
        lua_getglobal(L, "tdeck");

        // Create module table
        lua_newtable(L);
    }

    // Add a function to the module
    LuaModuleBuilder& addFunction(const char* fname, lua_CFunction func) {
        lua_pushcfunction(L, func);
        lua_setfield(L, -2, fname);
        return *this;
    }

    // Add a constant integer
    LuaModuleBuilder& addConstInt(const char* cname, lua_Integer value) {
        lua_pushinteger(L, value);
        lua_setfield(L, -2, cname);
        return *this;
    }

    // Add a constant number
    LuaModuleBuilder& addConstNumber(const char* cname, lua_Number value) {
        lua_pushnumber(L, value);
        lua_setfield(L, -2, cname);
        return *this;
    }

    // Add a constant string
    LuaModuleBuilder& addConstString(const char* cname, const char* value) {
        lua_pushstring(L, value);
        lua_setfield(L, -2, cname);
        return *this;
    }

    // Add a subtable (e.g., for colors)
    LuaModuleBuilder& beginSubtable(const char* subtableName) {
        lua_newtable(L);
        subtable = subtableName;
        return *this;
    }

    LuaModuleBuilder& endSubtable() {
        if (subtable) {
            lua_setfield(L, -2, subtable);
            subtable = nullptr;
        }
        return *this;
    }

    // Finish building and register the module
    void build() {
        // Set tdeck.name = module table
        lua_setfield(L, -2, name);
        // Pop tdeck table
        lua_pop(L, 1);
    }

private:
    lua_State* L;
    const char* name;
    const char* subtable = nullptr;
};
