// ez.wifi module bindings
// Provides WiFi connectivity functions

#include "../lua_bindings.h"
#include "../../config.h"
#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <WiFiServer.h>
#include <WiFiClient.h>
#include <esp_wifi.h>

// @module ez.wifi
// @brief WiFi connectivity for network access
// @description
// Provides WiFi station mode for connecting to access points. Supports scanning
// for networks, connecting with SSID/password, and querying connection status.
// WiFi runs asynchronously - use is_connected() to check status after calling
// connect(). Useful for NTP time sync, firmware updates, and data transfer.
// @end

// Connection state
static bool wifiInitialized = false;
static bool connecting = false;
static unsigned long connectStartTime = 0;
static constexpr unsigned long CONNECT_TIMEOUT_MS = 15000;

// SoftAP state. Tracked separately from station state so callers can
// flip between AP-only, STA-only, and AP+STA without losing either
// side's ssid/password. The Arduino-ESP32 layer handles the actual
// esp_wifi_set_mode() transitions when we call WiFi.mode().
static bool apActive = false;

// Scan results cache
static int lastScanCount = 0;

static void ensureWifiInit() {
    if (!wifiInitialized) {
        WiFi.mode(WIFI_STA);
        WiFi.setAutoConnect(false);
        WiFi.setAutoReconnect(true);

        // Disable modem sleep. The Arduino-ESP32 default
        // (WIFI_PS_MIN_MODEM) leaves the radio dozing between beacons,
        // which on a weak link silently misses deauth frames and
        // strands the device thinking it's still associated.
        // Disabling power-save costs ~80 mA but fixes both chat
        // hangs and the WiFi-disconnect-after-OTA pattern we hit on
        // bench.
        WiFi.setSleep(false);
        esp_wifi_set_ps(WIFI_PS_NONE);

        // Max TX power (~19.5 dBm). The default on Arduino-ESP32 is
        // sometimes lower depending on board, and our T-Deck antenna
        // tends to sit at -70 dBm RSSI in typical rooms -- a few extra
        // dB on the way out makes a noticeable difference for symmetric
        // packet loss.
        WiFi.setTxPower(WIFI_POWER_19_5dBm);

        wifiInitialized = true;
        Serial.println("[WiFi] Initialized in STA mode (power-save off, TX max)");
    }
}

// Pick the wifi_mode_t that matches the combination of STA / AP flags we
// currently want running. Leaves it to the caller (start_ap / stop_ap)
// to actually assert the mode — centralizing the mapping here keeps the
// state-transition table obvious in one place.
static wifi_mode_t desiredMode(bool wantSta, bool wantAp) {
    if (wantSta && wantAp) return WIFI_AP_STA;
    if (wantAp)            return WIFI_AP;
    if (wantSta)           return WIFI_STA;
    return WIFI_OFF;
}

// @lua ez.wifi.scan() -> table
// @brief Scan for available WiFi networks
// @description Performs a synchronous scan for nearby WiFi access points. Returns
// a table of networks with SSID, RSSI (signal strength), channel, and security info.
// Scanning takes 2-3 seconds. Networks are sorted by signal strength (strongest first).
// @return Array of network tables: {ssid, rssi, channel, secure, bssid}
// @example
// local networks = ez.wifi.scan()
// for i, net in ipairs(networks) do
//     print(net.ssid, net.rssi .. "dBm")
// end
// @end
LUA_FUNCTION(l_wifi_scan) {
    ensureWifiInit();

    // Disconnect if connected to allow scan
    if (WiFi.status() == WL_CONNECTED) {
        // Keep connected, async scan
    }

    Serial.println("[WiFi] Starting scan...");
    int n = WiFi.scanNetworks(false, true);  // sync, show hidden
    lastScanCount = n;

    if (n < 0) {
        Serial.printf("[WiFi] Scan failed: %d\n", n);
        lua_newtable(L);
        return 1;
    }

    Serial.printf("[WiFi] Found %d networks\n", n);

    lua_newtable(L);

    for (int i = 0; i < n; i++) {
        lua_newtable(L);

        lua_pushstring(L, WiFi.SSID(i).c_str());
        lua_setfield(L, -2, "ssid");

        lua_pushinteger(L, WiFi.RSSI(i));
        lua_setfield(L, -2, "rssi");

        lua_pushinteger(L, WiFi.channel(i));
        lua_setfield(L, -2, "channel");

        lua_pushboolean(L, WiFi.encryptionType(i) != WIFI_AUTH_OPEN);
        lua_setfield(L, -2, "secure");

        lua_pushstring(L, WiFi.BSSIDstr(i).c_str());
        lua_setfield(L, -2, "bssid");

        lua_rawseti(L, -2, i + 1);
    }

    WiFi.scanDelete();
    return 1;
}

