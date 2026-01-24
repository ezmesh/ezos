#pragma once

#include <vector>
#include <memory>
#include "../hardware/display.h"
#include "../hardware/keyboard.h"
#include "screen.h"
#include "theme.h"

// Status bar information
struct StatusInfo {
    uint8_t batteryPercent = 100;
    bool radioOk = false;
    int signalBars = 0;          // 0-4
    int nodeCount = 0;
    bool hasUnread = false;
    char nodeIdShort[8] = "------";
};

// TUI Manager - handles screen stack and rendering
class TUI {
public:
    TUI(Display& display, Keyboard& keyboard);
    ~TUI() = default;

    // Prevent copying
    TUI(const TUI&) = delete;
    TUI& operator=(const TUI&) = delete;

    // Screen management
    void push(Screen* screen);           // Push new screen onto stack
    void pop();                           // Pop current screen
    void replace(Screen* screen);         // Replace current screen
    void clear();                         // Clear all screens

    // Get current screen (nullptr if empty)
    Screen* current();

    // Check if screen stack is empty
    bool isEmpty() const { return _screens.empty(); }

    // Main loop methods
    void update();                        // Process input and render

    // Separate update phases (for custom loops)
    bool processInput();                  // Returns true if input was processed
    void render();                        // Render current screen

    // Status bar
    void setStatus(const StatusInfo& status);
    void updateBattery(uint8_t percent);
    void updateRadio(bool ok, int bars);
    void updateNodeCount(int count);
    void updateNodeId(const char* shortId);
    void setUnreadFlag(bool unread);

    // Force redraw on next render
    void invalidate();

    // Get status info for Lua
    const StatusInfo& getStatus() const { return _status; }

private:
    Display& _display;
    Keyboard& _keyboard;
    std::vector<std::unique_ptr<Screen>> _screens;
    StatusInfo _status;
    bool _needsRedraw = true;
    uint32_t _lastStatusUpdate = 0;

    void renderScreen();
};
