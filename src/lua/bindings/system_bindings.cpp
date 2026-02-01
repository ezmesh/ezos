// ez.system module bindings
// Provides system utilities: timing, memory info, logging, hot reload

#include "../lua_bindings.h"
#include "../lua_runtime.h"
#include "../../hardware/usb_msc.h"
#include "../../util/log.h"
#include <Arduino.h>
#include <esp_heap_caps.h>
#include <esp_partition.h>
#include <esp_ota_ops.h>
#include <esp_sleep.h>
#include <esp_mac.h>
#include <LittleFS.h>
#include <SD.h>
#include <sys/time.h>

// @module ez.system
// @brief System utilities, timers, memory info, and power management
// @description
// Provides access to ESP32 system functions including heap/PSRAM memory stats,
// time and date, timers (set_timeout/set_interval), sleep modes, timezone
// configuration, and garbage collection control. Timer callbacks run in the
// main Lua context during the scheduler update cycle.
// @end

// =============================================================================
// Bus Message Topics (system module)
// =============================================================================

// @bus screen/pushed
// @brief Posted when a screen is pushed onto the navigation stack
// @payload string Screen title
// @description
// Fired after ScreenManager.push() completes. Useful for analytics,
// logging navigation paths, or updating UI elements that depend on
// the current screen.
// @example
// ez.bus.subscribe("screen/pushed", function(title)
//     print("Navigated to: " .. title)
// end)
// @end

// @bus screen/popped
// @brief Posted when a screen is removed from the navigation stack
// @payload string Screen title that was removed
// @description
// Fired after ScreenManager.pop() completes. The previous screen
// is now active.
// @example
// ez.bus.subscribe("screen/popped", function(title)
//     print("Left screen: " .. title)
// end)
// @end

// @bus screen/replaced
// @brief Posted when the current screen is replaced with another
// @payload string Format: "old_title>new_title"
// @description
// Fired when ScreenManager.replace() swaps the current screen without
// pushing to the stack. Useful for tracking screen transitions.
// @example
// ez.bus.subscribe("screen/replaced", function(data)
//     local old, new = data:match("(.+)>(.+)")
//     print("Replaced " .. old .. " with " .. new)
// end)
// @end

// @bus settings/changed
// @brief Posted when any setting value is modified
// @payload string Format: "setting_name=value"
// @description
// Fired when user changes a setting in the Settings screen.
// Can be used to react to configuration changes in real-time.
// @example
// ez.bus.subscribe("settings/changed", function(data)
//     local name, value = data:match("(.+)=(.+)")
//     if name == "brightness" then
//         print("Brightness changed to: " .. value)
//     end
// end)
// @end

// =============================================================================

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

// Forward declarations
void processLuaTimers();

// @lua ez.system.millis() -> integer
// @brief Returns milliseconds since boot
// @description Returns the number of milliseconds since the device started.
// Wraps around approximately every 49 days. Use for timing, animations, and
// measuring durations between events.
// @return Milliseconds elapsed since device started
// @example
// local start = ez.system.millis()
// -- do some work
// local elapsed = ez.system.millis() - start
// print("Took", elapsed, "ms")
// @end
LUA_FUNCTION(l_system_millis) {
    lua_pushinteger(L, millis());
    return 1;
}

// @lua ez.system.delay(ms)
// @brief Blocking delay execution
// @description Pauses execution for the specified duration. Blocks all Lua code
// but allows C++ background tasks to run. Use sparingly as it freezes the UI.
// Prefer set_timer() or set_interval() for non-blocking delays.
// @param ms Delay duration in milliseconds (max 60000)
// @example
// ez.audio.beep()
// ez.system.delay(500)  -- Wait half second
// ez.audio.beep()
// @end
LUA_FUNCTION(l_system_delay) {
    LUA_CHECK_ARGC(L, 1);
    int ms = luaL_checkinteger(L, 1);
    if (ms > 0 && ms < 60000) {  // Cap at 60 seconds for safety
        delay(ms);
    }
    return 0;
}

// @lua ez.system.set_timer(ms, callback) -> integer
// @brief Schedule a one-shot callback
// @param ms Delay before callback fires
// @param callback Function to call
// @return Timer ID for cancellation
// @example
// ez.system.set_timer(1000, function() print("Done!") end)
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

