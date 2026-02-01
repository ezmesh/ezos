-- TextArea: Multi-line text input

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local TextArea = {}
TextArea.__index = TextArea

function TextArea:new(opts)
    opts = opts or {}
    local o = {
        value = opts.value or "",
        max_length = opts.max_length or 512,
        width = opts.width or 200,
        height = opts.height or 80,
        cursor_pos = opts.value and #opts.value or 0,
        scroll_offset = 0,
        cursor_visible = true,
        cursor_blink_time = 0,
        on_change = opts.on_change,
    }
    setmetatable(o, TextArea)
    return o
end

function TextArea:render(display, x, y, focused)
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
        local now = ez.system.millis()
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

function TextArea:wrap_text(max_chars)
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

function TextArea:get_cursor_line_col(lines)
    local pos = 0
    for i, line in ipairs(lines) do
        if pos + #line >= self.cursor_pos then
            return i, self.cursor_pos - pos + 1
        end
        pos = pos + #line + (i < #lines and 1 or 0)
    end
    return #lines, #lines[#lines] + 1
end

function TextArea:handle_key(key)
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
        local fw = 8
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

function TextArea:set_value(value)
    self.value = value or ""
    self.cursor_pos = #self.value
end

function TextArea:get_value()
    return self.value
end

return TextArea