// @lua ez.wifi.scan_start() -> boolean
// @brief Kick off a non-blocking WiFi scan
// @description Returns immediately; poll ez.wifi.scan_status() until it
// stops returning "running", then read the result with
// ez.wifi.scan_results(). The synchronous ez.wifi.scan() blocks the
// Lua VM for 2-3 s while the radio sweeps every channel; this lets
// the UI keep rendering during the sweep.
// @return true if a scan was started (or one is already in flight)
// @end
LUA_FUNCTION(l_wifi_scan_start) {
    ensureWifiInit();

    int prev = WiFi.scanComplete();
    if (prev == WIFI_SCAN_RUNNING) {
        // Already scanning; let the caller poll status normally.
        lua_pushboolean(L, true);
        return 1;
    }
    if (prev >= 0) {
        // Stale result still buffered from a previous scan -- drop it
        // so scanComplete() goes back to "not yet" / "running" and the
        // status check below isn't confused by leftover data.
        WiFi.scanDelete();
    }

    Serial.println("[WiFi] Starting async scan...");
    // max_ms_per_chan = 600 gives Arduino's internal scan timeout
    // (`_scanTimeout = max_ms_per_chan * 20` in WiFiScan.cpp) 12 s
    // of headroom. The default 300 ms per channel only buys a 6 s
    // ceiling, which scanComplete() trips while the radio is busy
    // staying associated to the current AP -- the user reported
    // "Scan failed after a while" with that default. The actual
    // per-channel dwell stays bounded by min/max in active mode, so
    // the wider cap doesn't slow the typical 2-3 s sweep.
    int started = WiFi.scanNetworks(true, true, false, 600);
    // `started` is WIFI_SCAN_RUNNING (-1) on a successful kick-off
    // or WIFI_SCAN_FAILED (-2) when the radio refused. Treat either
    // negative-but-running as success; the caller polls status.
    lua_pushboolean(L, started == WIFI_SCAN_RUNNING || started >= 0);
    return 1;
}

// @lua ez.wifi.scan_status() -> string|integer
// @brief Check the state of an in-flight scan
// @description Returns "running" while the radio is still sweeping,
// "failed" if the driver bailed, or an integer count when the scan is
// done and results are ready to read.
// @return "running", "failed", or integer count of networks
// @end
LUA_FUNCTION(l_wifi_scan_status) {
    int n = WiFi.scanComplete();
    if (n == WIFI_SCAN_RUNNING) {
        lua_pushstring(L, "running");
    } else if (n == WIFI_SCAN_FAILED) {
        lua_pushstring(L, "failed");
    } else {
        lua_pushinteger(L, n);
    }
    return 1;
}

// @lua ez.wifi.scan_results() -> table
// @brief Read the result of the most recent completed scan
// @description Returns the same table shape as ez.wifi.scan() (one
// entry per AP with ssid, rssi, channel, secure, bssid). The buffered
// scan is cleared after read, so a second call returns an empty
// table -- store the list if you need it twice.
// @return Array of network tables: {ssid, rssi, channel, secure, bssid}
// @end
LUA_FUNCTION(l_wifi_scan_results) {
    int n = WiFi.scanComplete();
    lua_newtable(L);
    if (n <= 0) {
        // -1 (still running), -2 (failed), or 0 (no APs found) all
        // produce an empty table; the caller can use scan_status()
        // first if it needs to disambiguate.
        if (n >= 0) WiFi.scanDelete();
        return 1;
    }
    for (int i = 0; i < n; i++) {
        lua_newtable(L);

        lua_pushstring(L, WiFi.SSID(i).c_str());
        lua_setfield(L, -2, "ssid");

        lua_pushinteger(L, WiFi.RSSI(i));
        lua_setfield(L, -2, "rssi");

        lua_pushinteger(L, WiFi.channel(i));
        lua_setfield(L, -2, "channel");

        lua_pushboolean(L, WiFi.encryptionType(i) != WIFI_AUTH_OPEN);
        lua_setfield(L, -2, "secure");

        lua_pushstring(L, WiFi.BSSIDstr(i).c_str());
        lua_setfield(L, -2, "bssid");

        lua_rawseti(L, -2, i + 1);
    }
    lastScanCount = n;
    WiFi.scanDelete();
    return 1;
}

// @lua ez.wifi.connect(ssid, password) -> boolean
// @brief Connect to a WiFi network
// @description Initiates connection to the specified access point. This function
// returns immediately - use is_connected() or wait_connected() to check when
// the connection is established. Connection typically takes 2-10 seconds.
// @param ssid Network name to connect to
// @param password Network password (use empty string for open networks)
// @return true if connection was initiated
// @example
// if ez.wifi.connect("MyNetwork", "password123") then
//     -- Wait for connection
//     if ez.wifi.wait_connected(10) then
//         print("Connected! IP:", ez.wifi.get_ip())
//     end
// end
// @end
LUA_FUNCTION(l_wifi_connect) {
    LUA_CHECK_ARGC(L, 2);
    const char* ssid = luaL_checkstring(L, 1);
    const char* password = luaL_checkstring(L, 2);

    ensureWifiInit();

    // Disconnect first if already connected
    if (WiFi.status() == WL_CONNECTED) {
        WiFi.disconnect();
        delay(100);
    }

    Serial.printf("[WiFi] Connecting to '%s'...\n", ssid);

    WiFi.begin(ssid, password);
    connecting = true;
    connectStartTime = millis();

    lua_pushboolean(L, true);
    return 1;
}

