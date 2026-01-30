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
};

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

    // Get current configuration
    const RadioConfig& getConfig() const { return _config; }

    // Transmission (blocking, bypasses queue)
    RadioResult send(const uint8_t* data, size_t len);

    // Queued transmission (non-blocking, respects throttle)
    RadioResult queueSend(const uint8_t* data, size_t len);

    // Process the transmit queue (call from main loop)
    void processQueue();

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

    float _lastRssi = 0;
    float _lastSnr = 0;

    // Transmit queue and throttling
    static constexpr size_t TX_QUEUE_MAX_SIZE = 16;
    static constexpr uint32_t TX_THROTTLE_DEFAULT_MS = 100;  // Minimum ms between transmissions
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
