#include "radio.h"
#include <Arduino.h>
#include <SPI.h>

// Static member initialization
volatile bool Radio::_rxFlag = false;
volatile bool Radio::_txDone = false;

// Interrupt service routine for radio events (RX complete or TX complete)
void IRAM_ATTR Radio::onInterrupt() {
    // This ISR fires for both RX and TX completion
    // We use _transmitting flag to determine which event occurred
    if (_txDone == false) {
        // Could be TX done or RX - set both flags, main loop will sort it out
        _txDone = true;
    }
    _rxFlag = true;
}

Radio::Radio() {
}

Radio::~Radio() {
    if (_radio) {
        delete _radio;
        _radio = nullptr;
    }
}

bool Radio::init() {
    return init(RadioConfig{});  // Use defaults
}

bool Radio::init(const RadioConfig& config) {
    if (_initialized) {
        return true;
    }

    _config = config;

    // Create SX1262 module instance
    // RadioLib uses its own module abstraction
    Module* mod = new Module(LORA_CS, LORA_IRQ, LORA_RST, LORA_BUSY);
    _radio = new SX1262(mod);

    Serial.println("Initializing SX1262 radio...");

    // Initialize the radio with configuration
    int state = _radio->begin(
        _config.frequency,
        _config.bandwidth,
        _config.spreadingFactor,
        _config.codingRate,
        _config.syncWord,
        _config.txPower,
        _config.preambleLength
    );

    if (state != RADIOLIB_ERR_NONE) {
        Serial.printf("Radio init failed with code: %d\n", state);
        return false;
    }

    // Configure additional settings
    // Enable CRC for packet integrity
    state = _radio->setCRC(true);
    if (state != RADIOLIB_ERR_NONE) {
        Serial.printf("Failed to enable CRC: %d\n", state);
    }

    // Set DIO2 as RF switch control (common on many modules)
    state = _radio->setDio2AsRfSwitch(true);
    if (state != RADIOLIB_ERR_NONE) {
        Serial.printf("Failed to set DIO2 as RF switch: %d\n", state);
    }

    // Set regulator mode to DC-DC for better efficiency
    state = _radio->setRegulatorDCDC();
    if (state != RADIOLIB_ERR_NONE) {
        Serial.printf("Failed to set DC-DC regulator: %d\n", state);
        // Not fatal, LDO mode will work
    }

    // Set up interrupt
    _radio->setDio1Action(onInterrupt);

    Serial.println("Radio initialized successfully");
    Serial.printf("  Frequency: %.2f MHz\n", _config.frequency);
    Serial.printf("  Bandwidth: %.1f kHz\n", _config.bandwidth);
    Serial.printf("  SF: %d, CR: 4/%d\n", _config.spreadingFactor, _config.codingRate);
    Serial.printf("  TX Power: %d dBm\n", _config.txPower);

    _initialized = true;
    return true;
}

RadioResult Radio::translateStatus(int status) {
    switch (status) {
        case RADIOLIB_ERR_NONE:
            return RadioResult::OK;
        case RADIOLIB_ERR_PACKET_TOO_LONG:
        case RADIOLIB_ERR_INVALID_BANDWIDTH:
        case RADIOLIB_ERR_INVALID_SPREADING_FACTOR:
        case RADIOLIB_ERR_INVALID_CODING_RATE:
        case RADIOLIB_ERR_INVALID_FREQUENCY:
            return RadioResult::ERROR_PARAM;
        case RADIOLIB_ERR_TX_TIMEOUT:
        case RADIOLIB_ERR_RX_TIMEOUT:
            return RadioResult::ERROR_TIMEOUT;
        case RADIOLIB_ERR_CRC_MISMATCH:
            return RadioResult::ERROR_CRC;
        default:
            return RadioResult::ERROR_TX;
    }
}