// @lua ez.system.set_interval(ms, callback) -> integer
// @brief Schedule a repeating callback
// @param ms Interval between calls (minimum 10ms)
// @param callback Function to call repeatedly
// @return Timer ID for cancellation
// @example
// local id = ez.system.set_interval(1000, function() print("tick") end)
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

// @lua ez.system.cancel_timer(timer_id)
// @brief Cancel a scheduled timer
// @description Stops a one-shot or repeating timer before it fires. Use the ID
// returned by set_timer() or set_interval(). Safe to call with an already-expired
// timer ID.
// @param timer_id ID returned by set_timer or set_interval
// @example
// local id = ez.system.set_interval(1000, tick)
// -- Later...
// ez.system.cancel_timer(id)  -- Stop the interval
// @end
LUA_FUNCTION(l_system_cancel_timer) {
    LUA_CHECK_ARGC(L, 1);
    int slot = luaL_checkinteger(L, 1);

    if (slot >= 0 && slot < MAX_TIMERS && timers[slot].active) {
        luaL_unref(L, LUA_REGISTRYINDEX, timers[slot].callbackRef);
        timers[slot].active = false;
    }

    return 0;
}

// @lua ez.system.get_battery_percent() -> integer
// @brief Get battery charge level
// @description Returns an estimated battery percentage based on ADC voltage reading.
// The value is approximate and may need calibration for your specific battery.
// Use for status display or low-battery warnings.
// @return Battery percentage (0-100)
// @example
// local pct = ez.system.get_battery_percent()
// if pct < 20 then
//     print("Low battery!")
// end
// @end
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

// @lua ez.system.get_battery_voltage() -> number
// @brief Get battery voltage
// @description Returns the estimated battery voltage. LiPo batteries are nominally
// 3.7V, fully charged ~4.2V, and depleted at ~3.0V. The reading assumes a 2:1
// voltage divider and may need calibration for accuracy.
// @return Estimated battery voltage in volts
// @example
// local v = ez.system.get_battery_voltage()
// print(string.format("Battery: %.2fV", v))
// @end
LUA_FUNCTION(l_system_get_battery_voltage) {
    int raw = analogRead(4);
    // Approximate conversion (calibration needed for accuracy)
    float voltage = (raw / 4095.0f) * 3.3f * 2.0f;  // Assuming 2:1 divider
    lua_pushnumber(L, voltage);
    return 1;
}

// @lua ez.system.get_free_heap() -> integer
// @brief Get free internal RAM
// @description Returns free internal SRAM. Critical for Lua operations and core
// system functions. If this drops below 32KB, the system may become unstable.
// Use get_free_psram() for larger allocations.
// @return Free heap memory in bytes
// @example
// local heap = ez.system.get_free_heap()
// print(string.format("Free heap: %d KB", heap / 1024))
// @end
LUA_FUNCTION(l_system_get_free_heap) {
    lua_pushinteger(L, ESP.getFreeHeap());
    return 1;
}

// @lua ez.system.get_free_psram() -> integer
// @brief Get free PSRAM
// @description Returns free external PSRAM. The ESP32-S3 on T-Deck has 8MB PSRAM
// for large allocations like framebuffers and caches. PSRAM is slower than internal
// SRAM but much more abundant.
// @return Free PSRAM in bytes
// @example
// local psram = ez.system.get_free_psram()
// print(string.format("Free PSRAM: %.1f MB", psram / (1024 * 1024)))
// @end
LUA_FUNCTION(l_system_get_free_psram) {
    lua_pushinteger(L, ESP.getFreePsram());
    return 1;
}

// @lua ez.system.get_total_heap() -> integer
// @brief Get total heap size
// @description Returns total internal SRAM available for heap allocations.
// Use with get_free_heap() to calculate usage percentage.
// @return Total heap memory in bytes
// @example
// local total = ez.system.get_total_heap()
// local free = ez.system.get_free_heap()
// print(string.format("Heap: %d%% used", 100 - (free * 100 / total)))
// @end
LUA_FUNCTION(l_system_get_total_heap) {
    lua_pushinteger(L, ESP.getHeapSize());
    return 1;
}