// @lua ez.wifi.disconnect()
// @brief Disconnect from the current network
// @description Disconnects from the current WiFi network if connected. Safe to
// call even when not connected. After disconnecting, the radio remains in
// station mode ready for a new connection.
// @example
// ez.wifi.disconnect()
// print("Disconnected from WiFi")
// @end
LUA_FUNCTION(l_wifi_disconnect) {
    if (wifiInitialized) {
        WiFi.disconnect();
        connecting = false;
        Serial.println("[WiFi] Disconnected");
    }
    return 0;
}

// @lua ez.wifi.is_connected() -> boolean
// @brief Check if WiFi is connected
// @description Returns true if currently connected to an access point with a
// valid IP address. Use this to poll connection status after calling connect().
// @return true if connected
// @example
// if ez.wifi.is_connected() then
//     print("Online!")
// else
//     print("Not connected")
// end
// @end
LUA_FUNCTION(l_wifi_is_connected) {
    bool connected = wifiInitialized && (WiFi.status() == WL_CONNECTED);
    lua_pushboolean(L, connected);
    return 1;
}

// @lua ez.wifi.wait_connected(timeout_seconds) -> boolean
// @brief Wait for WiFi connection with timeout
// @description Blocks until WiFi is connected or timeout expires. Use after
// calling connect() to wait for the connection to be established. Returns
// true if connected, false if timeout occurred.
// @param timeout_seconds Maximum seconds to wait (default 10)
// @return true if connected, false if timeout
// @example
// ez.wifi.connect("MyNetwork", "password")
// if ez.wifi.wait_connected(15) then
//     print("Connected!")
// else
//     print("Connection timeout")
// end
// @end
LUA_FUNCTION(l_wifi_wait_connected) {
    int timeout = luaL_optintegerdefault(L, 1, 10);

    if (!wifiInitialized) {
        lua_pushboolean(L, false);
        return 1;
    }

    unsigned long start = millis();
    unsigned long timeoutMs = timeout * 1000;

    while (WiFi.status() != WL_CONNECTED && (millis() - start) < timeoutMs) {
        delay(100);
    }

    bool connected = (WiFi.status() == WL_CONNECTED);
    if (connected) {
        connecting = false;
        Serial.printf("[WiFi] Connected! IP: %s\n", WiFi.localIP().toString().c_str());
    }

    lua_pushboolean(L, connected);
    return 1;
}

// @lua ez.wifi.get_ip() -> string
// @brief Get the current IP address
// @description Returns the device's IP address as a string. Returns "0.0.0.0"
// if not connected. The IP is assigned by the access point's DHCP server.
// @return IP address string (e.g., "192.168.1.100")
// @example
// local ip = ez.wifi.get_ip()
// print("My IP:", ip)
// @end
LUA_FUNCTION(l_wifi_get_ip) {
    if (wifiInitialized && WiFi.status() == WL_CONNECTED) {
        lua_pushstring(L, WiFi.localIP().toString().c_str());
    } else {
        lua_pushstring(L, "0.0.0.0");
    }
    return 1;
}

// @lua ez.wifi.get_rssi() -> integer
// @brief Get the current signal strength
// @description Returns the RSSI (Received Signal Strength Indicator) of the
// current connection in dBm. Typical values: -30 = excellent, -67 = good,
// -70 = fair, -80 = weak, -90 = unusable. Returns 0 if not connected.
// @return Signal strength in dBm (negative number)
// @example
// local rssi = ez.wifi.get_rssi()
// if rssi > -50 then
//     print("Excellent signal")
// elseif rssi > -70 then
//     print("Good signal")
// else
//     print("Weak signal")
// end
// @end
LUA_FUNCTION(l_wifi_get_rssi) {
    if (wifiInitialized && WiFi.status() == WL_CONNECTED) {
        lua_pushinteger(L, WiFi.RSSI());
    } else {
        lua_pushinteger(L, 0);
    }
    return 1;
}

// @lua ez.wifi.get_ssid() -> string
// @brief Get the connected network name
// @description Returns the SSID of the currently connected network. Returns
// an empty string if not connected.
// @return SSID string or empty string if not connected
// @example
// local ssid = ez.wifi.get_ssid()
// print("Connected to:", ssid)
// @end
LUA_FUNCTION(l_wifi_get_ssid) {
    if (wifiInitialized && WiFi.status() == WL_CONNECTED) {
        lua_pushstring(L, WiFi.SSID().c_str());
    } else {
        lua_pushstring(L, "");
    }
    return 1;
}

