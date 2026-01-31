-- Theme Configuration for T-Deck OS
-- Matches the C++ theme constants in src/tui/theme.h

local Theme = {}

-- Screen layout (in character cells, assuming default font)
Theme.SCREEN_COLS = 40
Theme.SCREEN_ROWS = 15
Theme.STATUS_BAR_ROW = 14

-- Content area (excluding borders and status bar)
Theme.CONTENT_START_ROW = 1
Theme.CONTENT_END_ROW = 13
Theme.CONTENT_START_COL = 1
Theme.CONTENT_END_COL = 38

-- Menu formatting
Theme.MENU_INDENT = 3
Theme.MENU_ITEM_SPACING = 1
Theme.MAX_TITLE_LEN = 30
Theme.MAX_PREVIEW_LEN = 35

-- Animation timing (milliseconds)
Theme.CURSOR_BLINK_MS = 500
Theme.STATUS_UPDATE_MS = 1000
Theme.SCROLL_DELAY_MS = 100
Theme.KEY_REPEAT_MS = 150
Theme.KEY_INITIAL_MS = 400

-- UI characters
Theme.CURSOR_CHAR = ">"
Theme.BULLET = "*"
Theme.ARROW_RIGHT = ">"
Theme.ARROW_LEFT = "<"
Theme.ARROW_UP = "^"
Theme.ARROW_DOWN = "v"
Theme.CHECK = "+"
Theme.CROSS = "x"
Theme.ELLIPSIS = "..."

-- Get colors from display module (must be called after display is initialized)
function Theme.get_colors()
    if not tdeck or not ez.display then
        return nil
    end
    return ez.display.colors
end

-- Helper to get visible content height in rows
function Theme.get_content_rows()
    return Theme.CONTENT_END_ROW - Theme.CONTENT_START_ROW
end

-- Helper to get visible content width in columns
function Theme.get_content_cols()
    return Theme.CONTENT_END_COL - Theme.CONTENT_START_COL
end

return Theme
