/**
 * T-Deck Plus MeshCore TUI Firmware
 *
 * Main entry point - initializes hardware and starts TUI.
 * Defensive initialization to prevent crashes.
 */

#include <Arduino.h>
#include <LittleFS.h>
#include "config.h"
#include "hardware/display.h"
#include "hardware/keyboard.h"
#include "hardware/radio.h"
#include "mesh/meshcore.h"
#include "tui/tui.h"
#include "tui/screens/main_menu.h"
#include "tui/screens/settings.h"
#include "lua/lua_runtime.h"
#include "lua/lua_screen.h"

// Track initialization status
bool displayOk = false;
bool keyboardOk = false;
bool radioOk = false;
bool meshOk = false;
bool luaOk = false;
bool littlefsOk = false;

// Hardware instances - as pointers to control initialization order
// Declared extern in headers for screen access
Display* display = nullptr;
Keyboard* keyboard = nullptr;
Radio* radio = nullptr;
MeshCore* mesh = nullptr;
TUI* tui = nullptr;

// Settings instance for loading saved preferences
static SettingsScreen* settings = nullptr;

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
    Serial.println("  T-Deck Plus MeshCore TUI");
    Serial.println("  Version 0.1.0");
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
    settings = new SettingsScreen();
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

    // Initialize Lua runtime (but don't run boot script yet - TUI not ready)
    Serial.println("Initializing Lua runtime...");
    if (LuaRuntime::instance().init()) {
        luaOk = true;
        Serial.printf("Lua OK, memory: %u bytes\n", LuaRuntime::instance().getMemoryUsed());
    } else {
        Serial.println("WARNING: Lua init failed");
    }

    // Initialize TUI (only if display and keyboard are OK)
    if (displayOk && keyboardOk) {
        Serial.println("Starting TUI...");
        tui = new TUI(*display, *keyboard);

        // Update TUI status bar with current hardware status
        tui->updateRadio(radioOk, 0);
        if (mesh && meshOk) {
            char shortId[8];
            mesh->getIdentity().getShortId(shortId);
            tui->updateNodeId(shortId);
        }

        // Now run boot script - TUI is ready so Lua can push screens
        if (luaOk) {
            if (LuaRuntime::instance().executeFile("/scripts/boot.lua")) {
                Serial.println("Boot script executed");
            } else {
                Serial.println("WARNING: Boot script failed - using C++ fallback");
                tui->push(new MainMenuScreen());
            }
        } else {
            // No Lua, use C++ main menu
            tui->push(new MainMenuScreen());
        }

        Serial.println("TUI started");
    } else {
        Serial.println("Cannot start TUI - display or keyboard not ready");
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
    static uint32_t lastHeartbeat = 0;
    uint32_t now = millis();

    // Heartbeat output every 5 seconds
    if (now - lastHeartbeat >= 5000) {
        lastHeartbeat = now;
        Serial.printf("Running... uptime=%lu ms\n", now);
    }

    // Update mesh networking
    if (mesh && meshOk) {
        mesh->update();
    }

    // Update Lua runtime (process timers)
    if (luaOk) {
        LuaRuntime::instance().update();
    }

    // Update TUI (handles input and rendering)
    if (tui) {
        tui->update();
    }

    // Small delay to prevent busy-waiting
    delay(10);
}
