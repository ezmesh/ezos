/**
 * T-Deck Plus MeshCore Firmware
 *
 * Main entry point - initializes hardware and starts Lua shell.
 * UI is now fully controlled by Lua.
 */

#include <Arduino.h>
#include <LittleFS.h>
#include "config.h"
#include "hardware/display.h"
#include "hardware/keyboard.h"
#include "hardware/radio.h"
#include "mesh/meshcore.h"
#include "settings.h"
#include "lua/lua_runtime.h"

// External functions from system_bindings.cpp for Lua main loop
extern bool hasLuaMainLoop();
extern void callLuaMainLoop();

// Track initialization status
bool displayOk = false;
bool keyboardOk = false;
bool radioOk = false;
bool meshOk = false;
bool luaOk = false;
bool littlefsOk = false;

// Hardware instances - as pointers to control initialization order
// Declared extern in headers for Lua binding access
Display* display = nullptr;
Keyboard* keyboard = nullptr;
Radio* radio = nullptr;
MeshCore* mesh = nullptr;

// Settings instance
static Settings* settings = nullptr;

void setup() {
    // Enable power - MUST be first on T-Deck Plus
    pinMode(BOARD_POWERON, OUTPUT);
    digitalWrite(BOARD_POWERON, HIGH);

    // Backlight on for visual feedback
    pinMode(TFT_BL, OUTPUT);
    digitalWrite(TFT_BL, HIGH);

    // Brief delay for power stabilization
    delay(100);

    // Initialize serial for debugging
    Serial.begin(115200);

    // Wait for USB CDC (up to 3 seconds)
    uint32_t start = millis();
    while (!Serial && (millis() - start) < 3000) {
        delay(10);
    }

    Serial.println();
    Serial.println("=====================================");
    Serial.println("  T-Deck Plus MeshCore");
    Serial.println("  Version 0.2.0 (Lua Shell)");
    Serial.println("=====================================");
    Serial.println();

    // Initialize display
    Serial.println("Initializing display...");
    display = new Display();
    if (display->init()) {
        displayOk = true;
        Serial.println("Display OK");
    } else {
        Serial.println("WARNING: Display init failed");
    }

    // Initialize keyboard
    Serial.println("Initializing keyboard...");
    keyboard = new Keyboard();
    if (keyboard->init()) {
        keyboardOk = true;
        Serial.println("Keyboard OK");
    } else {
        Serial.println("WARNING: Keyboard init failed");
    }

    // Load and apply saved settings
    Serial.println("Loading settings...");
    settings = new Settings();
    if (displayOk) {
        settings->applyToDisplay(*display);
        Serial.printf("Font size: %s\n", Display::getFontSizeName(display->getFontSize()));
    }
    if (keyboardOk) {
        settings->applyToKeyboard(*keyboard);
    }

    // Initialize radio
    Serial.println("Initializing radio...");
    radio = new Radio();
    if (radio->init()) {
        radioOk = true;
        Serial.println("Radio OK");
    } else {
        Serial.println("WARNING: Radio init failed");
    }

    // Initialize mesh networking (only if radio is OK)
    if (radioOk) {
        Serial.println("Initializing mesh...");
        mesh = new MeshCore(*radio);
        if (mesh->init()) {
            meshOk = true;
            char nodeIdStr[17];
            mesh->getIdentity().getFullId(nodeIdStr);
            Serial.printf("Node ID: %s\n", nodeIdStr);

            // Set up mesh callbacks
            mesh->setMessageCallback([](const Message& msg) {
                Serial.printf("MSG from %02X: %s\n", msg.fromHash, msg.text);
            });

            mesh->setNodeCallback([](const NodeInfo& node) {
                Serial.printf("Node discovered: %02X (%s)\n", node.pathHash, node.name);
            });
        } else {
            Serial.println("WARNING: Mesh init failed");
        }
    }

    // Initialize LittleFS for script storage
    Serial.println("Initializing LittleFS...");
    if (LittleFS.begin(true)) {
        littlefsOk = true;
        Serial.println("LittleFS OK");
    } else {
        Serial.println("WARNING: LittleFS init failed");
    }

    // Initialize Lua runtime
    Serial.println("Initializing Lua runtime...");
    if (LuaRuntime::instance().init()) {
        luaOk = true;
        Serial.printf("Lua OK, memory: %u bytes\n", LuaRuntime::instance().getMemoryUsed());
    } else {
        Serial.println("WARNING: Lua init failed");
    }

    // Run boot script (requires display and keyboard)
    if (displayOk && keyboardOk && luaOk) {
        Serial.println("Running boot script...");
        if (LuaRuntime::instance().executeFile("/scripts/boot.lua")) {
            Serial.println("Boot script executed - Lua shell active");
        } else {
            Serial.println("ERROR: Boot script failed!");
            // Show error on display with error message
            if (display) {
                display->fillRect(0, 0, display->getWidth(), display->getHeight(), 0x0000);
                display->drawText(10, 20, "Boot script failed!", 0xF800);

                // Get and display the error message
                const char* error = LuaRuntime::instance().getLastError();
                if (error && error[0] != '\0') {
                    // Word-wrap the error message across multiple lines
                    const int maxCharsPerLine = 38;  // Approximate chars that fit
                    const int lineHeight = 16;
                    int y = 45;
                    int len = strlen(error);
                    int pos = 0;

                    while (pos < len && y < display->getHeight() - 40) {
                        // Find line break point
                        int lineLen = maxCharsPerLine;
                        if (pos + lineLen > len) {
                            lineLen = len - pos;
                        } else {
                            // Try to break at newline or space
                            for (int i = pos; i < pos + lineLen && i < len; i++) {
                                if (error[i] == '\n') {
                                    lineLen = i - pos;
                                    break;
                                }
                            }
                            if (lineLen == maxCharsPerLine) {
                                // No newline found, break at last space
                                for (int i = pos + lineLen - 1; i > pos; i--) {
                                    if (error[i] == ' ') {
                                        lineLen = i - pos;
                                        break;
                                    }
                                }
                            }
                        }

                        // Copy line to buffer
                        char lineBuf[64];
                        int copyLen = (lineLen < 63) ? lineLen : 63;
                        strncpy(lineBuf, error + pos, copyLen);
                        lineBuf[copyLen] = '\0';

                        // Skip newline character if present
                        if (pos + lineLen < len && error[pos + lineLen] == '\n') {
                            pos += lineLen + 1;
                        } else {
                            pos += lineLen;
                            // Skip leading space on next line
                            while (pos < len && error[pos] == ' ') pos++;
                        }

                        display->drawText(10, y, lineBuf, 0xFFFF);
                        y += lineHeight;
                    }
                } else {
                    display->drawText(10, 50, "Check /scripts/boot.lua", 0xFFFF);
                }

                display->flush();
            }
        }
    } else {
        Serial.println("Cannot start Lua shell - hardware not ready");
        if (display) {
            display->fillRect(0, 0, display->getWidth(), display->getHeight(), 0x0000);
            display->drawText(10, 50, "Hardware init failed", 0xF800);
            display->drawText(10, 70, displayOk ? "Display: OK" : "Display: FAIL", 0xFFFF);
            display->drawText(10, 90, keyboardOk ? "Keyboard: OK" : "Keyboard: FAIL", 0xFFFF);
            display->drawText(10, 110, luaOk ? "Lua: OK" : "Lua: FAIL", 0xFFFF);
            display->flush();
        }
    }

    Serial.println();
    Serial.printf("Status: Display=%s Keyboard=%s Radio=%s Mesh=%s Lua=%s\n",
                  displayOk ? "OK" : "FAIL",
                  keyboardOk ? "OK" : "FAIL",
                  radioOk ? "OK" : "FAIL",
                  meshOk ? "OK" : "FAIL",
                  luaOk ? "OK" : "FAIL");
    Serial.println("Initialization complete!");
    Serial.println();
}

void loop() {
    // Lua main loop handles everything
    if (hasLuaMainLoop()) {
        callLuaMainLoop();
        return;
    }

    // Fallback: minimal loop if Lua not controlling
    // Just keep mesh alive and yield
    if (mesh && meshOk) {
        mesh->update();
    }

    if (luaOk) {
        LuaRuntime::instance().update();
    }

    delay(10);
}
