#include "gps_bindings.h"
#include "../../hardware/gps.h"

// tdeck.gps.init() -> boolean
static int l_gps_init(lua_State* L) {
    bool success = GPS::instance().init();
    lua_pushboolean(L, success);
    return 1;
}

// tdeck.gps.update() - call from main loop
static int l_gps_update(lua_State* L) {
    GPS::instance().update();
    return 0;
}

// tdeck.gps.get_location() -> {lat, lon, alt, valid, age} or nil
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

// tdeck.gps.get_time() -> {hour, min, sec, year, month, day, valid, synced} or nil
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

// tdeck.gps.get_movement() -> {speed, course} or nil
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

// tdeck.gps.get_satellites() -> {count, hdop}
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

// tdeck.gps.sync_time() -> boolean
static int l_gps_sync_time(lua_State* L) {
    bool success = GPS::instance().syncSystemTime();
    lua_pushboolean(L, success);
    return 1;
}

// tdeck.gps.get_stats() -> {chars, sentences, failed}
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

// tdeck.gps.is_valid() -> boolean (has valid location fix)
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
    lua_getglobal(L, "tdeck");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_setglobal(L, "tdeck");
        lua_getglobal(L, "tdeck");
    }

    // Create gps subtable
    lua_newtable(L);
    luaL_setfuncs(L, gps_funcs, 0);
    lua_setfield(L, -2, "gps");

    lua_pop(L, 1);  // pop tdeck table

    Serial.println("[GPS] Lua bindings registered");
}
