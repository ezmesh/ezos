// ez.radio module bindings
// Provides LoRa radio control functions

#include "../lua_bindings.h"
#include "../../hardware/radio.h"

// @module ez.radio
// @brief Low-level LoRa radio configuration and status
// @description
// Direct control of the SX1262 LoRa radio hardware. Configure frequency,
// bandwidth, spreading factor, and transmit power. Most applications should
// use ez.mesh instead, which provides higher-level mesh networking on top
// of the radio. The radio status indicator shows "!RF" if initialization fails.
// @end

// External reference to the global radio instance
extern Radio* radio;

// Helper to push RadioResult as string
static void pushRadioResult(lua_State* L, RadioResult result) {
    switch (result) {
        case RadioResult::OK:           lua_pushstring(L, "ok"); break;
        case RadioResult::ERROR_INIT:   lua_pushstring(L, "error_init"); break;
        case RadioResult::ERROR_TX:     lua_pushstring(L, "error_tx"); break;
        case RadioResult::ERROR_RX:     lua_pushstring(L, "error_rx"); break;
        case RadioResult::ERROR_TIMEOUT: lua_pushstring(L, "error_timeout"); break;
        case RadioResult::ERROR_CRC:    lua_pushstring(L, "error_crc"); break;
        case RadioResult::ERROR_BUSY:   lua_pushstring(L, "error_busy"); break;
        case RadioResult::ERROR_PARAM:  lua_pushstring(L, "error_param"); break;
        case RadioResult::NO_DATA:      lua_pushstring(L, "no_data"); break;
        default:                        lua_pushstring(L, "unknown"); break;
    }
}

// @lua ez.radio.is_initialized() -> boolean
// @brief Check if radio is initialized
// @description Checks if the LoRa radio hardware was successfully initialized at
// boot. If false, the radio module failed to start - check hardware connections.
// The status bar shows "!RF" when radio initialization fails.
// @return true if radio is ready
// @example
// if ez.radio.is_initialized() then
//     print("Radio ready")
// else
//     print("Radio failed - check LoRa module")
// end
// @end
LUA_FUNCTION(l_radio_is_initialized) {
    lua_pushboolean(L, radio != nullptr);
    return 1;
}

// @lua ez.radio.set_frequency(mhz) -> string
// @brief Set radio frequency
// @description Sets the LoRa carrier frequency. Common ISM bands: 433MHz (Asia),
// 868MHz (Europe), 915MHz (Americas). Ensure you use a frequency legal in your
// region. All nodes in a mesh must use the same frequency to communicate.
// @param mhz Frequency in MHz (e.g., 915.0 for US)
// @return Result string (ok, error_init, error_param)
// @example
// local result = ez.radio.set_frequency(915.0)
// if result == "ok" then
//     print("Frequency set to 915 MHz")
// end
// @end
LUA_FUNCTION(l_radio_set_frequency) {
    LUA_CHECK_ARGC(L, 1);
    float mhz = luaL_checknumber(L, 1);

    if (!radio) {
        lua_pushstring(L, "error_init");
        return 1;
    }

    pushRadioResult(L, radio->setFrequency(mhz));
    return 1;
}

// @lua ez.radio.set_bandwidth(khz) -> string
// @brief Set radio bandwidth
// @description Sets the LoRa channel bandwidth. Wider bandwidth allows faster data
// rates but reduces sensitivity. Common values: 125kHz (standard), 250kHz (faster),
// 500kHz (fastest). Narrower bandwidths (62.5, 41.7, 31.25, 20.8, 15.6, 10.4, 7.8)
// increase range but slow transmission.
// @param khz Bandwidth in kHz (7.8 to 500)
// @return Result string (ok, error_init, error_param)
// @example
// ez.radio.set_bandwidth(125)  -- Standard bandwidth
// @end
LUA_FUNCTION(l_radio_set_bandwidth) {
    LUA_CHECK_ARGC(L, 1);
    float khz = luaL_checknumber(L, 1);

    if (!radio) {
        lua_pushstring(L, "error_init");
        return 1;
    }

    pushRadioResult(L, radio->setBandwidth(khz));
    return 1;
}

