// ez.wifi module bindings
// Provides WiFi connectivity functions

#include "../lua_bindings.h"
#include "../../config.h"
#include <Arduino.h>
#include <WiFi.h>

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

// Scan results cache
static int lastScanCount = 0;

static void ensureWifiInit() {
    if (!wifiInitialized) {
        WiFi.mode(WIFI_STA);
        WiFi.setAutoConnect(false);
        WiFi.setAutoReconnect(true);
        wifiInitialized = true;
        Serial.println("[WiFi] Initialized in STA mode");
    }
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

// Function table for ez.wifi
static const luaL_Reg wifi_funcs[] = {
    {"scan",           l_wifi_scan},
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
    {nullptr, nullptr}
};

// Register the wifi module
void registerWifiModule(lua_State* L) {
    lua_register_module(L, "wifi", wifi_funcs);
    Serial.println("[LuaRuntime] Registered ez.wifi");
}
