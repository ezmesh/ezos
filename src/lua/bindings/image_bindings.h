#pragma once

extern "C" {
#include <lua.h>
}

namespace image_bindings {
    // Registers ez.image.* and adds encode_jpeg / encode_png methods
    // to the Sprite metatable. Call from LuaRuntime::registerAllModules
    // after the display bindings have set up the Sprite metatable.
    void registerBindings(lua_State* L);
}
