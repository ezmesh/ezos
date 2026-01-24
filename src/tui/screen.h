#pragma once

#include "../hardware/display.h"
#include "../hardware/keyboard.h"
#include "theme.h"

// Forward declaration
class TUI;

// Screen navigation result
enum class ScreenResult {
    CONTINUE,       // Keep current screen active
    POP,            // Go back to previous screen
    PUSH,           // A new screen was pushed (handled by TUI)
    REPLACE,        // Current screen was replaced
    EXIT            // Exit application
};

// Base class for all TUI screens
// Each screen manages its own rendering and input handling
class Screen {
public:
    virtual ~Screen() = default;

    // Called when screen becomes active (pushed or returned to)
    virtual void onEnter() {}

    // Called when screen is about to become inactive (popped or covered)
    virtual void onExit() {}

    // Called when screen needs to refresh its data
    virtual void onRefresh() {}

    // Render the screen contents
    // Should use the display reference to draw
    virtual void render(Display& display) = 0;

    // Handle keyboard input
    // Returns ScreenResult to indicate navigation action
    virtual ScreenResult handleKey(KeyEvent key) = 0;

    // Get screen title (displayed in header)
    virtual const char* getTitle() = 0;

    // Check if screen needs redraw
    bool needsRedraw() const { return _needsRedraw; }

    // Mark screen for redraw
    void invalidate() { _needsRedraw = true; }

    // Clear redraw flag (called after rendering)
    void clearRedrawFlag() { _needsRedraw = false; }

    // Set reference to parent TUI (called by TUI when pushing)
    void setTUI(TUI* tui) { _tui = tui; }

protected:
    TUI* _tui = nullptr;
    bool _needsRedraw = true;

    // Convenience method to push a new screen (implemented in tui.cpp)
    void pushScreen(Screen* screen);

    // Convenience method to replace current screen
    void replaceScreen(Screen* screen);
};

// Simple modal dialog screen
class DialogScreen : public Screen {
public:
    DialogScreen(const char* title, const char* message,
                 const char* okText = "OK", const char* cancelText = nullptr);

    void render(Display& display) override;
    ScreenResult handleKey(KeyEvent key) override;
    const char* getTitle() override { return _title; }

    // Check result after dialog closes
    bool wasConfirmed() const { return _confirmed; }

protected:
    const char* _title;
    const char* _message;
    const char* _okText;
    const char* _cancelText;
    bool _showCancel;
    int _selection = 0;  // 0 = OK, 1 = Cancel
    bool _confirmed = false;
};

// Text input dialog
class InputScreen : public Screen {
public:
    InputScreen(const char* title, const char* prompt,
                char* buffer, size_t bufferSize,
                const char* initialValue = nullptr);

    void render(Display& display) override;
    ScreenResult handleKey(KeyEvent key) override;
    const char* getTitle() override { return _title; }

    // Check if input was submitted (not cancelled)
    bool wasSubmitted() const { return _submitted; }

    // Get the entered text
    const char* getText() const { return _buffer; }

protected:
    const char* _title;
    const char* _prompt;
    char* _buffer;
    size_t _bufferSize;
    size_t _cursorPos = 0;
    bool _submitted = false;
    uint32_t _lastBlink = 0;
    bool _cursorVisible = true;
};
