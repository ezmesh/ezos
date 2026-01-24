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
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    local y = 2 * display.font_height
    local x = 2 * display.font_width

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
        display.fill_rect(x, y, 3 * display.font_width, display.font_height, c[2])

        -- Color name
        display.draw_text(x + 4 * display.font_width, y, c[1], c[2])

        y = y + display.font_height
    end

    -- Help text
    display.draw_text(x, (display.rows - 2) * display.font_height,
                    "ESC: Back", colors.TEXT_DIM)
end

function ColorTest:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end
    return "continue"
end

return ColorTest
