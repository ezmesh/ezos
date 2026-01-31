// ez.radio module bindings
// Provides LoRa radio control functions

#include "../lua_bindings.h"
#include "../../hardware/radio.h"

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
// @return true if radio is ready
LUA_FUNCTION(l_radio_is_initialized) {
    lua_pushboolean(L, radio != nullptr);
    return 1;
}

// @lua ez.radio.set_frequency(mhz) -> string
// @brief Set radio frequency
// @param mhz Frequency in MHz
// @return Result string (ok, error_init, etc.)
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
// @param khz Bandwidth in kHz
// @return Result string
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
// @param sf Spreading factor (6-12)
// @return Result string
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
// @param cr Coding rate (5-8)
// @return Result string
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
// @param dbm Power in dBm (0-22)
// @return Result string
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
// @param sw Sync word value
// @return Result string
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
// @return Table with frequency, bandwidth, spreading_factor, etc.
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
// @param data String or table of bytes to send
// @return Result string
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
// @return Result string
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
// @return true if packet waiting
LUA_FUNCTION(l_radio_available) {
    bool avail = radio && radio->available();
    lua_pushboolean(L, avail);
    return 1;
}

// @lua ez.radio.receive() -> string, number, number
// @brief Receive a packet
// @return Data string, RSSI, SNR or nil if no data
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
// @return RSSI in dBm
LUA_FUNCTION(l_radio_get_last_rssi) {
    float rssi = radio ? radio->getLastRSSI() : 0;
    lua_pushnumber(L, rssi);
    return 1;
}

// @lua ez.radio.get_last_snr() -> number
// @brief Get last signal-to-noise ratio
// @return SNR in dB
LUA_FUNCTION(l_radio_get_last_snr) {
    float snr = radio ? radio->getLastSNR() : 0;
    lua_pushnumber(L, snr);
    return 1;
}

// @lua ez.radio.is_transmitting() -> boolean
// @brief Check if currently transmitting
// @return true if transmission in progress
LUA_FUNCTION(l_radio_is_transmitting) {
    bool tx = radio && radio->isTransmitting();
    lua_pushboolean(L, tx);
    return 1;
}

// @lua ez.radio.is_receiving() -> boolean
// @brief Check if in receive mode
// @return true if listening
LUA_FUNCTION(l_radio_is_receiving) {
    bool rx = radio && radio->isReceiving();
    lua_pushboolean(L, rx);
    return 1;
}

// @lua ez.radio.is_busy() -> boolean
// @brief Check if radio is busy
// @return true if transmitting or receiving
LUA_FUNCTION(l_radio_is_busy) {
    bool busy = radio && radio->isBusy();
    lua_pushboolean(L, busy);
    return 1;
}

// @lua ez.radio.sleep() -> string
// @brief Put radio into sleep mode
// @return Result string
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
// @return Result string
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
