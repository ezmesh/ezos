-- Messages Screen for T-Deck OS
-- List of direct message conversations

local Messages = {
    title = "Messages",
    selected = 1,
    scroll_offset = 0,
    visible_items = 5,
    conversations = {},
    -- Auto-refresh tracking
    last_refresh = 0,
    refresh_interval = 1000,  -- Check every 1 second
    needs_refresh = false,
    last_count = 0,
    last_unread = 0,
}

function Messages:new()
    local o = {
        title = self.title,
        selected = 1,
        scroll_offset = 0,
        conversations = {},
        last_refresh = 0,
        refresh_interval = 1000,
        needs_refresh = false,
        last_count = 0,
        last_unread = 0,
    }
    setmetatable(o, {__index = Messages})
    return o
end

function Messages:on_enter()
    self:refresh_conversations()
    -- Store initial counts for change detection
    self.last_count = #self.conversations
    self.last_unread = self:_count_unread()
end

-- Force refresh on next render (called externally when messages arrive)
function Messages:mark_needs_refresh()
    self.needs_refresh = true
end

-- Count total unread messages across all conversations
function Messages:_count_unread()
    local total = 0
    for _, conv in ipairs(self.conversations) do
        total = total + (conv.unread_count or 0)
    end
    return total
end

-- Check for new conversations or messages (called during render)
function Messages:check_new_conversations()
    local now = tdeck.system.millis()
    local force = self.needs_refresh
    self.needs_refresh = false

    -- Throttle unless forced
    if not force and (now - self.last_refresh < self.refresh_interval) then
        return false
    end
    self.last_refresh = now

    if not _G.DirectMessages then return false end

    -- Get current state
    local current_convs = _G.DirectMessages.get_conversations()
    local current_count = #current_convs
    local current_unread = 0
    for _, conv in ipairs(current_convs) do
        current_unread = current_unread + (conv.unread_count or 0)
    end

    -- Check if anything changed
    local changed = force or
                    current_count ~= self.last_count or
                    current_unread ~= self.last_unread

    if changed then
        self:refresh_conversations()
        self.last_count = #self.conversations
        self.last_unread = self:_count_unread()
        return true
    end
    return false
end

function Messages:refresh_conversations()
    self.conversations = {}

    -- Use DirectMessages service if available
    if _G.DirectMessages then
        self.conversations = _G.DirectMessages.get_conversations()
        return
    end

    -- Fallback: no DirectMessages service
    if not tdeck.mesh.is_initialized() then
        return
    end
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

    -- Check for new conversations or messages
    self:check_new_conversations()

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
        display.draw_text_centered(6 * fh, "No messages yet", colors.TEXT_SECONDARY)
        display.draw_text_centered(8 * fh, "Use app menu to compose", colors.TEXT_SECONDARY)
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
                                colors.SURFACE_ALT)
                -- Draw chevron selection indicator (centered in double-height row)
                local chevron_y = py + math.floor((fh * 2 - 9) / 2)
                if _G.Icons and _G.Icons.draw_chevron_right then
                    _G.Icons.draw_chevron_right(display, display.font_width, chevron_y, colors.ACCENT, colors.SURFACE_ALT)
                else
                    display.draw_text(display.font_width, py, ">", colors.ACCENT)
                end
            end

            -- Name and time
            local name_color
            if is_selected then
                name_color = colors.ACCENT
            elseif conv.unread_count > 0 then
                name_color = colors.WARNING
            else
                name_color = colors.TEXT
            end

            display.draw_text(3 * display.font_width, py, conv.name, name_color)

            -- Unread badge (right-aligned)
            if conv.unread_count > 0 then
                local badge = string.format("(%d)", conv.unread_count)
                local badge_x = display.cols - 2 - #badge
                display.draw_text(badge_x * display.font_width, py, badge, colors.WARNING)
            end

            -- Message preview
            local preview_color = is_selected and colors.ACCENT or colors.TEXT_SECONDARY
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
            display.draw_text((display.cols - 1) * display.font_width, 2 * fh, "^", colors.TEXT_SECONDARY)
        end
        if self.scroll_offset + self.visible_items < #self.conversations then
            display.draw_text((display.cols - 1) * display.font_width,
                            (2 + self.visible_items * 2 - 1) * fh, "v", colors.TEXT_SECONDARY)
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
    local pub_key_hex = conv.pub_key_hex
    local name = conv.name

    load_module_async("/scripts/ui/screens/dm_conversation.lua", function(DMConversation, err)
        if DMConversation then
            ScreenManager.push(DMConversation:new(pub_key_hex, name))
        end
    end)
end

function Messages:compose_new()
    -- Open contacts screen to select who to message
    load_module_async("/scripts/ui/screens/contacts.lua", function(ContactsScreen, err)
        if ContactsScreen then
            ScreenManager.push(ContactsScreen:new())
            if _G.MessageBox then
                _G.MessageBox.show({title = "Select a contact", subtitle = "Press M to message"})
            end
        end
    end)
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
