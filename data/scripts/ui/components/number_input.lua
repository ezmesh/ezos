-- NumberInput: Numeric input with +/- controls

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local NumberInput = {}
NumberInput.__index = NumberInput

function NumberInput:new(opts)
    opts = opts or {}
    local o = {
        value = opts.value or 0,
        min = opts.min or 0,
        max = opts.max or 100,
        step = opts.step or 1,
        width = opts.width or 80,
        suffix = opts.suffix or "",
        on_change = opts.on_change,
    }
    setmetatable(o, NumberInput)
    return o
end

function NumberInput:get_size(display)
    local fh = display.get_font_height()
    return self.width, fh + 4
end

function NumberInput:render(display, x, y, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()

    -- Background
    local bg_color = focused and colors.SURFACE_ALT or colors.SURFACE
    display.fill_rect(x, y, self.width, fh + 4, bg_color)

    if focused then
        display.draw_rect(x, y, self.width, fh + 4, colors.ACCENT)
    end

    -- Value with arrows when focused
    local value_str = tostring(self.value) .. self.suffix
    if focused then
        value_str = "< " .. value_str .. " >"
    end

    -- Center the value (allow overflow if needed)
    local text_w = display.text_width(value_str)
    local text_x = x + math.floor((self.width - text_w) / 2)
    local text_color = focused and colors.ACCENT or colors.TEXT
    display.draw_text(text_x, y + 2, value_str, text_color)

    return self.width, fh + 4
end

function NumberInput:handle_key(key)
    if key.special == "LEFT" then
        if self.value > self.min then
            self.value = math.max(self.min, self.value - self.step)
            if self.on_change then self.on_change(self.value) end
            return "changed"
        end
    elseif key.special == "RIGHT" then
        if self.value < self.max then
            self.value = math.min(self.max, self.value + self.step)
            if self.on_change then self.on_change(self.value) end
            return "changed"
        end
    end
    return nil
end

function NumberInput:set_value(value)
    self.value = math.max(self.min, math.min(self.max, value))
end

function NumberInput:get_value()
    return self.value
end

return NumberInput