// @lua ez.system.get_total_psram() -> integer
// @brief Get total PSRAM size
// @description Returns total external PSRAM size. T-Deck has 8MB (8388608 bytes).
// @return Total PSRAM in bytes
// @example
// print("Total PSRAM:", ez.system.get_total_psram() / (1024*1024), "MB")
// @end
LUA_FUNCTION(l_system_get_total_psram) {
    lua_pushinteger(L, ESP.getPsramSize());
    return 1;
}

// @lua ez.system.log(message)
// @brief Log message to serial output
// @description Sends a log message to the serial console. Messages are prefixed
// with #LOG#[Lua] for easy filtering. Use for debugging during development.
// Also available as ez.log() shorthand for convenience.
// @param message Text to log
// @example
// ez.log("Starting initialization")
// ez.log("Battery at " .. ez.system.get_battery_percent() .. "%")
// @end
LUA_FUNCTION(l_system_log) {
    LUA_CHECK_ARGC(L, 1);
    const char* msg = luaL_checkstring(L, 1);
    // Prefix with #LOG# so remote control client can filter out log lines
    Serial.printf("#LOG#[Lua] %s\n", msg);
    return 0;
}

// @lua ez.system.restart()
// @brief Restart the device
// @description Performs a full system reboot. All state is lost. Use for applying
// settings that require restart or recovering from error conditions.
// @example
// print("Restarting in 3 seconds...")
// ez.system.delay(3000)
// ez.system.restart()
// @end
LUA_FUNCTION(l_system_restart) {
    LOG("Lua", "Restart requested");
    delay(100);  // Allow serial to flush
    ESP.restart();
    return 0;  // Never reached
}

// @lua ez.system.uptime() -> integer
// @brief Get device uptime
// @description Returns how long the device has been running since last boot.
// Useful for status displays and monitoring.
// @return Seconds since boot
// @example
// local up = ez.system.uptime()
// print(string.format("Uptime: %d:%02d:%02d",
//     up / 3600, (up % 3600) / 60, up % 60))
// @end
LUA_FUNCTION(l_system_uptime) {
    lua_pushinteger(L, millis() / 1000);
    return 1;
}

// @lua ez.system.get_time() -> table|nil
// @brief Get current wall clock time
// @return Table with hour, minute, second, or nil if time not set
// @example
// local t = ez.system.get_time()
// if t then print(t.hour .. ":" .. t.minute) end
// @end
LUA_FUNCTION(l_system_get_time) {
    time_t now;
    struct tm timeinfo;

    time(&now);
    localtime_r(&now, &timeinfo);

    // Check if time is valid (year > 2020 means NTP or RTC is set)
    if (timeinfo.tm_year < 120) {  // tm_year is years since 1900
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);

    lua_pushinteger(L, timeinfo.tm_hour);
    lua_setfield(L, -2, "hour");

    lua_pushinteger(L, timeinfo.tm_min);
    lua_setfield(L, -2, "minute");

    lua_pushinteger(L, timeinfo.tm_sec);
    lua_setfield(L, -2, "second");

    lua_pushinteger(L, timeinfo.tm_year + 1900);
    lua_setfield(L, -2, "year");

    lua_pushinteger(L, timeinfo.tm_mon + 1);
    lua_setfield(L, -2, "month");

    lua_pushinteger(L, timeinfo.tm_mday);
    lua_setfield(L, -2, "day");

    return 1;
}

