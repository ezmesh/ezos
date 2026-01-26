-- Color Test Screen for T-Deck OS
-- Display available colors

local ColorTest = {
    title = "Color Test"
}

function ColorTest:new()
    local o = {
        title = self.title
    }
    setmetatable(o, {__index = ColorTest})
    return o
end

function ColorTest:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    local y = 2 * fh
    local x = 2 * fw

    local color_list = {
        {"GREEN", colors.GREEN},
        {"CYAN", colors.CYAN},
        {"RED", colors.RED},
        {"YELLOW", colors.YELLOW},
        {"ORANGE", colors.ORANGE},
        {"BLUE", colors.BLUE},
        {"WHITE", colors.WHITE},
        {"GRAY", colors.GRAY},
        {"TEXT", colors.TEXT},
        {"TEXT_DIM", colors.TEXT_DIM},
    }

    for _, c in ipairs(color_list) do
        -- Color swatch
        display.fill_rect(x, y, 3 * fw, fh, c[2])

        -- Color name
        display.draw_text(x + 4 * fw, y, c[1], c[2])

        y = y + fh
    end
end

function ColorTest:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end
    return "continue"
end

return ColorTest
