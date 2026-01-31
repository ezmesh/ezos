-- Channel View Screen for T-Deck OS
-- View messages in a channel

local ListMixin = load_module("/scripts/ui/list_mixin.lua")
local TextUtils = load_module("/scripts/ui/text_utils.lua")

local ChannelView = {
    title = "",
    channel_name = "",
    messages = {},
    scroll_offset = 0,
    visible_lines = 6,  -- Reduced for 1.5x line height
    last_message_count = 0,
    last_refresh = 0,
    refresh_interval = 1000,
    wrapped_lines = {}  -- Cache of wrapped message lines
}

function ChannelView:new(channel_name)
    local o = {
        title = channel_name,
        channel_name = channel_name,
        messages = {},
        scroll_offset = 0,
        visible_lines = 6,
        last_message_count = 0,
        last_refresh = 0,
        wrapped_lines = {}
    }
    setmetatable(o, {__index = ChannelView})
    return o
end

-- Build wrapped lines cache for all messages
function ChannelView:build_wrapped_lines(display)
    self.wrapped_lines = {}
    local fw = display.get_font_width()
    -- Calculate max width in pixels: screen width minus prefix area (9 chars) and margin
    local max_text_width = display.width - (10 * fw)

    for i, msg in ipairs(self.messages) do
        local entry = {
            msg_index = i,
            lines = {}
        }

        -- Build prefix (verify icon + sender ID)
        local verify_icon = msg.verified and "+" or "?"
        local short_id
        if msg.is_ours then
            short_id = "You"
        else
            short_id = string.format("%02X", msg.from_hash % 256)
        end
        entry.prefix = verify_icon .. " " .. short_id .. ": "
        entry.verified = msg.verified
        entry.is_ours = msg.is_ours

        -- Wrap the message text using pixel-based measurement
        entry.lines = TextUtils.wrap_text(msg.text, max_text_width, display)

        table.insert(self.wrapped_lines, entry)
    end
end

-- Count total display lines
function ChannelView:count_total_lines()
    local total = 0
    for _, entry in ipairs(self.wrapped_lines) do
        total = total + #entry.lines
    end
    return total
end

function ChannelView:on_enter()
    self:refresh_messages()
    self.last_message_count = #self.messages

    -- Mark as read using Channels service
    local ChannelsService = _G.Channels
    if ChannelsService then
        ChannelsService.mark_read(self.channel_name)
    end
end

function ChannelView:refresh_messages()
    -- Get messages from Channels service
    local ChannelsService = _G.Channels
    if ChannelsService then
        self.messages = ChannelsService.get_messages(self.channel_name)
    else
        self.messages = {}
    end

    -- Sort by timestamp (oldest first)
    table.sort(self.messages, function(a, b)
        return a.timestamp < b.timestamp
    end)

    -- Mark that we need to rebuild wrapped lines on next render
    self.wrapped_lines = {}
end

-- Scroll to show most recent messages
function ChannelView:scroll_to_bottom()
    local total_lines = self:count_total_lines()
    if total_lines > self.visible_lines then
        self.scroll_offset = total_lines - self.visible_lines
    else
        self.scroll_offset = 0
    end
end

function ChannelView:check_new_messages()
    local now = ez.system.millis()
    if now - self.last_refresh < self.refresh_interval then
        return
    end
    self.last_refresh = now

    local ChannelsService = _G.Channels
    if not ChannelsService then return end

    local current_messages = ChannelsService.get_messages(self.channel_name)
    if #current_messages > self.last_message_count then
        self:refresh_messages()
        self.last_message_count = #self.messages
        -- Wrapped lines will be rebuilt on next render
        ChannelsService.mark_read(self.channel_name)
        ScreenManager.invalidate()
    end
end

function ChannelView:render(display)
    local colors = ListMixin.get_colors(display)

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Check for new messages
    self:check_new_messages()

    -- Title bar
    TitleBar.draw(display, self.channel_name)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    -- Build wrapped lines if needed
    if #self.wrapped_lines == 0 and #self.messages > 0 then
        self:build_wrapped_lines(display)
        self:scroll_to_bottom()
    end

    if #self.messages == 0 then
        display.draw_text_centered(6 * fh, "No messages yet", colors.TEXT_SECONDARY)
        display.draw_text_centered(8 * fh, "Use app menu to compose", colors.TEXT_SECONDARY)
    else
        -- Render wrapped lines with scroll offset
        local screen_row = 2  -- Start row on screen
        local max_screen_row = 2 + self.visible_lines
        local current_line = 0  -- Current line index across all messages

        for _, entry in ipairs(self.wrapped_lines) do
            for line_idx, line_text in ipairs(entry.lines) do
                current_line = current_line + 1

                -- Skip lines before scroll offset
                if current_line > self.scroll_offset then
                    if screen_row >= max_screen_row then
                        break
                    end

                    -- Use 1.5x line height for better readability
                    local line_height = math.floor(fh * 1.5)
                    local py = 2 * fh + (screen_row - 2) * line_height

                    if line_idx == 1 then
                        -- First line: show prefix (verify icon + sender)
                        local verify_color = entry.verified and colors.SUCCESS or colors.WARNING
                        display.draw_text(fw, py, entry.verified and "+" or "?", verify_color)

                        local id_text = entry.is_ours and "You" or
                            string.format("%02X", self.messages[entry.msg_index].from_hash % 256)
                        display.draw_text(3 * fw, py, id_text, colors.TEXT_SECONDARY)
                        display.draw_text(7 * fw, py, ":", colors.TEXT_SECONDARY)

                        -- Message text
                        local text_color = entry.is_ours and colors.ACCENT or colors.TEXT
                        display.draw_text(9 * fw, py, line_text, text_color)
                    else
                        -- Continuation line: indent to align with text
                        local text_color = entry.is_ours and colors.ACCENT or colors.TEXT
                        display.draw_text(9 * fw, py, line_text, text_color)
                    end

                    screen_row = screen_row + 1
                end
            end

            if screen_row >= max_screen_row then
                break
            end
        end

        -- Scroll indicators
        local total_lines = self:count_total_lines()
        local line_height = math.floor(fh * 1.5)
        if self.scroll_offset > 0 then
            display.draw_text((display.cols - 1) * fw, 2 * fh, "^", colors.ACCENT)
        end
        if self.scroll_offset + self.visible_lines < total_lines then
            local bottom_y = 2 * fh + (self.visible_lines - 1) * line_height
            display.draw_text((display.cols - 1) * fw, bottom_y, "v", colors.ACCENT)
        end
    end
end

function ChannelView:handle_key(key)
    if key.special == "UP" then
        self:scroll_up()
    elseif key.special == "DOWN" then
        self:scroll_down()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "c" then
        self:compose()
    end

    return "continue"
end

function ChannelView:scroll_up()
    if self.scroll_offset > 0 then
        self.scroll_offset = self.scroll_offset - 1
        ScreenManager.invalidate()
    end
end

function ChannelView:scroll_down()
    local total_lines = self:count_total_lines()
    if self.scroll_offset + self.visible_lines < total_lines then
        self.scroll_offset = self.scroll_offset + 1
        ScreenManager.invalidate()
    end
end

function ChannelView:compose()
    spawn_screen("/scripts/ui/screens/channel_compose.lua", self.channel_name)
end

return ChannelView