// @lua ez.system.set_time(year, month, day, hour, minute, second) -> boolean
// @brief Set system clock time
// @param year Full year (e.g., 2024)
// @param month Month (1-12)
// @param day Day of month (1-31)
// @param hour Hour (0-23)
// @param minute Minute (0-59)
// @param second Second (0-59)
// @return true if time was set successfully
LUA_FUNCTION(l_system_set_time) {
    LUA_CHECK_ARGC(L, 6);
    int year = luaL_checkinteger(L, 1);
    int month = luaL_checkinteger(L, 2);
    int day = luaL_checkinteger(L, 3);
    int hour = luaL_checkinteger(L, 4);
    int minute = luaL_checkinteger(L, 5);
    int second = luaL_checkinteger(L, 6);

    // Validate input ranges
    if (year < 2020 || year > 2100 ||
        month < 1 || month > 12 ||
        day < 1 || day > 31 ||
        hour < 0 || hour > 23 ||
        minute < 0 || minute > 59 ||
        second < 0 || second > 59) {
        lua_pushboolean(L, false);
        return 1;
    }

    struct tm timeinfo = {};
    timeinfo.tm_year = year - 1900;  // tm_year is years since 1900
    timeinfo.tm_mon = month - 1;      // tm_mon is 0-11
    timeinfo.tm_mday = day;
    timeinfo.tm_hour = hour;
    timeinfo.tm_min = minute;
    timeinfo.tm_sec = second;

    time_t t = mktime(&timeinfo);
    struct timeval tv = { .tv_sec = t, .tv_usec = 0 };

    int result = settimeofday(&tv, nullptr);
    LOG("System", "Time set to %04d-%02d-%02d %02d:%02d:%02d (result=%d)",
        year, month, day, hour, minute, second, result);

    lua_pushboolean(L, result == 0);
    return 1;
}

// @lua ez.system.set_time_unix(timestamp) -> boolean
// @brief Set system clock from Unix timestamp
// @param timestamp Unix timestamp (seconds since 1970-01-01)
// @return true if time was set successfully
LUA_FUNCTION(l_system_set_time_unix) {
    LUA_CHECK_ARGC(L, 1);
    lua_Integer timestamp = luaL_checkinteger(L, 1);

    // Validate timestamp (must be after 2020 and before 2100)
    if (timestamp < 1577836800 || timestamp > 4102444800) {  // 2020-01-01 to 2100-01-01
        lua_pushboolean(L, false);
        return 1;
    }

    struct timeval tv = { .tv_sec = (time_t)timestamp, .tv_usec = 0 };
    int result = settimeofday(&tv, nullptr);

    LOG("System", "Time set from Unix timestamp %lld (result=%d)",
        (long long)timestamp, result);

    lua_pushboolean(L, result == 0);
    return 1;
}

// @lua ez.system.get_time_unix() -> integer
// @brief Get current Unix timestamp
// @description Returns the current time as a Unix timestamp (seconds since
// 1970-01-01 00:00:00 UTC). Returns 0 if system time has not been set from
// GPS or manual input.
// @return Unix timestamp (seconds since 1970-01-01), or 0 if time not set
// @example
// local ts = ez.system.get_time_unix()
// if ts > 0 then
//     print("Current timestamp:", ts)
// end
// @end
LUA_FUNCTION(l_system_get_time_unix) {
    time_t now;
    time(&now);

    // Check if time is valid (year > 2020)
    struct tm timeinfo;
    localtime_r(&now, &timeinfo);
    if (timeinfo.tm_year < 120) {  // tm_year is years since 1900
        lua_pushinteger(L, 0);
        return 1;
    }

    lua_pushinteger(L, (lua_Integer)now);
    return 1;
}

// @lua ez.system.set_timezone(tz_string) -> boolean
// @brief Set timezone using POSIX TZ string
// @param tz_string POSIX timezone string (e.g., "CET-1CEST,M3.5.0,M10.5.0/3")
// @return true if timezone was set successfully
// @example
// ez.system.set_timezone("CET-1CEST,M3.5.0,M10.5.0/3")  -- Amsterdam/Berlin
// ez.system.set_timezone("EST5EDT,M3.2.0,M11.1.0")      -- New York
// ez.system.set_timezone("GMT0BST,M3.5.0/1,M10.5.0")    -- London
// @end
LUA_FUNCTION(l_system_set_timezone) {
    LUA_CHECK_ARGC(L, 1);
    const char* tz = luaL_checkstring(L, 1);

    setenv("TZ", tz, 1);
    tzset();

    LOG("System", "Timezone set: TZ=%s", tz);

    lua_pushboolean(L, true);
    return 1;
}

