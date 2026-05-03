#pragma once

extern "C" {
#include <lua.h>
}

namespace ntp_bindings {
void registerBindings(lua_State* L);
}
