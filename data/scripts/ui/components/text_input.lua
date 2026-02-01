-- TextInput: Single-line text input field

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local TextInput = {}
TextInput.__index = TextInput

function TextInput:new(opts)
    opts = opts or {}
    local o = {
        value = opts.value or "",
        placeholder = opts.placeholder or "",
        max_length = opts.max_length or 64,
        password_mode = opts.password_mode or false,
        width = opts.width or 120,
        cursor_pos = opts.value and #opts.value or 0,
        cursor_visible = true,
        cursor_blink_time = 0,
        on_change = opts.on_change,
        on_submit = opts.on_submit,
    }
    setmetatable(o, TextInput)
    return o
end

function TextInput:render(display, x, y, focused)
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
    local text_offset = 0

    -- Show placeholder if empty
    if #self.value == 0 and not focused then
        display.draw_text(x + 2, y + 2, self.placeholder, colors.TEXT_SECONDARY)
    else
        if #display_text > max_chars then
            text_offset = #display_text - max_chars
            display_text = string.sub(display_text, -max_chars)
        end
        display.draw_text(x + 2, y + 2, display_text, colors.TEXT)
    end

    -- Cursor
    if focused then
        local now = ez.system.millis()
        if now - self.cursor_blink_time > 500 then
            self.cursor_visible = not self.cursor_visible
            self.cursor_blink_time = now
        end

        if self.cursor_visible then
            local visible_cursor_pos = self.cursor_pos - text_offset
            visible_cursor_pos = math.max(0, math.min(visible_cursor_pos, #display_text))
            local cursor_x = x + 2 + visible_cursor_pos * fw
            display.draw_text(cursor_x, y + 2, "_", colors.ACCENT)
        end
    end
end

function TextInput:handle_key(key)
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

function TextInput:set_value(value)
    self.value = value or ""
    self.cursor_pos = #self.value
end

function TextInput:get_value()
    return self.value
end

return TextInput
