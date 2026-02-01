-- Label: Simple text label component

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local Label = {}
Label.__index = Label

function Label:new(opts)
    opts = opts or {}
    local o = {
        text = opts.text or "",
        color = opts.color,  -- nil = use theme
        align = opts.align or "left",  -- "left", "center", "right"
    }
    setmetatable(o, Label)
    return o
end

function Label:get_size(display)
    local fh = display.get_font_height()
    local w = display.text_width(self.text)
    return w, fh
end

function Label:render(display, x, y, focused)
    local colors = get_colors(display)
    local color = self.color or (focused and colors.ACCENT or colors.TEXT_SECONDARY)
    display.draw_text(x, y, self.text, color)
end

function Label:set_text(text)
    self.text = text or ""
end

return Label
