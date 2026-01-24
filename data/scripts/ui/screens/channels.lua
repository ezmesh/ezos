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
    self:refresh_channels()
end

function Channels:refresh_channels()
    self.channels = {}

    if not tdeck.mesh.is_initialized() then
        return
    end

    local raw_channels = tdeck.mesh.get_channels()

    -- Sort: joined first, then by last activity
    table.sort(raw_channels, function(a, b)
        if a.is_joined ~= b.is_joined then
            return a.is_joined
        end
        return (a.last_activity or 0) > (b.last_activity or 0)
    end)

    self.channels = raw_channels
end

function Channels:render(display)
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    if #self.channels == 0 then
        display.draw_text_centered(6 * display.font_height, "No channels yet", colors.TEXT_DIM)
        display.draw_text_centered(8 * display.font_height, "Press [N] to join", colors.TEXT_DIM)
    else
        local y = 2
        for i = 1, self.visible_items do
            local idx = i + self.scroll_offset
            if idx > #self.channels then break end

            local ch = self.channels[idx]
            local is_selected = (idx == self.selected)
            local py = y * display.font_height

            if is_selected then
                display.fill_rect(display.font_width, py,
                                (display.cols - 2) * display.font_width,
                                display.font_height * 2,
                                colors.SELECTION)
                display.draw_text(display.font_width, py, ">", colors.CYAN)
            end

            -- Channel name with indicators
            local lock_icon = ch.is_encrypted and "[E]" or ""
            local join_status = ch.is_joined and "" or "(not joined)"
            local name_line = string.format("%s %s %s", ch.name, lock_icon, join_status)

            local name_color
            if is_selected then
                name_color = colors.CYAN
            elseif ch.is_joined then
                name_color = colors.TEXT
            else
                name_color = colors.TEXT_DIM
            end

            display.draw_text(3 * display.font_width, py, name_line, name_color)

            -- Unread badge
            if ch.unread_count and ch.unread_count > 0 and ch.is_joined then
                local badge = string.format("(%d)", ch.unread_count)
                local badge_x = display.cols - 2 - #badge
                display.draw_text(badge_x * display.font_width, py, badge, colors.ORANGE)
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

            local status_color = is_selected and colors.CYAN or colors.TEXT_DIM
            display.draw_text(3 * display.font_width, py + display.font_height, status_line, status_color)

            y = y + 2
        end

        -- Scroll indicators
        if self.scroll_offset > 0 then
            display.draw_text((display.cols - 1) * display.font_width, 2 * display.font_height,
                            "^", colors.TEXT_DIM)
        end
        if self.scroll_offset + self.visible_items < #self.channels then
            display.draw_text((display.cols - 1) * display.font_width,
                            (2 + self.visible_items * 2 - 1) * display.font_height,
                            "v", colors.TEXT_DIM)
        end
    end

    -- Help bar
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[N]ew [J]oin [Enter]Open [Q]Back", colors.TEXT_DIM)
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
        tdeck.screen.invalidate()
    end
end

function Channels:select_previous()
    if #self.channels == 0 then return end

    if self.selected > 1 then
        self.selected = self.selected - 1
        if self.selected <= self.scroll_offset then
            self.scroll_offset = self.scroll_offset - 1
        end
        tdeck.screen.invalidate()
    end
end

function Channels:open_channel()
    if #self.channels == 0 then return end

    local ch = self.channels[self.selected]
    if ch.is_joined then
        local ChannelView = dofile("/scripts/ui/screens/channel_view.lua")
        tdeck.screen.push(ChannelView:new(ch.name))
    else
        self:join_new_channel()
    end
end

function Channels:join_new_channel()
    local JoinChannel = dofile("/scripts/ui/screens/join_channel.lua")
    tdeck.screen.push(JoinChannel:new())
end

function Channels:toggle_join()
    if #self.channels == 0 then return end

    local ch = self.channels[self.selected]
    if ch.is_joined then
        tdeck.mesh.leave_channel(ch.name)
    else
        if ch.is_encrypted then
            self:join_new_channel()
        else
            tdeck.mesh.join_channel(ch.name)
        end
    end
    self:refresh_channels()
    tdeck.screen.invalidate()
end

return Channels
