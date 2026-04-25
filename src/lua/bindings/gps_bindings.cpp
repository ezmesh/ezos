#include "gps_bindings.h"
#include "../../hardware/gps.h"

// @module ez.gps
// @brief GPS receiver for location, time, and navigation data
// @description
// Interfaces with the optional GPS module for position, altitude, speed, and
// satellite-synchronized time. The GPS runs continuously in the background
// once initialized, updating location data as fixes are acquired. Can auto-sync
// the system clock from GPS time for accurate timestamps without network access.
// @end

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

    lua_pushinteger(L, gps.getPassedChecksums());
    lua_setfield(L, -2, "passed");

    lua_pushinteger(L, gps.getSentencesWithFix());
    lua_setfield(L, -2, "sentences");

    lua_pushinteger(L, gps.getFailedChecksums());
    lua_setfield(L, -2, "failed");

    lua_pushinteger(L, gps.getSatsInView());
    lua_setfield(L, -2, "sats_in_view");

    lua_pushinteger(L, gps.getFixMode());
    lua_setfield(L, -2, "fix_mode");

    lua_pushinteger(L, gps.getFixQuality());
    lua_setfield(L, -2, "fix_quality");

    uint32_t age = gps.getLastByteAge();
    if (age == UINT32_MAX) {
        lua_pushnil(L);
    } else {
        lua_pushinteger(L, age);
    }
    lua_setfield(L, -2, "last_byte_age");

    lua_pushstring(L, gps.getTalkerIds());
    lua_setfield(L, -2, "talkers");

    lua_pushboolean(L, gps.isInitialized());
    lua_setfield(L, -2, "initialized");

    return 1;
}

