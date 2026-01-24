#include "screen.h"
#include "tui.h"
#include <cstring>
#include <Arduino.h>

// Screen base class implementation
void Screen::pushScreen(Screen* screen) {
    if (_tui) {
        _tui->push(screen);
    }
}

void Screen::replaceScreen(Screen* screen) {
    if (_tui) {
        _tui->replace(screen);
    }
}

// DialogScreen implementation
DialogScreen::DialogScreen(const char* title, const char* message,
                           const char* okText, const char* cancelText)
    : _title(title)
    , _message(message)
    , _okText(okText)
    , _cancelText(cancelText)
    , _showCancel(cancelText != nullptr)
{
}

void DialogScreen::render(Display& display) {
    // Calculate dialog dimensions
    int msgLen = strlen(_message);
    int dialogWidth = msgLen + 4;
    if (dialogWidth > Theme::SCREEN_COLS - 4) {
        dialogWidth = Theme::SCREEN_COLS - 4;
    }
    if (dialogWidth < 20) {
        dialogWidth = 20;
    }

    int dialogHeight = 7;
    int startX = (Theme::SCREEN_COLS - dialogWidth) / 2;
    int startY = (Theme::SCREEN_ROWS - dialogHeight) / 2;

    // Draw dialog box
    display.drawBox(startX, startY, dialogWidth, dialogHeight, _title,
                   Theme::Color::BORDER_ACTIVE, Theme::Color::TITLE);

    // Draw message (centered)
    int msgX = startX + (dialogWidth - msgLen) / 2;
    if (msgX < startX + 1) msgX = startX + 1;
    display.drawText(msgX * TUI_FONT_WIDTH, (startY + 2) * TUI_FONT_HEIGHT,
                     _message, Theme::Color::TEXT_PRIMARY);

    // Draw buttons
    int buttonY = startY + dialogHeight - 2;

    if (_showCancel) {
        // Two buttons: [OK] and [Cancel]
        int okX = startX + dialogWidth / 4;
        int cancelX = startX + (3 * dialogWidth) / 4 - strlen(_cancelText) - 2;

        // OK button
        if (_selection == 0) {
            display.fillRect(okX * TUI_FONT_WIDTH - 2, buttonY * TUI_FONT_HEIGHT,
                           (strlen(_okText) + 2) * TUI_FONT_WIDTH + 4, TUI_FONT_HEIGHT,
                           Theme::Color::SELECTION_BG);
            display.drawText(okX * TUI_FONT_WIDTH, buttonY * TUI_FONT_HEIGHT,
                            _okText, Theme::Color::SELECTION_FG);
        } else {
            display.drawText(okX * TUI_FONT_WIDTH, buttonY * TUI_FONT_HEIGHT,
                            _okText, Theme::Color::TEXT_SECONDARY);
        }

        // Cancel button
        if (_selection == 1) {
            display.fillRect(cancelX * TUI_FONT_WIDTH - 2, buttonY * TUI_FONT_HEIGHT,
                           (strlen(_cancelText) + 2) * TUI_FONT_WIDTH + 4, TUI_FONT_HEIGHT,
                           Theme::Color::SELECTION_BG);
            display.drawText(cancelX * TUI_FONT_WIDTH, buttonY * TUI_FONT_HEIGHT,
                            _cancelText, Theme::Color::SELECTION_FG);
        } else {
            display.drawText(cancelX * TUI_FONT_WIDTH, buttonY * TUI_FONT_HEIGHT,
                            _cancelText, Theme::Color::TEXT_SECONDARY);
        }
    } else {
        // Single OK button centered
        int okX = startX + (dialogWidth - strlen(_okText)) / 2;
        display.fillRect(okX * TUI_FONT_WIDTH - 2, buttonY * TUI_FONT_HEIGHT,
                       (strlen(_okText) + 2) * TUI_FONT_WIDTH + 4, TUI_FONT_HEIGHT,
                       Theme::Color::SELECTION_BG);
        display.drawText(okX * TUI_FONT_WIDTH, buttonY * TUI_FONT_HEIGHT,
                        _okText, Theme::Color::SELECTION_FG);
    }
}

ScreenResult DialogScreen::handleKey(KeyEvent key) {
    if (!key.valid) return ScreenResult::CONTINUE;

    if (key.isSpecial()) {
        switch (key.special) {
            case SpecialKey::LEFT:
            case SpecialKey::RIGHT:
                if (_showCancel) {
                    _selection = 1 - _selection;
                    invalidate();
                }
                break;

            case SpecialKey::ENTER:
                _confirmed = (_selection == 0);
                return ScreenResult::POP;

            case SpecialKey::ESCAPE:
                _confirmed = false;
                return ScreenResult::POP;

            default:
                break;
        }
    }

    return ScreenResult::CONTINUE;
}

