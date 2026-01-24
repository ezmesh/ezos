-- Channel View Screen for T-Deck OS
-- View messages in a channel

local ChannelView = {
    title = "",
    channel_name = "",
    messages = {},
    scroll_offset = 0,
    visible_lines = 7,  -- Fewer lines due to increased spacing
    last_message_count = 0,
    last_refresh = 0,
    refresh_interval = 1000,
    wrapped_lines = {},  -- Cache of wrapped message lines
    line_spacing = 1.3   -- Line height multiplier for better readability
}

function ChannelView:new(channel_name)
    local o = {
        title = channel_name,
        channel_name = channel_name,
        messages = {},
        scroll_offset = 0,
        visible_lines = 7,
        last_message_count = 0,
        last_refresh = 0,
        wrapped_lines = {},
        line_spacing = 1.3
    }
    setmetatable(o, {__index = ChannelView})
    return o
end

-- Wrap text to fit within max_width characters
-- Returns array of lines
function ChannelView:wrap_text(text, max_width)
    local lines = {}
    local remaining = text

    while #remaining > 0 do
        if #remaining <= max_width then
            table.insert(lines, remaining)
            break
        end

        -- Find last space within max_width
        local break_pos = max_width
        local space_pos = remaining:sub(1, max_width):match(".*()%s")
        if space_pos and space_pos > 1 then
            break_pos = space_pos - 1
        end

        table.insert(lines, remaining:sub(1, break_pos))
        remaining = remaining:sub(break_pos + 1):gsub("^%s+", "")  -- Trim leading space
    end

    return lines
end

-- Build wrapped lines cache for all messages
function ChannelView:build_wrapped_lines(display)
    self.wrapped_lines = {}
    local max_text_width = display.cols - 10  -- Account for prefix

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

        -- Wrap the message text
        entry.lines = self:wrap_text(msg.text, max_text_width)

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

    -- Mark as read
    tdeck.mesh.mark_channel_read(self.channel_name)
end

function ChannelView:refresh_messages()
    self.messages = tdeck.mesh.get_channel_messages(self.channel_name)

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
    local now = tdeck.system.millis()
    if now - self.last_refresh < self.refresh_interval then
        return
    end
    self.last_refresh = now

    local current_messages = tdeck.mesh.get_channel_messages(self.channel_name)
    if #current_messages > self.last_message_count then
        self:refresh_messages()
        self.last_message_count = #self.messages
        -- Wrapped lines will be rebuilt on next render
        tdeck.mesh.mark_channel_read(self.channel_name)
        tdeck.screen.invalidate()
    end
end

function ChannelView:render(display)
    local colors = display.colors

    -- Check for new messages
    self:check_new_messages()

    -- Build wrapped lines if needed
    if #self.wrapped_lines == 0 and #self.messages > 0 then
        self:build_wrapped_lines(display)
        self:scroll_to_bottom()
    end

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.channel_name, colors.CYAN, colors.WHITE)

    if #self.messages == 0 then
        display.draw_text_centered(6 * display.font_height, "No messages yet", colors.TEXT_DIM)
        display.draw_text_centered(8 * display.font_height, "Press [C] to compose", colors.TEXT_DIM)
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

                    local line_height = math.floor(display.font_height * self.line_spacing)
                    local py = 2 * display.font_height + (screen_row - 2) * line_height

                    if line_idx == 1 then
                        -- First line: show prefix (verify icon + sender)
                        local verify_color = entry.verified and colors.GREEN or colors.YELLOW
                        display.draw_text(display.font_width, py,
                            entry.verified and "+" or "?", verify_color)

                        local id_text = entry.is_ours and "You" or
                            string.format("%02X", self.messages[entry.msg_index].from_hash % 256)
                        display.draw_text(3 * display.font_width, py, id_text, colors.TEXT_DIM)
                        display.draw_text(7 * display.font_width, py, ":", colors.TEXT_DIM)

                        -- Message text
                        local text_color = entry.is_ours and colors.CYAN or colors.TEXT
                        display.draw_text(9 * display.font_width, py, line_text, text_color)
                    else
                        -- Continuation line: indent to align with text
                        local text_color = entry.is_ours and colors.CYAN or colors.TEXT
                        display.draw_text(9 * display.font_width, py, line_text, text_color)
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
        if self.scroll_offset > 0 then
            display.draw_text((display.cols - 1) * display.font_width,
                            2 * display.font_height, "^", colors.CYAN)
        end
        if self.scroll_offset + self.visible_lines < total_lines then
            display.draw_text((display.cols - 1) * display.font_width,
                            (max_screen_row - 1) * display.font_height, "v", colors.CYAN)
        end
    end

    -- Help bar
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[C]ompose [Q]Back", colors.TEXT_DIM)
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
        tdeck.screen.invalidate()
    end
end

function ChannelView:scroll_down()
    local total_lines = self:count_total_lines()
    if self.scroll_offset + self.visible_lines < total_lines then
        self.scroll_offset = self.scroll_offset + 1
        tdeck.screen.invalidate()
    end
end

function ChannelView:compose()
    local Compose = dofile("/scripts/ui/screens/channel_compose.lua")
    tdeck.screen.push(Compose:new(self.channel_name))
end

return ChannelView
