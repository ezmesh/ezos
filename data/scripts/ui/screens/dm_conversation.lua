-- Direct Message Conversation Screen for T-Deck OS
-- Chat bubbles UI with input field

local ListMixin = load_module("/scripts/ui/list_mixin.lua")
local TextUtils = load_module("/scripts/ui/text_utils.lua")

local DMConversation = {
    title = "",
    contact_pub_key = "",
    contact_name = "",
    messages = {},
    scroll_offset = 0,
    visible_lines = 5,
    wrapped_messages = {},
    last_refresh = 0,
    refresh_interval = 1000,
    -- Input field
    input_text = "",
    cursor_pos = 0,
    cursor_visible = true,
    last_blink = 0,
    blink_interval = 500,
    -- Message selection (nil = no selection, input mode)
    selected_msg_index = nil,
    -- Layout constants
    INPUT_HEIGHT = 24,
    STATUS_BAR_HEIGHT = 26,  -- Space for status bar at bottom
    BUBBLE_MAX_WIDTH_PERCENT = 0.75,
    BUBBLE_PADDING = 4,
    BUBBLE_MARGIN = 2,
    BUBBLE_RADIUS = 6,
}

function DMConversation:new(contact_pub_key, contact_name)
    local o = {
        title = contact_name or "Message",
        contact_pub_key = contact_pub_key,
        contact_name = contact_name,
        messages = {},
        scroll_offset = 0,
        visible_lines = 5,
        wrapped_messages = {},
        last_refresh = 0,
        input_text = "",
        cursor_pos = 0,
        cursor_visible = true,
        last_blink = 0,
        selected_msg_index = nil,
    }
    setmetatable(o, {__index = DMConversation})
    return o
end

function DMConversation:on_enter()
    self:refresh_messages()

    -- Mark conversation as read
    if _G.DirectMessages then
        _G.DirectMessages.mark_read(self.contact_pub_key)
    end
end

function DMConversation:refresh_messages()
    -- Get messages from DirectMessages service
    if _G.DirectMessages then
        self.messages = _G.DirectMessages.get_messages(self.contact_pub_key)
    else
        self.messages = {}
    end

    -- Sort by sequence number (order received/sent)
    table.sort(self.messages, function(a, b)
        return (a.seq or 0) < (b.seq or 0)
    end)

    -- Clear wrapped cache to trigger rebuild
    self.wrapped_messages = {}
end

-- Build wrapped messages for display
function DMConversation:build_wrapped_messages(display)
    self.wrapped_messages = {}

    local fw = display.get_font_width()
    local max_bubble_width = math.floor(display.width * self.BUBBLE_MAX_WIDTH_PERCENT)
    local text_max_width = max_bubble_width - (self.BUBBLE_PADDING * 2)

    for i, msg in ipairs(self.messages) do
        local lines
        if msg.is_gap then
            lines = {"?"}  -- Single placeholder for gap
        else
            lines = TextUtils.wrap_text(msg.text, text_max_width, display)
        end
        local wrapped = {
            msg_index = i,
            direction = msg.direction,
            verified = msg.verified,
            acked = msg.acked,
            is_gap = msg.is_gap,
            failed = msg.failed,
            counter = msg.counter,
            lines = lines,
        }
        table.insert(self.wrapped_messages, wrapped)
    end
end

-- Count total display lines
function DMConversation:count_total_lines()
    local total = 0
    for _, entry in ipairs(self.wrapped_messages) do
        -- Each message is at least 1 line, plus additional wrapped lines
        total = total + #entry.lines
    end
    return total
end

-- Scroll to show most recent messages
function DMConversation:scroll_to_bottom()
    local total_lines = self:count_total_lines()
    if total_lines > self.visible_lines then
        self.scroll_offset = total_lines - self.visible_lines
    else
        self.scroll_offset = 0
    end
end

