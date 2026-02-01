-- Compose Screen for T-Deck OS
-- Compose a broadcast message

local ListMixin = load_module("/scripts/ui/list_mixin.lua")
local TextUtils = load_module("/scripts/ui/text_utils.lua")

local Compose = {
    title = "Compose",
    channel = "#Public",
    text = "",
    max_length = 200,
    cursor_pos = 0,
    scroll_offset = 0,
    cursor_visible = true,
    last_blink = 0,
    blink_interval = 500
}

function Compose:new()
    local o = {
        title = "Compose",
        channel = "#Public",
        text = "",
        cursor_pos = 0,
        scroll_offset = 0,
        cursor_visible = true,
        last_blink = 0
    }
    setmetatable(o, {__index = Compose})
    return o
end

function Compose:on_enter()
    self.last_blink = ez.system.millis()
end

function Compose:update_cursor()
    local now = ez.system.millis()
    if now - self.last_blink > self.blink_interval then
        self.cursor_visible = not self.cursor_visible
        self.last_blink = now
        ScreenManager.invalidate()
    end
end

function Compose:render(display)
    local colors = ListMixin.get_colors(display)

    self:update_cursor()

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    -- Channel line
    display.draw_text(fw, 2 * fh, "To:", colors.TEXT_SECONDARY)
    display.draw_text(5 * fw, 2 * fh, self.channel, colors.ACCENT)

    -- Message label
    display.draw_text(fw, 4 * fh, "Message:", colors.TEXT_SECONDARY)

    -- Character count
    local count_str = string.format("%d/%d", #self.text, self.max_length)
    local count_x = display.cols - 2 - #count_str
    local count_color = #self.text > self.max_length - 20 and colors.WARNING or colors.TEXT_SECONDARY
    display.draw_text(count_x * fw, 4 * fh, count_str, count_color)

    -- Text area
    local text_area_y = 5
    local text_area_height = 6
    local text_area_width_chars = display.cols - 4
    local text_area_width_px = text_area_width_chars * fw

    -- Draw text area background
    display.fill_rect(fw, text_area_y * fh, text_area_width_px, text_area_height * fh, colors.SURFACE)

    -- Render message with word wrap using pixel-based measurement
    local line_x_px = 0  -- Current x position in pixels on current line
    local y = 0          -- Current line number
    local cursor_x_px, cursor_y = -1, -1

    for i = 0, #self.text do
        -- Track cursor position
        if i == self.cursor_pos then
            cursor_x_px = line_x_px
            cursor_y = y
        end

        if i < #self.text then
            local c = string.sub(self.text, i + 1, i + 1)
            local char_width = display.text_width(c)

            -- Check for newline or wrap (using pixel width)
            if c == "\n" or line_x_px + char_width > text_area_width_px then
                y = y + 1
                line_x_px = 0
                if c == "\n" then goto continue end
            end

            -- Only render visible lines
            if y >= self.scroll_offset and y < self.scroll_offset + text_area_height then
                local render_y = (text_area_y + y - self.scroll_offset) * fh
                local render_x = fw + line_x_px
                display.draw_text(render_x, render_y, c, colors.TEXT)
            end

            line_x_px = line_x_px + char_width
        end

        ::continue::
    end

    -- Draw cursor
    if self.cursor_visible and cursor_y >= self.scroll_offset and cursor_y < self.scroll_offset + text_area_height then
        local cx = fw + cursor_x_px
        local cy = (text_area_y + cursor_y - self.scroll_offset) * fh
        display.fill_rect(cx, cy, 2, fh, colors.ACCENT)
    end

    -- Scroll indicator
    if self.scroll_offset > 0 then
        display.draw_text((display.cols - 2) * fw, text_area_y * fh, "^", colors.ACCENT)
    end
end

function Compose:handle_key(key)
    ScreenManager.invalidate()

    if key.special == "ENTER" then
        if key.ctrl or key.shift then
            -- Ctrl/Shift+Enter inserts newline
            self:insert_char("\n")
        else
            -- Enter sends
            self:send()
            return "pop"
        end
    elseif key.special == "ESCAPE" then
        return "pop"
    elseif key.special == "BACKSPACE" then
        self:delete_char()
    elseif key.special == "LEFT" then
        if self.cursor_pos > 0 then
            self.cursor_pos = self.cursor_pos - 1
            self:update_scroll()
        end
    elseif key.special == "RIGHT" then
        if self.cursor_pos < #self.text then
            self.cursor_pos = self.cursor_pos + 1
            self:update_scroll()
        end
    elseif key.special == "UP" then
        if self.scroll_offset > 0 then
            self.scroll_offset = self.scroll_offset - 1
        end
    elseif key.special == "DOWN" then
        self.scroll_offset = self.scroll_offset + 1
    elseif key.character then
        self:insert_char(key.character)
    end

    return "continue"
end

function Compose:insert_char(c)
    if #self.text >= self.max_length then return end

    -- Insert at cursor position
    local before = string.sub(self.text, 1, self.cursor_pos)
    local after = string.sub(self.text, self.cursor_pos + 1)
    self.text = before .. c .. after
    self.cursor_pos = self.cursor_pos + 1

    self:update_scroll()
end

function Compose:delete_char()
    if self.cursor_pos == 0 then return end

    local before = string.sub(self.text, 1, self.cursor_pos - 1)
    local after = string.sub(self.text, self.cursor_pos + 1)
    self.text = before .. after
    self.cursor_pos = self.cursor_pos - 1

    self:update_scroll()
end

function Compose:update_scroll()
    -- Calculate which line the cursor is on using pixel-based measurement
    local fw = ez.display.get_font_width()
    local text_area_width_px = (ez.display.get_cols() - 4) * fw
    local cursor_line = 0
    local line_x_px = 0

    for i = 1, self.cursor_pos do
        local c = string.sub(self.text, i, i)
        local char_width = ez.display.text_width(c)

        if c == "\n" or line_x_px + char_width > text_area_width_px then
            cursor_line = cursor_line + 1
            line_x_px = 0
            if c == "\n" then goto continue end
        end
        line_x_px = line_x_px + char_width
        ::continue::
    end

    -- Adjust scroll to keep cursor visible
    local text_area_height = 6
    if cursor_line < self.scroll_offset then
        self.scroll_offset = cursor_line
    elseif cursor_line >= self.scroll_offset + text_area_height then
        self.scroll_offset = cursor_line - text_area_height + 1
    end
end

function Compose:send()
    if #self.text == 0 then return end

    -- Use Lua Channels service to send message
    if _G.Channels and _G.Channels.send(self.channel, self.text) then
        ez.log("Sent to " .. self.channel .. ": " .. self.text)
    else
        ez.log("Failed to send message")
    end
end

return Compose
