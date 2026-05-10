// ez.debug.* -- introspection bindings used by the on-device test
// suite (tools/remote/tests/). The pytest harness calls these via
// ez_remote.py -e to: drain the AsyncIO queue between cases, force
// an SD remount to exercise the openWithRetry path, snapshot heap
// pressure around suspect operations, and pull the most recent
// reset_reason + coredump_status in one call so a test can assert
// "no panic happened during this case".
//
// Kept separate from system_bindings on purpose: this is test-only
// scaffolding, and grouping it under ez.debug makes the boundary
// obvious to anyone reading app Lua.

#include "debug_bindings.h"
#include "../lua_bindings.h"
#include "../async.h"
#include "../../hardware/sd_manager.h"

#include <Arduino.h>
#include <esp_heap_caps.h>
#include <esp_core_dump.h>
#include <esp_system.h>

extern "C" {
#include <lualib.h>
#include <lauxlib.h>
}

// @lua ez.debug.asyncio_stats() -> { queued, completed, failed, in_flight, queue_depth }
// @brief Snapshot of the AsyncIO worker counters
// @description Returns a table with the running totals of requests
// that have entered the Core 0 worker, completed successfully, failed,
// the live in-flight count (queued - completed - failed), and the
// current `uxQueueMessagesWaiting` depth. Test fixtures use this to
// poll until `in_flight == 0` before asserting on side effects.
// @example
// local s = ez.debug.asyncio_stats()
// print(s.in_flight, s.queue_depth)
// @end
LUA_FUNCTION(l_debug_asyncio_stats) {
    AsyncIO::Stats s = AsyncIO::instance().getStats();
    lua_newtable(L);
    lua_pushinteger(L, (lua_Integer)s.queued);      lua_setfield(L, -2, "queued");
    lua_pushinteger(L, (lua_Integer)s.completed);   lua_setfield(L, -2, "completed");
    lua_pushinteger(L, (lua_Integer)s.failed);      lua_setfield(L, -2, "failed");
    lua_pushinteger(L, (lua_Integer)s.in_flight);   lua_setfield(L, -2, "in_flight");
    lua_pushinteger(L, (lua_Integer)s.queue_depth); lua_setfield(L, -2, "queue_depth");
    return 1;
}

// @lua ez.debug.sd_remount() -> boolean
// @brief Force SDManager::remount(), returning success
// @description Test-only hook: triggers SD.end() + SD.begin() under
// the SDManager lock, the same path openWithRetry takes after a
// failed open. Used to exercise the post-MSC-desync recovery code
// without actually plugging into a host. Returns false if the card
// is genuinely gone or busy.
// @example
// assert(ez.debug.sd_remount())
// @end
LUA_FUNCTION(l_debug_sd_remount) {
    bool ok = SDManager::remount();
    lua_pushboolean(L, ok);
    return 1;
}

// @lua ez.debug.heap() -> { free, free_psram, largest_free, largest_free_psram, min_free }
// @brief Heap-pressure snapshot for the test suite
// @description Captures the same numbers ez.system.get_free_heap /
// get_free_psram return, plus the largest contiguous free block in
// each heap (useful for spotting fragmentation independently of
// total-free) and the all-time minimum free heap since boot
// (esp_get_minimum_free_heap_size). Tests use this to fail loudly
// when a regression burns memory across runs.
// @example
// local before = ez.debug.heap()
// run_thing()
// local after = ez.debug.heap()
// assert(after.free > before.free - 8192, "leaked > 8 KiB")
// @end
LUA_FUNCTION(l_debug_heap) {
    lua_newtable(L);
    lua_pushinteger(L, (lua_Integer)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    lua_setfield(L, -2, "free");
    lua_pushinteger(L, (lua_Integer)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
    lua_setfield(L, -2, "free_psram");
    lua_pushinteger(L, (lua_Integer)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
    lua_setfield(L, -2, "largest_free");
    lua_pushinteger(L, (lua_Integer)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM));
    lua_setfield(L, -2, "largest_free_psram");
    lua_pushinteger(L, (lua_Integer)esp_get_minimum_free_heap_size());
    lua_setfield(L, -2, "min_free");
    return 1;
}

// @lua ez.debug.last_panic() -> { reset_reason, coredump_present, coredump_size }
// @brief One-shot read of reset reason + coredump partition state
// @description Shorthand for `ez.system.get_reset_reason()` paired
// with `ez.system.coredump_status()`. The test suite calls this once
// per test (after exercising suspect code) so the assertion `not
// last_panic().coredump_present` can detect a crash that the device
// has already rebooted from. `reset_reason` strings match
// `ez.system.get_reset_reason()`.
// @example
// local p = ez.debug.last_panic()
// assert(p.reset_reason ~= "panic" and not p.coredump_present)
// @end
LUA_FUNCTION(l_debug_last_panic) {
    lua_newtable(L);

    const char* name = "unknown";
    switch (esp_reset_reason()) {
        case ESP_RST_POWERON:    name = "power_on"; break;
        case ESP_RST_EXT:        name = "external"; break;
        case ESP_RST_SW:         name = "software"; break;
        case ESP_RST_PANIC:      name = "panic"; break;
        case ESP_RST_INT_WDT:    name = "int_wdt"; break;
        case ESP_RST_TASK_WDT:   name = "task_wdt"; break;
        case ESP_RST_WDT:        name = "wdt"; break;
        case ESP_RST_DEEPSLEEP:  name = "deepsleep"; break;
        case ESP_RST_BROWNOUT:   name = "brownout"; break;
        case ESP_RST_SDIO:       name = "sdio"; break;
        default: break;
    }
    lua_pushstring(L, name);
    lua_setfield(L, -2, "reset_reason");

    size_t addr = 0, size = 0;
    esp_err_t rc = esp_core_dump_image_get(&addr, &size);
    bool present = (rc == ESP_OK && size > 0);
    lua_pushboolean(L, present);
    lua_setfield(L, -2, "coredump_present");
    lua_pushinteger(L, (lua_Integer)size);
    lua_setfield(L, -2, "coredump_size");

    return 1;
}

static const luaL_Reg debug_funcs[] = {
    {"asyncio_stats", l_debug_asyncio_stats},
    {"sd_remount",    l_debug_sd_remount},
    {"heap",          l_debug_heap},
    {"last_panic",    l_debug_last_panic},
    {nullptr, nullptr},
};

namespace debug_bindings {

void registerBindings(lua_State* L) {
    lua_register_module(L, "debug", debug_funcs);
    Serial.println("[debug_bindings] Registered ez.debug.*");
}

}  // namespace debug_bindings
