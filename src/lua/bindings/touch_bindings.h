#pragma once

extern "C" {
#include <lua.h>
}

namespace touch_bindings {
    void registerBindings(lua_State* L);

    // Polled from the main loop. Reads the GT911, posts touch/down,
    // touch/move, and touch/up events on the global bus, and tracks
    // currently-down points so we know when a finger has lifted.
    // Cheap when idle (a single 3-byte I2C read) so it's safe to
    // call every frame.
    void update();
}
