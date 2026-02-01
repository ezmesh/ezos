-- font_test.lua - Test screen for font display
-- Shows available fonts and sizes, including TTF fonts

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local FontTest = {
    title = "Fonts Test",
}

local SAMPLE_TEXT = "The quick brown fox jumps!"
local SAMPLE_CHARS = "ABCabc123@#$"

function FontTest:new()
    local o = {
        title = "Fonts Test",
        scroll_y = 0,
    }
    setmetatable(o, {__index = FontTest})
    return o
end

function FontTest:on_enter()
    self.scroll_y = 0
end

function FontTest:render(display)
    local colors = ListMixin.get_colors(display)

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    local y = 30 - self.scroll_y
    local x = 8

    -- Small font section
    display.set_font_size("small")
    local small_fw = display.get_font_width()
    local small_fh = display.get_font_height()

    if y > 10 and y < display.height then
        display.draw_text(x, y, "SMALL FONT:", colors.ACCENT)
    end
    y = y + small_fh + 4

    if y > 10 and y < display.height then
        display.draw_text(x, y, SAMPLE_TEXT, colors.WHITE)
    end
    y = y + small_fh + 2

    if y > 10 and y < display.height then
        display.draw_text(x, y, SAMPLE_CHARS, colors.WHITE)
    end
    y = y + small_fh + 2

    if y > 10 and y < display.height then
        local info = string.format("Size: %dx%d px", small_fw, small_fh)
        display.draw_text(x, y, info, colors.TEXT_SECONDARY)
    end
    y = y + small_fh + 12

    -- Medium font section
    display.set_font_size("medium")
    local med_fw = display.get_font_width()
    local med_fh = display.get_font_height()

    if y > 10 and y < display.height then
        display.draw_text(x, y, "MEDIUM FONT:", colors.ACCENT)
    end
    y = y + med_fh + 4

    if y > 10 and y < display.height then
        display.draw_text(x, y, SAMPLE_TEXT, colors.WHITE)
    end
    y = y + med_fh + 2

    if y > 10 and y < display.height then
        display.draw_text(x, y, SAMPLE_CHARS, colors.WHITE)
    end
    y = y + med_fh + 2

    if y > 10 and y < display.height then
        local info = string.format("Size: %dx%d px", med_fw, med_fh)
        display.draw_text(x, y, info, colors.TEXT_SECONDARY)
    end
    y = y + med_fh + 12

    -- Large font section
    display.set_font_size("large")
    local large_fw = display.get_font_width()
    local large_fh = display.get_font_height()

    if y > 10 and y < display.height then
        display.draw_text(x, y, "LARGE FONT:", colors.ACCENT)
    end
    y = y + large_fh + 4

    if y > 10 and y < display.height then
        display.draw_text(x, y, "Quick brown fox", colors.WHITE)
    end
    y = y + large_fh + 2

    if y > 10 and y < display.height then
        display.draw_text(x, y, SAMPLE_CHARS, colors.WHITE)
    end
    y = y + large_fh + 2

    if y > 10 and y < display.height then
        local info = string.format("Size: %dx%d px", large_fw, large_fh)
        display.draw_text(x, y, info, colors.TEXT_SECONDARY)
    end
    y = y + large_fh + 12

    -- Reset to medium
    display.set_font_size("medium")

    -- Show scroll hint at bottom
    display.set_font_size("small")
    display.draw_text(5, display.height - 12, "[Up/Down] Scroll  [Q] Quit", colors.TEXT_MUTED)
end

function FontTest:handle_key(key)
    if key.character == "q" or key.special == "ESCAPE" then
        return "pop"
    elseif key.special == "UP" then
        self.scroll_y = math.max(0, self.scroll_y - 20)
        ScreenManager.invalidate()
    elseif key.special == "DOWN" then
        self.scroll_y = math.min(150, self.scroll_y + 20)
        ScreenManager.invalidate()
    end

    return "continue"
end

return FontTest
