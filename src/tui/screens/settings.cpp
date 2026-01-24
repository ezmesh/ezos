#include "settings.h"
#include <Preferences.h>
#include <cstdio>
#include <cstring>
#include <Arduino.h>
#include "../../mesh/meshcore.h"

// Access global instances from main.cpp
extern MeshCore* mesh;
extern Keyboard* keyboard;

// Region options
const char* SettingsScreen::REGION_OPTIONS[] = {
    "EU868",
    "US915",
    "AU915",
    "AS923"
};
const int SettingsScreen::REGION_COUNT = 4;

// Frequency mapping for regions
static const float REGION_FREQUENCIES[] = {
    869.618f, // EU868
    915.0f,   // US915
    915.0f,   // AU915
    923.0f    // AS923
};

// SettingsScreen implementation
SettingsScreen::SettingsScreen() {
    memset(_nodeName, 0, sizeof(_nodeName));
    strcpy(_nodeName, "MeshNode");
    loadSettings();
}

void SettingsScreen::onEnter() {
    loadSettings();
    invalidate();
}

void SettingsScreen::loadSettings() {
    Preferences prefs;
    if (prefs.begin("settings", true)) {  // Read-only
        String name = prefs.getString("nodeName", "MeshNode");
        strncpy(_nodeName, name.c_str(), MAX_NODE_NAME);
        _nodeName[MAX_NODE_NAME] = '\0';

        _region = prefs.getInt("region", 0);
        _txPower = prefs.getInt("txPower", 22);
        _ttl = prefs.getInt("ttl", 3);
        _brightness = prefs.getInt("brightness", 200);
        _fontSize = prefs.getInt("fontSize", 1);  // Default to Medium
        _trackballSensitivity = prefs.getInt("tbSens", 2);
        _adaptiveScrolling = prefs.getBool("adaptScroll", true);

        prefs.end();

        // Apply trackball settings on load
        if (keyboard) {
            keyboard->setTrackballSensitivity(_trackballSensitivity);
            keyboard->setAdaptiveScrolling(_adaptiveScrolling);
        }
    }
}

void SettingsScreen::saveSettings() {
    Preferences prefs;
    if (prefs.begin("settings", false)) {  // Read-write
        prefs.putString("nodeName", _nodeName);
        prefs.putInt("region", _region);
        prefs.putInt("txPower", _txPower);
        prefs.putInt("ttl", _ttl);
        prefs.putInt("brightness", _brightness);
        prefs.putInt("fontSize", _fontSize);
        prefs.putInt("tbSens", _trackballSensitivity);
        prefs.putBool("adaptScroll", _adaptiveScrolling);
        prefs.end();

        // Apply trackball settings on save
        if (keyboard) {
            keyboard->setTrackballSensitivity(_trackballSensitivity);
            keyboard->setAdaptiveScrolling(_adaptiveScrolling);
        }
    }
}

void SettingsScreen::render(Display& display) {
    display.drawBox(0, 0, Theme::SCREEN_COLS, Theme::SCREEN_ROWS - 1,
                   getTitle(), Theme::Color::BORDER, Theme::Color::TITLE);

    int labelX = 2;
    int valueX = 14;  // Moved closer to fit on single line

    // Helper lambda to render a setting item
    auto renderItem = [&](int index, int row, const char* label, const char* value, bool showArrows = false) {
        bool isSelected = (_selectedIndex == index);
        int py = row * TUI_FONT_HEIGHT;

        if (isSelected) {
            display.fillRect(TUI_FONT_WIDTH, py,
                           (Theme::SCREEN_COLS - 2) * TUI_FONT_WIDTH,
                           TUI_FONT_HEIGHT, Theme::Color::SELECTION_BG);
            display.drawText(TUI_FONT_WIDTH, py, ">", Theme::Color::SELECTION_FG);
        }

        display.drawText(labelX * TUI_FONT_WIDTH, py, label,
                        isSelected ? Theme::Color::SELECTION_FG : Theme::Color::TEXT_SECONDARY);

        if (showArrows && _editing && isSelected) {
            char arrowVal[32];
            snprintf(arrowVal, sizeof(arrowVal), "< %s >", value);
            display.drawText(valueX * TUI_FONT_WIDTH, py, arrowVal, Theme::Color::HIGHLIGHT);
        } else {
            display.drawText(valueX * TUI_FONT_WIDTH, py, value,
                           isSelected ? Theme::Color::SELECTION_FG : Theme::Color::TEXT_PRIMARY);
        }
    };

    int row = 2;  // Start after title

    // Node Name
    renderItem(0, row++, "Name:", _nodeName);

    // Region
    renderItem(1, row++, "Region:", REGION_OPTIONS[_region], true);

    // TX Power
    {
        char val[16];
        snprintf(val, sizeof(val), "%d dBm", _txPower);
        renderItem(2, row++, "TX Power:", val, true);
    }

    // TTL
    {
        char val[16];
        snprintf(val, sizeof(val), "%d hops", _ttl);
        renderItem(3, row++, "TTL:", val, true);
    }

    // Brightness
    {
        char val[16];
        int percent = (_brightness * 100) / 255;
        snprintf(val, sizeof(val), "%d%%", percent);
        renderItem(4, row++, "Brightness:", val, true);
    }

    // Font Size
    {
        const char* label = _fontSize == 0 ? "Small" :
                           _fontSize == 1 ? "Medium" : "Large";
        renderItem(5, row++, "Font:", label, true);
    }

    // Trackball Sensitivity
    {
        char val[20];
        const char* label = _trackballSensitivity <= 2 ? "Fast" :
                           _trackballSensitivity <= 4 ? "Normal" :
                           _trackballSensitivity <= 6 ? "Slow" : "V.Slow";
        snprintf(val, sizeof(val), "%d (%s)", _trackballSensitivity, label);
        renderItem(6, row++, "Trackball:", val, true);
    }

    // Adaptive Scrolling toggle
    renderItem(7, row++, "Adaptive:", _adaptiveScrolling ? "On" : "Off", true);

    // Save button
    {
        bool isSelected = (_selectedIndex == 8);
        int py = row * TUI_FONT_HEIGHT;

        if (isSelected) {
            display.fillRect(TUI_FONT_WIDTH, py,
                           (Theme::SCREEN_COLS - 2) * TUI_FONT_WIDTH,
                           TUI_FONT_HEIGHT, Theme::Color::SELECTION_BG);
            display.drawText(TUI_FONT_WIDTH, py, ">", Theme::Color::SELECTION_FG);
        }

        display.drawText(labelX * TUI_FONT_WIDTH, py, "[Save Settings]",
                        isSelected ? Theme::Color::SELECTION_FG : Theme::Color::HIGHLIGHT);
    }

    // Help bar
    const char* helpText = _editing ?
        "[<>]Adjust [Enter]Done" : "[Enter]Edit [Q]Back";
    display.drawText(TUI_FONT_WIDTH, (Theme::SCREEN_ROWS - 3) * TUI_FONT_HEIGHT,
                    helpText, Theme::Color::TEXT_SECONDARY);
}

