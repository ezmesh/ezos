-- Toggle: On/Off switch

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local Toggle = {}
Toggle.__index = Toggle

function Toggle:new(opts)
    opts = opts or {}
    local o = {
        value = opts.value or false,
        label = opts.label or "",
        on_change = opts.on_change,
    }
    setmetatable(o, Toggle)
    return o
end

function Toggle:get_size(display)
    local fh = display.get_font_height()
    local switch_w = 32
    local label_width = #self.label > 0 and (8 + display.text_width(self.label)) or 0
    return switch_w + label_width, fh
end

function Toggle:render(display, x, y, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()

    local switch_w = 32
    local switch_h = fh

    -- Switch background
    local bg_color = self.value and colors.SUCCESS or colors.SURFACE
    display.fill_rect(x, y, switch_w, switch_h, bg_color)

    -- Border when focused
    if focused then
        display.draw_rect(x, y, switch_w, switch_h, colors.ACCENT)
    end

    -- Switch knob
    local knob_x = self.value and (x + switch_w - switch_h + 2) or (x + 2)
    display.fill_rect(knob_x, y + 2, switch_h - 4, switch_h - 4, colors.WHITE)

    -- Label
    local label_width = 0
    if #self.label > 0 then
        local label_color = focused and colors.ACCENT or colors.TEXT
        display.draw_text(x + switch_w + 8, y, self.label, label_color)
        label_width = 8 + display.text_width(self.label)
    end

    return switch_w + label_width, switch_h
end

function Toggle:handle_key(key)
    if key.special == "ENTER" or key.character == " " or
       key.special == "LEFT" or key.special == "RIGHT" then
        self.value = not self.value
        if self.on_change then self.on_change(self.value) end
        return "changed"
    end
    return nil
end

function Toggle:set_value(value)
    self.value = value
end

function Toggle:get_value()
    return self.value
end

return Toggle
