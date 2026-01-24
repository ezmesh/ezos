-- Compose Screen for T-Deck OS
-- Compose a broadcast message

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
    self.last_blink = tdeck.system.millis()
end

function Compose:update_cursor()
    local now = tdeck.system.millis()
    if now - self.last_blink > self.blink_interval then
        self.cursor_visible = not self.cursor_visible
        self.last_blink = now
        tdeck.screen.invalidate()
    end
end

function Compose:render(display)
    local colors = display.colors

    self:update_cursor()

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    -- Channel line
    display.draw_text(display.font_width, 2 * display.font_height,
                     "To:", colors.TEXT_DIM)
    display.draw_text(5 * display.font_width, 2 * display.font_height,
                     self.channel, colors.CYAN)

    -- Message label
    display.draw_text(display.font_width, 4 * display.font_height,
                     "Message:", colors.TEXT_DIM)

    -- Character count
    local count_str = string.format("%d/%d", #self.text, self.max_length)
    local count_x = display.cols - 2 - #count_str
    local count_color = #self.text > self.max_length - 20 and colors.ORANGE or colors.TEXT_DIM
    display.draw_text(count_x * display.font_width, 4 * display.font_height, count_str, count_color)

    -- Text area
    local text_area_y = 5
    local text_area_height = 6
    local text_area_width = display.cols - 4

    -- Draw text area background
    display.fill_rect(display.font_width, text_area_y * display.font_height,
                     text_area_width * display.font_width,
                     text_area_height * display.font_height,
                     colors.DARK_GRAY)

    -- Render message with word wrap
    local x = 0
    local y = 0
    local cursor_x, cursor_y = -1, -1

    for i = 0, #self.text do
        -- Track cursor position
        if i == self.cursor_pos then
            cursor_x = x
            cursor_y = y
        end

        if i < #self.text then
            local c = string.sub(self.text, i + 1, i + 1)

            -- Check for newline or wrap
            if c == "\n" or x >= text_area_width then
                y = y + 1
                x = 0
                if c == "\n" then goto continue end
            end

            -- Only render visible lines
            if y >= self.scroll_offset and y < self.scroll_offset + text_area_height then
                local render_y = (text_area_y + y - self.scroll_offset) * display.font_height
                local render_x = (1 + x) * display.font_width
                display.draw_text(render_x, render_y, c, colors.TEXT)
            end

            x = x + 1
        end

        ::continue::
    end

    -- Draw cursor
    if self.cursor_visible and cursor_y >= self.scroll_offset and cursor_y < self.scroll_offset + text_area_height then
        local cx = (1 + cursor_x) * display.font_width
        local cy = (text_area_y + cursor_y - self.scroll_offset) * display.font_height
        display.fill_rect(cx, cy, 2, display.font_height, colors.CYAN)
    end

    -- Scroll indicator
    if self.scroll_offset > 0 then
        display.draw_text((display.cols - 2) * display.font_width,
                         text_area_y * display.font_height, "^", colors.CYAN)
    end

    -- Help bar
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[Enter]Send [Esc]Cancel", colors.TEXT_DIM)
end

function Compose:handle_key(key)
    tdeck.screen.invalidate()

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
    -- Calculate which line the cursor is on
    local text_area_width = 36
    local cursor_line = 0
    local x = 0

    for i = 1, self.cursor_pos do
        local c = string.sub(self.text, i, i)
        if c == "\n" or x >= text_area_width then
            cursor_line = cursor_line + 1
            x = 0
            if c == "\n" then goto continue end
        end
        x = x + 1
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

    if tdeck.mesh.send_channel_message(self.channel, self.text) then
        tdeck.system.log("Sent to " .. self.channel .. ": " .. self.text)
    else
        tdeck.system.log("Failed to send message")
    end
end

return Compose