ScreenResult SettingsScreen::handleKey(KeyEvent key) {
    if (!key.valid) return ScreenResult::CONTINUE;

    invalidate();

    if (_editing) {
        if (key.isSpecial()) {
            switch (key.special) {
                case SpecialKey::LEFT:
                    adjustValue(-1);
                    break;
                case SpecialKey::RIGHT:
                    adjustValue(1);
                    break;
                case SpecialKey::ENTER:
                case SpecialKey::ESCAPE:
                    stopEditing();
                    break;
                default:
                    break;
            }
        }
        return ScreenResult::CONTINUE;
    }

    if (key.isSpecial()) {
        switch (key.special) {
            case SpecialKey::UP:
                selectPrevious();
                break;
            case SpecialKey::DOWN:
                selectNext();
                break;
            case SpecialKey::ENTER:
                startEditing();
                break;
            case SpecialKey::ESCAPE:
                return ScreenResult::POP;
            default:
                break;
        }
    } else if (key.isPrintable()) {
        if (key.character == 'q' || key.character == 'Q') {
            return ScreenResult::POP;
        }
    }

    return ScreenResult::CONTINUE;
}

void SettingsScreen::selectNext() {
    if (_selectedIndex < SETTING_COUNT - 1) {
        _selectedIndex++;
    }
}

void SettingsScreen::selectPrevious() {
    if (_selectedIndex > 0) {
        _selectedIndex--;
    }
}

void SettingsScreen::startEditing() {
    if (_selectedIndex == 0) {
        // Node name - would need text input dialog
        editText();
    } else if (_selectedIndex == 8) {
        // Save button
        saveSettings();
        Serial.println("Settings saved");
    } else {
        _editing = true;
    }
}

void SettingsScreen::stopEditing() {
    _editing = false;
}

void SettingsScreen::adjustValue(int delta) {
    switch (_selectedIndex) {
        case 1:  // Region
            _region = (_region + delta + REGION_COUNT) % REGION_COUNT;
            break;
        case 2:  // TX Power
            _txPower += delta;
            if (_txPower < 0) _txPower = 0;
            if (_txPower > 22) _txPower = 22;
            break;
        case 3:  // TTL
            _ttl += delta;
            if (_ttl < 1) _ttl = 1;
            if (_ttl > 10) _ttl = 10;
            break;
        case 4:  // Brightness
            _brightness += delta * 25;
            if (_brightness < 25) _brightness = 25;
            if (_brightness > 255) _brightness = 255;
            break;
        case 5:  // Font Size
            _fontSize += delta;
            if (_fontSize < 0) _fontSize = 2;  // Wrap around
            if (_fontSize > 2) _fontSize = 0;
            // Note: Font change requires save & restart to take effect properly
            break;
        case 6:  // Trackball Sensitivity
            _trackballSensitivity += delta;
            if (_trackballSensitivity < 1) _trackballSensitivity = 1;
            if (_trackballSensitivity > 10) _trackballSensitivity = 10;
            // Apply immediately for instant feedback
            if (keyboard) {
                keyboard->setTrackballSensitivity(_trackballSensitivity);
            }
            break;
        case 7:  // Adaptive Scrolling toggle
            _adaptiveScrolling = !_adaptiveScrolling;
            // Apply immediately for instant feedback
            if (keyboard) {
                keyboard->setAdaptiveScrolling(_adaptiveScrolling);
            }
            break;
    }
}

