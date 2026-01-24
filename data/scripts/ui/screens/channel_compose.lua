-- Channel Compose Screen for T-Deck OS
-- Compose and send a message to a channel

local ChannelCompose = {
    title = "",
    channel_name = "",
    text = "",
    max_length = 200,
    cursor_visible = true,
    last_blink = 0,
    blink_interval = 500
}

function ChannelCompose:new(channel_name)
    local o = {
        title = "To: " .. channel_name,
        channel_name = channel_name,
        text = "",
        cursor_visible = true,
        last_blink = 0
    }
    setmetatable(o, {__index = ChannelCompose})
    return o
end

function ChannelCompose:on_enter()
    self.last_blink = tdeck.system.millis()
end

function ChannelCompose:update_cursor()
    local now = tdeck.system.millis()
    if now - self.last_blink > self.blink_interval then
        self.cursor_visible = not self.cursor_visible
        self.last_blink = now
        tdeck.screen.invalidate()
    end
end

function ChannelCompose:render(display)
    local colors = display.colors

    self:update_cursor()

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    -- Character count
    local count_str = string.format("%d/%d", #self.text, self.max_length)
    local count_x = display.cols - #count_str - 2
    local count_color = #self.text > self.max_length - 20 and colors.ORANGE or colors.TEXT_DIM
    display.draw_text(count_x * display.font_width, display.font_height, count_str, count_color)

    -- Text area
    local text_area_y = 3
    local text_area_height = 8

    -- Background for text area
    display.fill_rect(display.font_width, text_area_y * display.font_height,
                     (display.cols - 2) * display.font_width,
                     text_area_height * display.font_height,
                     colors.DARK_GRAY)

    -- Render text with word wrap
    local y = text_area_y
    local x = 2
    local max_x = display.cols - 2

    for i = 1, #self.text do
        local ch = string.sub(self.text, i, i)

        if ch == "\n" or x >= max_x then
            y = y + 1
            x = 2
            if ch == "\n" then
                goto continue
            end
        end

        if y < text_area_y + text_area_height then
            display.draw_text(x * display.font_width, y * display.font_height, ch, colors.TEXT)
        end
        x = x + 1

        ::continue::
    end

    -- Cursor
    if self.cursor_visible and y < text_area_y + text_area_height then
        display.draw_text(x * display.font_width, y * display.font_height, "_", colors.CYAN)
    end

    -- Help bar
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[Enter]Send [Esc]Cancel", colors.TEXT_DIM)
end

function ChannelCompose:handle_key(key)
    tdeck.screen.invalidate()

    if key.special == "ENTER" then
        self:send()
        return "pop"
    elseif key.special == "BACKSPACE" then
        if #self.text > 0 then
            self.text = string.sub(self.text, 1, -2)
        end
    elseif key.special == "ESCAPE" then
        return "pop"
    elseif key.character then
        if #self.text < self.max_length then
            self.text = self.text .. key.character
        end
    end

    return "continue"
end

function ChannelCompose:send()
    if #self.text == 0 then
        tdeck.system.log("Cannot send empty message")
        return
    end

    if tdeck.mesh.send_channel_message(self.channel_name, self.text) then
        tdeck.system.log("Sent to " .. self.channel_name .. ": " .. self.text)
    else
        tdeck.system.log("Failed to send channel message")
    end
end

return ChannelCompose
