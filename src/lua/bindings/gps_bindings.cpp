#include "gps_bindings.h"
#include "../../hardware/gps.h"

// @lua ez.gps.init() -> boolean
// @brief Initialize the GPS module
// @description Initializes the UART connection to the GPS module. Must be called
// before using any other GPS functions. On the T-Deck, the GPS shares UART2 and
// uses 9600 baud. Returns false if the serial port could not be configured.
// @return true if initialization successful
// @example
// if ez.gps.init() then
//     print("GPS ready")
// else
//     print("GPS init failed")
// end
// @end
static int l_gps_init(lua_State* L) {
    bool success = GPS::instance().init();
    lua_pushboolean(L, success);
    return 1;
}

// @lua ez.gps.update()
// @brief Process incoming GPS data, call from main loop
// @description Reads and parses NMEA sentences from the GPS serial buffer. Should
// be called frequently (every frame or every 100ms) to prevent buffer overflow.
// The main loop already calls this automatically, so you typically don't need to
// call it manually unless using GPS in a custom loop.
// @example
// -- Manual GPS polling loop
// while true do
//     ez.gps.update()
//     local loc = ez.gps.get_location()
//     if loc and loc.valid then
//         print(loc.lat, loc.lon)
//     end
//     ez.system.delay(100)
// end
// @end
static int l_gps_update(lua_State* L) {
    GPS::instance().update();
    return 0;
}

// @lua ez.gps.get_location() -> table|nil
// @brief Get current GPS location
// @description Returns the current GPS position with latitude, longitude, and altitude.
// The 'valid' field indicates if the GPS has a fix. The 'age' field shows milliseconds
// since the last valid position update - use this to detect stale data (age > 5000ms
// suggests no recent fix). Returns nil if GPS not initialized.
// @return Table with lat, lon, alt, valid, age (ms since last fix), or nil if not initialized
// @example
// local loc = ez.gps.get_location()
// if loc and loc.valid then
//     print(string.format("Position: %.6f, %.6f", loc.lat, loc.lon))
//     print(string.format("Altitude: %.1f m", loc.alt))
//     if loc.age > 5000 then
//         print("Warning: GPS data is stale")
//     end
// end
// @end
static int l_gps_get_location(lua_State* L) {
    GPS& gps = GPS::instance();

    if (!gps.isInitialized()) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);

    lua_pushnumber(L, gps.getLatitude());
    lua_setfield(L, -2, "lat");

    lua_pushnumber(L, gps.getLongitude());
    lua_setfield(L, -2, "lon");

    lua_pushnumber(L, gps.getAltitude());
    lua_setfield(L, -2, "alt");

    lua_pushboolean(L, gps.hasValidLocation());
    lua_setfield(L, -2, "valid");

    lua_pushinteger(L, gps.getLocationAge());
    lua_setfield(L, -2, "age");

    return 1;
}

// @lua ez.gps.get_time() -> table|nil
// @brief Get GPS time
// @description Returns UTC time from the GPS module. GPS time is highly accurate
// (atomic clock synchronized) and available even without a position fix. The 'valid'
// field indicates if the time data is valid. The 'synced' field shows if the system
// clock has been synchronized to GPS time via sync_time().
// @return Table with hour, min, sec, year, month, day, valid, synced, or nil if not initialized
// @example
// local t = ez.gps.get_time()
// if t and t.valid then
//     print(string.format("UTC: %04d-%02d-%02d %02d:%02d:%02d",
//         t.year, t.month, t.day, t.hour, t.min, t.sec))
// end
// @end
static int l_gps_get_time(lua_State* L) {
    GPS& gps = GPS::instance();

    if (!gps.isInitialized()) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);

    lua_pushinteger(L, gps.getHour());
    lua_setfield(L, -2, "hour");

    lua_pushinteger(L, gps.getMinute());
    lua_setfield(L, -2, "min");

    lua_pushinteger(L, gps.getSecond());
    lua_setfield(L, -2, "sec");

    lua_pushinteger(L, gps.getYear());
    lua_setfield(L, -2, "year");

    lua_pushinteger(L, gps.getMonth());
    lua_setfield(L, -2, "month");

    lua_pushinteger(L, gps.getDay());
    lua_setfield(L, -2, "day");

    lua_pushboolean(L, gps.hasValidTime());
    lua_setfield(L, -2, "valid");

    lua_pushboolean(L, gps.hasTimeSynced());
    lua_setfield(L, -2, "synced");

    return 1;
}

// @lua ez.gps.get_movement() -> table|nil
// @brief Get speed and heading
// @description Returns current speed and heading from GPS. Speed is in km/h and
// course is compass heading in degrees (0-360, where 0=North, 90=East). These
// values require movement to be accurate - when stationary, course may be unreliable.
// @return Table with speed (km/h) and course (degrees), or nil if not initialized
// @example
// local mov = ez.gps.get_movement()
// if mov then
//     print(string.format("Speed: %.1f km/h", mov.speed))
//     print(string.format("Heading: %.0f°", mov.course))
// end
// @end
static int l_gps_get_movement(lua_State* L) {
    GPS& gps = GPS::instance();

    if (!gps.isInitialized()) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);

    lua_pushnumber(L, gps.getSpeed());
    lua_setfield(L, -2, "speed");  // km/h

    lua_pushnumber(L, gps.getCourse());
    lua_setfield(L, -2, "course");  // degrees

    return 1;
}