// @lua ez.radio.set_spreading_factor(sf) -> string
// @brief Set LoRa spreading factor
// @description Sets the spreading factor (SF) which controls the chirp rate.
// Higher SF increases range and noise immunity but reduces data rate. SF7 is
// fastest (~5.5kbps), SF12 has longest range (~300bps). Each SF increase roughly
// doubles range but halves speed. MeshCore typically uses SF9-SF11.
// @param sf Spreading factor (6-12)
// @return Result string (ok, error_init, error_param)
// @example
// ez.radio.set_spreading_factor(10)  -- Good balance of range and speed
// @end
LUA_FUNCTION(l_radio_set_spreading_factor) {
    LUA_CHECK_ARGC(L, 1);
    int sf = luaL_checkinteger(L, 1);

    if (!radio) {
        lua_pushstring(L, "error_init");
        return 1;
    }

    pushRadioResult(L, radio->setSpreadingFactor(sf));
    return 1;
}

// @lua ez.radio.set_coding_rate(cr) -> string
// @brief Set LoRa coding rate
// @description Sets the forward error correction (FEC) coding rate. Higher values
// add more redundancy for error recovery but reduce throughput. Value represents
// the denominator of 4/x ratio: 5=4/5, 6=4/6, 7=4/7, 8=4/8. CR5 is fastest, CR8
// is most robust against interference.
// @param cr Coding rate (5-8)
// @return Result string (ok, error_init, error_param)
// @example
// ez.radio.set_coding_rate(5)  -- Minimal FEC, highest throughput
// ez.radio.set_coding_rate(8)  -- Maximum FEC, best error recovery
// @end
LUA_FUNCTION(l_radio_set_coding_rate) {
    LUA_CHECK_ARGC(L, 1);
    int cr = luaL_checkinteger(L, 1);

    if (!radio) {
        lua_pushstring(L, "error_init");
        return 1;
    }

    pushRadioResult(L, radio->setCodingRate(cr));
    return 1;
}

// @lua ez.radio.set_tx_power(dbm) -> string
// @brief Set transmit power
// @description Sets the RF transmit power level. Higher power increases range
// but uses more battery and may cause interference. The SX1262 on T-Deck supports
// up to +22dBm. Use the minimum power needed for your application. Power is
// limited by regional regulations (e.g., +20dBm for US ISM band).
// @param dbm Power in dBm (0-22)
// @return Result string (ok, error_init, error_param)
// @example
// ez.radio.set_tx_power(17)  -- Moderate power, good battery life
// ez.radio.set_tx_power(22)  -- Maximum power, maximum range
// @end
LUA_FUNCTION(l_radio_set_tx_power) {
    LUA_CHECK_ARGC(L, 1);
    int dbm = luaL_checkinteger(L, 1);

    if (!radio) {
        lua_pushstring(L, "error_init");
        return 1;
    }

    pushRadioResult(L, radio->setTxPower(dbm));
    return 1;
}

// @lua ez.radio.set_sync_word(sw) -> string
// @brief Set sync word
// @description Sets the sync word for packet detection. Only packets with matching
// sync word are received. Different networks can coexist on same frequency by using
// different sync words. Public LoRa uses 0x12, LoRaWAN uses 0x34. MeshCore uses 0x12.
// @param sw Sync word value (0-255)
// @return Result string (ok, error_init, error_param)
// @example
// ez.radio.set_sync_word(0x12)  -- Standard LoRa sync word
// @end
LUA_FUNCTION(l_radio_set_sync_word) {
    LUA_CHECK_ARGC(L, 1);
    int sw = luaL_checkinteger(L, 1);

    if (!radio) {
        lua_pushstring(L, "error_init");
        return 1;
    }

    pushRadioResult(L, radio->setSyncWord(sw));
    return 1;
}