RadioResult Radio::setFrequency(float mhz) {
    if (!_initialized) return RadioResult::ERROR_INIT;

    int state = _radio->setFrequency(mhz);
    if (state == RADIOLIB_ERR_NONE) {
        _config.frequency = mhz;
    }
    return translateStatus(state);
}

RadioResult Radio::setBandwidth(float khz) {
    if (!_initialized) return RadioResult::ERROR_INIT;

    int state = _radio->setBandwidth(khz);
    if (state == RADIOLIB_ERR_NONE) {
        _config.bandwidth = khz;
    }
    return translateStatus(state);
}

RadioResult Radio::setSpreadingFactor(uint8_t sf) {
    if (!_initialized) return RadioResult::ERROR_INIT;

    int state = _radio->setSpreadingFactor(sf);
    if (state == RADIOLIB_ERR_NONE) {
        _config.spreadingFactor = sf;
    }
    return translateStatus(state);
}

RadioResult Radio::setCodingRate(uint8_t cr) {
    if (!_initialized) return RadioResult::ERROR_INIT;

    int state = _radio->setCodingRate(cr);
    if (state == RADIOLIB_ERR_NONE) {
        _config.codingRate = cr;
    }
    return translateStatus(state);
}

RadioResult Radio::setSyncWord(uint8_t sw) {
    if (!_initialized) return RadioResult::ERROR_INIT;

    int state = _radio->setSyncWord(sw);
    if (state == RADIOLIB_ERR_NONE) {
        _config.syncWord = sw;
    }
    return translateStatus(state);
}

RadioResult Radio::setTxPower(int8_t dbm) {
    if (!_initialized) return RadioResult::ERROR_INIT;

    int state = _radio->setOutputPower(dbm);
    if (state == RADIOLIB_ERR_NONE) {
        _config.txPower = dbm;
    }
    return translateStatus(state);
}

RadioResult Radio::setPreambleLength(uint16_t len) {
    if (!_initialized) return RadioResult::ERROR_INIT;

    int state = _radio->setPreambleLength(len);
    if (state == RADIOLIB_ERR_NONE) {
        _config.preambleLength = len;
    }
    return translateStatus(state);
}

RadioResult Radio::configure(const RadioConfig& config) {
    RadioResult result;

    result = setFrequency(config.frequency);
    if (result != RadioResult::OK) return result;

    result = setBandwidth(config.bandwidth);
    if (result != RadioResult::OK) return result;

    result = setSpreadingFactor(config.spreadingFactor);
    if (result != RadioResult::OK) return result;

    result = setCodingRate(config.codingRate);
    if (result != RadioResult::OK) return result;

    result = setSyncWord(config.syncWord);
    if (result != RadioResult::OK) return result;

    result = setTxPower(config.txPower);
    if (result != RadioResult::OK) return result;

    result = setPreambleLength(config.preambleLength);
    if (result != RadioResult::OK) return result;

    _config = config;
    return RadioResult::OK;
}

RadioResult Radio::send(const uint8_t* data, size_t len) {
    if (!_initialized) return RadioResult::ERROR_INIT;
    if (len == 0 || len > 255) return RadioResult::ERROR_PARAM;
    if (_transmitting) return RadioResult::ERROR_BUSY;

    _transmitting = true;
    _receiving = false;
    _txDone = false;

    // Use non-blocking startTransmit - ISR will set _txDone when complete
    int state = _radio->startTransmit(const_cast<uint8_t*>(data), len);

    if (state != RADIOLIB_ERR_NONE) {
        _transmitting = false;
        Serial.printf("TX start failed with code: %d\n", state);
        return translateStatus(state);
    }

    return RadioResult::OK;
}

bool Radio::checkTxComplete() {
    if (!_transmitting) return true;  // Not transmitting

    if (_txDone) {
        // TX completed via interrupt
        _radio->finishTransmit();
        _transmitting = false;
        _txDone = false;
        _lastTxTime = millis();
        return true;
    }

    return false;  // Still transmitting
}

