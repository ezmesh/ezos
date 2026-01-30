-- Channels Screen for T-Deck OS
-- List and manage mesh channels

local Channels = {
    title = "Channels",
    selected = 1,
    scroll_offset = 0,
    visible_items = 5,
    channels = {}
}

function Channels:new()
    local o = {
        title = self.title,
        selected = 1,
        scroll_offset = 0,
        channels = {}
    }
    setmetatable(o, {__index = Channels})
    return o
end

function Channels:on_enter()
    -- Ensure Channels service is loaded (lazy-load on first use)
    if not _G.Channels then
        _G.Channels = load_module("/scripts/services/channels.lua")
        if _G.Channels and tdeck.mesh.is_initialized() then
            _G.Channels.init()
        end
    end
    self:refresh_channels()
end

function Channels:refresh_channels()
    self.channels = {}

    -- Use global Channels service
    local ChannelsService = _G.Channels
    if not ChannelsService then
        tdeck.system.log("[Channels] Service not available")
        return
    end

    -- Get channels from Lua service (already sorted by last_activity)
    self.channels = ChannelsService.get_all()
end

function Channels:render(display)
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

    if #self.channels == 0 then
        display.draw_text_centered(6 * fh, "No channels yet", colors.TEXT_SECONDARY)
        display.draw_text_centered(8 * fh, "Use app menu to join", colors.TEXT_SECONDARY)
    else
        local y = 2
        for i = 1, self.visible_items do
            local idx = i + self.scroll_offset
            if idx > #self.channels then break end

            local ch = self.channels[idx]
            local is_selected = (idx == self.selected)
            local py = y * fh

            if is_selected then
                display.fill_rect(fw, py, (display.cols - 2) * fw, fh * 2, colors.SURFACE_ALT)
                -- Draw chevron selection indicator (centered in double-height row)
                local chevron_y = py + math.floor((fh * 2 - 9) / 2)
                if _G.Icons and _G.Icons.draw_chevron_right then
                    _G.Icons.draw_chevron_right(display, fw, chevron_y, colors.ACCENT, colors.SURFACE_ALT)
                else
                    display.draw_text(fw, py, ">", colors.ACCENT)
                end
            end

            -- Channel name with indicators
            local lock_icon = ch.is_encrypted and "[E]" or ""
            local join_status = ch.is_joined and "" or "(not joined)"
            local name_line = string.format("%s %s %s", ch.name, lock_icon, join_status)

            local name_color
            if is_selected then
                name_color = colors.ACCENT
            elseif ch.is_joined then
                name_color = colors.TEXT
            else
                name_color = colors.TEXT_SECONDARY
            end

            display.draw_text(3 * fw, py, name_line, name_color)

            -- Unread badge
            if ch.unread_count and ch.unread_count > 0 and ch.is_joined then
                local badge = string.format("(%d)", ch.unread_count)
                local badge_x = display.cols - 2 - #badge
                display.draw_text(badge_x * fw, py, badge, colors.WARNING)
            end

            -- Activity status line
            local status_line
            if ch.last_activity and ch.last_activity > 0 then
                local ago = math.floor((tdeck.system.millis() - ch.last_activity) / 1000)
                if ago < 60 then
                    status_line = "Active now"
                elseif ago < 3600 then
                    status_line = string.format("Active %dm ago", math.floor(ago / 60))
                else
                    status_line = string.format("Active %dh ago", math.floor(ago / 3600))
                end
            else
                status_line = "No activity"
            end

            local status_color = is_selected and colors.ACCENT or colors.TEXT_SECONDARY
            display.draw_text(3 * fw, py + fh, status_line, status_color)

            y = y + 2
        end

        -- Scroll indicators
        if self.scroll_offset > 0 then
            display.draw_text((display.cols - 1) * fw, 2 * fh, "^", colors.TEXT_SECONDARY)
        end
        if self.scroll_offset + self.visible_items < #self.channels then
            display.draw_text((display.cols - 1) * fw, (2 + self.visible_items * 2 - 1) * fh, "v", colors.TEXT_SECONDARY)
        end
    end
end

function Channels:handle_key(key)
    if key.special == "UP" then
        self:select_previous()
    elseif key.special == "DOWN" then
        self:select_next()
    elseif key.special == "ENTER" then
        self:open_channel()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "n" then
        self:join_new_channel()
    elseif key.character == "j" then
        self:toggle_join()
    end

    return "continue"
end

function Channels:select_next()
    if #self.channels == 0 then return end

    if self.selected < #self.channels then
        self.selected = self.selected + 1
        if self.selected > self.scroll_offset + self.visible_items then
            self.scroll_offset = self.scroll_offset + 1
        end
        ScreenManager.invalidate()
    end
end

function Channels:select_previous()
    if #self.channels == 0 then return end

    if self.selected > 1 then
        self.selected = self.selected - 1
        if self.selected <= self.scroll_offset then
            self.scroll_offset = self.scroll_offset - 1
        end
        ScreenManager.invalidate()
    end
end

function Channels:open_channel()
    if #self.channels == 0 then return end

    local ch = self.channels[self.selected]
    if ch.is_joined then
        local ch_name = ch.name
        spawn(function()
            local ok, ChannelView = pcall(load_module, "/scripts/ui/screens/channel_view.lua")
            if ok and ChannelView then
                ScreenManager.push(ChannelView:new(ch_name))
            end
        end)
    else
        self:join_new_channel()
    end
end

function Channels:join_new_channel()
    spawn(function()
        local ok, JoinChannel = pcall(load_module, "/scripts/ui/screens/join_channel.lua")
        if ok and JoinChannel then
            ScreenManager.push(JoinChannel:new())
        end
    end)
end

function Channels:toggle_join()
    if #self.channels == 0 then return end

    local ChannelsService = _G.Channels
    if not ChannelsService then return end

    local ch = self.channels[self.selected]
    if ch.is_joined then
        ChannelsService.leave(ch.name)
    else
        if ch.is_encrypted then
            self:join_new_channel()
        else
            ChannelsService.join(ch.name)
        end
    end
    self:refresh_channels()
    ScreenManager.invalidate()
end

-- Menu items for app menu integration
function Channels:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = "Join New",
        action = function()
            self_ref:join_new_channel()
        end
    })

    table.insert(items, {
        label = "Refresh",
        action = function()
            self_ref:refresh_channels()
            ScreenManager.invalidate()
        end
    })

    if #self.channels > 0 then
        local ch = self.channels[self.selected]
        if ch then
            if ch.is_joined then
                table.insert(items, {
                    label = "Leave",
                    action = function()
                        self_ref:toggle_join()
                    end
                })

                table.insert(items, {
                    label = "Open",
                    action = function()
                        self_ref:open_channel()
                    end
                })
            else
                table.insert(items, {
                    label = "Join",
                    action = function()
                        self_ref:toggle_join()
                    end
                })
            end
        end
    end

    return items
end

return Channels