// @lua ez.radio.get_config() -> table
// @brief Get current radio configuration
// @description Returns a table with all current radio settings. Useful for debugging
// or displaying radio status. Returns nil if radio not initialized.
// @return Table with frequency, bandwidth, spreading_factor, coding_rate, sync_word,
// tx_power, preamble_length, or nil if not initialized
// @example
// local cfg = ez.radio.get_config()
// if cfg then
//     print(string.format("Freq: %.1f MHz, SF%d, BW %.0f kHz",
//         cfg.frequency, cfg.spreading_factor, cfg.bandwidth))
// end
// @end
LUA_FUNCTION(l_radio_get_config) {
    if (!radio) {
        lua_pushnil(L);
        return 1;
    }

    const RadioConfig& cfg = radio->getConfig();

    lua_newtable(L);
    lua_pushnumber(L, cfg.frequency);
    lua_setfield(L, -2, "frequency");
    lua_pushnumber(L, cfg.bandwidth);
    lua_setfield(L, -2, "bandwidth");
    lua_pushinteger(L, cfg.spreadingFactor);
    lua_setfield(L, -2, "spreading_factor");
    lua_pushinteger(L, cfg.codingRate);
    lua_setfield(L, -2, "coding_rate");
    lua_pushinteger(L, cfg.syncWord);
    lua_setfield(L, -2, "sync_word");
    lua_pushinteger(L, cfg.txPower);
    lua_setfield(L, -2, "tx_power");
    lua_pushinteger(L, cfg.preambleLength);
    lua_setfield(L, -2, "preamble_length");

    return 1;
}

// @lua ez.radio.send(data) -> string
// @brief Transmit data
// @description Transmits a raw LoRa packet. For mesh networking, use ez.mesh
// functions instead which handle routing and encryption. This is for low-level
// radio access. Maximum packet size is 255 bytes. Blocks until transmission complete.
// @param data String or table of bytes to send (max 255 bytes)
// @return Result string (ok, error_init, error_tx, error_busy)
// @example
// local result = ez.radio.send("Hello LoRa")
// if result == "ok" then
//     print("Packet sent")
// else
//     print("Send failed:", result)
// end
// @end
LUA_FUNCTION(l_radio_send) {
    LUA_CHECK_ARGC(L, 1);

    if (!radio) {
        lua_pushstring(L, "error_init");
        return 1;
    }

    size_t len;
    const uint8_t* data;

    if (lua_isstring(L, 1)) {
        data = reinterpret_cast<const uint8_t*>(lua_tolstring(L, 1, &len));
    } else if (lua_istable(L, 1)) {
        // Convert table to byte array
        len = lua_rawlen(L, 1);
        if (len > 256) {
            lua_pushstring(L, "error_param");
            return 1;
        }

        static uint8_t buffer[256];
        for (size_t i = 0; i < len; i++) {
            lua_rawgeti(L, 1, i + 1);
            buffer[i] = lua_tointeger(L, -1);
            lua_pop(L, 1);
        }
        data = buffer;
    } else {
        lua_pushstring(L, "error_param");
        return 1;
    }

    pushRadioResult(L, radio->send(data, len));
    return 1;
}

// @lua ez.radio.start_receive() -> string
// @brief Start listening for packets
// @description Puts the radio in continuous receive mode. The radio will listen
// for packets until a packet is received or another operation is started. Use
// available() to check for received packets and receive() to read them.
// @return Result string (ok, error_init)
// @example
// ez.radio.start_receive()
// while true do
//     if ez.radio.available() then
//         local data, rssi, snr = ez.radio.receive()
//         print("Received:", data, "RSSI:", rssi)
//     end
//     ez.system.delay(10)
// end
// @end
LUA_FUNCTION(l_radio_start_receive) {
    if (!radio) {
        lua_pushstring(L, "error_init");
        return 1;
    }

    pushRadioResult(L, radio->startReceive());
    return 1;
}

