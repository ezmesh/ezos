#pragma once

extern "C" {
#include <lua.h>
}

namespace debug_bindings {
    // Registers ez.debug.* helpers used by the on-device test suite
    // (tools/remote/tests). Not part of the public Lua API; if you
    // depend on these from app Lua you're holding it wrong.
    void registerBindings(lua_State* L);
}
