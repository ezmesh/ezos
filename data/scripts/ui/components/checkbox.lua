-- Checkbox: Toggle checkbox with label

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local Checkbox = {}
Checkbox.__index = Checkbox

function Checkbox:new(opts)
    opts = opts or {}
    local o = {
        checked = opts.checked or false,
        label = opts.label or "",
        on_change = opts.on_change,
    }
    setmetatable(o, Checkbox)
    return o
end

function Checkbox:get_size(display)
    local fh = display.get_font_height()
    local box_size = fh - 2
    local label_width = #self.label > 0 and (4 + display.text_width(self.label)) or 0
    return box_size + label_width, fh
end

function Checkbox:render(display, x, y, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local box_size = fh - 2

    -- Checkbox box
    local box_color = focused and colors.ACCENT or colors.TEXT_SECONDARY
    display.draw_rect(x, y + 1, box_size, box_size, box_color)

    -- Check mark
    if self.checked then
        local inner = box_size - 4
        display.fill_rect(x + 2, y + 3, inner, inner, colors.ACCENT)
    end

    -- Label
    local label_width = 0
    if #self.label > 0 then
        local label_color = focused and colors.ACCENT or colors.TEXT
        display.draw_text(x + box_size + 4, y, self.label, label_color)
        label_width = 4 + display.text_width(self.label)
    end

    return box_size + label_width, fh
end

function Checkbox:handle_key(key)
    if key.special == "ENTER" or key.character == " " then
        self:toggle()
        return "changed"
    end
    return nil
end

function Checkbox:toggle()
    self.checked = not self.checked
    if self.on_change then
        self.on_change(self.checked)
    end
end

function Checkbox:set_checked(checked)
    self.checked = checked
end

function Checkbox:is_checked()
    return self.checked
end

return Checkbox