// @lua ez.wifi.get_mac() -> string
// @brief Get the WiFi MAC address
// @description Returns the device's WiFi MAC address as a colon-separated
// hex string. The MAC address is unique to each device and does not change.
// @return MAC address string (e.g., "AA:BB:CC:DD:EE:FF")
// @example
// print("MAC:", ez.wifi.get_mac())
// @end
LUA_FUNCTION(l_wifi_get_mac) {
    ensureWifiInit();
    lua_pushstring(L, WiFi.macAddress().c_str());
    return 1;
}

// @lua ez.wifi.get_status() -> string
// @brief Get detailed connection status
// @description Returns a human-readable string describing the current WiFi
// status. Useful for debugging connection issues.
// @return Status string: "connected", "connecting", "disconnected", "failed", etc.
// @example
// print("WiFi status:", ez.wifi.get_status())
// @end
LUA_FUNCTION(l_wifi_get_status) {
    if (!wifiInitialized) {
        lua_pushstring(L, "disabled");
        return 1;
    }

    wl_status_t status = WiFi.status();
    const char* str;

    switch (status) {
        case WL_CONNECTED:
            str = "connected";
            break;
        case WL_NO_SSID_AVAIL:
            str = "network_not_found";
            break;
        case WL_CONNECT_FAILED:
            str = "connection_failed";
            break;
        case WL_CONNECTION_LOST:
            str = "connection_lost";
            break;
        case WL_DISCONNECTED:
            str = connecting ? "connecting" : "disconnected";
            break;
        case WL_IDLE_STATUS:
            str = "idle";
            break;
        case WL_NO_SHIELD:
            str = "no_wifi_hardware";
            break;
        default:
            str = "unknown";
            break;
    }

    lua_pushstring(L, str);
    return 1;
}

// @lua ez.wifi.get_gateway() -> string
// @brief Get the gateway IP address
// @description Returns the gateway (router) IP address. This is typically
// the IP of your WiFi router. Returns "0.0.0.0" if not connected.
// @return Gateway IP address string
// @example
// print("Gateway:", ez.wifi.get_gateway())
// @end
LUA_FUNCTION(l_wifi_get_gateway) {
    if (wifiInitialized && WiFi.status() == WL_CONNECTED) {
        lua_pushstring(L, WiFi.gatewayIP().toString().c_str());
    } else {
        lua_pushstring(L, "0.0.0.0");
    }
    return 1;
}

// @lua ez.wifi.get_dns() -> string
// @brief Get the DNS server IP address
// @description Returns the primary DNS server IP address assigned by DHCP.
// Returns "0.0.0.0" if not connected.
// @return DNS server IP address string
// @example
// print("DNS:", ez.wifi.get_dns())
// @end
LUA_FUNCTION(l_wifi_get_dns) {
    if (wifiInitialized && WiFi.status() == WL_CONNECTED) {
        lua_pushstring(L, WiFi.dnsIP().toString().c_str());
    } else {
        lua_pushstring(L, "0.0.0.0");
    }
    return 1;
}

// @lua ez.wifi.set_power(enabled)
// @brief Enable or disable WiFi radio
// @description Turns the WiFi radio on or off. Disabling WiFi saves power
// when not needed. When re-enabled, you'll need to call connect() again.
// @param enabled true to enable, false to disable
// @example
// ez.wifi.set_power(false)  -- Turn off WiFi to save power
// @end
LUA_FUNCTION(l_wifi_set_power) {
    LUA_CHECK_ARGC(L, 1);
    bool enabled = lua_toboolean(L, 1);

    if (enabled) {
        ensureWifiInit();
    } else if (wifiInitialized) {
        WiFi.disconnect();
        WiFi.mode(WIFI_OFF);
        wifiInitialized = false;
        connecting = false;
        Serial.println("[WiFi] Radio disabled");
    }

    return 0;
}

// @lua ez.wifi.is_enabled() -> boolean
// @brief Check if WiFi radio is enabled
// @description Returns true if the WiFi radio is powered on and initialized.
// Note that enabled doesn't mean connected - use is_connected() for that.
// @return true if WiFi radio is enabled
// @example
// if ez.wifi.is_enabled() then
//     print("WiFi is on")
// end
// @end
LUA_FUNCTION(l_wifi_is_enabled) {
    lua_pushboolean(L, wifiInitialized);
    return 1;
}

// ---------------------------------------------------------------------------
// SoftAP (access-point hosting)
// ---------------------------------------------------------------------------

