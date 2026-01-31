#pragma once

#include "hardware/display.h"
#include "hardware/keyboard.h"
#include "hardware/radio.h"
#include "mesh/identity.h"

// Settings persistence and application (no UI)
class Settings {
public:
    Settings();

    // Load settings from NVS
    void load();

    // Save settings to NVS
    void save();

    // Apply settings to hardware
    void applyToRadio(Radio& radio);
    void applyToDisplay(Display& display);
    void applyToIdentity(Identity& identity);
    void applyToKeyboard(Keyboard& keyboard);

    // Getters
    const char* getNodeName() const { return _nodeName; }
    int getRegion() const { return _region; }
    int getTxPower() const { return _txPower; }
    int getTTL() const { return _ttl; }
    int getBrightness() const { return _brightness; }
    int getFontSize() const { return _fontSize; }
    int getTrackballSensitivity() const { return _trackballSensitivity; }

    // Setters
    void setNodeName(const char* name);
    void setRegion(int region) { _region = region; }
    void setTxPower(int power) { _txPower = power; }
    void setTTL(int ttl) { _ttl = ttl; }
    void setBrightness(int brightness) { _brightness = brightness; }
    void setFontSize(int size) { _fontSize = size; }
    void setTrackballSensitivity(int sens) { _trackballSensitivity = sens; }

private:
    static constexpr int MAX_NODE_NAME = 16;

    char _nodeName[MAX_NODE_NAME + 1];
    int _region = 0;        // 0=EU868, 1=US915, 2=AU915, 3=AS923
    int _txPower = 22;      // dBm
    int _ttl = 3;           // Default TTL
    int _brightness = 200;  // 0-255
    int _fontSize = 1;      // 0=Small, 1=Medium, 2=Large
    int _trackballSensitivity = 2;

    // Region frequency table
    static const uint32_t REGION_FREQUENCIES[];
};
