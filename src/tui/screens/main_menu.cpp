#include "main_menu.h"
#include "../../lua/lua_runtime.h"
#include <cstdio>

extern bool luaOk;

MainMenuScreen::MainMenuScreen() {
}

void MainMenuScreen::onEnter() {
    invalidate();
}

void MainMenuScreen::render(Display& display) {
    // This is the C++ fallback when Lua fails
    display.drawBox(0, 0, Theme::SCREEN_COLS, Theme::SCREEN_ROWS - 1,
                   "System", Theme::Color::BORDER, Theme::Color::TITLE);

    int y = 3 * TUI_FONT_HEIGHT;
    display.drawTextCentered(y, "Lua scripting failed", Theme::Color::TEXT_ERROR);

    y += 2 * TUI_FONT_HEIGHT;
    display.drawTextCentered(y, "Check /scripts/boot.lua", Theme::Color::TEXT_PRIMARY);

    y += TUI_FONT_HEIGHT;
    display.drawTextCentered(y, "on the filesystem", Theme::Color::TEXT_PRIMARY);

    y += 3 * TUI_FONT_HEIGHT;
    display.drawTextCentered(y, "[R] Retry  [Q] Quit", Theme::Color::TEXT_SECONDARY);
}

ScreenResult MainMenuScreen::handleKey(KeyEvent key) {
    if (!key.valid) return ScreenResult::CONTINUE;

    if (key.isPrintable()) {
        char c = key.character;

        if (c == 'q' || c == 'Q') {
            return ScreenResult::EXIT;
        }

        if (c == 'r' || c == 'R') {
            // Try to reload Lua boot script
            if (luaOk && LuaRuntime::instance().reloadBootScript()) {
                return ScreenResult::POP;  // Pop this fallback screen
            }
            invalidate();  // Redraw to show we tried
        }
    }

    return ScreenResult::CONTINUE;
}

void MainMenuScreen::selectNext() {
}

void MainMenuScreen::selectPrevious() {
}

void MainMenuScreen::activateSelected() {
}

void MainMenuScreen::setMessageCount(int unread) {
}

void MainMenuScreen::setChannelCount(int unread) {
}

void MainMenuScreen::setContactCount(int count) {
}

void MainMenuScreen::setNodeCount(int count) {
}
