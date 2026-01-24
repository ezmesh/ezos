#pragma once

#include <cstdint>
#include <cstddef>
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
    NO_DATA
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

    // Transmission (blocking)
    RadioResult send(const uint8_t* data, size_t len);

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

    // Interrupt flag (set by ISR)
    static volatile bool _rxFlag;
    static volatile bool _txDone;

    // ISR callback
    static void onInterrupt();

    // Convert RadioLib status to RadioResult
    RadioResult translateStatus(int status);
};
