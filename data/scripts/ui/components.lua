-- UI Components Library for T-Deck OS
-- Reusable input elements: TextInput, Button, Checkbox, RadioGroup, Dropdown, TextArea, VerticalList

local Components = {}

-- Helper to get theme colors
local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

--------------------------------------------------------------------------------
-- TextInput: Single-line text input field
--------------------------------------------------------------------------------
Components.TextInput = {}
Components.TextInput.__index = Components.TextInput

function Components.TextInput:new(opts)
    opts = opts or {}
    local o = {
        value = opts.value or "",
        placeholder = opts.placeholder or "",
        max_length = opts.max_length or 64,
        password_mode = opts.password_mode or false,
        width = opts.width or 120,  -- in pixels
        cursor_pos = opts.value and #opts.value or 0,
        cursor_visible = true,
        cursor_blink_time = 0,
        on_change = opts.on_change,  -- callback(new_value)
        on_submit = opts.on_submit,  -- callback(value)
    }
    setmetatable(o, Components.TextInput)
    return o
end

function Components.TextInput:render(display, x, y, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local fw = display.get_font_width()

    -- Background
    local bg_color = focused and colors.SURFACE_ALT or colors.SURFACE
    display.fill_rect(x, y, self.width, fh + 4, bg_color)

    -- Border when focused
    if focused then
        display.draw_rect(x, y, self.width, fh + 4, colors.ACCENT)
    end

    -- Text content
    local display_text = self.value
    if self.password_mode then
        display_text = string.rep("*", #self.value)
    end

    -- Calculate visible portion of text
    local max_chars = math.floor((self.width - 4) / fw)
    local text_offset = 0  -- How many chars were cut from the beginning

    -- Show placeholder if empty
    if #self.value == 0 and not focused then
        display.draw_text(x + 2, y + 2, self.placeholder, colors.TEXT_SECONDARY)
    else
        -- Truncate text to fit width (show last max_chars characters)
        if #display_text > max_chars then
            text_offset = #display_text - max_chars
            display_text = string.sub(display_text, -max_chars)
        end
        display.draw_text(x + 2, y + 2, display_text, colors.TEXT)
    end

    -- Cursor
    if focused then
        local now = tdeck.system.millis()
        if now - self.cursor_blink_time > 500 then
            self.cursor_visible = not self.cursor_visible
            self.cursor_blink_time = now
        end

        if self.cursor_visible then
            -- Calculate cursor position relative to visible text
            local visible_cursor_pos = self.cursor_pos - text_offset
            -- Clamp to visible range
            visible_cursor_pos = math.max(0, math.min(visible_cursor_pos, #display_text))
            local cursor_x = x + 2 + visible_cursor_pos * fw
            display.draw_text(cursor_x, y + 2, "_", colors.ACCENT)
        end
    end
end

function Components.TextInput:handle_key(key)
    local changed = false

    if key.special == "BACKSPACE" then
        if #self.value > 0 and self.cursor_pos > 0 then
            self.value = string.sub(self.value, 1, self.cursor_pos - 1) ..
                        string.sub(self.value, self.cursor_pos + 1)
            self.cursor_pos = self.cursor_pos - 1
            changed = true
        end
    elseif key.special == "LEFT" then
        if self.cursor_pos > 0 then
            self.cursor_pos = self.cursor_pos - 1
        end
    elseif key.special == "RIGHT" then
        if self.cursor_pos < #self.value then
            self.cursor_pos = self.cursor_pos + 1
        end
    elseif key.special == "ENTER" then
        if self.on_submit then
            self.on_submit(self.value)
        end
        return "submit"
    elseif key.character and #self.value < self.max_length then
        self.value = string.sub(self.value, 1, self.cursor_pos) ..
                    key.character ..
                    string.sub(self.value, self.cursor_pos + 1)
        self.cursor_pos = self.cursor_pos + 1
        changed = true
    end

    if changed and self.on_change then
        self.on_change(self.value)
    end

    return changed and "changed" or nil
end

function Components.TextInput:set_value(value)
    self.value = value or ""
    self.cursor_pos = #self.value
end

function Components.TextInput:get_value()
    return self.value
end

--------------------------------------------------------------------------------
-- Button: Clickable button
--------------------------------------------------------------------------------
Components.Button = {}
Components.Button.__index = Components.Button

function Components.Button:new(opts)
    opts = opts or {}
    local o = {
        label = opts.label or "Button",
        width = opts.width,  -- nil = auto-size
        disabled = opts.disabled or false,
        on_press = opts.on_press,  -- callback()
    }
    setmetatable(o, Components.Button)
    return o
end

function Components.Button:render(display, x, y, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local fw = display.get_font_width()

    local width = self.width or (#self.label * fw + 12)
    local height = fh + 6

    -- Background
    local bg_color
    if self.disabled then
        bg_color = colors.SURFACE
    elseif focused then
        bg_color = colors.SURFACE_ALT
    else
        bg_color = colors.SURFACE
    end
    display.fill_rect(x, y, width, height, bg_color)

    -- Border
    local border_color = focused and colors.ACCENT or colors.TEXT_SECONDARY
    if self.disabled then
        border_color = colors.SURFACE
    end
    display.draw_rect(x, y, width, height, border_color)

    -- Label centered
    local text_color = self.disabled and colors.TEXT_SECONDARY or (focused and colors.ACCENT or colors.TEXT)
    local text_x = x + math.floor((width - #self.label * fw) / 2)
    local text_y = y + 3
    display.draw_text(text_x, text_y, self.label, text_color)

    return width, height
end

function Components.Button:handle_key(key)
    if self.disabled then return nil end

    if key.special == "ENTER" then
        if self.on_press then
            self.on_press()
        end
        return "pressed"
    end
    return nil
end

--------------------------------------------------------------------------------
-- Checkbox: Toggle checkbox with label
--------------------------------------------------------------------------------
Components.Checkbox = {}
Components.Checkbox.__index = Components.Checkbox

function Components.Checkbox:new(opts)
    opts = opts or {}
    local o = {
        checked = opts.checked or false,
        label = opts.label or "",
        on_change = opts.on_change,  -- callback(checked)
    }
    setmetatable(o, Components.Checkbox)
    return o
end

function Components.Checkbox:render(display, x, y, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local fw = display.get_font_width()
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
    if #self.label > 0 then
        local label_color = focused and colors.ACCENT or colors.TEXT
        display.draw_text(x + box_size + 4, y, self.label, label_color)
    end

    return box_size + (#self.label > 0 and (4 + #self.label * fw) or 0), fh
end

function Components.Checkbox:handle_key(key)
    if key.special == "ENTER" or key.character == " " then
        self:toggle()
        return "changed"
    end
    return nil
end

function Components.Checkbox:toggle()
    self.checked = not self.checked
    if self.on_change then
        self.on_change(self.checked)
    end
end

function Components.Checkbox:set_checked(checked)
    self.checked = checked
end

function Components.Checkbox:is_checked()
    return self.checked
end

--------------------------------------------------------------------------------
-- RadioGroup: Group of radio buttons
--------------------------------------------------------------------------------
Components.RadioGroup = {}
Components.RadioGroup.__index = Components.RadioGroup

function Components.RadioGroup:new(opts)
    opts = opts or {}
    local o = {
        options = opts.options or {},  -- array of strings
        selected = opts.selected or 1,
        horizontal = opts.horizontal or false,
        on_change = opts.on_change,  -- callback(selected_index, selected_value)
    }
    setmetatable(o, Components.RadioGroup)
    return o
end

function Components.RadioGroup:render(display, x, y, focused, focus_index)
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

function Components.RadioGroup:handle_key(key)
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

function Components.RadioGroup:set_selected(index)
    self.selected = math.max(1, math.min(index, #self.options))
end

function Components.RadioGroup:get_selected()
    return self.selected, self.options[self.selected]
end

--------------------------------------------------------------------------------
-- Dropdown: Expandable select menu
--------------------------------------------------------------------------------
Components.Dropdown = {}
Components.Dropdown.__index = Components.Dropdown

function Components.Dropdown:new(opts)
    opts = opts or {}
    local o = {
        options = opts.options or {},
        selected = opts.selected or 1,
        width = opts.width or 100,
        expanded = false,
        scroll_offset = 0,
        max_visible = opts.max_visible or 5,
        on_change = opts.on_change,  -- callback(selected_index, selected_value)
    }
    setmetatable(o, Components.Dropdown)
    return o
end

function Components.Dropdown:render(display, x, y, focused)
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

function Components.Dropdown:handle_key(key)
    if self.expanded then
        if key.special == "UP" then
            if self.selected > 1 then
                self.selected = self.selected - 1
                -- Adjust scroll
                if self.selected <= self.scroll_offset then
                    self.scroll_offset = self.selected - 1
                end
                return "changed"
            end
        elseif key.special == "DOWN" then
            if self.selected < #self.options then
                self.selected = self.selected + 1
                -- Adjust scroll
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
            -- Ensure selected item is visible
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

function Components.Dropdown:is_expanded()
    return self.expanded
end

function Components.Dropdown:collapse()
    self.expanded = false
end

function Components.Dropdown:set_selected(index)
    self.selected = math.max(1, math.min(index, #self.options))
end

function Components.Dropdown:get_selected()
    return self.selected, self.options[self.selected]
end

--------------------------------------------------------------------------------
-- TextArea: Multi-line text input
--------------------------------------------------------------------------------
Components.TextArea = {}
Components.TextArea.__index = Components.TextArea

function Components.TextArea:new(opts)
    opts = opts or {}
    local o = {
        value = opts.value or "",
        max_length = opts.max_length or 512,
        width = opts.width or 200,
        height = opts.height or 80,
        cursor_pos = opts.value and #opts.value or 0,
        scroll_offset = 0,  -- Line scroll offset
        cursor_visible = true,
        cursor_blink_time = 0,
        on_change = opts.on_change,
    }
    setmetatable(o, Components.TextArea)
    return o
end

function Components.TextArea:render(display, x, y, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local fw = display.get_font_width()

    -- Background
    local bg_color = focused and colors.SURFACE_ALT or colors.SURFACE
    display.fill_rect(x, y, self.width, self.height, bg_color)

    -- Border
    if focused then
        display.draw_rect(x, y, self.width, self.height, colors.ACCENT)
    end

    -- Word wrap and display text
    local max_chars = math.floor((self.width - 8) / fw)
    local max_lines = math.floor((self.height - 4) / fh)
    local lines = self:wrap_text(max_chars)

    -- Calculate cursor line and column
    local cursor_line, cursor_col = self:get_cursor_line_col(lines)

    -- Adjust scroll to keep cursor visible
    if cursor_line <= self.scroll_offset then
        self.scroll_offset = cursor_line - 1
    elseif cursor_line > self.scroll_offset + max_lines then
        self.scroll_offset = cursor_line - max_lines
    end
    self.scroll_offset = math.max(0, self.scroll_offset)

    -- Draw visible lines
    for i = 1, max_lines do
        local line_idx = self.scroll_offset + i
        if line_idx > #lines then break end

        local line_y = y + 2 + (i - 1) * fh
        display.draw_text(x + 4, line_y, lines[line_idx], colors.TEXT)
    end

    -- Cursor
    if focused then
        local now = tdeck.system.millis()
        if now - self.cursor_blink_time > 500 then
            self.cursor_visible = not self.cursor_visible
            self.cursor_blink_time = now
        end

        if self.cursor_visible then
            local visible_line = cursor_line - self.scroll_offset
            if visible_line >= 1 and visible_line <= max_lines then
                local cursor_x = x + 4 + (cursor_col - 1) * fw
                local cursor_y = y + 2 + (visible_line - 1) * fh
                display.draw_text(cursor_x, cursor_y, "_", colors.ACCENT)
            end
        end
    end

    -- Scroll indicator
    if #lines > max_lines then
        if self.scroll_offset > 0 then
            display.draw_text(x + self.width - 10, y + 2, "^", colors.TEXT_SECONDARY)
        end
        if self.scroll_offset + max_lines < #lines then
            display.draw_text(x + self.width - 10, y + self.height - fh - 2, "v", colors.TEXT_SECONDARY)
        end
    end
end

function Components.TextArea:wrap_text(max_chars)
    local lines = {}
    local text = self.value

    if #text == 0 then
        return {""}
    end

    local pos = 1
    while pos <= #text do
        local newline = string.find(text, "\n", pos, true)
        local line_end = newline and (newline - 1) or #text
        local line = string.sub(text, pos, line_end)

        -- Wrap long lines
        while #line > max_chars do
            table.insert(lines, string.sub(line, 1, max_chars))
            line = string.sub(line, max_chars + 1)
        end
        table.insert(lines, line)

        pos = (newline and newline + 1) or (#text + 1)
    end

    return lines
end

function Components.TextArea:get_cursor_line_col(lines)
    local pos = 0
    for i, line in ipairs(lines) do
        if pos + #line >= self.cursor_pos then
            return i, self.cursor_pos - pos + 1
        end
        pos = pos + #line + (i < #lines and 1 or 0)  -- +1 for newline/wrap
    end
    return #lines, #lines[#lines] + 1
end

function Components.TextArea:handle_key(key)
    local changed = false

    if key.special == "BACKSPACE" then
        if #self.value > 0 and self.cursor_pos > 0 then
            self.value = string.sub(self.value, 1, self.cursor_pos - 1) ..
                        string.sub(self.value, self.cursor_pos + 1)
            self.cursor_pos = self.cursor_pos - 1
            changed = true
        end
    elseif key.special == "LEFT" then
        if self.cursor_pos > 0 then
            self.cursor_pos = self.cursor_pos - 1
        end
    elseif key.special == "RIGHT" then
        if self.cursor_pos < #self.value then
            self.cursor_pos = self.cursor_pos + 1
        end
    elseif key.special == "UP" then
        -- Move cursor up one line (simplified)
        local fw = 8  -- Approximate
        local max_chars = math.floor((self.width - 8) / fw)
        if self.cursor_pos > max_chars then
            self.cursor_pos = self.cursor_pos - max_chars
        else
            self.cursor_pos = 0
        end
    elseif key.special == "DOWN" then
        local fw = 8
        local max_chars = math.floor((self.width - 8) / fw)
        self.cursor_pos = math.min(#self.value, self.cursor_pos + max_chars)
    elseif key.special == "ENTER" then
        if #self.value < self.max_length then
            self.value = string.sub(self.value, 1, self.cursor_pos) ..
                        "\n" ..
                        string.sub(self.value, self.cursor_pos + 1)
            self.cursor_pos = self.cursor_pos + 1
            changed = true
        end
    elseif key.character and #self.value < self.max_length then
        self.value = string.sub(self.value, 1, self.cursor_pos) ..
                    key.character ..
                    string.sub(self.value, self.cursor_pos + 1)
        self.cursor_pos = self.cursor_pos + 1
        changed = true
    end

    if changed and self.on_change then
        self.on_change(self.value)
    end

    return changed and "changed" or nil
end

function Components.TextArea:set_value(value)
    self.value = value or ""
    self.cursor_pos = #self.value
end

function Components.TextArea:get_value()
    return self.value
end

--------------------------------------------------------------------------------
-- VerticalList: Scrollable list of items
--------------------------------------------------------------------------------
Components.VerticalList = {}
Components.VerticalList.__index = Components.VerticalList

function Components.VerticalList:new(opts)
    opts = opts or {}
    local o = {
        items = opts.items or {},  -- Array of {label, sublabel?, icon?, data?}
        selected = opts.selected or 1,
        scroll_offset = 0,
        visible_rows = opts.visible_rows or 5,
        row_height = opts.row_height or 24,
        show_icons = opts.show_icons or false,
        play_sounds = opts.play_sounds ~= false,  -- default: true
        on_select = opts.on_select,  -- callback(index, item)
        on_change = opts.on_change,  -- callback(index, item) when selection moves
    }
    setmetatable(o, Components.VerticalList)
    return o
end

function Components.VerticalList:render(display, x, y, width, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local fw = display.get_font_width()

    local height = self.visible_rows * self.row_height

    -- Background
    display.fill_rect(x, y, width, height, colors.BLACK)

    if #self.items == 0 then
        display.draw_text(x + 4, y + height / 2 - fh / 2, "No items", colors.TEXT_SECONDARY)
        return width, height
    end

    -- Items
    local icon_offset = self.show_icons and 28 or 0

    for i = 1, self.visible_rows do
        local item_idx = self.scroll_offset + i
        if item_idx > #self.items then break end

        local item = self.items[item_idx]
        local item_y = y + (i - 1) * self.row_height
        local is_selected = focused and (item_idx == self.selected)

        -- Selection background
        if is_selected then
            display.fill_rect(x, item_y, width - 8, self.row_height, colors.SURFACE_ALT)

            -- Chevron indicator
            if _G.Icons and _G.Icons.draw_chevron_right then
                local chevron_y = item_y + math.floor((self.row_height - 9) / 2)
                _G.Icons.draw_chevron_right(display, x + 2, chevron_y, colors.ACCENT, colors.SURFACE_ALT)
            end
        end

        -- Icon
        if self.show_icons and item.icon and _G.Icons then
            local icon_y = item_y + math.floor((self.row_height - 20) / 2)
            local icon_color = is_selected and colors.ACCENT or colors.WHITE
            _G.Icons.draw(item.icon, display, x + 12, icon_y, 20, icon_color)
        end

        -- Label
        local label_x = x + 12 + icon_offset
        local label_color = is_selected and colors.ACCENT or colors.TEXT
        display.draw_text(label_x, item_y + 2, item.label or "", label_color)

        -- Sublabel
        if item.sublabel then
            display.set_font_size("small")
            local sublabel_color = is_selected and colors.TEXT_SECONDARY or colors.TEXT_MUTED
            display.draw_text(label_x, item_y + 2 + fh - 2, item.sublabel, sublabel_color)
            display.set_font_size("medium")
        end
    end

    -- Scrollbar
    if #self.items > self.visible_rows then
        local sb_x = x + width - 6
        local sb_height = height - 4
        local thumb_height = math.max(8, math.floor(sb_height * self.visible_rows / #self.items))
        local scroll_range = #self.items - self.visible_rows
        local thumb_range = sb_height - thumb_height
        local thumb_y = y + 2 + math.floor(self.scroll_offset * thumb_range / scroll_range)

        display.fill_rect(sb_x, y + 2, 4, sb_height, colors.SURFACE)
        display.fill_rect(sb_x, thumb_y, 4, thumb_height, focused and colors.ACCENT or colors.TEXT_SECONDARY)
    end

    return width, height
end

function Components.VerticalList:handle_key(key)
    if #self.items == 0 then return nil end

    -- Sound helper
    local function play_sound(name)
        if self.play_sounds and _G.SoundUtils and _G.SoundUtils[name] then
            pcall(_G.SoundUtils[name])
        end
    end

    if key.special == "UP" then
        if self.selected > 1 then
            self.selected = self.selected - 1
            if self.selected <= self.scroll_offset then
                self.scroll_offset = self.selected - 1
            end
            play_sound("navigate")
            if self.on_change then
                self.on_change(self.selected, self.items[self.selected])
            end
            return "changed"
        end
    elseif key.special == "DOWN" then
        if self.selected < #self.items then
            self.selected = self.selected + 1
            if self.selected > self.scroll_offset + self.visible_rows then
                self.scroll_offset = self.selected - self.visible_rows
            end
            play_sound("navigate")
            if self.on_change then
                self.on_change(self.selected, self.items[self.selected])
            end
            return "changed"
        end
    elseif key.special == "ENTER" then
        play_sound("click")
        if self.on_select then
            self.on_select(self.selected, self.items[self.selected])
        end
        return "selected"
    end

    return nil
end

function Components.VerticalList:set_items(items)
    self.items = items or {}
    self.selected = math.min(self.selected, math.max(1, #self.items))
    self.scroll_offset = 0
end

function Components.VerticalList:get_selected()
    if #self.items == 0 then return nil, nil end
    return self.selected, self.items[self.selected]
end

function Components.VerticalList:set_selected(index)
    self.selected = math.max(1, math.min(index, #self.items))
    -- Adjust scroll to show selected
    if self.selected <= self.scroll_offset then
        self.scroll_offset = self.selected - 1
    elseif self.selected > self.scroll_offset + self.visible_rows then
        self.scroll_offset = self.selected - self.visible_rows
    end
end

--------------------------------------------------------------------------------
-- NumberInput: Numeric input with +/- controls
--------------------------------------------------------------------------------
Components.NumberInput = {}
Components.NumberInput.__index = Components.NumberInput

function Components.NumberInput:new(opts)
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
    setmetatable(o, Components.NumberInput)
    return o
end

function Components.NumberInput:render(display, x, y, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local fw = display.get_font_width()

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

    -- Center the value
    local text_w = #value_str * fw
    local text_x = x + math.floor((self.width - text_w) / 2)
    local text_color = focused and colors.ACCENT or colors.TEXT
    display.draw_text(text_x, y + 2, value_str, text_color)

    return self.width, fh + 4
end

function Components.NumberInput:handle_key(key)
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

function Components.NumberInput:set_value(value)
    self.value = math.max(self.min, math.min(self.max, value))
end

function Components.NumberInput:get_value()
    return self.value
end

--------------------------------------------------------------------------------
-- Toggle: On/Off switch
--------------------------------------------------------------------------------
Components.Toggle = {}
Components.Toggle.__index = Components.Toggle

function Components.Toggle:new(opts)
    opts = opts or {}
    local o = {
        value = opts.value or false,
        label = opts.label or "",
        on_change = opts.on_change,
    }
    setmetatable(o, Components.Toggle)
    return o
end

function Components.Toggle:render(display, x, y, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local fw = display.get_font_width()

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
    if #self.label > 0 then
        local label_color = focused and colors.ACCENT or colors.TEXT
        display.draw_text(x + switch_w + 8, y, self.label, label_color)
    end

    return switch_w + (#self.label > 0 and (8 + #self.label * fw) or 0), switch_h
end

function Components.Toggle:handle_key(key)
    if key.special == "ENTER" or key.character == " " or
       key.special == "LEFT" or key.special == "RIGHT" then
        self.value = not self.value
        if self.on_change then self.on_change(self.value) end
        return "changed"
    end
    return nil
end

function Components.Toggle:set_value(value)
    self.value = value
end

function Components.Toggle:get_value()
    return self.value
end

return Components
