// tdeck.system module bindings
// Provides system utilities: timing, memory info, logging, hot reload

#include "../lua_bindings.h"
#include "../lua_runtime.h"
#include "../../hardware/usb_msc.h"
#include <Arduino.h>
#include <esp_heap_caps.h>
#include <LittleFS.h>
#include <SD.h>

// Timer entry for scheduled callbacks
struct TimerEntry {
    int callbackRef;     // Registry reference to Lua callback
    uint32_t interval;   // Interval in ms (0 for one-shot)
    uint32_t nextTrigger;
    bool active;
};

// Simple timer pool (limited number of active timers)
static constexpr int MAX_TIMERS = 16;
static TimerEntry timers[MAX_TIMERS];
static int nextTimerId = 1;
static lua_State* timerLuaState = nullptr;

// @lua tdeck.system.millis() -> integer
// @brief Returns milliseconds since boot
// @return Milliseconds elapsed since device started
LUA_FUNCTION(l_system_millis) {
    lua_pushinteger(L, millis());
    return 1;
}

// @lua tdeck.system.delay(ms)
// @brief Blocking delay execution
// @param ms Delay duration in milliseconds (max 60000)
LUA_FUNCTION(l_system_delay) {
    LUA_CHECK_ARGC(L, 1);
    int ms = luaL_checkinteger(L, 1);
    if (ms > 0 && ms < 60000) {  // Cap at 60 seconds for safety
        delay(ms);
    }
    return 0;
}

// @lua tdeck.system.set_timer(ms, callback) -> integer
// @brief Schedule a one-shot callback
// @param ms Delay before callback fires
// @param callback Function to call
// @return Timer ID for cancellation
// @example
// tdeck.system.set_timer(1000, function() print("Done!") end)
// @end
LUA_FUNCTION(l_system_set_timer) {
    LUA_CHECK_ARGC(L, 2);
    int ms = luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);

    // Find free timer slot
    int slot = -1;
    for (int i = 0; i < MAX_TIMERS; i++) {
        if (!timers[i].active) {
            slot = i;
            break;
        }
    }

    if (slot < 0) {
        return luaL_error(L, "No free timer slots");
    }

    // Store callback in registry
    lua_pushvalue(L, 2);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);

    // Set up timer
    timers[slot].callbackRef = ref;
    timers[slot].interval = 0;  // One-shot
    timers[slot].nextTrigger = millis() + ms;
    timers[slot].active = true;
    timerLuaState = L;

    // Return timer ID (slot + base)
    int timerId = nextTimerId++;
    lua_pushinteger(L, timerId);
    return 1;
}

// @lua tdeck.system.set_interval(ms, callback) -> integer
// @brief Schedule a repeating callback
// @param ms Interval between calls (minimum 10ms)
// @param callback Function to call repeatedly
// @return Timer ID for cancellation
// @example
// local id = tdeck.system.set_interval(1000, function() print("tick") end)
// @end
LUA_FUNCTION(l_system_set_interval) {
    LUA_CHECK_ARGC(L, 2);
    int ms = luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);

    if (ms < 10) {
        return luaL_error(L, "Interval must be >= 10ms");
    }

    // Find free timer slot
    int slot = -1;
    for (int i = 0; i < MAX_TIMERS; i++) {
        if (!timers[i].active) {
            slot = i;
            break;
        }
    }

    if (slot < 0) {
        return luaL_error(L, "No free timer slots");
    }

    // Store callback in registry
    lua_pushvalue(L, 2);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);

    // Set up repeating timer
    timers[slot].callbackRef = ref;
    timers[slot].interval = ms;
    timers[slot].nextTrigger = millis() + ms;
    timers[slot].active = true;
    timerLuaState = L;

    lua_pushinteger(L, slot);
    return 1;
}

// @lua tdeck.system.cancel_timer(timer_id)
// @brief Cancel a scheduled timer
// @param timer_id ID returned by set_timer or set_interval
LUA_FUNCTION(l_system_cancel_timer) {
    LUA_CHECK_ARGC(L, 1);
    int slot = luaL_checkinteger(L, 1);

    if (slot >= 0 && slot < MAX_TIMERS && timers[slot].active) {
        luaL_unref(L, LUA_REGISTRYINDEX, timers[slot].callbackRef);
        timers[slot].active = false;
    }

    return 0;
}

