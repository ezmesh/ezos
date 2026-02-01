# Non-Blocking Radio TX

## Problem

The current `Radio::send()` implementation blocks for the full transmission time. On LoRa with typical settings, this can be 50-200ms depending on packet size and spreading factor. During this time:

- The main loop is blocked
- UI becomes unresponsive
- Incoming packets may be missed
- GPS updates are delayed

## Current Implementation

```cpp
// src/hardware/radio.cpp
bool Radio::send(const uint8_t* data, size_t len) {
    int state = _radio.transmit(data, len);  // Blocks until TX complete
    return state == RADIOLIB_ERR_NONE;
}
```

The RadioLib `transmit()` function waits for the transmission to complete before returning.

## Proposed Solution

Use interrupt-driven TX with RadioLib's async API:

### 1. Add TX state tracking

```cpp
// radio.h
class Radio {
    // ...
    volatile bool _txInProgress = false;
    volatile bool _txSuccess = false;
    static void IRAM_ATTR txDoneISR();
};
```

### 2. Implement non-blocking send

```cpp
// radio.cpp
static Radio* _instance = nullptr;

void IRAM_ATTR Radio::txDoneISR() {
    if (_instance) {
        _instance->_txInProgress = false;
        _instance->_txSuccess = true;
    }
}

bool Radio::sendAsync(const uint8_t* data, size_t len) {
    if (_txInProgress) return false;  // Already transmitting

    _txInProgress = true;
    _txSuccess = false;

    _radio.setDio1Action(txDoneISR);
    int state = _radio.startTransmit(data, len);

    if (state != RADIOLIB_ERR_NONE) {
        _txInProgress = false;
        return false;
    }
    return true;
}

bool Radio::isTxBusy() {
    return _txInProgress;
}

bool Radio::finishTx() {
    if (_txInProgress) return false;
    _radio.finishTransmit();
    _radio.setDio1Action(rxDoneISR);  // Restore RX interrupt
    _radio.startReceive();
    return _txSuccess;
}
```

### 3. Update MeshCore to use async TX

```cpp
// meshcore.cpp
bool MeshCore::sendPacket(const MeshPacket& packet) {
    uint8_t buffer[MAX_TRANS_UNIT];
    size_t len = packet.serialize(buffer, sizeof(buffer));

    // Queue packet if TX busy
    if (_radio.isTxBusy()) {
        return queuePacket(packet);
    }

    return _radio.sendAsync(buffer, len);
}

void MeshCore::update() {
    // Check if TX completed
    if (!_radio.isTxBusy() && _pendingTxComplete) {
        _radio.finishTx();
        _pendingTxComplete = false;

        // Send next queued packet if any
        if (!_txQueue.empty()) {
            sendPacket(_txQueue.front());
            _txQueue.pop();
        }
    }

    // ... rest of update
}
```

## Considerations

1. **TX Queue**: Need a queue for packets that arrive while TX is in progress
2. **Priority**: ADVERT packets could be lower priority than messages
3. **Timeout**: Add timeout for stuck TX operations
4. **RX/TX Switching**: Must properly switch back to RX mode after TX
5. **Thread Safety**: ISR and main loop access shared state

## Testing

1. Send multiple messages rapidly - verify queuing works
2. Monitor UI responsiveness during TX
3. Verify no packet loss on RX during TX
4. Test with high mesh traffic

## Effort Estimate

Medium-high complexity:
- Radio class changes: ~2 hours
- MeshCore queue implementation: ~2 hours
- Testing and debugging: ~4 hours

## References

- [RadioLib Interrupt TX Example](https://github.com/jgromes/RadioLib/blob/master/examples/SX126x/SX126x_Transmit_Interrupt/SX126x_Transmit_Interrupt.ino)
- [ESP32 IRAM_ATTR for ISRs](https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-guides/memory-types.html)
