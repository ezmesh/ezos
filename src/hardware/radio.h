#pragma once

#include <cstdint>
#include <cstddef>
#include <deque>
#include <RadioLib.h>
#include "../config.h"

// Radio operation result codes
enum class RadioResult {
    OK = 0,
    ERROR_INIT,
    ERROR_TX,
    ERROR_RX,
    ERROR_TIMEOUT,
    ERROR_CRC,
    ERROR_BUSY,
    ERROR_PARAM,
    ERROR_QUEUE_FULL,
    NO_DATA
};

// Air-protocol profile. Selects LoRa modulation parameters and sync word
// so the radio can listen to either a MeshCore mesh or a Meshtastic mesh.
// The chip is single-tuner so only one profile is active at a time;
// switching is a hard re-tune. Frequency is orthogonal and selected by
// the user via the band picker (see lua/screens/settings/radio_settings.lua).
enum class RadioProfile {
    MESHCORE = 0,    // Default: SF8 / BW62.5 / CR4/8 / sync 0x12
    MESHTASTIC = 1,  // Meshtastic "LongFast" preset: SF11 / BW250 / CR4/5 / sync 0x2B
};

// Queued packet for transmission
struct QueuedTxPacket {
    uint8_t data[256];
    size_t len;
    uint32_t queuedAt;  // When packet was queued (for stats/debugging)
};

// Radio configuration structure
struct RadioConfig {
    float frequency = LORA_FREQ_DEFAULT;       // MHz
    float bandwidth = LORA_BW_DEFAULT;         // kHz
    uint8_t spreadingFactor = LORA_SF_DEFAULT;
    uint8_t codingRate = LORA_CR_DEFAULT;
    uint8_t syncWord = LORA_SYNC_DEFAULT;
    int8_t txPower = LORA_POWER_DEFAULT;       // dBm
    uint16_t preambleLength = LORA_PREAMBLE_DEFAULT;
    RadioProfile profile = RadioProfile::MESHCORE;
};

// Apply a profile's modulation params to a config, leaving frequency
// and txPower untouched (those are user/region choices, not protocol).
void applyRadioProfile(RadioConfig& cfg, RadioProfile profile);

// Convert profile <-> name for prefs / Lua bindings.
const char* radioProfileName(RadioProfile profile);
bool        radioProfileFromName(const char* name, RadioProfile& out);

// Received packet metadata
struct RxMetadata {
    float rssi;         // Received signal strength (dBm)
    float snr;          // Signal-to-noise ratio (dB)
    uint32_t timestamp; // Receive timestamp (millis)
};

class Radio {
public:
    Radio();
    ~Radio();

    // Prevent copying
    Radio(const Radio&) = delete;
    Radio& operator=(const Radio&) = delete;

    // Initialization
    bool init();
    bool init(const RadioConfig& config);

    // Configuration
    RadioResult setFrequency(float mhz);
    RadioResult setBandwidth(float khz);
    RadioResult setSpreadingFactor(uint8_t sf);
    RadioResult setCodingRate(uint8_t cr);
    RadioResult setSyncWord(uint8_t sw);
    RadioResult setTxPower(int8_t dbm);
    RadioResult setPreambleLength(uint16_t len);

    // Apply full configuration
    RadioResult configure(const RadioConfig& config);

    // Apply a protocol profile (modulation + sync word). Frequency and
    // txPower are preserved. After this returns the radio is back in RX
    // mode listening with the new params.
    RadioResult setProfile(RadioProfile profile);
    RadioProfile getProfile() const { return _config.profile; }

    // Get current configuration
    const RadioConfig& getConfig() const { return _config; }

    // Transmission (non-blocking async, bypasses queue)
    RadioResult send(const uint8_t* data, size_t len);

    // Queued transmission (non-blocking, respects throttle)
    RadioResult queueSend(const uint8_t* data, size_t len);

    // Process the transmit queue and TX completion (call from main loop)
    void processQueue();

    // Check if async TX completed (call after send() returns OK)
    bool checkTxComplete();

    // Queue status
    size_t getQueueSize() const { return _txQueue.size(); }
    size_t getQueueCapacity() const { return TX_QUEUE_MAX_SIZE; }
    bool isQueueFull() const { return _txQueue.size() >= TX_QUEUE_MAX_SIZE; }
    void clearQueue() { _txQueue.clear(); }

    // Throttle settings
    void setThrottleInterval(uint32_t ms) { _throttleIntervalMs = ms; }
    uint32_t getThrottleInterval() const { return _throttleIntervalMs; }

    // Reception
    // Start listening for packets (non-blocking)
    RadioResult startReceive();

    // Check if packet is available
    bool available();

    // Read received packet (returns bytes read, -1 on error)
    int receive(uint8_t* buffer, size_t maxLen);

    // Read received packet with metadata
    int receive(uint8_t* buffer, size_t maxLen, RxMetadata& metadata);

    // Get last packet's RSSI and SNR
    float getLastRSSI() const { return _lastRssi; }
    float getLastSNR() const { return _lastSnr; }

    // Radio state
    bool isTransmitting() const { return _transmitting; }
    bool isReceiving() const { return _receiving; }
    bool isBusy() const;

    // Sleep/wake
    RadioResult sleep();
    RadioResult wake();

    // Carrier wave test (for compliance testing)
    RadioResult transmitCW(bool enable);

    // Get raw module for advanced operations
    SX1262* getModule() { return _radio; }

private:
    SX1262* _radio = nullptr;
    RadioConfig _config;

    bool _initialized = false;
    bool _transmitting = false;
    bool _receiving = false;
    // Suppresses the per-setter auto-restart of RX while a multi-step
    // operation (setProfile, configure) walks through the modulation
    // setters. The wrapping op restores it and issues exactly one
    // startReceive at the end so we don't bounce through standby per
    // setter. See Radio::reArmAfterSetter.
    bool _suppressAutoRestart = false;

    // Re-arm RX after a single modulation setter. RadioLib drops the
    // chip to standby internally when applying setFrequency / setBandwidth
    // / etc., and the original implementation didn't restart RX; the
    // _receiving flag stayed truthy but the chip was silent. Boot.lua's
    // set_frequency call landed every device in this state until a
    // subsequent TX (or explicit start_receive) kicked it. See radio.cpp
    // for the full reasoning.
    void reArmAfterSetter();

    float _lastRssi = 0;
    float _lastSnr = 0;

    // Transmit queue and throttling
    static constexpr size_t TX_QUEUE_MAX_SIZE = 16;
    // Minimum ms between transmissions. 200 ms keeps us under ~85%
    // airtime when draining a back-to-back queue at SF8/BW62.5 (~1 s
    // per packet) and stays clear of the receiver's FLOOD rebroadcast
    // window. Lower values starve neighbours and cause our follow-up
    // TX to collide with the receiver's rebroadcast of the previous
    // packet -- see lua/services/direct_messages.lua dm.send.
    static constexpr uint32_t TX_THROTTLE_DEFAULT_MS = 200;
    std::deque<QueuedTxPacket> _txQueue;
    uint32_t _lastTxTime = 0;
    uint32_t _throttleIntervalMs = TX_THROTTLE_DEFAULT_MS;

    // Interrupt flag (set by ISR)
    static volatile bool _rxFlag;
    static volatile bool _txDone;

    // ISR callback
    static void onInterrupt();

    // Convert RadioLib status to RadioResult
    RadioResult translateStatus(int status);
};