// @lua tdeck.system.get_battery_percent() -> integer
// @brief Get battery charge level
// @return Battery percentage (0-100)
LUA_FUNCTION(l_system_get_battery_percent) {
    // Read battery ADC (pin 4 on T-Deck Plus)
    // This is a rough estimate - actual calibration may be needed
    int raw = analogRead(4);

    // T-Deck Plus uses voltage divider: full = ~2150, empty = ~1650
    // Map to 0-100%
    int percent = map(raw, 1650, 2150, 0, 100);
    percent = constrain(percent, 0, 100);

    lua_pushinteger(L, percent);
    return 1;
}

// @lua tdeck.system.get_battery_voltage() -> number
// @brief Get battery voltage
// @return Estimated battery voltage in volts
LUA_FUNCTION(l_system_get_battery_voltage) {
    int raw = analogRead(4);
    // Approximate conversion (calibration needed for accuracy)
    float voltage = (raw / 4095.0f) * 3.3f * 2.0f;  // Assuming 2:1 divider
    lua_pushnumber(L, voltage);
    return 1;
}

// @lua tdeck.system.get_free_heap() -> integer
// @brief Get free internal RAM
// @return Free heap memory in bytes
LUA_FUNCTION(l_system_get_free_heap) {
    lua_pushinteger(L, ESP.getFreeHeap());
    return 1;
}

// @lua tdeck.system.get_free_psram() -> integer
// @brief Get free PSRAM
// @return Free PSRAM in bytes
LUA_FUNCTION(l_system_get_free_psram) {
    lua_pushinteger(L, ESP.getFreePsram());
    return 1;
}

// @lua tdeck.system.get_total_heap() -> integer
// @brief Get total heap size
// @return Total heap memory in bytes
LUA_FUNCTION(l_system_get_total_heap) {
    lua_pushinteger(L, ESP.getHeapSize());
    return 1;
}

// @lua tdeck.system.get_total_psram() -> integer
// @brief Get total PSRAM size
// @return Total PSRAM in bytes
LUA_FUNCTION(l_system_get_total_psram) {
    lua_pushinteger(L, ESP.getPsramSize());
    return 1;
}

// @lua tdeck.system.log(message)
// @brief Log message to serial output
// @param message Text to log
LUA_FUNCTION(l_system_log) {
    LUA_CHECK_ARGC(L, 1);
    const char* msg = luaL_checkstring(L, 1);
    Serial.printf("[Lua] %s\n", msg);
    return 0;
}

// @lua tdeck.system.restart()
// @brief Restart the device
LUA_FUNCTION(l_system_restart) {
    Serial.println("[Lua] Restart requested");
    delay(100);  // Allow serial to flush
    ESP.restart();
    return 0;  // Never reached
}

// @lua tdeck.system.uptime() -> integer
// @brief Get device uptime
// @return Seconds since boot
LUA_FUNCTION(l_system_uptime) {
    lua_pushinteger(L, millis() / 1000);
    return 1;
}

// @lua tdeck.system.chip_model() -> string
// @brief Get ESP32 chip model name
// @return Chip model string
LUA_FUNCTION(l_system_chip_model) {
    lua_pushstring(L, ESP.getChipModel());
    return 1;
}

// @lua tdeck.system.cpu_freq() -> integer
// @brief Get CPU frequency
// @return Frequency in MHz
LUA_FUNCTION(l_system_cpu_freq) {
    lua_pushinteger(L, ESP.getCpuFreqMHz());
    return 1;
}

// @lua tdeck.system.reload_scripts() -> boolean
// @brief Reload all Lua scripts (hot reload)
// @return true if successful
LUA_FUNCTION(l_system_reload_scripts) {
    bool result = LuaRuntime::instance().reloadScripts();
    lua_pushboolean(L, result);
    return 1;
}

// @lua tdeck.system.gc()
// @brief Force full garbage collection
LUA_FUNCTION(l_system_gc) {
    LuaRuntime::instance().collectGarbage();
    return 0;
}

// @lua tdeck.system.gc_step(steps) -> integer
// @brief Perform incremental garbage collection
// @param steps Number of GC steps (default 10)
// @return Result from lua_gc
LUA_FUNCTION(l_system_gc_step) {
    int steps = luaL_optinteger(L, 1, 10);
    int result = lua_gc(L, LUA_GCSTEP, steps);
    lua_pushinteger(L, result);
    return 1;
}

