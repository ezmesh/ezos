-- Messages Screen for T-Deck OS
-- List of direct message conversations

local Messages = {
    title = "Messages",
    selected = 1,
    scroll_offset = 0,
    visible_items = 5,
    conversations = {}
}

function Messages:new()
    local o = {
        title = self.title,
        selected = 1,
        scroll_offset = 0,
        conversations = {}
    }
    setmetatable(o, {__index = Messages})
    return o
end

function Messages:on_enter()
    self:refresh_conversations()
end

function Messages:refresh_conversations()
    self.conversations = {}

    if not tdeck.mesh.is_initialized() then
        return
    end

    -- Get direct messages and group by sender
    local messages = tdeck.mesh.get_direct_messages()
    local nodes = tdeck.mesh.get_nodes()

    -- Create a map for quick node lookup
    local node_map = {}
    for _, node in ipairs(nodes) do
        node_map[node.path_hash] = node.name
    end

    -- Group messages by sender
    local conv_map = {}
    for _, msg in ipairs(messages) do
        local hash = msg.from_hash
        if not conv_map[hash] then
            conv_map[hash] = {
                path_hash = hash,
                name = node_map[hash] or string.format("%02X", hash % 256),
                last_message = msg.text,
                last_timestamp = msg.timestamp,
                unread_count = msg.is_read and 0 or 1
            }
        else
            local conv = conv_map[hash]
            if msg.timestamp > conv.last_timestamp then
                conv.last_message = msg.text
                conv.last_timestamp = msg.timestamp
            end
            if not msg.is_read then
                conv.unread_count = conv.unread_count + 1
            end
        end
    end

    -- Convert map to array and sort by timestamp
    for _, conv in pairs(conv_map) do
        table.insert(self.conversations, conv)
    end

    table.sort(self.conversations, function(a, b)
        return a.last_timestamp > b.last_timestamp
    end)
end

function Messages:format_time(timestamp)
    local now = tdeck.system.millis()
    local diff = math.floor((now - timestamp) / 1000)

    if diff < 60 then
        return "now"
    elseif diff < 3600 then
        return string.format("%dm", math.floor(diff / 60))
    elseif diff < 86400 then
        return string.format("%dh", math.floor(diff / 3600))
    else
        return string.format("%dd", math.floor(diff / 86400))
    end
end

function Messages:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

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
    local fh = display.get_font_height()

    if #self.conversations == 0 then
        display.draw_text_centered(6 * fh, "No messages yet", colors.TEXT_DIM)
        display.draw_text_centered(8 * fh, "Use app menu to compose", colors.TEXT_DIM)
    else
        local y = 2
        for i = 1, self.visible_items do
            local idx = i + self.scroll_offset
            if idx > #self.conversations then break end

            local conv = self.conversations[idx]
            local is_selected = (idx == self.selected)
            local py = y * fh

            if is_selected then
                display.fill_rect(display.font_width, py,
                                (display.cols - 2) * display.font_width,
                                fh * 2,
                                colors.SELECTION)
                -- Draw chevron selection indicator (centered in double-height row)
                local chevron_y = py + math.floor((fh * 2 - 9) / 2)
                if _G.Icons and _G.Icons.draw_chevron_right then
                    _G.Icons.draw_chevron_right(display, display.font_width, chevron_y, colors.CYAN, colors.SELECTION)
                else
                    display.draw_text(display.font_width, py, ">", colors.CYAN)
                end
            end

            -- Name and time
            local name_color
            if is_selected then
                name_color = colors.CYAN
            elseif conv.unread_count > 0 then
                name_color = colors.ORANGE
            else
                name_color = colors.TEXT
            end

            display.draw_text(3 * display.font_width, py, conv.name, name_color)

            -- Time ago
            local time_str = self:format_time(conv.last_timestamp)
            local time_x = display.cols - 2 - #time_str
            display.draw_text(time_x * display.font_width, py, time_str, colors.TEXT_DIM)

            -- Unread badge
            if conv.unread_count > 0 then
                local badge = string.format("(%d)", conv.unread_count)
                local badge_x = time_x - #badge - 1
                display.draw_text(badge_x * display.font_width, py, badge, colors.ORANGE)
            end

            -- Message preview
            local preview_color = is_selected and colors.CYAN or colors.TEXT_DIM
            local max_preview = display.cols - 6
            local preview = conv.last_message
            if #preview > max_preview then
                preview = string.sub(preview, 1, max_preview - 3) .. "..."
            end
            display.draw_text(3 * display.font_width, py + fh, preview, preview_color)

            y = y + 2
        end

        -- Scroll indicators
        if self.scroll_offset > 0 then
            display.draw_text((display.cols - 1) * display.font_width, 2 * fh, "^", colors.TEXT_DIM)
        end
        if self.scroll_offset + self.visible_items < #self.conversations then
            display.draw_text((display.cols - 1) * display.font_width,
                            (2 + self.visible_items * 2 - 1) * fh, "v", colors.TEXT_DIM)
        end
    end
end

function Messages:handle_key(key)
    if key.special == "UP" then
        self:select_previous()
    elseif key.special == "DOWN" then
        self:select_next()
    elseif key.special == "ENTER" then
        self:open_conversation()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    return "continue"
end

function Messages:select_next()
    if #self.conversations == 0 then return end

    if self.selected < #self.conversations then
        self.selected = self.selected + 1
        if self.selected > self.scroll_offset + self.visible_items then
            self.scroll_offset = self.scroll_offset + 1
        end
        ScreenManager.invalidate()
    end
end

function Messages:select_previous()
    if #self.conversations == 0 then return end

    if self.selected > 1 then
        self.selected = self.selected - 1
        if self.selected <= self.scroll_offset then
            self.scroll_offset = self.scroll_offset - 1
        end
        ScreenManager.invalidate()
    end
end

function Messages:open_conversation()
    if #self.conversations == 0 then return end

    local conv = self.conversations[self.selected]
    local ConversationView = load_module("/scripts/ui/screens/conversation_view.lua")
    ScreenManager.push(ConversationView:new(conv.path_hash, conv.name))
end

function Messages:compose_new()
    -- For now, just open broadcast compose
    local Compose = load_module("/scripts/ui/screens/compose.lua")
    ScreenManager.push(Compose:new())
end

-- Menu items for app menu integration
function Messages:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = "Compose",
        action = function()
            self_ref:compose_new()
        end
    })

    table.insert(items, {
        label = "Refresh",
        action = function()
            self_ref:refresh_conversations()
            ScreenManager.invalidate()
        end
    })

    if #self.conversations > 0 then
        table.insert(items, {
            label = "Open",
            action = function()
                self_ref:open_conversation()
            end
        })
    end

    return items
end

return Messages