// @lua ez.radio.available() -> boolean
// @brief Check if data is available
// @description Checks if a packet has been received and is waiting to be read.
// Call this after start_receive() to poll for incoming data. Non-blocking.
// @return true if packet waiting
// @example
// if ez.radio.available() then
//     local data = ez.radio.receive()
//     print("Got packet:", data)
// end
// @end
LUA_FUNCTION(l_radio_available) {
    bool avail = radio && radio->available();
    lua_pushboolean(L, avail);
    return 1;
}

// @lua ez.radio.receive() -> string, number, number
// @brief Receive a packet
// @description Reads a received packet from the radio buffer. Returns the packet
// data along with signal quality metrics: RSSI (Received Signal Strength Indicator)
// in dBm and SNR (Signal-to-Noise Ratio) in dB. Higher SNR means cleaner signal.
// Returns nil if no packet is available.
// @return Data string, RSSI in dBm, SNR in dB, or nil if no data
// @example
// local data, rssi, snr = ez.radio.receive()
// if data then
//     print("Data:", data)
//     print(string.format("Signal: %d dBm, SNR: %.1f dB", rssi, snr))
// end
// @end
LUA_FUNCTION(l_radio_receive) {
    if (!radio) {
        lua_pushnil(L);
        return 1;
    }

    static uint8_t buffer[256];
    RxMetadata metadata;

    int len = radio->receive(buffer, sizeof(buffer), metadata);
    if (len < 0) {
        lua_pushnil(L);
        return 1;
    }

    // Push data as string
    lua_pushlstring(L, reinterpret_cast<char*>(buffer), len);
    lua_pushnumber(L, metadata.rssi);
    lua_pushnumber(L, metadata.snr);
    return 3;
}

// @lua ez.radio.get_last_rssi() -> number
// @brief Get last received signal strength
// @description Returns the RSSI of the most recently received packet. RSSI is
// typically negative: -30dBm is strong, -90dBm is weak, -120dBm is near the noise
// floor. Useful for signal strength displays and link quality assessment.
// @return RSSI in dBm
// @example
// local rssi = ez.radio.get_last_rssi()
// if rssi > -80 then
//     print("Good signal")
// elseif rssi > -100 then
//     print("Weak signal")
// else
//     print("Very weak signal")
// end
// @end
LUA_FUNCTION(l_radio_get_last_rssi) {
    float rssi = radio ? radio->getLastRSSI() : 0;
    lua_pushnumber(L, rssi);
    return 1;
}

// @lua ez.radio.get_last_snr() -> number
// @brief Get last signal-to-noise ratio
// @description Returns the SNR of the most recently received packet. SNR indicates
// how much the signal stands above noise: positive values are good, negative values
// mean signal is below noise floor (LoRa can decode signals down to -20dB SNR).
// Higher spreading factors work better with lower SNR.
// @return SNR in dB
// @example
// local snr = ez.radio.get_last_snr()
// if snr > 5 then
//     print("Excellent signal quality")
// elseif snr > 0 then
//     print("Good signal quality")
// else
//     print("Signal below noise floor, SNR:", snr)
// end
// @end
LUA_FUNCTION(l_radio_get_last_snr) {
    float snr = radio ? radio->getLastSNR() : 0;
    lua_pushnumber(L, snr);
    return 1;
}

// @lua ez.radio.is_transmitting() -> boolean
// @brief Check if currently transmitting
// @description Checks if the radio is currently transmitting a packet. Do not start
// another transmission while this returns true. Useful for implementing TX indicators
// or managing channel access.
// @return true if transmission in progress
// @example
// if ez.radio.is_transmitting() then
//     display:draw_text(10, 10, "TX", 0xFF0000)
// end
// @end
LUA_FUNCTION(l_radio_is_transmitting) {
    bool tx = radio && radio->isTransmitting();
    lua_pushboolean(L, tx);
    return 1;
}

