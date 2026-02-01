-- RadioGroup: Group of radio buttons

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local RadioGroup = {}
RadioGroup.__index = RadioGroup

function RadioGroup:new(opts)
    opts = opts or {}
    local o = {
        options = opts.options or {},
        selected = opts.selected or 1,
        horizontal = opts.horizontal or false,
        on_change = opts.on_change,
    }
    setmetatable(o, RadioGroup)
    return o
end

function RadioGroup:render(display, x, y, focused, focus_index)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local fw = display.get_font_width()
    local circle_size = fh - 2

    local cx, cy = x, y
    local total_w, total_h = 0, 0

    for i, option in ipairs(self.options) do
        local is_focused = focused and (focus_index == i or (focus_index == nil and i == self.selected))

        -- Radio circle
        local circle_color = is_focused and colors.ACCENT or colors.TEXT_SECONDARY
        display.draw_rect(cx, cy + 1, circle_size, circle_size, circle_color)

        -- Fill if selected
        if i == self.selected then
            local inner = circle_size - 4
            display.fill_rect(cx + 2, cy + 3, inner, inner, colors.ACCENT)
        end

        -- Label
        local label_color = is_focused and colors.ACCENT or colors.TEXT
        display.draw_text(cx + circle_size + 4, cy, option, label_color)

        local item_w = circle_size + 4 + #option * fw + 8

        if self.horizontal then
            cx = cx + item_w
            total_w = total_w + item_w
            total_h = fh
        else
            cy = cy + fh + 2
            total_w = math.max(total_w, item_w)
            total_h = total_h + fh + 2
        end
    end

    return total_w, total_h
end

function RadioGroup:handle_key(key)
    if key.special == "UP" or key.special == "LEFT" then
        if self.selected > 1 then
            self.selected = self.selected - 1
            if self.on_change then
                self.on_change(self.selected, self.options[self.selected])
            end
            return "changed"
        end
    elseif key.special == "DOWN" or key.special == "RIGHT" then
        if self.selected < #self.options then
            self.selected = self.selected + 1
            if self.on_change then
                self.on_change(self.selected, self.options[self.selected])
            end
            return "changed"
        end
    elseif key.special == "ENTER" then
        return "selected"
    end
    return nil
end

function RadioGroup:set_selected(index)
    self.selected = math.max(1, math.min(index, #self.options))
end

function RadioGroup:get_selected()
    return self.selected, self.options[self.selected]
end

return RadioGroup