// @lua tdeck.system.get_lua_memory() -> integer
// @brief Get memory used by Lua runtime
// @return Memory usage in bytes
LUA_FUNCTION(l_system_get_lua_memory) {
    lua_pushinteger(L, LuaRuntime::instance().getMemoryUsed());
    return 1;
}

// @lua tdeck.system.is_low_memory() -> boolean
// @brief Check if memory is critically low
// @return true if less than 32KB available
LUA_FUNCTION(l_system_is_low_memory) {
    lua_pushboolean(L, LuaRuntime::instance().isLowMemory());
    return 1;
}

// @lua tdeck.system.get_last_error() -> string
// @brief Get last Lua error message
// @return Error message or nil if no error
LUA_FUNCTION(l_system_get_last_error) {
    const char* err = LuaRuntime::instance().getLastError();
    if (err && err[0] != '\0') {
        lua_pushstring(L, err);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

// @lua tdeck.system.start_usb_msc() -> boolean
// @brief Start USB Mass Storage mode to access SD card from PC
// @return true if started successfully
LUA_FUNCTION(l_system_start_usb_msc) {
    lua_pushboolean(L, SDCardUSB::start());
    return 1;
}

// @lua tdeck.system.stop_usb_msc()
// @brief Stop USB Mass Storage mode
LUA_FUNCTION(l_system_stop_usb_msc) {
    SDCardUSB::stop();
    return 0;
}

// @lua tdeck.system.is_usb_msc_active() -> boolean
// @brief Check if USB MSC mode is active
// @return true if MSC mode is active
LUA_FUNCTION(l_system_is_usb_msc_active) {
    lua_pushboolean(L, SDCardUSB::isActive());
    return 1;
}

// @lua tdeck.system.is_sd_available() -> boolean
// @brief Check if SD card is available
// @return true if SD card is present and accessible
LUA_FUNCTION(l_system_is_sd_available) {
    lua_pushboolean(L, SDCardUSB::isSDAvailable());
    return 1;
}

// Function table for tdeck.system
static const luaL_Reg system_funcs[] = {
    {"millis",             l_system_millis},
    {"delay",              l_system_delay},
    {"set_timer",          l_system_set_timer},
    {"set_interval",       l_system_set_interval},
    {"cancel_timer",       l_system_cancel_timer},
    {"get_battery_percent", l_system_get_battery_percent},
    {"get_battery_voltage", l_system_get_battery_voltage},
    {"get_free_heap",      l_system_get_free_heap},
    {"get_free_psram",     l_system_get_free_psram},
    {"get_total_heap",     l_system_get_total_heap},
    {"get_total_psram",    l_system_get_total_psram},
    {"log",                l_system_log},
    {"restart",            l_system_restart},
    {"uptime",             l_system_uptime},
    {"chip_model",         l_system_chip_model},
    {"cpu_freq",           l_system_cpu_freq},
    // Phase 6: Hot reload and memory management
    {"reload_scripts",     l_system_reload_scripts},
    {"gc",                 l_system_gc},
    {"gc_step",            l_system_gc_step},
    {"get_lua_memory",     l_system_get_lua_memory},
    {"is_low_memory",      l_system_is_low_memory},
    {"get_last_error",     l_system_get_last_error},
    // USB Mass Storage for SD card file transfer
    {"start_usb_msc",      l_system_start_usb_msc},
    {"stop_usb_msc",       l_system_stop_usb_msc},
    {"is_usb_msc_active",  l_system_is_usb_msc_active},
    {"is_sd_available",    l_system_is_sd_available},
    {nullptr, nullptr}
};

// Register the system module
// Load a file from filesystem (checks SD card first, then LittleFS)
// Returns true if successful, false otherwise (with error on stack)
static bool loadScriptFile(lua_State* L, const char* path) {
    File file;

    // Check SD card first (allows overriding built-in scripts)
    // SD paths are the same as LittleFS paths
    if (SD.exists(path)) {
        file = SD.open(path, "r");
        if (file) {
            Serial.printf("[Lua] Loading from SD: %s\n", path);
        }
    }

    // Fall back to LittleFS
    if (!file) {
        file = LittleFS.open(path, "r");
    }

    if (!file) {
        lua_pushfstring(L, "cannot open %s: No such file or directory", path);
        return false;
    }

    size_t size = file.size();
    char* buffer = (char*)malloc(size + 1);
    if (!buffer) {
        file.close();
        lua_pushstring(L, "out of memory");
        return false;
    }

    file.readBytes(buffer, size);
    buffer[size] = '\0';
    file.close();

    int status = luaL_loadbuffer(L, buffer, size, path);
    free(buffer);

    if (status != LUA_OK) {
        return false;  // Error message already on stack
    }
    return true;
}

// Custom package searcher for scripts
// Searches /scripts/<module>.lua on SD card first, then LittleFS
static int l_script_searcher(lua_State* L) {
    const char* modname = luaL_checkstring(L, 1);

    // Build path: /scripts/<modname>.lua
    // First copy modname and replace dots with slashes (for nested modules like "foo.bar")
    char modpath[100];
    strncpy(modpath, modname, sizeof(modpath) - 1);
    modpath[sizeof(modpath) - 1] = '\0';

    // Replace dots with slashes for nested module paths
    for (char* p = modpath; *p; p++) {
        if (*p == '.') *p = '/';
    }

    // Build final path
    char path[128];
    snprintf(path, sizeof(path), "/scripts/%s.lua", modpath);

    // Try to load the file (checks SD then LittleFS)
    if (!loadScriptFile(L, path)) {
        // Return error message as the search result (nil + message)
        return 1;
    }

    // Return the loader function and the path
    lua_pushstring(L, path);
    return 2;
}

// Custom dofile that checks SD card first, then LittleFS
// This overrides the built-in Lua dofile to work with ESP32 filesystems
static int l_dofile_script(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    // Remember stack position before we add anything
    int base = lua_gettop(L);

    // Load script file (checks SD first, then LittleFS)
    if (!loadScriptFile(L, path)) {
        return lua_error(L);  // Error message is on stack
    }

    // Call the loaded chunk
    lua_call(L, 0, LUA_MULTRET);

    // Return only the values added after the original arguments
    return lua_gettop(L) - base;
}

void registerSystemModule(lua_State* L) {
    lua_register_module(L, "system", system_funcs);

    // Override global dofile with our custom version (checks SD first, then LittleFS)
    lua_pushcfunction(L, l_dofile_script);
    lua_setglobal(L, "dofile");

    // Add custom package searcher for scripts
    // Insert at position 2 (after preload, before standard Lua searchers)
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "searchers");
    if (lua_istable(L, -1)) {
        // Get current length
        lua_Integer len = luaL_len(L, -1);

        // Shift existing searchers (2 onwards) up by one
        for (lua_Integer i = len; i >= 2; i--) {
            lua_rawgeti(L, -1, i);
            lua_rawseti(L, -2, i + 1);
        }

        // Insert our searcher at position 2
        lua_pushcfunction(L, l_script_searcher);
        lua_rawseti(L, -2, 2);
    }
    lua_pop(L, 2);  // pop searchers and package

    Serial.println("[LuaRuntime] Registered tdeck.system");
}

// Process pending timers (called from LuaRuntime::update())
void processLuaTimers() {
    if (timerLuaState == nullptr) return;

    uint32_t now = millis();

    for (int i = 0; i < MAX_TIMERS; i++) {
        if (!timers[i].active) continue;

        if (now >= timers[i].nextTrigger) {
            // Get callback from registry
            lua_rawgeti(timerLuaState, LUA_REGISTRYINDEX, timers[i].callbackRef);

            // Call callback with no arguments
            if (lua_pcall(timerLuaState, 0, 0, 0) != LUA_OK) {
                Serial.printf("[Lua Timer] Error: %s\n", lua_tostring(timerLuaState, -1));
                lua_pop(timerLuaState, 1);
            }

            // Handle one-shot vs interval
            if (timers[i].interval == 0) {
                // One-shot: deactivate
                luaL_unref(timerLuaState, LUA_REGISTRYINDEX, timers[i].callbackRef);
                timers[i].active = false;
            } else {
                // Interval: reschedule
                timers[i].nextTrigger = now + timers[i].interval;
            }
        }
    }
}
