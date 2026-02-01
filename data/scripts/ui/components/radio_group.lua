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

-- Get size for layout measurement
function RadioGroup:get_size(display)
    local fh = display.get_font_height()
    local radius = math.floor((fh - 2) / 2)
    local diameter = radius * 2

    local total_w, total_h = 0, 0

    for i, option in ipairs(self.options) do
        local label_width = display.text_width(option)
        local item_w = diameter + 4 + label_width + 8

        if self.horizontal then
            total_w = total_w + item_w
            total_h = fh
        else
            total_w = math.max(total_w, item_w)
            total_h = total_h + fh + 2
        end
    end

    return total_w, total_h
end

function RadioGroup:render(display, x, y, focused, focus_index)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local radius = math.floor((fh - 2) / 2)
    local diameter = radius * 2

    local cx, cy = x, y
    local total_w, total_h = 0, 0

    for i, option in ipairs(self.options) do
        local is_focused = focused and (focus_index == i or (focus_index == nil and i == self.selected))

        -- Radio circle (outline)
        local circle_color = is_focused and colors.ACCENT or colors.TEXT_SECONDARY
        local center_x = cx + radius
        local center_y = cy + radius + 1
        display.draw_circle(center_x, center_y, radius, circle_color)

        -- Fill center if selected
        if i == self.selected then
            local inner_radius = math.max(2, radius - 3)
            display.fill_circle(center_x, center_y, inner_radius, colors.ACCENT)
        end

        -- Label
        local label_color = is_focused and colors.ACCENT or colors.TEXT
        display.draw_text(cx + diameter + 4, cy, option, label_color)

        local label_width = display.text_width(option)
        local item_w = diameter + 4 + label_width + 8

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
