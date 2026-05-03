// ez.ntp module bindings
//
// Thin wrapper around lwIP's SNTP client (the same one Arduino's
// configTime() drives). Exposes:
//
//   ez.ntp.start(server1 [, server2, server3]) -> nil
//   ez.ntp.stop()                              -> nil
//   ez.ntp.is_running()                        -> boolean
//   ez.ntp.is_synced()                         -> boolean
//   ez.ntp.get_servers()                       -> table of strings
//   ez.ntp.last_sync_ms()                      -> integer | nil
//
// The Lua side (lua/services/ntp.lua) handles preset selection,
// custom-host entry, persistence, and the boot-time auto-start
// gated by `ntp_on` / `ntp_server` prefs. We deliberately keep the
// C++ surface tiny: any presets / UX policy lives in Lua so it can
// be tweaked without a rebuild.

#include "ntp_bindings.h"
#include "../lua_bindings.h"
#include "../../util/log.h"

#include <Arduino.h>
#include <esp_sntp.h>
#include <string.h>

extern "C" {
#include <lauxlib.h>
}

// @module ez.ntp
// @brief Network Time Protocol client (clock sync over WiFi)
// @description
// Wraps lwIP's SNTP. Call ez.ntp.start("pool.ntp.org") to begin
// background polling -- the client runs on its own thread, so the
// call returns immediately and ez.ntp.is_synced() flips true a few
// hundred ms after the first response. The system clock
// (ez.system.get_time / get_time_unix) is updated automatically when
// a packet arrives.
// @end

namespace ntp_bindings {

namespace {

// We track the configured servers ourselves rather than calling
// sntp_getservername() back, because that returns the resolved
// hostname/IP pointer which lwIP may rewrite at runtime; we want to
// hand the user back exactly what they passed in.
char g_servers[3][64] = {{0}, {0}, {0}};
int  g_serverCount    = 0;
bool g_running        = false;
uint32_t g_lastSyncMs = 0;

void on_sync_event(struct timeval* tv) {
    g_lastSyncMs = millis();
    LOG("NTP", "sync received: epoch=%lld",
        (long long)(tv ? tv->tv_sec : 0));
}

}  // namespace

// @lua ez.ntp.start(server1 [, server2, server3]) -> nil
// @brief Start the SNTP client with the given server(s)
// @description
// Stops any previous client and starts a fresh one polling the
// supplied hostnames. Up to three are honoured (lwIP's SNTP cap);
// extras are ignored. The first packet usually arrives in 200-800 ms
// once WiFi is up. Calling start() while already running just
// reconfigures with the new server list.
// @param server1  Primary NTP host (e.g. "pool.ntp.org")
// @param server2  Optional fallback
// @param server3  Optional fallback
// @end
LUA_FUNCTION(l_ntp_start) {
    int n = lua_gettop(L);
    if (n < 1) return luaL_error(L, "ez.ntp.start: need at least one server");

    if (esp_sntp_enabled()) {
        esp_sntp_stop();
    }

    g_serverCount = 0;
    for (int i = 1; i <= n && i <= 3; i++) {
        const char* s = luaL_checkstring(L, i);
        if (!s || !s[0]) continue;
        strncpy(g_servers[g_serverCount], s, sizeof(g_servers[0]) - 1);
        g_servers[g_serverCount][sizeof(g_servers[0]) - 1] = '\0';
        // sntp_setservername stores a pointer, not a copy. Our static
        // buffer outlives the binding call, so it's safe to hand the
        // pointer over.
        sntp_setservername(g_serverCount, g_servers[g_serverCount]);
        g_serverCount++;
    }
    if (g_serverCount == 0) {
        return luaL_error(L, "ez.ntp.start: no usable server names");
    }

    sntp_set_time_sync_notification_cb(on_sync_event);
    // SNTP_OPMODE_POLL is a plain `#define ... 0` from lwIP's
    // sntp.h, but esp_sntp_setoperatingmode wants the C++-typed
    // esp_sntp_operatingmode_t enum -- a bare `0` is rejected under
    // -fpermissive. Cast explicitly.
    esp_sntp_setoperatingmode(
        (esp_sntp_operatingmode_t)SNTP_OPMODE_POLL);
    esp_sntp_init();
    g_running = true;

    LOG("NTP", "started: %s%s%s%s%s",
        g_servers[0],
        g_serverCount > 1 ? ", " : "",
        g_serverCount > 1 ? g_servers[1] : "",
        g_serverCount > 2 ? ", " : "",
        g_serverCount > 2 ? g_servers[2] : "");
    return 0;
}

// @lua ez.ntp.stop() -> nil
// @brief Stop the SNTP client
// @description
// Halts the background polling task. The system clock keeps the value
// from the last successful sync; nothing rewinds. Safe to call when
// no client is running.
// @end
LUA_FUNCTION(l_ntp_stop) {
    if (esp_sntp_enabled()) esp_sntp_stop();
    g_running = false;
    LOG("NTP", "stopped");
    return 0;
}

// @lua ez.ntp.is_running() -> boolean
// @brief Whether the SNTP client is currently active
// @end
LUA_FUNCTION(l_ntp_is_running) {
    lua_pushboolean(L, esp_sntp_enabled());
    return 1;
}

// @lua ez.ntp.is_synced() -> boolean
// @brief True after a successful NTP packet has updated the clock
// @description
// Reflects lwIP's `sntp_get_sync_status() == SNTP_SYNC_STATUS_COMPLETED`
// -- it stays true once the first sync lands, even between subsequent
// poll-interval refreshes (the status only flips back to "in_progress"
// while the next adjustment is being applied with the smooth-update
// mode, which we don't enable).
// @end
LUA_FUNCTION(l_ntp_is_synced) {
    sntp_sync_status_t s = sntp_get_sync_status();
    lua_pushboolean(L, s == SNTP_SYNC_STATUS_COMPLETED);
    return 1;
}

// @lua ez.ntp.get_servers() -> table
// @brief Return the currently-configured server list
// @return Array of hostname strings (1-3 entries)
// @end
LUA_FUNCTION(l_ntp_get_servers) {
    lua_newtable(L);
    for (int i = 0; i < g_serverCount; i++) {
        lua_pushstring(L, g_servers[i]);
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

// @lua ez.ntp.last_sync_ms() -> integer | nil
// @brief millis() value at the most recent successful sync, or nil
// @description
// Useful for "synced 3 m ago" status lines. Returns nil before the
// first sync of this boot.
// @end
LUA_FUNCTION(l_ntp_last_sync_ms) {
    if (g_lastSyncMs == 0) {
        lua_pushnil(L);
    } else {
        lua_pushinteger(L, (lua_Integer)g_lastSyncMs);
    }
    return 1;
}

void registerBindings(lua_State* L) {
    static const luaL_Reg funcs[] = {
        {"start",        l_ntp_start},
        {"stop",         l_ntp_stop},
        {"is_running",   l_ntp_is_running},
        {"is_synced",    l_ntp_is_synced},
        {"get_servers",  l_ntp_get_servers},
        {"last_sync_ms", l_ntp_last_sync_ms},
        {nullptr, nullptr},
    };
    lua_register_module(L, "ntp", funcs);
    LOG("NTP", "Bindings registered");
}

}  // namespace ntp_bindings
