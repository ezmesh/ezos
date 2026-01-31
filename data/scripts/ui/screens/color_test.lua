-- Color Test Screen for T-Deck OS
-- Display available colors

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

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
    local colors = ListMixin.get_colors(display)

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    local y = 2 * fh
    local x = 2 * fw

    local color_list = {
        {"SUCCESS", colors.SUCCESS},
        {"ACCENT", colors.ACCENT},
        {"ERROR", colors.ERROR},
        {"WARNING", colors.WARNING},
        {"INFO", colors.INFO},
        {"BLUE", colors.BLUE},
        {"WHITE", colors.WHITE},
        {"GRAY", colors.GRAY},
        {"TEXT", colors.TEXT},
        {"TEXT_SECONDARY", colors.TEXT_SECONDARY},
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
