#pragma once

extern "C" {
#include <lua.h>
}

namespace ota_bindings {

// Register the ez.ota module
void registerBindings(lua_State* L);

// Pump the dev OTA web server. Cheap no-op when the server isn't running,
// so it's safe to call from the main loop on every frame.
void update();

// Stop the dev OTA server and free resources. Safe to call when nothing
// is running.
void shutdown();

} // namespace ota_bindings
