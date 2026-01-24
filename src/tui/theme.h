#pragma once

#include <cstdint>
#include "../hardware/display.h"

// TUI Theme configuration for terminal-style interface
// Provides consistent styling across all screens

namespace Theme {
    // Screen layout constants (in character cells)
    constexpr int SCREEN_COLS = TUI_COLS;       // 40 columns
    constexpr int SCREEN_ROWS = TUI_ROWS;       // 15 rows

    // Status bar location (bottom row)
    constexpr int STATUS_BAR_ROW = SCREEN_ROWS - 1;

    // Content area (excluding borders and status bar)
    constexpr int CONTENT_START_ROW = 1;
    constexpr int CONTENT_END_ROW = SCREEN_ROWS - 2;
    constexpr int CONTENT_START_COL = 1;
    constexpr int CONTENT_END_COL = SCREEN_COLS - 2;

    // Color palette for the TUI
    namespace Color {
        // Base colors
        constexpr uint16_t BACKGROUND     = Colors::BLACK;
        constexpr uint16_t FOREGROUND     = Colors::GREEN;

        // Text colors
        constexpr uint16_t TEXT_PRIMARY   = Colors::GREEN;
        constexpr uint16_t TEXT_SECONDARY = Colors::DARK_GREEN;
        constexpr uint16_t TEXT_HIGHLIGHT = Colors::CYAN;
        constexpr uint16_t TEXT_ERROR     = Colors::RED;
        constexpr uint16_t TEXT_WARNING   = Colors::YELLOW;
        constexpr uint16_t TEXT_SUCCESS   = Colors::GREEN;

        // UI element colors
        constexpr uint16_t BORDER         = Colors::DARK_GREEN;
        constexpr uint16_t BORDER_ACTIVE  = Colors::GREEN;
        constexpr uint16_t TITLE          = Colors::CYAN;

        // Selection/highlighting
        constexpr uint16_t SELECTION_BG   = Colors::SELECTION;
        constexpr uint16_t SELECTION_FG   = Colors::CYAN;
        constexpr uint16_t CURSOR         = Colors::GREEN;
        constexpr uint16_t HIGHLIGHT      = Colors::CYAN;  // Alias for TEXT_HIGHLIGHT

        // Status indicators
        constexpr uint16_t STATUS_OK      = Colors::GREEN;
        constexpr uint16_t STATUS_WARN    = Colors::YELLOW;
        constexpr uint16_t STATUS_ERROR   = Colors::RED;
        constexpr uint16_t STATUS_INFO    = Colors::CYAN;
        constexpr uint16_t WARNING        = Colors::YELLOW;  // Alias for STATUS_WARN

        // Message indicators
        constexpr uint16_t UNREAD         = Colors::CYAN;
        constexpr uint16_t READ           = Colors::DARK_GREEN;
        constexpr uint16_t SENT           = Colors::GREEN;
        constexpr uint16_t FAILED         = Colors::RED;
    }

    // Unicode/ASCII art characters for TUI elements
    // Using simple ASCII for maximum compatibility
    namespace Chars {
        constexpr char CURSOR_CHAR      = '>';
        constexpr char BULLET           = '*';
        constexpr char ARROW_RIGHT      = '>';
        constexpr char ARROW_LEFT       = '<';
        constexpr char ARROW_UP         = '^';
        constexpr char ARROW_DOWN       = 'v';
        constexpr char CHECK            = '+';
        constexpr char CROSS            = 'x';
        constexpr char ELLIPSIS         = '.';

        // Battery indicator characters
        constexpr char BATTERY_FULL     = '#';
        constexpr char BATTERY_EMPTY    = '-';

        // Signal strength characters
        constexpr char SIGNAL_BAR       = '|';
    }

    // Animation timing (milliseconds)
    namespace Timing {
        constexpr uint32_t CURSOR_BLINK_MS   = 500;
        constexpr uint32_t STATUS_UPDATE_MS  = 1000;
        constexpr uint32_t SCROLL_DELAY_MS   = 100;
        constexpr uint32_t KEY_REPEAT_MS     = 150;
        constexpr uint32_t KEY_INITIAL_MS    = 400;
    }

    // Menu item formatting
    namespace Format {
        constexpr int MENU_INDENT        = 3;    // Characters from left
        constexpr int MENU_ITEM_SPACING  = 1;    // Lines between items
        constexpr int MAX_TITLE_LEN      = 30;   // Max title length
        constexpr int MAX_PREVIEW_LEN    = 35;   // Max message preview
    }
}