void SettingsScreen::editText() {
    // For simplicity, just toggle to a preset name
    // In a full implementation, you'd push an InputScreen
    Serial.println("TODO: Implement text input for node name");
}

void SettingsScreen::applyToRadio(Radio& radio) {
    radio.setFrequency(REGION_FREQUENCIES[_region]);
    radio.setTxPower(_txPower);
}

void SettingsScreen::applyToDisplay(Display& display) {
    display.setBrightness(_brightness);
    display.setFontSize(static_cast<FontSize>(_fontSize));
}

void SettingsScreen::applyToIdentity(Identity& identity) {
    identity.setNodeName(_nodeName);
}

void SettingsScreen::applyToKeyboard(Keyboard& keyboard) {
    keyboard.setTrackballSensitivity(_trackballSensitivity);
    keyboard.setAdaptiveScrolling(_adaptiveScrolling);
}

// NodeInfoScreen implementation
NodeInfoScreen::NodeInfoScreen() {
}

void NodeInfoScreen::onEnter() {
    // Populate from global mesh instance
    if (mesh) {
        mesh->getIdentity().getFullId(_nodeId);
        strncpy(_nodeName, mesh->getIdentity().getNodeName(), MAX_NODE_NAME);
        _nodeName[MAX_NODE_NAME] = '\0';
        mesh->getIdentity().getPublicKeyFingerprint(_pubKeyFingerprint);
        _txCount = mesh->getTxCount();
        _rxCount = mesh->getRxCount();
        _uptimeSeconds = millis() / 1000;
        // TODO: get actual battery, radio config from hardware
    }
    invalidate();
}

void NodeInfoScreen::render(Display& display) {
    display.drawBox(0, 0, Theme::SCREEN_COLS, Theme::SCREEN_ROWS - 1,
                   getTitle(), Theme::Color::BORDER, Theme::Color::TITLE);

    int row = 2;
    int labelX = 2;
    int valueX = 12;

    // Helper to render an info row
    auto renderRow = [&](const char* label, const char* value, uint16_t valueColor = Theme::Color::TEXT_PRIMARY) {
        int py = row * TUI_FONT_HEIGHT;
        display.drawText(labelX * TUI_FONT_WIDTH, py, label, Theme::Color::TEXT_SECONDARY);
        display.drawText(valueX * TUI_FONT_WIDTH, py, value, valueColor);
        row++;
    };

    // Node Name
    renderRow("Name:", _nodeName, Theme::Color::HIGHLIGHT);

    // Node ID
    renderRow("ID:", _nodeId);

    // Public Key Fingerprint
    renderRow("PubKey:", _pubKeyFingerprint, Theme::Color::HIGHLIGHT);

    // Battery
    char battStr[16];
    snprintf(battStr, sizeof(battStr), "%d%%", _battery);
    uint16_t battColor = _battery > 20 ? Theme::Color::STATUS_OK : Theme::Color::STATUS_ERROR;
    renderRow("Battery:", battStr, battColor);

    // TX/RX counts
    char statsStr[24];
    snprintf(statsStr, sizeof(statsStr), "TX:%lu RX:%lu", _txCount, _rxCount);
    renderRow("Packets:", statsStr);

    // Uptime
    char uptimeStr[24];
    formatUptime(uptimeStr, sizeof(uptimeStr));
    renderRow("Uptime:", uptimeStr);

    // Help bar
    display.drawText(TUI_FONT_WIDTH, (Theme::SCREEN_ROWS - 3) * TUI_FONT_HEIGHT,
                    "[Q]Back", Theme::Color::TEXT_SECONDARY);
}

ScreenResult NodeInfoScreen::handleKey(KeyEvent key) {
    if (!key.valid) return ScreenResult::CONTINUE;

    if (key.isSpecial() && key.special == SpecialKey::ESCAPE) {
        return ScreenResult::POP;
    }

    if (key.isPrintable() && (key.character == 'q' || key.character == 'Q')) {
        return ScreenResult::POP;
    }

    return ScreenResult::CONTINUE;
}

void NodeInfoScreen::formatUptime(char* buffer, size_t bufLen) {
    uint32_t secs = _uptimeSeconds;
    uint32_t days = secs / 86400;
    secs %= 86400;
    uint32_t hours = secs / 3600;
    secs %= 3600;
    uint32_t mins = secs / 60;

    if (days > 0) {
        snprintf(buffer, bufLen, "%lud %luh %lum", days, hours, mins);
    } else if (hours > 0) {
        snprintf(buffer, bufLen, "%luh %lum", hours, mins);
    } else {
        snprintf(buffer, bufLen, "%lum", mins);
    }
}