RadioResult Radio::queueSend(const uint8_t* data, size_t len) {
    if (!_initialized) return RadioResult::ERROR_INIT;
    if (len == 0 || len > 255) return RadioResult::ERROR_PARAM;

    if (_txQueue.size() >= TX_QUEUE_MAX_SIZE) {
        Serial.println("[Radio] TX queue full, dropping packet");
        return RadioResult::ERROR_QUEUE_FULL;
    }

    QueuedTxPacket pkt;
    memcpy(pkt.data, data, len);
    pkt.len = len;
    pkt.queuedAt = millis();

    _txQueue.push_back(pkt);
    return RadioResult::OK;
}

void Radio::processQueue() {
    // Check if previous TX completed
    if (_transmitting) {
        if (checkTxComplete()) {
            // TX done, restart receive mode
            startReceive();
        }
        return;  // Still transmitting or just finished, don't send yet
    }

    if (_txQueue.empty()) return;

    uint32_t now = millis();

    // Respect throttle interval
    if (now - _lastTxTime < _throttleIntervalMs) {
        return;
    }

    // Send the next packet (non-blocking)
    QueuedTxPacket& pkt = _txQueue.front();

    RadioResult result = send(pkt.data, pkt.len);
    if (result == RadioResult::OK) {
        // Packet transmission started, remove from queue
        _txQueue.pop_front();
    } else {
        // On error, still remove to prevent infinite retry
        Serial.printf("[Radio] Queue send failed, dropping packet\n");
        _txQueue.pop_front();
    }
}

RadioResult Radio::startReceive() {
    if (!_initialized) return RadioResult::ERROR_INIT;

    _rxFlag = false;
    _receiving = true;
    _transmitting = false;

    int state = _radio->startReceive();

    if (state != RADIOLIB_ERR_NONE) {
        _receiving = false;
        Serial.printf("Start receive failed with code: %d\n", state);
        return translateStatus(state);
    }

    return RadioResult::OK;
}

bool Radio::available() {
    return _rxFlag;
}

int Radio::receive(uint8_t* buffer, size_t maxLen) {
    RxMetadata meta;
    return receive(buffer, maxLen, meta);
}

int Radio::receive(uint8_t* buffer, size_t maxLen, RxMetadata& metadata) {
    if (!_initialized) return -1;
    if (!_rxFlag) return 0;

    _rxFlag = false;

    // Read received data
    size_t len = _radio->getPacketLength();
    if (len == 0) {
        startReceive();  // Restart reception
        return 0;
    }

    if (len > maxLen) {
        len = maxLen;  // Truncate to buffer size
    }

    int state = _radio->readData(buffer, len);

    if (state != RADIOLIB_ERR_NONE) {
        Serial.printf("Read data failed with code: %d\n", state);
        startReceive();  // Restart reception
        return -1;
    }

    // Get packet metadata
    _lastRssi = _radio->getRSSI();
    _lastSnr = _radio->getSNR();

    metadata.rssi = _lastRssi;
    metadata.snr = _lastSnr;
    metadata.timestamp = millis();

    // Restart reception for next packet
    startReceive();

    return static_cast<int>(len);
}

bool Radio::isBusy() const {
    if (!_initialized) return false;

    // Check the BUSY pin
    return digitalRead(LORA_BUSY) == HIGH;
}

RadioResult Radio::sleep() {
    if (!_initialized) return RadioResult::ERROR_INIT;

    _receiving = false;
    _transmitting = false;

    int state = _radio->sleep();
    return translateStatus(state);
}

RadioResult Radio::wake() {
    if (!_initialized) return RadioResult::ERROR_INIT;

    int state = _radio->standby();
    return translateStatus(state);
}

RadioResult Radio::transmitCW(bool enable) {
    if (!_initialized) return RadioResult::ERROR_INIT;

    int state;
    if (enable) {
        state = _radio->transmitDirect();
    } else {
        state = _radio->standby();
    }

    return translateStatus(state);
}
