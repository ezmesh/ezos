// Embedded Lua scripts interface
// When NO_EMBEDDED_SCRIPTS is defined, provides inline null implementations
// Otherwise, includes the auto-generated embedded_lua_scripts.h

#pragma once

#include <cstddef>

namespace embedded_lua {

#ifdef NO_EMBEDDED_SCRIPTS

// SD-card-only build: no embedded scripts, load from SD instead
inline const char* get_script(const char* path, size_t* out_size = nullptr) {
    (void)path;
    if (out_size) *out_size = 0;
    return nullptr;
}

inline size_t get_script_count() { return 0; }
inline size_t get_total_size() { return 0; }

#else

// Normal build: use auto-generated embedded scripts
const char* get_script(const char* path, size_t* out_size = nullptr);
size_t get_script_count();
size_t get_total_size();

#endif

} // namespace embedded_lua
