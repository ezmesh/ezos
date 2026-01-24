#pragma once

#include "../screen.h"
#include "../../hardware/radio.h"
#include "../../hardware/keyboard.h"
#include "../../mesh/identity.h"

// Setting item types
enum class SettingType {
    TEXT,       // Text input
    NUMBER,     // Numeric input
    TOGGLE,     // On/Off toggle
    SELECT,     // Selection from list
    ACTION      // Trigger action
};

// Setting item structure
struct SettingItem {
    const char* label;
    const char* description;
    SettingType type;
    void* value;           // Pointer to value storage
    int minVal, maxVal;    // For NUMBER type
    const char** options;  // For SELECT type
    int optionCount;       // For SELECT type
};

// Settings screen
class SettingsScreen : public Screen {
public:
    SettingsScreen();
    ~SettingsScreen() override = default;

    void onEnter() override;
    void render(Display& display) override;
    ScreenResult handleKey(KeyEvent key) override;
    const char* getTitle() override { return "Settings"; }

    // Get current settings
    const char* getNodeName() const { return _nodeName; }
    int getRegion() const { return _region; }
    int getTxPower() const { return _txPower; }
    int getTTL() const { return _ttl; }
    int getBrightness() const { return _brightness; }
    int getTrackballSensitivity() const { return _trackballSensitivity; }
    bool getAdaptiveScrolling() const { return _adaptiveScrolling; }
    int getFontSize() const { return _fontSize; }

    // Apply settings to hardware
    void applyToRadio(Radio& radio);
    void applyToDisplay(Display& display);
    void applyToIdentity(Identity& identity);
    void applyToKeyboard(Keyboard& keyboard);

private:
    static constexpr int SETTING_COUNT = 9;  // Name, Region, TXPower, TTL, Brightness, Font, Trackball, Adaptive, Save
    static constexpr int VISIBLE_ITEMS = 10;

    int _selectedIndex = 0;
    int _scrollOffset = 0;
    bool _editing = false;

    // Setting values
    char _nodeName[MAX_NODE_NAME + 1];
    int _region = 0;        // 0=EU868, 1=US915, 2=AU915, 3=AS923
    int _txPower = 22;      // dBm (max for SX1262)
    int _ttl = 3;           // Default TTL
    int _brightness = 200;  // 0-255
    int _fontSize = 1;       // 0=Small, 1=Medium, 2=Large (FontSize enum)
    int _trackballSensitivity = 2;  // 1-10, lower = more sensitive
    bool _adaptiveScrolling = true;  // Threshold loosens when scrolling continuously

    // Region options
    static const char* REGION_OPTIONS[];
    static const int REGION_COUNT;

    void selectNext();
    void selectPrevious();
    void startEditing();
    void stopEditing();
    void adjustValue(int delta);
    void editText();
    void saveSettings();
    void loadSettings();
};

// Node info screen (device status)
class NodeInfoScreen : public Screen {
public:
    NodeInfoScreen();
    ~NodeInfoScreen() override = default;

    void onEnter() override;
    void render(Display& display) override;
    ScreenResult handleKey(KeyEvent key) override;
    const char* getTitle() override { return "Node Info"; }

    // Update info
    void setNodeId(const char* nodeId) { strncpy(_nodeId, nodeId, 12); }
    void setNodeName(const char* name) { strncpy(_nodeName, name, MAX_NODE_NAME); }
    void setPubKeyFingerprint(const char* fp) { strncpy(_pubKeyFingerprint, fp, 8); }
    void setBattery(uint8_t percent) { _battery = percent; }
    void setRadioConfig(const RadioConfig& config) { _radioConfig = config; }
    void setStats(uint32_t tx, uint32_t rx) { _txCount = tx; _rxCount = rx; }
    void setUptime(uint32_t seconds) { _uptimeSeconds = seconds; }

private:
    char _nodeId[16] = "------------";
    char _nodeName[MAX_NODE_NAME + 1] = "Unknown";
    char _pubKeyFingerprint[16] = "--------";
    uint8_t _battery = 0;
    RadioConfig _radioConfig;
    uint32_t _txCount = 0;
    uint32_t _rxCount = 0;
    uint32_t _uptimeSeconds = 0;

    void formatUptime(char* buffer, size_t bufLen);
};
