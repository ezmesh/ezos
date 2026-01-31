-- Conversation View Screen for T-Deck OS
-- View direct messages with a specific node

local TextUtils = load_module("/scripts/ui/text_utils.lua")

local ConversationView = {
    title = "",
    path_hash = 0,
    node_name = "",
    messages = {},
    scroll_offset = 0,
    visible_lines = 9
}

function ConversationView:new(path_hash, node_name)
    local o = {
        title = node_name,
        path_hash = path_hash,
        node_name = node_name,
        messages = {},
        scroll_offset = 0
    }
    setmetatable(o, {__index = ConversationView})
    return o
end

function ConversationView:on_enter()
    self:refresh_messages()
end

function ConversationView:refresh_messages()
    self.messages = {}

    if not ez.mesh.is_initialized() then
        return
    end

    local all_messages = ez.mesh.get_direct_messages()

    -- Filter messages for this conversation
    for _, msg in ipairs(all_messages) do
        if msg.from_hash == self.path_hash then
            table.insert(self.messages, msg)
        end
    end

    -- Sort by timestamp (oldest first)
    table.sort(self.messages, function(a, b)
        return a.timestamp < b.timestamp
    end)

    -- Scroll to bottom
    if #self.messages > self.visible_lines then
        self.scroll_offset = #self.messages - self.visible_lines
    end
end

function ConversationView:render(display)
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
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    if #self.messages == 0 then
        display.draw_text_centered(6 * fh, "No messages", colors.TEXT_SECONDARY)
    else
        local y = 2
        local max_y = 2 + self.visible_lines
        local idx = self.scroll_offset + 1

        while y < max_y and idx <= #self.messages do
            local msg = self.messages[idx]
            local py = y * fh

            -- Sender short ID
            local short_id = string.format("%02X", msg.from_hash % 256)
            display.draw_text(fw, py, short_id, colors.TEXT_SECONDARY)
            display.draw_text(4 * fw, py, ":", colors.TEXT_SECONDARY)

            -- Message text (truncated using pixel measurement)
            local max_text_px = display.width - (8 * fw)
            local text = TextUtils.truncate(msg.text, max_text_px, display)
            display.draw_text(6 * fw, py, text, colors.TEXT)

            y = y + 1
            idx = idx + 1
        end

        -- Scroll indicators
        if self.scroll_offset > 0 then
            display.draw_text((display.cols - 1) * fw, 2 * fh, "^", colors.ACCENT)
        end
        if self.scroll_offset + self.visible_lines < #self.messages then
            display.draw_text((display.cols - 1) * fw, (max_y - 1) * fh, "v", colors.ACCENT)
        end
    end
end

function ConversationView:handle_key(key)
    if key.special == "UP" then
        self:scroll_up()
    elseif key.special == "DOWN" then
        self:scroll_down()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "r" then
        self:reply()
    end

    return "continue"
end

function ConversationView:scroll_up()
    if self.scroll_offset > 0 then
        self.scroll_offset = self.scroll_offset - 1
        ScreenManager.invalidate()
    end
end

function ConversationView:scroll_down()
    if self.scroll_offset + self.visible_lines < #self.messages then
        self.scroll_offset = self.scroll_offset + 1
        ScreenManager.invalidate()
    end
end

function ConversationView:reply()
    spawn_screen("/scripts/ui/screens/compose.lua")
end

return ConversationView