// @lua ez.wifi.start_ap(ssid, password, channel?, hidden?, max_connection?) -> boolean
// @brief Start a WiFi access point (SoftAP)
// @description Brings up a SoftAP with the given SSID and password. If station
// mode is already active the radio transitions to AP+STA so a simultaneous
// client connection is preserved. Password must be 8+ characters (WPA2-PSK
// requirement); pass an empty string for an open network. Default channel 1,
// default SSID visible. Subsequent calls reconfigure the AP in place.
// @param ssid Network name to advertise
// @param password Network password (8+ chars, empty = open)
// @param channel 1..13, default 1
// @param hidden true to hide SSID from scan, default false
// @param max_connection Max simultaneous stations (1..10, default 4). Each
//   station costs ~2-3 kB internal heap for driver state + TCP/LWIP state,
//   so the useful ceiling on this build is ~8 before the accept path starts
//   failing on low-memory. Keep this as tight as the app actually needs.
// @return true on success
// @example
// ez.wifi.start_ap("tdeck-test", "tdeckpass")         -- default 4 clients
// ez.wifi.start_ap("party", "secret123", 6, false, 8) -- up to 8 clients
// print("AP IP:", ez.wifi.get_ap_ip())
// @end
LUA_FUNCTION(l_wifi_start_ap) {
    LUA_CHECK_ARGC_RANGE(L, 2, 5);
    const char* ssid = luaL_checkstring(L, 1);
    const char* password = luaL_checkstring(L, 2);
    int channel = luaL_optintegerdefault(L, 3, 1);
    bool hidden = lua_isnoneornil(L, 4) ? false : lua_toboolean(L, 4);
    int max_conn = luaL_optintegerdefault(L, 5, 4);
    // Clamp: the esp-idf SoftAP supports 1..10 (WIFI_MAX_CONN_NUM).
    // We hard-cap to 10 so a typo doesn't accidentally trigger an
    // esp-idf ESP_ERR_INVALID_ARG that surfaces as a vague softAP()
    // false return.
    if (max_conn < 1) max_conn = 1;
    if (max_conn > 10) max_conn = 10;

    // Open-network escape: WPA2 requires 8+ chars but passing an empty
    // string to softAP() signals "open" in the Arduino layer. Anything
    // shorter than 8 that isn't empty is rejected up front so we fail
    // loudly instead of silently dropping the config.
    size_t plen = strlen(password);
    if (plen > 0 && plen < 8) {
        return luaL_error(L,
            "WPA2 password must be at least 8 characters (got %d)", (int)plen);
    }

    // Transition to a mode that includes AP. If station side was up
    // (connected or connecting) we keep it by using WIFI_AP_STA. The
    // Arduino layer remembers the STA config and will reassociate.
    //
    // Arduino-ESP32's softAP() quietly returns false if the WiFi
    // subsystem hasn't been booted yet, so we walk STA→AP even for the
    // AP-only case to force the driver up before esp_wifi_set_config
    // fires. The transient STA state is harmless; stop_ap() will drop
    // back to the correct target mode.
    bool wantSta = wifiInitialized;
    if (!wifiInitialized) {
        WiFi.mode(WIFI_STA);
        wifiInitialized = true;
    }
    WiFi.mode(desiredMode(wantSta, true));

    const char* pass = (plen == 0) ? nullptr : password;
    bool ok = WiFi.softAP(ssid, pass, channel, hidden ? 1 : 0, max_conn);
    if (!ok) {
        // Surface the last esp_wifi error to the Lua caller so the
        // failure reason is visible from a remote-exec rather than
        // stuck in an unread serial buffer.
        uint32_t heap = ESP.getFreeHeap();
        uint32_t min_heap = ESP.getMinFreeHeap();
        Serial.printf("[WiFi] softAP() failed (heap=%u min=%u)\n",
            (unsigned)heap, (unsigned)min_heap);
        lua_pushboolean(L, false);
        lua_pushfstring(L,
            "softAP() returned false; free_heap=%d min_heap=%d",
            (int)heap, (int)min_heap);
        return 2;
    }

    apActive = true;
    Serial.printf("[WiFi] AP up: ssid='%s' ch=%d ip=%s\n",
        ssid, channel, WiFi.softAPIP().toString().c_str());

    lua_pushboolean(L, true);
    return 1;
}

// @lua ez.wifi.stop_ap()
// @brief Stop the SoftAP
// @description Tears the SoftAP down. If station mode was running, the radio
// returns to STA-only; otherwise it goes to WIFI_OFF. Safe to call when no
// AP is active.
// @example
// ez.wifi.stop_ap()
// @end
LUA_FUNCTION(l_wifi_stop_ap) {
    if (!apActive) return 0;
    WiFi.softAPdisconnect(true);
    apActive = false;
    bool wantSta = wifiInitialized;
    WiFi.mode(desiredMode(wantSta, false));
    Serial.println("[WiFi] AP down");
    return 0;
}

// @lua ez.wifi.is_ap_active() -> boolean
// @brief Check whether the SoftAP is running
// @return true if AP is up
// @end
LUA_FUNCTION(l_wifi_is_ap_active) {
    lua_pushboolean(L, apActive);
    return 1;
}

// @lua ez.wifi.get_ap_ip() -> string
// @brief Get the SoftAP's own IP address
// @description Defaults to 192.168.4.1 on Arduino-ESP32. Returns "0.0.0.0"
// if the AP isn't up.
// @end
LUA_FUNCTION(l_wifi_get_ap_ip) {
    if (!apActive) { lua_pushstring(L, "0.0.0.0"); return 1; }
    lua_pushstring(L, WiFi.softAPIP().toString().c_str());
    return 1;
}