// @lua ez.system.get_timezone() -> integer
// @brief Get current timezone UTC offset in hours
// @description Returns the difference between local time and UTC in hours.
// Positive values are east of UTC, negative are west. Accounts for DST if
// the timezone string includes daylight saving rules.
// @return UTC offset in hours
// @example
// local offset = ez.system.get_timezone()
// print("Timezone: UTC" .. (offset >= 0 and "+" or "") .. offset)
// @end
LUA_FUNCTION(l_system_get_timezone) {
    // Get current time to force timezone calculation
    time_t now;
    struct tm local_tm, utc_tm;

    time(&now);
    localtime_r(&now, &local_tm);
    gmtime_r(&now, &utc_tm);

    // Calculate offset in hours
    int local_mins = local_tm.tm_hour * 60 + local_tm.tm_min;
    int utc_mins = utc_tm.tm_hour * 60 + utc_tm.tm_min;

    // Handle day boundary
    int diff_mins = local_mins - utc_mins;
    if (diff_mins > 720) diff_mins -= 1440;  // Crossed day boundary
    if (diff_mins < -720) diff_mins += 1440;

    int offset_hours = diff_mins / 60;

    lua_pushinteger(L, offset_hours);
    return 1;
}

// @lua ez.system.chip_model() -> string
// @brief Get ESP32 chip model name
// @description Returns the specific ESP32 chip model. T-Deck Plus uses ESP32-S3.
// @return Chip model string (e.g., "ESP32-S3")
// @example
// print("Running on:", ez.system.chip_model())
// @end
LUA_FUNCTION(l_system_chip_model) {
    lua_pushstring(L, ESP.getChipModel());
    return 1;
}

// @lua ez.system.cpu_freq() -> integer
// @brief Get CPU frequency
// @description Returns the current CPU clock frequency. ESP32-S3 typically runs
// at 240MHz but can be reduced for power saving.
// @return Frequency in MHz
// @example
// print("CPU:", ez.system.cpu_freq(), "MHz")
// @end
LUA_FUNCTION(l_system_cpu_freq) {
    lua_pushinteger(L, ESP.getCpuFreqMHz());
    return 1;
}

// @lua ez.system.reload_scripts() -> boolean
// @brief Reload all Lua scripts (hot reload)
// @description Reinitializes the Lua runtime and reloads all scripts. Useful
// during development to test changes without rebooting. Screen stack and state
// are reset.
// @return true if reload successful
// @example
// if ez.system.reload_scripts() then
//     print("Scripts reloaded")
// end
// @end
LUA_FUNCTION(l_system_reload_scripts) {
    bool result = LuaRuntime::instance().reloadScripts();
    lua_pushboolean(L, result);
    return 1;
}

// @lua ez.system.gc()
// @brief Force full garbage collection
// @description Runs a complete garbage collection cycle immediately. Use after
// unloading screens or when memory is low. The main loop runs incremental GC
// automatically, so manual calls are rarely needed.
// @example
// unload_module("large_module")
// ez.system.gc()  -- Reclaim memory immediately
// @end
LUA_FUNCTION(l_system_gc) {
    LuaRuntime::instance().collectGarbage();
    return 0;
}

// @lua ez.system.gc_step(steps) -> integer
// @brief Perform incremental garbage collection
// @description Runs a limited number of GC steps without completing a full cycle.
// Used by the main loop to spread GC work across frames, preventing frame drops.
// @param steps Number of GC steps (default 10)
// @return 1 if collection finished, 0 if more work needed
// @example
// ez.system.gc_step(5)  -- Do a little GC work
// @end
LUA_FUNCTION(l_system_gc_step) {
    int steps = luaL_optinteger(L, 1, 10);
    int result = lua_gc(L, LUA_GCSTEP, steps);
    lua_pushinteger(L, result);
    return 1;
}

// @lua ez.system.get_lua_memory() -> integer
// @brief Get memory used by Lua runtime
// @description Returns memory currently allocated by the Lua VM for scripts,
// tables, and strings. Use to monitor memory growth and detect leaks.
// @return Memory usage in bytes
// @example
// print("Lua using:", ez.system.get_lua_memory() / 1024, "KB")
// @end
LUA_FUNCTION(l_system_get_lua_memory) {
    lua_pushinteger(L, LuaRuntime::instance().getMemoryUsed());
    return 1;
}

