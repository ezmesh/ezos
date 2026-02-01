-- Dropdown: Expandable select menu

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local Dropdown = {}
Dropdown.__index = Dropdown

function Dropdown:new(opts)
    opts = opts or {}
    local o = {
        options = opts.options or {},
        selected = opts.selected or 1,
        width = opts.width or 100,
        expanded = false,
        scroll_offset = 0,
        max_visible = opts.max_visible or 5,
        on_change = opts.on_change,
    }
    setmetatable(o, Dropdown)
    return o
end

function Dropdown:render(display, x, y, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local fw = display.get_font_width()

    -- Main button area
    local bg_color = focused and colors.SURFACE_ALT or colors.SURFACE
    display.fill_rect(x, y, self.width, fh + 4, bg_color)

    if focused then
        display.draw_rect(x, y, self.width, fh + 4, colors.ACCENT)
    end

    -- Current selection
    local current = self.options[self.selected] or ""
    local max_chars = math.floor((self.width - 16) / fw)
    if #current > max_chars then
        current = string.sub(current, 1, max_chars - 2) .. ".."
    end
    display.draw_text(x + 4, y + 2, current, focused and colors.ACCENT or colors.TEXT)

    -- Dropdown arrow
    local arrow = self.expanded and "^" or "v"
    display.draw_text(x + self.width - 10, y + 2, arrow, colors.TEXT_SECONDARY)

    local height = fh + 4

    -- Expanded dropdown list
    if self.expanded then
        local list_y = y + fh + 4
        local visible = math.min(#self.options, self.max_visible)
        local list_height = visible * (fh + 2)

        -- Background
        display.fill_rect(x, list_y, self.width, list_height, colors.BLACK)
        display.draw_rect(x, list_y, self.width, list_height, colors.ACCENT)

        -- Options
        for i = 1, visible do
            local opt_idx = self.scroll_offset + i
            if opt_idx > #self.options then break end

            local opt_y = list_y + (i - 1) * (fh + 2)
            local is_selected = (opt_idx == self.selected)

            if is_selected then
                display.fill_rect(x + 1, opt_y, self.width - 2, fh + 2, colors.SURFACE_ALT)
            end

            local opt_text = self.options[opt_idx]
            if #opt_text > max_chars then
                opt_text = string.sub(opt_text, 1, max_chars - 2) .. ".."
            end
            display.draw_text(x + 4, opt_y + 1, opt_text, is_selected and colors.ACCENT or colors.TEXT)
        end

        -- Scroll indicators
        if self.scroll_offset > 0 then
            display.draw_text(x + self.width - 10, list_y + 1, "^", colors.TEXT_SECONDARY)
        end
        if self.scroll_offset + visible < #self.options then
            display.draw_text(x + self.width - 10, list_y + list_height - fh - 1, "v", colors.TEXT_SECONDARY)
        end

        height = height + list_height
    end

    return self.width, height
end

function Dropdown:handle_key(key)
    if self.expanded then
        if key.special == "UP" then
            if self.selected > 1 then
                self.selected = self.selected - 1
                if self.selected <= self.scroll_offset then
                    self.scroll_offset = self.selected - 1
                end
                return "changed"
            end
        elseif key.special == "DOWN" then
            if self.selected < #self.options then
                self.selected = self.selected + 1
                if self.selected > self.scroll_offset + self.max_visible then
                    self.scroll_offset = self.selected - self.max_visible
                end
                return "changed"
            end
        elseif key.special == "ENTER" then
            self.expanded = false
            if self.on_change then
                self.on_change(self.selected, self.options[self.selected])
            end
            return "selected"
        elseif key.special == "ESCAPE" then
            self.expanded = false
            return "collapsed"
        end
    else
        if key.special == "ENTER" then
            self.expanded = true
            if self.selected > self.max_visible then
                self.scroll_offset = self.selected - self.max_visible
            else
                self.scroll_offset = 0
            end
            return "expanded"
        elseif key.special == "LEFT" then
            if self.selected > 1 then
                self.selected = self.selected - 1
                if self.on_change then
                    self.on_change(self.selected, self.options[self.selected])
                end
                return "changed"
            end
        elseif key.special == "RIGHT" then
            if self.selected < #self.options then
                self.selected = self.selected + 1
                if self.on_change then
                    self.on_change(self.selected, self.options[self.selected])
                end
                return "changed"
            end
        end
    end
    return nil
end

function Dropdown:is_expanded()
    return self.expanded
end

function Dropdown:collapse()
    self.expanded = false
end

function Dropdown:set_selected(index)
    self.selected = math.max(1, math.min(index, #self.options))
end

function Dropdown:get_selected()
    return self.selected, self.options[self.selected]
end

return Dropdown
