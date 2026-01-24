-- Conversation View Screen for T-Deck OS
-- View direct messages with a specific node

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

    if not tdeck.mesh.is_initialized() then
        return
    end

    local all_messages = tdeck.mesh.get_direct_messages()

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
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    if #self.messages == 0 then
        display.draw_text_centered(6 * display.font_height, "No messages", colors.TEXT_DIM)
    else
        local y = 2
        local max_y = 2 + self.visible_lines
        local idx = self.scroll_offset + 1

        while y < max_y and idx <= #self.messages do
            local msg = self.messages[idx]
            local py = y * display.font_height

            -- Sender short ID
            local short_id = string.format("%02X", msg.from_hash % 256)
            display.draw_text(display.font_width, py, short_id, colors.TEXT_DIM)
            display.draw_text(4 * display.font_width, py, ":", colors.TEXT_DIM)

            -- Message text (truncated)
            local max_text = display.cols - 8
            local text = msg.text
            if #text > max_text then
                text = string.sub(text, 1, max_text - 3) .. "..."
            end
            display.draw_text(6 * display.font_width, py, text, colors.TEXT)

            y = y + 1
            idx = idx + 1
        end

        -- Scroll indicators
        if self.scroll_offset > 0 then
            display.draw_text((display.cols - 1) * display.font_width,
                            2 * display.font_height, "^", colors.CYAN)
        end
        if self.scroll_offset + self.visible_lines < #self.messages then
            display.draw_text((display.cols - 1) * display.font_width,
                            (max_y - 1) * display.font_height, "v", colors.CYAN)
        end
    end

    -- Help bar
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[R]eply [Q]Back", colors.TEXT_DIM)
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
        tdeck.screen.invalidate()
    end
end

function ConversationView:scroll_down()
    if self.scroll_offset + self.visible_lines < #self.messages then
        self.scroll_offset = self.scroll_offset + 1
        tdeck.screen.invalidate()
    end
end

function ConversationView:reply()
    local Compose = dofile("/scripts/ui/screens/compose.lua")
    tdeck.screen.push(Compose:new())
end

return ConversationView