// @lua ez.gps.reset_stats()
// @brief Zero the diagnostics counters and clear cached fix state
// @description Useful when debugging: snapshot the current running totals
// so subsequent get_stats() calls start from zero again. Also forgets the
// last position/satellite numbers so stale values don't linger on screen
// until the next NMEA arrives. The underlying parser keeps running; only
// the reported counters are rebased.
// @end
static int l_gps_reset_stats(lua_State* L) {
    GPS::instance().resetCounters();
    return 0;
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

// @lua ez.gps.send_command(body) -> boolean
// @brief Send a proprietary NMEA command to the GPS module
// @description Accepts the body of an NMEA sentence — everything between
// '$' and '*'. The XOR checksum and CRLF terminator are appended automatically.
// Used to send vendor-specific configuration commands (e.g. $PCAS04 to select
// constellations on a Quectel L76K). Fire-and-forget; any response from the
// module shows up in get_last_info_sentence() once the line completes.
// @return true if the UART is open and the command was written
// @example
// ez.gps.send_command("PCAS06,0")  -- query firmware version
// ez.gps.send_command("PCAS04,7")  -- enable GPS+BDS+GLONASS on L76K
// @end
static int l_gps_send_command(lua_State* L) {
    const char* body = luaL_checkstring(L, 1);
    bool ok = GPS::instance().sendCommand(body);
    lua_pushboolean(L, ok);
    return 1;
}

// @lua ez.gps.get_last_info_sentence() -> string
// @brief Most recently captured proprietary or TXT NMEA sentence
// @description Returns the verbatim text of the last "$P..." or "$GxTXT"
// sentence the module emitted. These are typically responses to commands
// sent via send_command(), or vendor status messages. Empty string if the
// module hasn't emitted one since boot (or since reset_stats()).
// @return Sentence string, e.g. "$GPTXT,01,01,02,SW=URANUS5,V5.1.0.0*1D"
// @end
static int l_gps_get_last_info_sentence(lua_State* L) {
    lua_pushstring(L, GPS::instance().getLastInfoSentence());
    return 1;
}

// @lua ez.gps.query_chip([timeout_ms]) -> table|nil
// @brief Identify the GNSS chip via UBX-MON-VER
// @description Sends UBX-MON-VER and blocks (up to timeout_ms, default 800)
// for the receiver's reply. On success returns { sw = "...", hw = "..." }
// with the firmware/hardware version strings. Returns nil on timeout or
// when the chip doesn't speak UBX (the L76K variant won't respond).
// @example
// local info = ez.gps.query_chip()
// if info then print("Chip:", info.hw, "FW:", info.sw) end
// @end
static int l_gps_query_chip(lua_State* L) {
    uint32_t timeout = (uint32_t)luaL_optinteger(L, 1, 800);
    GPS& gps = GPS::instance();
    bool ok = gps.queryVersion(timeout);
    if (!ok) { lua_pushnil(L); return 1; }
    lua_newtable(L);
    lua_pushstring(L, gps.getSwVersion()); lua_setfield(L, -2, "sw");
    lua_pushstring(L, gps.getHwVersion()); lua_setfield(L, -2, "hw");
    return 1;
}

// @lua ez.gps.get_chip_info() -> table|nil
// @brief Cached chip identification (last successful query_chip())
// @description Same fields as query_chip() but reads the cached result
// without re-querying. nil until query_chip() has succeeded once.
// @end
static int l_gps_get_chip_info(lua_State* L) {
    GPS& gps = GPS::instance();
    if (!gps.hasVersion()) { lua_pushnil(L); return 1; }
    lua_newtable(L);
    lua_pushstring(L, gps.getSwVersion()); lua_setfield(L, -2, "sw");
    lua_pushstring(L, gps.getHwVersion()); lua_setfield(L, -2, "hw");
    return 1;
}

// @lua ez.gps.set_signal_enabled(key_id, enabled, [timeout_ms]) -> boolean
// @brief Toggle a UBX CFG-SIGNAL-* key
// @description Sends UBX-CFG-VALSET writing the L1-typed key to RAM, BBR
// and Flash so the change persists across reboots. Blocks until UBX-ACK
// arrives or timeout fires. Returns true on ACK, false on NAK / timeout.
// Common key IDs (u-blox M10):
//   0x1031001F GPS, 0x10310020 SBAS, 0x10310021 Galileo,
//   0x10310022 BeiDou, 0x10310024 QZSS, 0x10310025 GLONASS
// @end
static int l_gps_set_signal_enabled(lua_State* L) {
    lua_Integer keyId  = luaL_checkinteger(L, 1);
    bool enabled       = lua_toboolean(L, 2);
    uint32_t timeout   = (uint32_t)luaL_optinteger(L, 3, 800);
    bool ok = GPS::instance().setSignalEnabled((uint32_t)keyId, enabled, timeout);
    lua_pushboolean(L, ok);
    return 1;
}

// @lua ez.gps.get_signal_enabled(key_id, [timeout_ms]) -> boolean|nil
// @brief Read a UBX CFG-SIGNAL-* key from the chip
// @description Sends UBX-CFG-VALGET for the key and blocks for the
// reply. Returns true / false for the boolean value, or nil on timeout.
// @end
static int l_gps_get_signal_enabled(lua_State* L) {
    lua_Integer keyId  = luaL_checkinteger(L, 1);
    uint32_t timeout   = (uint32_t)luaL_optinteger(L, 2, 800);
    int v = GPS::instance().queryConfigKey((uint32_t)keyId, timeout);
    if (v < 0) { lua_pushnil(L); }
    else       { lua_pushboolean(L, v != 0); }
    return 1;
}

static const luaL_Reg gps_funcs[] = {
    {"init",                   l_gps_init},
    {"update",                 l_gps_update},
    {"get_location",           l_gps_get_location},
    {"get_time",               l_gps_get_time},
    {"get_movement",           l_gps_get_movement},
    {"get_satellites",         l_gps_get_satellites},
    {"sync_time",              l_gps_sync_time},
    {"get_stats",              l_gps_get_stats},
    {"reset_stats",            l_gps_reset_stats},
    {"is_valid",               l_gps_is_valid},
    {"send_command",           l_gps_send_command},
    {"get_last_info_sentence", l_gps_get_last_info_sentence},
    {"query_chip",             l_gps_query_chip},
    {"get_chip_info",          l_gps_get_chip_info},
    {"set_signal_enabled",     l_gps_set_signal_enabled},
    {"get_signal_enabled",     l_gps_get_signal_enabled},
    {"_get_last_ack",          [](lua_State* L) -> int {
        GPS& gps = GPS::instance();
        lua_newtable(L);
        lua_pushboolean(L, gps.hasAck());     lua_setfield(L, -2, "received");
        lua_pushinteger(L, gps.getLastAckCls()); lua_setfield(L, -2, "cls");
        lua_pushinteger(L, gps.getLastAckId());  lua_setfield(L, -2, "id");
        lua_pushboolean(L, gps.getLastAckOk());  lua_setfield(L, -2, "ok");
        return 1;
    }},
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
