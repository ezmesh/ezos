#include "tui.h"
#include <Arduino.h>
#include <cstdio>

TUI::TUI(Display& display, Keyboard& keyboard)
    : _display(display)
    , _keyboard(keyboard)
{
}

void TUI::push(Screen* screen) {
    if (!screen) return;

    // Notify current screen it's being covered
    if (!_screens.empty()) {
        _screens.back()->onExit();
    }

    // Add new screen and set TUI reference
    screen->setTUI(this);
    _screens.push_back(std::unique_ptr<Screen>(screen));
    screen->onEnter();

    _needsRedraw = true;
}

void TUI::pop() {
    if (_screens.empty()) return;

    // Notify screen it's being removed
    _screens.back()->onExit();
    _screens.pop_back();

    // Notify newly visible screen
    if (!_screens.empty()) {
        _screens.back()->onEnter();
        _screens.back()->invalidate();
    }

    _needsRedraw = true;
}

void TUI::replace(Screen* screen) {
    if (!screen) return;

    // Remove current screen
    if (!_screens.empty()) {
        _screens.back()->onExit();
        _screens.pop_back();
    }

    // Add new screen
    screen->setTUI(this);
    _screens.push_back(std::unique_ptr<Screen>(screen));
    screen->onEnter();

    _needsRedraw = true;
}

void TUI::clear() {
    while (!_screens.empty()) {
        _screens.back()->onExit();
        _screens.pop_back();
    }
    _needsRedraw = true;
}

Screen* TUI::current() {
    return _screens.empty() ? nullptr : _screens.back().get();
}

void TUI::update() {
    processInput();

    // Allow current screen to update its state (for animations, games, etc.)
    if (!_screens.empty()) {
        _screens.back()->onRefresh();
    }

    render();
}

bool TUI::processInput() {
    if (_screens.empty()) return false;

    KeyEvent key = _keyboard.read();
    if (!key.valid) return false;

    ScreenResult result = _screens.back()->handleKey(key);

    switch (result) {
        case ScreenResult::POP:
            pop();
            break;

        case ScreenResult::EXIT:
            clear();
            break;

        case ScreenResult::PUSH:
        case ScreenResult::REPLACE:
            // These are handled by the screen itself via pushScreen/replaceScreen
            break;

        case ScreenResult::CONTINUE:
        default:
            break;
    }

    return true;
}

void TUI::render() {
    // Check if any screen needs redraw
    bool needsRedraw = _needsRedraw;
    if (!needsRedraw && !_screens.empty()) {
        needsRedraw = _screens.back()->needsRedraw();
    }

    // Periodic status bar update
    uint32_t now = millis();
    if (now - _lastStatusUpdate >= Theme::Timing::STATUS_UPDATE_MS) {
        _lastStatusUpdate = now;
        needsRedraw = true;
    }

    if (!needsRedraw) return;

    // Clear display buffer
    _display.clear();

    // Render current screen
    if (!_screens.empty()) {
        renderScreen();
        _screens.back()->clearRedrawFlag();
    }

    // Push to display
    _display.flush();

    _needsRedraw = false;
}

void TUI::renderScreen() {
    Screen* screen = current();
    if (!screen) return;

    screen->render(_display);
}

void TUI::setStatus(const StatusInfo& status) {
    _status = status;
    _needsRedraw = true;
}

void TUI::updateBattery(uint8_t percent) {
    _status.batteryPercent = percent;
}

void TUI::updateRadio(bool ok, int bars) {
    _status.radioOk = ok;
    _status.signalBars = bars;
}

void TUI::updateNodeCount(int count) {
    _status.nodeCount = count;
}

void TUI::updateNodeId(const char* shortId) {
    strncpy(_status.nodeIdShort, shortId, sizeof(_status.nodeIdShort) - 1);
    _status.nodeIdShort[sizeof(_status.nodeIdShort) - 1] = '\0';
}

void TUI::setUnreadFlag(bool unread) {
    _status.hasUnread = unread;
}

void TUI::invalidate() {
    _needsRedraw = true;
    if (!_screens.empty()) {
        _screens.back()->invalidate();
    }
}