function DMConversation:check_new_messages()
    local now = ez.system.millis()
    local force = self.needs_refresh
    self.needs_refresh = false

    -- Throttle unless forced
    if not force and (now - self.last_refresh < self.refresh_interval) then
        return false
    end
    self.last_refresh = now

    if not _G.DirectMessages then return false end

    local current_messages = _G.DirectMessages.get_messages(self.contact_pub_key)
    local needs_refresh = false

    -- Check for new messages
    if #current_messages ~= #self.messages then
        needs_refresh = true
    end

    -- Count current ACKs to detect changes
    if not needs_refresh then
        local current_ack_count = 0
        for _, msg in ipairs(current_messages) do
            if msg.acked then current_ack_count = current_ack_count + 1 end
        end
        if current_ack_count ~= (self.ack_count or 0) then
            self.ack_count = current_ack_count
            needs_refresh = true
        end
    end

    if needs_refresh or force then
        self:refresh_messages()
        _G.DirectMessages.mark_read(self.contact_pub_key)
        self.wrapped_messages = {}
        -- Update ack count
        local ack_count = 0
        for _, msg in ipairs(self.messages) do
            if msg.acked then ack_count = ack_count + 1 end
        end
        self.ack_count = ack_count
        return true
    end
    return false
end

-- Force refresh on next render (called externally when messages/ACKs arrive)
function DMConversation:mark_needs_refresh()
    self.needs_refresh = true
end

function DMConversation:update_cursor()
    local now = ez.system.millis()
    if now - self.last_blink > self.blink_interval then
        self.cursor_visible = not self.cursor_visible
        self.last_blink = now
        ScreenManager.invalidate()
    end
end

-- Draw custom title bar with contact name and hop count indicator
function DMConversation:draw_title_bar(display, colors)
    -- Title bar constants (match TitleBar module)
    local title_y = 3
    local bar_padding = 6
    local underline_gap = 5

    display.set_font_size("small")
    local fh = display.get_font_height()

    -- Black background for title area
    display.fill_rect(0, 0, display.width, fh + bar_padding, colors.BLACK)

    -- Get hop count from DirectMessages
    local hop_count = nil
    if _G.DirectMessages and _G.DirectMessages.conversations then
        local conv = _G.DirectMessages.conversations[self.contact_pub_key]
        if conv then
            if conv.out_path then
                hop_count = #conv.out_path
            end
        end
    end

    -- Calculate total title width for centering
    local title_text = self.title or self.contact_name or "Message"
    local title_width = display.text_width(title_text)
    local bunny_size = 12
    local hop_text = ""

    if hop_count then
        hop_text = tostring(hop_count)
        title_width = title_width + 4 + bunny_size + 2 + display.text_width(hop_text)
    end

    -- Draw centered title with bunny and hop count
    local start_x = math.floor((display.width - title_width) / 2)
    display.draw_text(start_x, title_y, self.title or self.contact_name or "Message", colors.WHITE)

    if hop_count and _G.Icons and _G.Icons.draw_small then
        local text_end_x = start_x + display.text_width(self.title or self.contact_name or "Message")
        local bunny_x = text_end_x + 4
        local bunny_y = title_y + math.floor((fh - bunny_size) / 2)
        _G.Icons.draw_small("bunny", display, bunny_x, bunny_y, colors.TEXT_SECONDARY)
        display.draw_text(bunny_x + bunny_size + 2, title_y, hop_text, colors.TEXT_SECONDARY)
    end

    -- Draw underline
    display.fill_rect(0, fh + underline_gap, display.width, 1, colors.SUCCESS)
end