// @lua ez.wifi.get_ap_client_count() -> integer
// @brief Number of stations currently associated to this AP
// @end
LUA_FUNCTION(l_wifi_get_ap_client_count) {
    lua_pushinteger(L, apActive ? WiFi.softAPgetStationNum() : 0);
    return 1;
}

// ---------------------------------------------------------------------------
// UDP echo + probe (minimal end-to-end connectivity test)
//
// Two primitives are enough to verify the AP actually forwards traffic:
//   udp_echo_start(port)  — installs a tiny server that mirrors every
//                           incoming datagram back to its sender. The
//                           echo is pumped via udp_pump() which is
//                           called from the main loop.
//   udp_probe(ip, port, timeout_ms)
//                         — synchronous request/reply round-trip. Sends
//                           a random 8-byte token and blocks until the
//                           same token comes back (or the timeout
//                           fires). Returns the round-trip time in ms.
//
// Kept tiny on purpose: this is a test tool, not a general socket API.
// If we ever need real TCP / UDP sockets we'll build that out in a
// separate module rather than accrete here.
// ---------------------------------------------------------------------------

static WiFiUDP echoServer;
static bool echoActive = false;
static uint16_t echoPort = 0;
// Keep small — the probe payload is 8 bytes; a 128-byte buffer leaves
// plenty of headroom for any reasonable test datagram while saving
// internal .bss compared to the default 512.
static uint8_t echoBuf[128];

// Called from the main loop to drain any pending datagrams on the echo
// server and mirror them back to their sender. Cheap when idle (a single
// parsePacket() poll that returns 0).
void wifiUdpPump() {
    if (!echoActive) return;
    int pktSize = echoServer.parsePacket();
    if (pktSize <= 0) return;
    IPAddress from = echoServer.remoteIP();
    uint16_t port = echoServer.remotePort();
    int n = echoServer.read(echoBuf,
        pktSize < (int)sizeof(echoBuf) ? pktSize : (int)sizeof(echoBuf));
    if (n <= 0) return;
    echoServer.beginPacket(from, port);
    echoServer.write(echoBuf, n);
    echoServer.endPacket();
}

// @lua ez.wifi.udp_echo_start(port) -> boolean
// @brief Start a UDP echo server
// @description Listens on the given UDP port and mirrors every datagram
// received back to its sender. Used by ez.wifi.udp_probe() on the remote
// side as the reflection target. Safe to call repeatedly — restarts on
// the new port.
// @param port 1..65535
// @return true on success
// @end
LUA_FUNCTION(l_wifi_udp_echo_start) {
    LUA_CHECK_ARGC(L, 1);
    uint16_t port = (uint16_t)luaL_checkinteger(L, 1);
    if (echoActive) echoServer.stop();
    bool ok = echoServer.begin(port);
    echoActive = ok;
    echoPort = ok ? port : 0;
    if (ok) Serial.printf("[WiFi] UDP echo on :%u\n", (unsigned)port);
    lua_pushboolean(L, ok);
    return 1;
}

// @lua ez.wifi.udp_echo_stop()
// @brief Stop the UDP echo server
// @end
LUA_FUNCTION(l_wifi_udp_echo_stop) {
    if (echoActive) {
        echoServer.stop();
        echoActive = false;
        echoPort = 0;
    }
    return 0;
}

// @lua ez.wifi.udp_probe(ip, port, timeout_ms?) -> integer|nil
// @brief Measure UDP round-trip time to an echo server
// @description Sends a fresh 8-byte random token to ip:port and waits for
// the same 8 bytes to come back. Returns the round-trip time in
// milliseconds on success, nil on timeout or transport failure. Blocks
// the caller for up to timeout_ms; intended to be used inside a spawn()
// coroutine on the screen so the UI stays responsive.
// @param ip Target IP
// @param port Target UDP port
// @param timeout_ms Default 1000
// @return Round-trip time in ms, or nil on timeout
// @end
LUA_FUNCTION(l_wifi_udp_probe) {
    LUA_CHECK_ARGC_RANGE(L, 2, 3);
    const char* ip = luaL_checkstring(L, 1);
    uint16_t port = (uint16_t)luaL_checkinteger(L, 2);
    uint32_t timeout = (uint32_t)luaL_optintegerdefault(L, 3, 1000);

    IPAddress dest;
    if (!dest.fromString(ip)) {
        Serial.printf("[WiFi] udp_probe: invalid ip '%s'\n", ip);
        lua_pushnil(L);
        return 1;
    }

    // Random token — 8 bytes from esp_random() is plenty to reject any
    // stray late-arriving echo from a previous probe during the same
    // session. Fresh bytes per call.
    uint8_t token[8];
    uint32_t r0 = esp_random();
    uint32_t r1 = esp_random();
    memcpy(token, &r0, 4);
    memcpy(token + 4, &r1, 4);

    WiFiUDP client;
    // Bind to ephemeral port (0). parsePacket() on this handle only
    // surfaces packets sent back to our bound port, which naturally
    // filters out unrelated traffic.
    if (!client.begin(0)) {
        Serial.println("[WiFi] udp_probe: bind failed");
        lua_pushnil(L);
        return 1;
    }

    uint32_t t0 = millis();
    client.beginPacket(dest, port);
    client.write(token, sizeof(token));
    if (!client.endPacket()) {
        Serial.println("[WiFi] udp_probe: send failed");
        client.stop();
        lua_pushnil(L);
        return 1;
    }

    uint8_t rx[32];
    while ((millis() - t0) < timeout) {
        int n = client.parsePacket();
        if (n >= (int)sizeof(token)) {
            int got = client.read(rx, sizeof(rx));
            if (got >= (int)sizeof(token)
                    && memcmp(rx, token, sizeof(token)) == 0) {
                uint32_t rtt = millis() - t0;
                client.stop();
                lua_pushinteger(L, (lua_Integer)rtt);
                return 1;
            }
            // Different payload — ignore and keep waiting.
        }
        delay(2);
    }

    client.stop();
    lua_pushnil(L);
    return 1;
}