// InputScreen implementation
InputScreen::InputScreen(const char* title, const char* prompt,
                         char* buffer, size_t bufferSize,
                         const char* initialValue)
    : _title(title)
    , _prompt(prompt)
    , _buffer(buffer)
    , _bufferSize(bufferSize)
{
    if (initialValue) {
        strncpy(_buffer, initialValue, _bufferSize - 1);
        _buffer[_bufferSize - 1] = '\0';
        _cursorPos = strlen(_buffer);
    } else {
        _buffer[0] = '\0';
        _cursorPos = 0;
    }
}

void InputScreen::render(Display& display) {
    // Update cursor blink
    uint32_t now = millis();
    if (now - _lastBlink >= Theme::Timing::CURSOR_BLINK_MS) {
        _cursorVisible = !_cursorVisible;
        _lastBlink = now;
    }

    // Calculate dialog dimensions
    int dialogWidth = Theme::SCREEN_COLS - 4;
    int dialogHeight = 7;
    int startX = 2;
    int startY = (Theme::SCREEN_ROWS - dialogHeight) / 2;

    // Draw dialog box
    display.drawBox(startX, startY, dialogWidth, dialogHeight, _title,
                   Theme::Color::BORDER_ACTIVE, Theme::Color::TITLE);

    // Draw prompt
    display.drawText((startX + 1) * TUI_FONT_WIDTH, (startY + 2) * TUI_FONT_HEIGHT,
                     _prompt, Theme::Color::TEXT_SECONDARY);

    // Draw input field background
    int inputY = startY + 3;
    int inputWidth = dialogWidth - 4;
    display.fillRect((startX + 2) * TUI_FONT_WIDTH, inputY * TUI_FONT_HEIGHT,
                     inputWidth * TUI_FONT_WIDTH, TUI_FONT_HEIGHT,
                     Colors::DARK_GRAY);

    // Draw input text
    display.drawText((startX + 2) * TUI_FONT_WIDTH, inputY * TUI_FONT_HEIGHT,
                     _buffer, Theme::Color::TEXT_PRIMARY);

    // Draw cursor
    if (_cursorVisible) {
        int cursorX = (startX + 2 + _cursorPos) * TUI_FONT_WIDTH;
        display.fillRect(cursorX, inputY * TUI_FONT_HEIGHT, 2, TUI_FONT_HEIGHT,
                        Theme::Color::CURSOR);
    }

    // Draw hint
    display.drawText((startX + 1) * TUI_FONT_WIDTH, (startY + dialogHeight - 2) * TUI_FONT_HEIGHT,
                     "[Enter] Submit  [Esc] Cancel", Theme::Color::TEXT_SECONDARY);
}

ScreenResult InputScreen::handleKey(KeyEvent key) {
    if (!key.valid) return ScreenResult::CONTINUE;

    invalidate();  // Any key press should redraw

    if (key.isSpecial()) {
        switch (key.special) {
            case SpecialKey::ENTER:
                _submitted = true;
                return ScreenResult::POP;

            case SpecialKey::ESCAPE:
                _submitted = false;
                return ScreenResult::POP;

            case SpecialKey::BACKSPACE:
                if (_cursorPos > 0) {
                    // Move characters after cursor back
                    memmove(_buffer + _cursorPos - 1, _buffer + _cursorPos,
                           strlen(_buffer) - _cursorPos + 1);
                    _cursorPos--;
                }
                break;

            case SpecialKey::DELETE:
                if (_cursorPos < strlen(_buffer)) {
                    memmove(_buffer + _cursorPos, _buffer + _cursorPos + 1,
                           strlen(_buffer) - _cursorPos);
                }
                break;

            case SpecialKey::LEFT:
                if (_cursorPos > 0) {
                    _cursorPos--;
                }
                break;

            case SpecialKey::RIGHT:
                if (_cursorPos < strlen(_buffer)) {
                    _cursorPos++;
                }
                break;

            default:
                break;
        }
    } else if (key.isPrintable()) {
        // Insert character at cursor position
        size_t len = strlen(_buffer);
        if (len < _bufferSize - 1) {
            // Make room for new character
            memmove(_buffer + _cursorPos + 1, _buffer + _cursorPos,
                   len - _cursorPos + 1);
            _buffer[_cursorPos] = key.character;
            _cursorPos++;
        }
    }

    return ScreenResult::CONTINUE;
}
