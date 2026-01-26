#include "settings.h"
#include <Preferences.h>
#include <Arduino.h>

// Region frequency table (matching original)
const uint32_t Settings::REGION_FREQUENCIES[] = {
    868000000,  // EU868
    915000000,  // US915
    915000000,  // AU915
    923000000   // AS923
};

Settings::Settings() {
    strcpy(_nodeName, "MeshNode");
    load();
}

void Settings::load() {
    Preferences prefs;
    if (prefs.begin("settings", true)) {  // Read-only
        String name = prefs.getString("nodeName", "MeshNode");
        strncpy(_nodeName, name.c_str(), MAX_NODE_NAME);
        _nodeName[MAX_NODE_NAME] = '\0';

        _region = prefs.getInt("region", 0);
        _txPower = prefs.getInt("txPower", 22);
        _ttl = prefs.getInt("ttl", 3);
        _brightness = prefs.getInt("brightness", 200);
        _fontSize = prefs.getInt("fontSize", 1);
        _trackballSensitivity = prefs.getInt("trackball", 2);
        _adaptiveScrolling = prefs.getBool("adaptive", true);

        prefs.end();
        Serial.println("[Settings] Loaded from NVS");
    } else {
        Serial.println("[Settings] Using defaults");
    }
}

void Settings::save() {
    Preferences prefs;
    if (prefs.begin("settings", false)) {  // Read-write
        prefs.putString("nodeName", _nodeName);
        prefs.putInt("region", _region);
        prefs.putInt("txPower", _txPower);
        prefs.putInt("ttl", _ttl);
        prefs.putInt("brightness", _brightness);
        prefs.putInt("fontSize", _fontSize);
        prefs.putInt("trackball", _trackballSensitivity);
        prefs.putBool("adaptive", _adaptiveScrolling);
        prefs.end();
        Serial.println("[Settings] Saved to NVS");
    }
}

void Settings::setNodeName(const char* name) {
    strncpy(_nodeName, name, MAX_NODE_NAME);
    _nodeName[MAX_NODE_NAME] = '\0';
}

void Settings::applyToRadio(Radio& radio) {
    if (_region >= 0 && _region < 4) {
        radio.setFrequency(REGION_FREQUENCIES[_region]);
    }
    radio.setTxPower(_txPower);
}

void Settings::applyToDisplay(Display& display) {
    display.setBrightness(_brightness);
    display.setFontSize(static_cast<FontSize>(_fontSize));
}

void Settings::applyToIdentity(Identity& identity) {
    identity.setNodeName(_nodeName);
}

void Settings::applyToKeyboard(Keyboard& keyboard) {
    keyboard.setTrackballSensitivity(_trackballSensitivity);
    keyboard.setAdaptiveScrolling(_adaptiveScrolling);
}