// ---------------------------------------------------------------------------
// TCP blob transfer (one-shot serve + fetch)
//
// Deliberately narrow: each call handles exactly one blob in one
// direction, opens a fresh server or client socket, does the I/O, and
// tears everything down. No keepalive, no multiplexing, no handles
// exposed to Lua. The file transfer screen's whole point is a single
// file per WiFi session, so the API matches the use case.
//
// Both are blocking and pumped with delay(1) during I/O waits so the
// system watchdog + FreeRTOS scheduler keep running. They are intended
// to be called from inside spawn() on the Lua side, which lets the UI
// stay responsive (other screens can still paint while this coroutine
// yields on delay()).
// ---------------------------------------------------------------------------

// @lua ez.wifi.tcp_serve_blob(port, blob, timeout_ms?) -> integer|nil
// @brief Serve a single blob to the first TCP client that connects
// @description Opens a TCP server on the given port, waits for one
// client to connect (up to timeout_ms), writes the full blob to that
// client, closes the connection and the server. Used by the WiFi file
// transfer to serve a file's bytes to a peer without running a
// persistent service. Returns the number of bytes written on success
// or nil on timeout / error.
// @param port 1..65535
// @param blob Binary string with the full payload
// @param timeout_ms Default 30000. Applies to the accept phase AND to
//   any individual write stall — once bytes stop flowing for longer
//   than this many ms the server gives up.
// @return bytes_written, or nil on failure
// @end
LUA_FUNCTION(l_wifi_tcp_serve_blob) {
    LUA_CHECK_ARGC_RANGE(L, 2, 3);
    uint16_t port = (uint16_t)luaL_checkinteger(L, 1);
    size_t blob_len = 0;
    const char* blob = luaL_checklstring(L, 2, &blob_len);
    uint32_t timeout = (uint32_t)luaL_optintegerdefault(L, 3, 30000);

    WiFiServer server(port);
    server.begin();
    server.setNoDelay(true);

    uint32_t t0 = millis();
    WiFiClient client;
    while ((millis() - t0) < timeout) {
        client = server.available();
        if (client && client.connected()) break;
        client = WiFiClient();   // reset so next loop re-polls
        delay(5);
    }
    if (!client || !client.connected()) {
        server.stop();
        Serial.println("[WiFi] tcp_serve_blob: accept timeout");
        lua_pushnil(L);
        return 1;
    }

    // Stream the blob in 1 KB slices so a single massive write() can't
    // starve the rest of the system (cooperative delay inserted
    // between slices). LWIP's TCP buffer is small relative to our
    // typical blob; most slices will block briefly waiting for the
    // window to drain, which delay(1) handles.
    const size_t SLICE = 1024;
    size_t sent = 0;
    uint32_t stall_start = millis();
    while (sent < blob_len) {
        if (!client.connected()) break;
        size_t remain = blob_len - sent;
        size_t n = remain > SLICE ? SLICE : remain;
        int w = client.write((const uint8_t*)(blob + sent), n);
        if (w <= 0) {
            if ((millis() - stall_start) > timeout) break;
            delay(1);
            continue;
        }
        sent += (size_t)w;
        stall_start = millis();
    }

    client.flush();
    client.stop();
    server.stop();

    if (sent == blob_len) {
        lua_pushinteger(L, (lua_Integer)sent);
    } else {
        Serial.printf("[WiFi] tcp_serve_blob: sent %u/%u\n",
            (unsigned)sent, (unsigned)blob_len);
        lua_pushnil(L);
    }
    return 1;
}