// @lua ez.radio.is_receiving() -> boolean
// @brief Check if in receive mode
// @description Checks if the radio is currently in receive mode and listening for
// packets. Returns true after calling start_receive() until a packet is received
// or another operation changes the radio state.
// @return true if listening
// @example
// if not ez.radio.is_receiving() then
//     ez.radio.start_receive()
// end
// @end
LUA_FUNCTION(l_radio_is_receiving) {
    bool rx = radio && radio->isReceiving();
    lua_pushboolean(L, rx);
    return 1;
}

// @lua ez.radio.is_busy() -> boolean
// @brief Check if radio is busy
// @description Returns true if the radio is currently transmitting or receiving
// a packet. Use this to check if the radio can accept a new command. Combines
// the checks of is_transmitting() and is_receiving().
// @return true if transmitting or receiving
// @example
// -- Wait for radio to be idle
// while ez.radio.is_busy() do
//     ez.system.delay(10)
// end
// ez.radio.send("data")
// @end
LUA_FUNCTION(l_radio_is_busy) {
    bool busy = radio && radio->isBusy();
    lua_pushboolean(L, busy);
    return 1;
}

// @lua ez.radio.sleep() -> string
// @brief Put radio into sleep mode
// @description Puts the LoRa radio into low-power sleep mode. In sleep mode, the
// radio cannot transmit or receive but consumes minimal power. Use for battery
// saving when mesh communication is not needed. Call wake() to resume operation.
// @return Result string (ok, error_init)
// @example
// -- Save power when idle
// ez.radio.sleep()
// ez.system.delay(60000)  -- Sleep for 1 minute
// ez.radio.wake()
// ez.radio.start_receive()
// @end
LUA_FUNCTION(l_radio_sleep) {
    if (!radio) {
        lua_pushstring(L, "error_init");
        return 1;
    }
    pushRadioResult(L, radio->sleep());
    return 1;
}

// @lua ez.radio.wake() -> string
// @brief Wake radio from sleep
// @description Wakes the LoRa radio from sleep mode. After waking, the radio is
// in standby mode and ready for commands. Call start_receive() to resume listening
// for packets.
// @return Result string (ok, error_init)
// @example
// ez.radio.wake()
// ez.radio.start_receive()  -- Resume listening
// @end
LUA_FUNCTION(l_radio_wake) {
    if (!radio) {
        lua_pushstring(L, "error_init");
        return 1;
    }
    pushRadioResult(L, radio->wake());
    return 1;
}

// Function table for ez.radio
static const luaL_Reg radio_funcs[] = {
    {"is_initialized",      l_radio_is_initialized},
    {"set_frequency",       l_radio_set_frequency},
    {"set_bandwidth",       l_radio_set_bandwidth},
    {"set_spreading_factor", l_radio_set_spreading_factor},
    {"set_coding_rate",     l_radio_set_coding_rate},
    {"set_tx_power",        l_radio_set_tx_power},
    {"set_sync_word",       l_radio_set_sync_word},
    {"get_config",          l_radio_get_config},
    {"send",                l_radio_send},
    {"start_receive",       l_radio_start_receive},
    {"available",           l_radio_available},
    {"receive",             l_radio_receive},
    {"get_last_rssi",       l_radio_get_last_rssi},
    {"get_last_snr",        l_radio_get_last_snr},
    {"is_transmitting",     l_radio_is_transmitting},
    {"is_receiving",        l_radio_is_receiving},
    {"is_busy",             l_radio_is_busy},
    {"sleep",               l_radio_sleep},
    {"wake",                l_radio_wake},
    {nullptr, nullptr}
};

// Register the radio module
void registerRadioModule(lua_State* L) {
    lua_register_module(L, "radio", radio_funcs);
    Serial.println("[LuaRuntime] Registered ez.radio");
}