function DMConversation:render(display)
    local colors = ListMixin.get_colors(display)

    self:update_cursor()

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Check for new messages (wrapped_messages is cleared in check_new_messages)
    self:check_new_messages()

    -- Custom title bar with hop count indicator
    self:draw_title_bar(display, colors)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    -- Calculate layout (account for status bar at bottom)
    local title_height = _G.ThemeManager and _G.ThemeManager.TITLE_BAR_HEIGHT or 30
    local input_area_height = self.INPUT_HEIGHT + 4
    local status_bar_height = self.STATUS_BAR_HEIGHT
    local chat_area_top = title_height + 2
    local chat_area_bottom = display.height - input_area_height - status_bar_height - 2
    local chat_area_height = chat_area_bottom - chat_area_top

    -- Calculate visible lines based on line height
    local line_height = math.floor(fh * 1.5)
    self.visible_lines = math.floor(chat_area_height / line_height)

    -- Build wrapped messages if needed
    if #self.wrapped_messages == 0 and #self.messages > 0 then
        self:build_wrapped_messages(display)
        self:scroll_to_bottom()
    end

    -- Render chat bubbles
    if #self.messages == 0 then
        display.draw_text_centered(chat_area_top + 40, "No messages yet", colors.TEXT_SECONDARY)
        display.draw_text_centered(chat_area_top + 60, "Type below to send", colors.TEXT_SECONDARY)
    else
        local max_bubble_width = math.floor(display.width * self.BUBBLE_MAX_WIDTH_PERCENT)

        -- Render visible lines
        local screen_line = 0
        local current_line = 0

        for _, wrapped in ipairs(self.wrapped_messages) do
            local is_sent = wrapped.direction == "sent"
            local msg_start_line = current_line

            for line_idx, line_text in ipairs(wrapped.lines) do
                current_line = current_line + 1

                -- Skip lines before scroll offset
                if current_line > self.scroll_offset then
                    if screen_line >= self.visible_lines then
                        break
                    end

                    local py = chat_area_top + screen_line * line_height

                    -- Calculate bubble dimensions
                    local text_width = display.text_width(line_text)
                    local bubble_width = text_width + self.BUBBLE_PADDING * 2

                    -- Position bubble
                    local bubble_x
                    if is_sent then
                        -- Right-aligned for sent messages
                        bubble_x = display.width - bubble_width - self.BUBBLE_MARGIN - 4
                    else
                        -- Left-aligned for received messages
                        bubble_x = self.BUBBLE_MARGIN + 4
                    end

                    -- Check if this message is selected
                    local is_selected = (self.selected_msg_index == wrapped.msg_index)

                    -- Draw bubble background (special handling for gap and failed messages)
                    if wrapped.is_gap then
                        -- Gap message: muted outline with question mark, red if failed
                        local gap_color = wrapped.failed and colors.ERROR or (colors.TEXT_MUTED or 0x8410)
                        display.draw_round_rect(bubble_x, py, bubble_width, fh + 4,
                                               self.BUBBLE_RADIUS, gap_color)
                        local gap_icon = wrapped.failed and "X" or "?"
                        display.draw_text(bubble_x + self.BUBBLE_PADDING, py + 2, gap_icon, gap_color)
                        -- Selection outline for gap messages
                        if is_selected then
                            display.draw_round_rect(bubble_x - 2, py - 2, bubble_width + 4, fh + 8,
                                                   self.BUBBLE_RADIUS, colors.WARNING)
                        end
                    elseif wrapped.failed then
                        -- Failed message: red outline
                        display.draw_round_rect(bubble_x, py, bubble_width, fh + 4,
                                               self.BUBBLE_RADIUS, colors.ERROR)
                        display.draw_text(bubble_x + self.BUBBLE_PADDING, py + 2, line_text, colors.ERROR)
                        -- Selection outline
                        if is_selected then
                            display.draw_round_rect(bubble_x - 2, py - 2, bubble_width + 4, fh + 8,
                                                   self.BUBBLE_RADIUS, colors.WARNING)
                        end
                    else
                        local bg_color = is_sent and colors.ACCENT or colors.SURFACE
                        display.fill_round_rect(bubble_x, py, bubble_width, fh + 4,
                                               self.BUBBLE_RADIUS, bg_color)

                        -- Draw text
                        local text_color = is_sent and colors.BLACK or colors.TEXT
                        display.draw_text(bubble_x + self.BUBBLE_PADDING, py + 2, line_text, text_color)

                        -- Selection outline
                        if is_selected then
                            display.draw_round_rect(bubble_x - 2, py - 2, bubble_width + 4, fh + 8,
                                                   self.BUBBLE_RADIUS, colors.WARNING)
                        end
                    end

                    -- Draw status indicator on first line (skip for gap messages)
                    if line_idx == 1 and not wrapped.is_gap then
                        local icon_x
                        if is_sent then
                            icon_x = bubble_x - 10
                        else
                            icon_x = bubble_x + bubble_width + 4
                        end

                        local indicator_color, indicator_icon
                        if is_sent then
                            -- For sent messages: show delivery status
                            if wrapped.failed then
                                indicator_color = colors.ERROR  -- Red when failed
                                indicator_icon = "X"
                            elseif wrapped.acked then
                                indicator_color = colors.SUCCESS  -- Green when acknowledged
                                indicator_icon = "."
                            else
                                indicator_color = colors.TEXT_MUTED  -- Muted when pending
                                indicator_icon = "."
                            end
                        else
                            -- For received messages: show verification status
                            if wrapped.failed then
                                indicator_color = colors.ERROR
                                indicator_icon = "X"
                            else
                                indicator_color = wrapped.verified and colors.SUCCESS or colors.WARNING
                                indicator_icon = wrapped.verified and "+" or "?"
                            end
                        end
                        display.draw_text(icon_x, py + 2, indicator_icon, indicator_color)
                    end

                    screen_line = screen_line + 1
                end
            end

            if screen_line >= self.visible_lines then
                break
            end
        end

        -- Scroll indicators
        local total_lines = self:count_total_lines()
        if self.scroll_offset > 0 then
            display.draw_text(display.width - fw - 4, chat_area_top, "^", colors.ACCENT)
        end
        if self.scroll_offset + self.visible_lines < total_lines then
            display.draw_text(display.width - fw - 4, chat_area_bottom - fh, "v", colors.ACCENT)
        end
    end

    -- Draw input field (above status bar)
    local input_y = display.height - input_area_height - status_bar_height
    local input_x = 4
    local input_width = display.width - 8

    -- Input background
    display.fill_round_rect(input_x, input_y, input_width, self.INPUT_HEIGHT,
                            self.BUBBLE_RADIUS, colors.SURFACE)

    -- Input text
    local input_display_x = input_x + self.BUBBLE_PADDING
    local input_display_y = input_y + (self.INPUT_HEIGHT - fh) / 2

    if #self.input_text == 0 then
        -- Placeholder text
        display.draw_text(input_display_x, input_display_y, "Type message...", colors.TEXT_MUTED)
        -- Still show cursor at start position when empty
        if self.cursor_visible then
            display.fill_rect(input_display_x, input_display_y, 2, fh, colors.ACCENT)
        end
    else
        -- Calculate visible portion of input
        local max_input_width = input_width - self.BUBBLE_PADDING * 2 - 4
        local text_to_show = self.input_text
        local cursor_x_offset = display.text_width(self.input_text:sub(1, self.cursor_pos))

        -- Scroll input if cursor would be off-screen
        local input_scroll = 0
        if cursor_x_offset > max_input_width then
            input_scroll = cursor_x_offset - max_input_width + fw
        end

        -- Render visible portion
        display.draw_text(input_display_x, input_display_y, text_to_show, colors.TEXT)

        -- Draw cursor
        if self.cursor_visible then
            local cursor_x = input_display_x + cursor_x_offset - input_scroll
            display.fill_rect(cursor_x, input_display_y, 2, fh, colors.ACCENT)
        end
    end

    -- Send icon hint
    local send_x = display.width - fw * 2 - 4
    display.draw_text(send_x, input_display_y, ">", colors.ACCENT)