// @lua ez.wifi.tcp_fetch_blob(ip, port, max_bytes?, timeout_ms?) -> string|nil
// @brief Connect to a TCP server and read everything until EOF
// @description Opens a TCP client to ip:port, reads until the remote
// side closes the connection (or max_bytes is reached, or the idle
// timeout expires), returns the accumulated bytes. Used by the WiFi
// file transfer to pull a file from the peer. Returns nil on any
// failure (connect, idle timeout, overflow).
// @param ip Target IP address
// @param port Target port
// @param max_bytes Safety cap on received bytes (default 1048576 / 1 MB)
// @param timeout_ms Connect timeout AND per-read idle timeout (default 30000)
// @return blob string on success, nil on failure
// @end
LUA_FUNCTION(l_wifi_tcp_fetch_blob) {
    LUA_CHECK_ARGC_RANGE(L, 2, 4);
    const char* ip_str = luaL_checkstring(L, 1);
    uint16_t port = (uint16_t)luaL_checkinteger(L, 2);
    size_t max_bytes = (size_t)luaL_optintegerdefault(L, 3, 1048576);
    uint32_t timeout = (uint32_t)luaL_optintegerdefault(L, 4, 30000);

    IPAddress addr;
    if (!addr.fromString(ip_str)) {
        lua_pushnil(L);
        return 1;
    }

    WiFiClient client;
    client.setTimeout(timeout);
    uint32_t t0 = millis();
    if (!client.connect(addr, port, timeout)) {
        Serial.println("[WiFi] tcp_fetch_blob: connect failed");
        lua_pushnil(L);
        return 1;
    }

    // Use a luaL_Buffer to accumulate — it grows via realloc() into
    // PSRAM once above the heap_caps_malloc_extmem_enable() threshold,
    // which is what we want for a potentially 100 KB+ file blob.
    luaL_Buffer b;
    luaL_buffinit(L, &b);

    uint8_t rx[1024];
    size_t total = 0;
    uint32_t last_rx = millis();

    while (true) {
        if (total >= max_bytes) {
            Serial.printf("[WiFi] tcp_fetch_blob: max_bytes %u reached\n",
                (unsigned)max_bytes);
            break;
        }
        int avail = client.available();
        if (avail > 0) {
            int cap = (int)sizeof(rx);
            int want = avail > cap ? cap : avail;
            int n = client.read(rx, want);
            if (n > 0) {
                luaL_addlstring(&b, (const char*)rx, (size_t)n);
                total += (size_t)n;
                last_rx = millis();
            }
        } else if (!client.connected()) {
            // Remote closed AND no more buffered bytes — clean EOF.
            break;
        } else if ((millis() - last_rx) > timeout) {
            Serial.println("[WiFi] tcp_fetch_blob: idle timeout");
            client.stop();
            lua_pushnil(L);
            return 1;
        } else {
            delay(2);
        }
    }

    client.stop();
    luaL_pushresult(&b);

    // Sanity log — helpful when debugging partial transfers against
    // the serve side's Serial output.
    Serial.printf("[WiFi] tcp_fetch_blob: got %u bytes in %u ms\n",
        (unsigned)total, (unsigned)(millis() - t0));
    return 1;
}

// Function table for ez.wifi
static const luaL_Reg wifi_funcs[] = {
    {"scan",           l_wifi_scan},
    {"scan_start",     l_wifi_scan_start},
    {"scan_status",    l_wifi_scan_status},
    {"scan_results",   l_wifi_scan_results},
    {"connect",        l_wifi_connect},
    {"disconnect",     l_wifi_disconnect},
    {"is_connected",   l_wifi_is_connected},
    {"wait_connected", l_wifi_wait_connected},
    {"get_ip",         l_wifi_get_ip},
    {"get_rssi",       l_wifi_get_rssi},
    {"get_ssid",       l_wifi_get_ssid},
    {"get_mac",        l_wifi_get_mac},
    {"get_status",     l_wifi_get_status},
    {"get_gateway",    l_wifi_get_gateway},
    {"get_dns",        l_wifi_get_dns},
    {"set_power",      l_wifi_set_power},
    {"is_enabled",     l_wifi_is_enabled},
    {"start_ap",             l_wifi_start_ap},
    {"stop_ap",              l_wifi_stop_ap},
    {"is_ap_active",         l_wifi_is_ap_active},
    {"get_ap_ip",            l_wifi_get_ap_ip},
    {"get_ap_client_count",  l_wifi_get_ap_client_count},
    {"udp_echo_start", l_wifi_udp_echo_start},
    {"udp_echo_stop",  l_wifi_udp_echo_stop},
    {"udp_probe",      l_wifi_udp_probe},
    {"tcp_serve_blob", l_wifi_tcp_serve_blob},
    {"tcp_fetch_blob", l_wifi_tcp_fetch_blob},
    {nullptr, nullptr}
};

// Register the wifi module
void registerWifiModule(lua_State* L) {
    lua_register_module(L, "wifi", wifi_funcs);
    Serial.println("[LuaRuntime] Registered ez.wifi");
}
