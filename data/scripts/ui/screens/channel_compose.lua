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
    self.last_blink = ez.system.millis()
end

function ChannelCompose:update_cursor()
    local now = ez.system.millis()
    if now - self.last_blink > self.blink_interval then
        self.cursor_visible = not self.cursor_visible
        self.last_blink = now
        ScreenManager.invalidate()
    end
end

function ChannelCompose:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    self:update_cursor()

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    -- Character count
    local count_str = string.format("%d/%d", #self.text, self.max_length)
    local count_x = display.cols - #count_str - 2
    local count_color = #self.text > self.max_length - 20 and colors.WARNING or colors.TEXT_SECONDARY
    display.draw_text(count_x * fw, fh, count_str, count_color)

    -- Text area
    local text_area_y = 3
    local text_area_height = 8
    local text_area_width_px = (display.cols - 3) * fw

    -- Background for text area
    display.fill_rect(fw, text_area_y * fh, (display.cols - 2) * fw, text_area_height * fh, colors.SURFACE)

    -- Render text with word wrap using pixel-based measurement
    local line_num = 0        -- Current line number (0-indexed)
    local line_x_px = 0       -- Current x position in pixels on line
    local cursor_x_px = 0     -- Cursor x position for drawing

    for i = 1, #self.text do
        local ch = string.sub(self.text, i, i)
        local char_width = display.text_width(ch)

        if ch == "\n" or line_x_px + char_width > text_area_width_px then
            line_num = line_num + 1
            line_x_px = 0
            if ch == "\n" then
                goto continue
            end
        end

        if line_num < text_area_height then
            local py = (text_area_y + line_num) * fh
            local px = 2 * fw + line_x_px
            display.draw_text(px, py, ch, colors.TEXT)
        end
        line_x_px = line_x_px + char_width

        ::continue::
    end

    -- Track cursor position at end of text
    cursor_x_px = line_x_px

    -- Cursor
    if self.cursor_visible and line_num < text_area_height then
        local cy = (text_area_y + line_num) * fh
        local cx = 2 * fw + cursor_x_px
        display.draw_text(cx, cy, "_", colors.ACCENT)
    end
end

function ChannelCompose:handle_key(key)
    ScreenManager.invalidate()

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
        ez.system.log("Cannot send empty message")
        return
    end

    local ChannelsService = _G.Channels
    if ChannelsService then
        if ChannelsService.send(self.channel_name, self.text) then
            ez.system.log("Sent to " .. self.channel_name .. ": " .. self.text)
        else
            ez.system.log("Failed to send channel message")
        end
    else
        ez.system.log("Channels service not available")
    end
end

return ChannelCompose