end

function DMConversation:handle_key(key)
    ScreenManager.invalidate()

    -- Debug: log all key events to help diagnose input issues
    if key.character then
        ez.log("[DMConv] key: char='" .. key.character .. "' input_len=" .. #self.input_text .. " sel=" .. tostring(self.selected_msg_index))
    elseif key.special then
        ez.log("[DMConv] key: special=" .. key.special .. " input_len=" .. #self.input_text .. " sel=" .. tostring(self.selected_msg_index))
    end

    if key.special == "ENTER" then
        if self.selected_msg_index then
            -- Open app menu when a message is selected
            ez.log("[DMConv] ENTER on selected message #" .. self.selected_msg_index)
            if _G.AppMenu then
                _G.AppMenu.show()
            end
        elseif #self.input_text > 0 then
            self:send_message()
        elseif #self.messages > 0 then
            -- Empty input, no selection: select the last message for quick interaction
            self.selected_msg_index = #self.messages
            self:scroll_to_selected()
            ez.log("[DMConv] ENTER: auto-selected last message #" .. self.selected_msg_index)
        end
    elseif key.special == "BACKSPACE" then
        if self.selected_msg_index then
            -- Clear selection
            self.selected_msg_index = nil
        else
            self:delete_char()
        end
    elseif key.special == "ESCAPE" then
        -- Clear message selection
        if self.selected_msg_index then
            self.selected_msg_index = nil
        end
    elseif key.special == "LEFT" then
        if self.cursor_pos > 0 then
            self.cursor_pos = self.cursor_pos - 1
        end
    elseif key.special == "RIGHT" then
        if self.cursor_pos < #self.input_text then
            self.cursor_pos = self.cursor_pos + 1
        end
    elseif key.special == "UP" then
        -- Select messages when input is empty
        if #self.input_text == 0 then
            self:select_prev_message()
        elseif key.ctrl or key.alt then
            self:scroll_up()
        end
    elseif key.special == "DOWN" then
        -- Navigate messages when input is empty
        if #self.input_text == 0 then
            self:select_next_message()
        elseif key.ctrl or key.alt then
            self:scroll_down()
        end
    elseif key.character then
        -- Clear selection when typing
        self.selected_msg_index = nil
        self:insert_char(key.character)
    end

    return "continue"
end

function DMConversation:insert_char(c)
    local max_length = 120
    if #self.input_text >= max_length then return end

    local before = self.input_text:sub(1, self.cursor_pos)
    local after = self.input_text:sub(self.cursor_pos + 1)
    self.input_text = before .. c .. after
    self.cursor_pos = self.cursor_pos + 1
end

function DMConversation:delete_char()
    if self.cursor_pos == 0 then return end

    local before = self.input_text:sub(1, self.cursor_pos - 1)
    local after = self.input_text:sub(self.cursor_pos + 1)
    self.input_text = before .. after
    self.cursor_pos = self.cursor_pos - 1
end

function DMConversation:scroll_up()
    if self.scroll_offset > 0 then
        self.scroll_offset = self.scroll_offset - 1
    end
end

function DMConversation:scroll_down()
    local total_lines = self:count_total_lines()
    if self.scroll_offset + self.visible_lines < total_lines then
        self.scroll_offset = self.scroll_offset + 1
    end
end

-- Select previous message (UP key when input empty)
function DMConversation:select_prev_message()
    if #self.messages == 0 then return end

    if self.selected_msg_index == nil then
        -- Start selection at the last message
        self.selected_msg_index = #self.messages
    elseif self.selected_msg_index > 1 then
        self.selected_msg_index = self.selected_msg_index - 1
    end

    -- Scroll to keep selected message visible
    self:scroll_to_selected()
end

-- Select next message (DOWN key when input empty)
function DMConversation:select_next_message()
    if #self.messages == 0 then return end

    if self.selected_msg_index == nil then
        -- Start selection at the last message
        self.selected_msg_index = #self.messages
    elseif self.selected_msg_index < #self.messages then
        self.selected_msg_index = self.selected_msg_index + 1
    else
        -- At the last message, clear selection to return to input
        self.selected_msg_index = nil
    end

    -- Scroll to keep selected message visible
    if self.selected_msg_index then
        self:scroll_to_selected()
    end
end

-- Scroll to keep selected message visible
function DMConversation:scroll_to_selected()
    if not self.selected_msg_index or #self.wrapped_messages == 0 then return end

    -- Find which wrapped message corresponds to our selected index
    local target_line = 0
    for _, wrapped in ipairs(self.wrapped_messages) do
        if wrapped.msg_index == self.selected_msg_index then
            break
        end
        target_line = target_line + #wrapped.lines
    end

    -- Adjust scroll to show the selected message
    if target_line < self.scroll_offset then
        self.scroll_offset = target_line
    elseif target_line >= self.scroll_offset + self.visible_lines then
        self.scroll_offset = target_line - self.visible_lines + 1
    end
end

-- Get the currently selected message
function DMConversation:get_selected_message()
    if not self.selected_msg_index then return nil end
    return self.messages[self.selected_msg_index]
end

function DMConversation:send_message()
    if #self.input_text == 0 then return end

    local text = self.input_text

    if _G.DirectMessages then
        local ok = _G.DirectMessages.send(self.contact_pub_key, text)
        if ok then
            self.input_text = ""
            self.cursor_pos = 0
            self:refresh_messages()
            self.wrapped_messages = {}  -- Rebuild on next render
        else
            if _G.MessageBox then
                _G.MessageBox.show({title = "Failed to send"})
            end
        end
    end
end

-- Menu items for app menu integration
function DMConversation:get_menu_items()
    local self_ref = self
    local items = {}

    -- Note: "Home" is automatically added by AppMenu when deeper than main menu

    table.insert(items, {
        label = "Clear Chat",
        action = function()
            if _G.DirectMessages then
                local pub_key = self_ref.contact_pub_key
                _G.DirectMessages.clear_conversation(pub_key)
            end
            -- Refresh from DirectMessages (now returns empty)
            self_ref:refresh_messages()
            self_ref.scroll_offset = 0
        end
    })

    table.insert(items, {
        label = "Contact Info",
        action = function()
            -- Find contact info and show details
            local node = nil
            if ez.mesh.is_initialized() then
                local nodes = ez.mesh.get_nodes() or {}
                for _, n in ipairs(nodes) do
                    if n.pub_key_hex == self_ref.contact_pub_key then
                        node = n
                        break
                    end
                end
            end

            if node then
                spawn_screen("/scripts/ui/screens/node_details.lua", node)
            else
                if _G.MessageBox then
                    _G.MessageBox.show({
                        title = self_ref.contact_name,
                        subtitle = "Key: " .. self_ref.contact_pub_key:sub(1, 16) .. "..."
                    })
                end
            end
        end
    })

    -- Reset cached route to force flood routing for path discovery
    if _G.DirectMessages then
        local conv = _G.DirectMessages.conversations[self_ref.contact_pub_key]
        local has_path = conv and conv.out_path and #conv.out_path >= 0
        local hop_count = has_path and #conv.out_path or nil

        table.insert(items, {
            label = hop_count and ("Reset Route (" .. hop_count .. " hops)") or "Reset Route",
            action = function()
                if _G.DirectMessages then
                    _G.DirectMessages.reset_route(self_ref.contact_pub_key)
                    if _G.MessageBox then
                        _G.MessageBox.show({
                            title = "Route Reset",
                            subtitle = "Next message will use flood routing"
                        })
                    end
                    ScreenManager.invalidate()
                end
            end
        })
    end

    -- Add context-sensitive items based on selected message
    local selected = self_ref:get_selected_message()
    if selected and _G.DirectMessages then
        if selected.direction == "sent" and not selected.acked then
            -- Sent message not ACKed - offer to request ACK
            table.insert(items, {
                label = "Request ACK",
                action = function()
                    local ok = _G.DirectMessages.request_ack(self_ref.contact_pub_key, selected.counter)
                    if ok and _G.MessageBox then
                        _G.MessageBox.show({title = "ACK Requested", subtitle = "Message #" .. selected.counter})
                    end
                end
            })
        end

        if selected.is_gap then
            -- Gap message - offer to request retry
            table.insert(items, {
                label = "Request Retry",
                action = function()
                    -- Reset failed state to allow retries
                    selected.failed = false
                    selected.gap_retry_count = 0
                    local ok = _G.DirectMessages.request_retry(self_ref.contact_pub_key, selected.counter)
                    if ok and _G.MessageBox then
                        _G.MessageBox.show({title = "Retry Requested", subtitle = "Message #" .. selected.counter})
                    end
                    _G.DirectMessages._save_conversation(self_ref.contact_pub_key)
                    ScreenManager.invalidate()
                end
            })
        end

        -- Retry failed sent message
        if selected.direction == "sent" and selected.failed then
            table.insert(items, {
                label = "Resend Message",
                action = function()
                    -- Reset failed state and retry counters
                    selected.failed = false
                    selected.ack_retry_count = 0
                    selected.sendCount = 0  -- Allow resend
                    selected.sent_at = nil
                    _G.DirectMessages._try_send_message(self_ref.contact_pub_key, selected)
                    if _G.MessageBox then
                        _G.MessageBox.show({title = "Resending", subtitle = "Message #" .. selected.counter})
                    end
                    ScreenManager.invalidate()
                end
            })
        end
    end

    return items
end

return DMConversation
