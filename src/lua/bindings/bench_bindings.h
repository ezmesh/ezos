#pragma once

extern "C" {
#include <lua.h>
}

namespace bench_bindings {
    // Registers ez.bench.* helpers used by the on-device test suite
    // (tools/remote/tests/test_benchmarks.py and test_boot_profile.py).
    // Same trust model as ez.debug.*: test-only scaffolding, not part of
    // the public Lua API.
    void registerBindings(lua_State* L);
}
