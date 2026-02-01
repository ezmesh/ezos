#pragma once

extern "C" {
#include <lua.h>
}

namespace http_bindings {

// Register the ez.http module
void registerBindings(lua_State* L);

// Process pending HTTP responses (call from main loop)
void update(lua_State* L);

// Shutdown HTTP system
void shutdown();

} // namespace http_bindings