// @lua ez.system.is_low_memory() -> boolean
// @brief Check if memory is critically low
// @description Returns true when free heap drops below 32KB. At this level, the
// system may become unstable. Consider unloading unused modules or triggering GC.
// @return true if less than 32KB heap available
// @example
// if ez.system.is_low_memory() then
//     ez.system.gc()
//     print("Warning: Low memory")
// end
// @end
LUA_FUNCTION(l_system_is_low_memory) {
    lua_pushboolean(L, LuaRuntime::instance().isLowMemory());
    return 1;
}

// @lua ez.system.get_last_error() -> string
// @brief Get last Lua error message
// @description Returns the most recent error message from a failed Lua operation.
// Useful for debugging when pcall returns false or a module fails to load.
// @return Error message string, or nil if no error
// @example
// local err = ez.system.get_last_error()
// if err then print("Last error:", err) end
// @end
LUA_FUNCTION(l_system_get_last_error) {
    const char* err = LuaRuntime::instance().getLastError();
    if (err && err[0] != '\0') {
        lua_pushstring(L, err);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

// @lua ez.system.start_usb_msc() -> boolean
// @brief Start USB Mass Storage mode to access SD card from PC
// @description Presents the SD card as a USB drive to the connected computer.
// The device appears as a removable drive for file transfer. While MSC mode
// is active, ezOS cannot access the SD card. Call stop_usb_msc() to resume
// normal operation.
// @return true if MSC mode started successfully
// @example
// if ez.system.start_usb_msc() then
//     print("SD card now accessible from PC")
// end
// @end
LUA_FUNCTION(l_system_start_usb_msc) {
    lua_pushboolean(L, SDCardUSB::start());
    return 1;
}

// @lua ez.system.stop_usb_msc()
// @brief Stop USB Mass Storage mode
// @description Exits USB Mass Storage mode and returns SD card control to ezOS.
// Always call this after file transfers are complete to restore normal operation.
// @example
// ez.system.stop_usb_msc()
// print("SD card returned to ezOS")
// @end
LUA_FUNCTION(l_system_stop_usb_msc) {
    SDCardUSB::stop();
    return 0;
}

// @lua ez.system.is_usb_msc_active() -> boolean
// @brief Check if USB MSC mode is active
// @description Returns true if the device is currently in USB Mass Storage mode.
// SD card operations will fail while MSC is active.
// @return true if MSC mode is active
// @example
// if ez.system.is_usb_msc_active() then
//     print("USB mode - SD not available to Lua")
// end
// @end
LUA_FUNCTION(l_system_is_usb_msc_active) {
    lua_pushboolean(L, SDCardUSB::isActive());
    return 1;
}

// @lua ez.system.is_sd_available() -> boolean
// @brief Check if SD card is available
// @description Checks if an SD card is inserted and accessible. Returns false
// if no card is present, card is damaged, or USB MSC mode is active.
// @return true if SD card is present and accessible
// @example
// if not ez.system.is_sd_available() then
//     print("Please insert SD card")
// end
// @end
LUA_FUNCTION(l_system_is_sd_available) {
    lua_pushboolean(L, SDCardUSB::isSDAvailable());
    return 1;
}

// @lua ez.system.get_firmware_info() -> table
// @brief Get firmware partition info
// @description Returns information about the running firmware partition including
// size, app binary size, and available space for OTA updates.
// @return Table with partition_size, app_size, free_bytes, partition_label, flash_chip_size
// @example
// local info = ez.system.get_firmware_info()
// print("Partition:", info.partition_label)
// print("App size:", info.app_size / 1024, "KB")
// @end
LUA_FUNCTION(l_system_get_firmware_info) {
    lua_newtable(L);

    // Get the running app partition
    const esp_partition_t* running = esp_ota_get_running_partition();
    if (running) {
        lua_pushinteger(L, running->size);
        lua_setfield(L, -2, "partition_size");

        // Get the actual app size from the app descriptor
        esp_app_desc_t app_desc;
        if (esp_ota_get_partition_description(running, &app_desc) == ESP_OK) {
            // The partition size is the max, we need the actual binary size
            // Use the OTA data to get the actual image size
            esp_ota_img_states_t state;
            if (esp_ota_get_state_partition(running, &state) == ESP_OK) {
                // We can't easily get exact binary size, but we can estimate
                // by getting the sketch size from ESP Arduino API
                lua_pushinteger(L, ESP.getSketchSize());
                lua_setfield(L, -2, "app_size");

                lua_pushinteger(L, running->size - ESP.getSketchSize());
                lua_setfield(L, -2, "free_bytes");
            }
        }

        lua_pushstring(L, running->label);
        lua_setfield(L, -2, "partition_label");
    }

    // Also get total flash size
    lua_pushinteger(L, ESP.getFlashChipSize());
    lua_setfield(L, -2, "flash_chip_size");

    return 1;
}

// Global loop delay setting (accessed by main.cpp)
uint32_t g_loopDelayMs = 0;

// @lua ez.system.set_loop_delay(ms)
// @brief Set the main loop delay in milliseconds
// @description Adds a delay at the end of each main loop iteration. Can reduce
// CPU usage and heat when fast updates aren't needed. Default 0 for maximum
// responsiveness.
// @param ms Delay in milliseconds (0-100, default 0)
// @example
// ez.system.set_loop_delay(10)  -- ~100 FPS max
// @end
LUA_FUNCTION(l_system_set_loop_delay) {
    int ms = luaL_checkinteger(L, 1);
    if (ms < 0) ms = 0;
    if (ms > 100) ms = 100;
    g_loopDelayMs = ms;
    return 0;
}

// @lua ez.system.get_loop_delay() -> integer
// @brief Get the current main loop delay in milliseconds
// @description Returns the delay added at the end of each main loop iteration.
// @return Current loop delay in milliseconds
// @example
// print("Loop delay:", ez.system.get_loop_delay(), "ms")
// @end
LUA_FUNCTION(l_system_get_loop_delay) {
    lua_pushinteger(L, g_loopDelayMs);
    return 1;
}

// @lua ez.system.yield(ms)
// @brief Yield execution to allow C++ background tasks to run
// @description Temporarily yields execution to allow background C++ tasks (radio,
// GPS, timers) to run. Also processes Lua timers. Essential in custom main loops
// to prevent watchdog timeouts and keep mesh networking responsive.
// @param ms Optional sleep time in milliseconds (default 1, max 100)
// @example
// while game_running do
//     update_game()
//     render_game()
//     ez.system.yield(10)  -- Give background tasks time to run
// end
// @end
LUA_FUNCTION(l_system_yield) {
    int ms = luaL_optinteger(L, 1, 1);
    if (ms < 0) ms = 0;
    if (ms > 100) ms = 100;  // Cap to prevent long blocks

    // Process timers while yielding
    processLuaTimers();

    // Small delay to yield to other tasks
    if (ms > 0) {
        delay(ms);
    } else {
        yield();  // Arduino yield for watchdog
    }

    return 0;
}

// @lua ez.system.deep_sleep(seconds)
// @brief Enter deep sleep mode, device will reboot on wake
// @description Deep sleep is the lowest power mode (~10µA). The CPU and most RAM
// are powered off, so all program state is lost. When the device wakes (via timer
// or GPIO), it performs a full reboot and starts from setup().
// Use this for long idle periods (hours/days) where you want maximum battery life.
// For shorter pauses where you need to preserve state, use light_sleep() instead.
// @param seconds Sleep duration (0 = indefinite, wake on GPIO only)
LUA_FUNCTION(l_system_deep_sleep) {
    int seconds = luaL_optinteger(L, 1, 0);

    // Configure timer wake source if duration specified
    if (seconds > 0) {
        esp_sleep_enable_timer_wakeup((uint64_t)seconds * 1000000ULL);
    }

    // Configure GPIO wake source (trackball button on GPIO 0)
    esp_sleep_enable_ext0_wakeup(GPIO_NUM_0, 0);

    LOG("System", "Entering deep sleep...");
    Serial.flush();

    // Enter deep sleep - does not return, device reboots on wake
    esp_deep_sleep_start();

    return 0;  // Never reached
}

// @lua ez.system.light_sleep(seconds) -> string
// @brief Enter light sleep mode, execution continues on wake
// @param seconds Sleep duration (0 = indefinite, wake on GPIO only)
// @return Wake reason: "timer", "gpio", or "unknown"
LUA_FUNCTION(l_system_light_sleep) {
    int seconds = luaL_optinteger(L, 1, 0);

    // Configure timer wake source if duration specified
    if (seconds > 0) {
        esp_sleep_enable_timer_wakeup((uint64_t)seconds * 1000000ULL);
    }

    // Configure GPIO wake source (trackball button on GPIO 0)
    esp_sleep_enable_ext0_wakeup(GPIO_NUM_0, 0);

    // Enter light sleep - blocks until wake
    esp_err_t err = esp_light_sleep_start();

    if (err != ESP_OK) {
        lua_pushstring(L, "error");
        return 1;
    }

    // Return wake reason
    esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
    switch (cause) {
        case ESP_SLEEP_WAKEUP_TIMER: lua_pushstring(L, "timer"); break;
        case ESP_SLEEP_WAKEUP_EXT0:  lua_pushstring(L, "gpio"); break;
        case ESP_SLEEP_WAKEUP_EXT1:  lua_pushstring(L, "gpio"); break;
        default:                      lua_pushstring(L, "unknown"); break;
    }
    return 1;
}

// @lua ez.system.get_wake_reason() -> string
// @brief Get the reason the device woke from sleep
// @return Wake reason: "timer", "gpio", "touch", "ulp", "reset"
LUA_FUNCTION(l_system_get_wake_reason) {
    esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();

    switch (cause) {
        case ESP_SLEEP_WAKEUP_TIMER:     lua_pushstring(L, "timer"); break;
        case ESP_SLEEP_WAKEUP_EXT0:      lua_pushstring(L, "gpio"); break;
        case ESP_SLEEP_WAKEUP_EXT1:      lua_pushstring(L, "gpio"); break;
        case ESP_SLEEP_WAKEUP_TOUCHPAD:  lua_pushstring(L, "touch"); break;
        case ESP_SLEEP_WAKEUP_ULP:       lua_pushstring(L, "ulp"); break;
        default:                          lua_pushstring(L, "reset"); break;
    }
    return 1;
}

// @lua ez.system.get_mac_address() -> string
// @brief Get the device MAC address
// @return MAC address as hex string (e.g., "AA:BB:CC:DD:EE:FF")
LUA_FUNCTION(l_system_get_mac_address) {
    uint8_t mac[6];
    esp_read_mac(mac, ESP_MAC_WIFI_STA);

    char macStr[18];
    snprintf(macStr, sizeof(macStr), "%02X:%02X:%02X:%02X:%02X:%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    lua_pushstring(L, macStr);
    return 1;
}

// Function table for ez.system
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
    {"restart",            l_system_restart},
    {"uptime",             l_system_uptime},
    {"get_time",           l_system_get_time},
    {"set_time",           l_system_set_time},
    {"get_time_unix",      l_system_get_time_unix},
    {"set_time_unix",      l_system_set_time_unix},
    {"set_timezone",       l_system_set_timezone},
    {"get_timezone",       l_system_get_timezone},
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
    {"get_firmware_info",  l_system_get_firmware_info},
    {"yield",              l_system_yield},
    {"set_loop_delay",     l_system_set_loop_delay},
    {"get_loop_delay",     l_system_get_loop_delay},
    // Power management
    {"deep_sleep",         l_system_deep_sleep},
    {"light_sleep",        l_system_light_sleep},
    {"get_wake_reason",    l_system_get_wake_reason},
    {"get_mac_address",    l_system_get_mac_address},
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
            LOG("Lua", "Loading from SD: %s", path);
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

    // Add ez.log as shorthand for ez.system.log
    lua_getglobal(L, "ez");
    lua_pushcfunction(L, l_system_log);
    lua_setfield(L, -2, "log");
    lua_pop(L, 1);

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

    LOG("LuaRuntime", "Registered ez.system");
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
                LOG("Lua Timer", "Error: %s", lua_tostring(timerLuaState, -1));
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
