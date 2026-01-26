-- title_bar.lua - Centralized title bar drawing utility
-- All screens should use this for consistent title bar rendering

local TitleBar = {
    -- Constants
    TITLE_Y = 3,        -- Y position of title text
    BAR_PADDING = 6,    -- Extra height below font
    UNDERLINE_GAP = 5,  -- Gap before underline
}

-- Draw standard title bar with white text and green underline
-- @param display Display object
-- @param title Title text to display
-- @param color Optional title color (default: WHITE)
-- @param underline_color Optional underline color (default: GREEN)
-- @return height The height of the title bar area (for content positioning)
function TitleBar.draw(display, title, color, underline_color)
    -- Use themed colors if available
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    color = color or colors.WHITE
    underline_color = underline_color or colors.GREEN

    -- Use small font for title
    display.set_font_size("small")
    local fh = display.get_font_height()

    -- Black background for title area
    display.fill_rect(0, 0, display.width, fh + TitleBar.BAR_PADDING, colors.BLACK)

    -- Draw centered title
    display.draw_text_centered(TitleBar.TITLE_Y, title, color)

    -- Draw underline
    display.fill_rect(0, fh + TitleBar.UNDERLINE_GAP, display.width, 1, underline_color)

    return fh + TitleBar.BAR_PADDING + 1
end

-- Draw error-style title bar (red text and underline)
-- @param display Display object
-- @param title Title text to display
-- @return height The height of the title bar area
function TitleBar.draw_error(display, title)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    return TitleBar.draw(display, title, colors.RED, colors.RED)
end

-- Get the content start Y position (after title bar)
-- Useful for screens that need to know where content starts
function TitleBar.get_content_y()
    return 28  -- Standard content start position
end

return TitleBar