// @lua ez.gps.get_satellites() -> table|nil
// @brief Get satellite info
// @description Returns satellite tracking information. Count is the number of
// satellites used in the position fix. HDOP (Horizontal Dilution of Precision)
// indicates fix quality: <1 is ideal, 1-2 is excellent, 2-5 is good, >5 is poor.
// Lower HDOP means better position accuracy.
// @return Table with count and hdop (horizontal dilution of precision), or nil if not initialized
// @example
// local sat = ez.gps.get_satellites()
// if sat then
//     print(string.format("Satellites: %d", sat.count))
//     if sat.hdop < 2 then
//         print("Excellent accuracy")
//     elseif sat.hdop < 5 then
//         print("Good accuracy")
//     else
//         print("Poor accuracy")
//     end
// end
// @end
static int l_gps_get_satellites(lua_State* L) {
    GPS& gps = GPS::instance();

    if (!gps.isInitialized()) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);

    lua_pushinteger(L, gps.getSatellites());
    lua_setfield(L, -2, "count");

    lua_pushnumber(L, gps.getHDOP());
    lua_setfield(L, -2, "hdop");

    return 1;
}

// @lua ez.gps.sync_time() -> boolean
// @brief Sync system time from GPS
// @description Sets the ESP32 system clock from GPS UTC time. This provides accurate
// time even without network connectivity. The sync is only performed if GPS has
// valid time data. After syncing, ez.system.get_time() will return accurate UTC.
// Consider calling this once after GPS gets a fix, or periodically to correct drift.
// @return true if time was synced successfully
// @example
// if ez.gps.sync_time() then
//     print("System clock synced to GPS")
//     local t = ez.system.get_time()
//     print("Current UTC:", t.hour, t.min, t.sec)
// end
// @end
static int l_gps_sync_time(lua_State* L) {
    bool success = GPS::instance().syncSystemTime();
    lua_pushboolean(L, success);
    return 1;
}

// @lua ez.gps.get_stats() -> table|nil
// @brief Get GPS parsing statistics
// @description Returns diagnostic statistics about GPS data processing. Useful for
// debugging GPS issues. 'chars' is total bytes received, 'sentences' is valid NMEA
// sentences with fix data, 'failed' is checksum errors (indicates noise or wiring
// issues if high). A high failed/sentences ratio suggests signal problems.
// @return Table with chars processed, sentences with fix, failed checksums, initialized flag
// @example
// local stats = ez.gps.get_stats()
// if stats then
//     print("Chars received:", stats.chars)
//     print("Valid sentences:", stats.sentences)
//     print("Failed checksums:", stats.failed)
//     if stats.failed > stats.sentences * 0.1 then
//         print("Warning: high checksum failure rate")
//     end
// end
// @end
static int l_gps_get_stats(lua_State* L) {
    GPS& gps = GPS::instance();

    if (!gps.isInitialized()) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);

    lua_pushinteger(L, gps.getCharsProcessed());
    lua_setfield(L, -2, "chars");

    lua_pushinteger(L, gps.getSentencesWithFix());
    lua_setfield(L, -2, "sentences");

    lua_pushinteger(L, gps.getFailedChecksums());
    lua_setfield(L, -2, "failed");

    lua_pushboolean(L, gps.isInitialized());
    lua_setfield(L, -2, "initialized");

    return 1;
}

// @lua ez.gps.is_valid() -> boolean
// @brief Check if GPS has a valid location fix
// @description Quick check if GPS currently has a valid position fix. This is
// equivalent to checking get_location().valid but more efficient when you only
// need to know fix status. Use this for status indicators or to gate GPS-dependent
// features.
// @return true if location is valid
// @example
// if ez.gps.is_valid() then
//     status_bar:set_gps_icon("fix")
// else
//     status_bar:set_gps_icon("searching")
// end
// @end
static int l_gps_is_valid(lua_State* L) {
    lua_pushboolean(L, GPS::instance().hasValidLocation());
    return 1;
}

static const luaL_Reg gps_funcs[] = {
    {"init",           l_gps_init},
    {"update",         l_gps_update},
    {"get_location",   l_gps_get_location},
    {"get_time",       l_gps_get_time},
    {"get_movement",   l_gps_get_movement},
    {"get_satellites", l_gps_get_satellites},
    {"sync_time",      l_gps_sync_time},
    {"get_stats",      l_gps_get_stats},
    {"is_valid",       l_gps_is_valid},
    {nullptr, nullptr}
};

void gps_bindings::registerBindings(lua_State* L) {
    // Get or create tdeck table
    lua_getglobal(L, "ez");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_setglobal(L, "ez");
        lua_getglobal(L, "ez");
    }

    // Create gps subtable
    lua_newtable(L);
    luaL_setfuncs(L, gps_funcs, 0);
    lua_setfield(L, -2, "gps");

    lua_pop(L, 1);  // pop tdeck table

    Serial.println("[GPS] Lua bindings registered");
}
