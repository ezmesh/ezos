-- Time Sync Screen for T-Deck OS
-- Allows syncing time from mesh nodes or manual entry

local TimeSync = {
    title = "Time Sync",
    mode = "list",  -- "list" for node selection, "manual" for manual entry
    selected = 1,
    scroll_offset = 0,
    VISIBLE_ROWS = 4,
    ROW_HEIGHT = 40,

    -- Collected time sources
    sources = {},

    -- Manual entry state
    manual = {
        year = 2025,
        month = 1,
        day = 1,
        hour = 12,
        minute = 0,
        second = 0,
        field = 1,  -- 1=year, 2=month, 3=day, 4=hour, 5=min, 6=sec
    },

    -- Polling
    last_update = 0,
    UPDATE_INTERVAL = 1000,
}

function TimeSync:new()
    local o = {
        title = self.title,
        mode = "list",
        selected = 1,
        scroll_offset = 0,
        sources = {},
        manual = {
            year = 2025,
            month = 1,
            day = 1,
            hour = 12,
            minute = 0,
            second = 0,
            field = 1,
        },
        last_update = 0,
    }
    setmetatable(o, {__index = TimeSync})
    return o
end

function TimeSync:on_enter()
    -- Initialize sources list with "Manual Entry" option
    self.sources = {
        {name = "Manual Entry", timestamp = 0, is_manual = true}
    }

    -- Get current time if set
    local t = tdeck.system.get_time()
    if t then
        self.manual.year = t.year
        self.manual.month = t.month
        self.manual.day = t.day
        self.manual.hour = t.hour
        self.manual.minute = t.minute
        self.manual.second = t.second
    end

    -- Collect nodes from mesh
    self:refresh_sources()
end

function TimeSync:refresh_sources()
    -- Keep manual entry at top
    local new_sources = {
        {name = "Manual Entry", timestamp = 0, is_manual = true}
    }

    -- Get nodes from mesh
    local nodes = tdeck.mesh.get_nodes()
    if nodes then
        for _, node in ipairs(nodes) do
            -- Only include nodes that have valid Unix timestamps from ADVERT packets
            local advert_ts = node.advert_timestamp or 0
            -- Valid Unix timestamp: after 2020 and before 2100
            if advert_ts > 1577836800 and advert_ts < 4102444800 then
                table.insert(new_sources, {
                    name = node.name or string.format("%02X", node.path_hash),
                    pathHash = node.path_hash,
                    timestamp = advert_ts,
                    rssi = node.rssi,
                    hops = node.hops,
                    age_seconds = node.age_seconds,
                    is_manual = false,
                })
            end
        end
    end

    -- Sort by most recent timestamp (newest first)
    table.sort(new_sources, function(a, b)
        if a.is_manual then return true end
        if b.is_manual then return false end
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)

    self.sources = new_sources
end

function TimeSync:format_timestamp(ts)
    if ts == 0 then
        return "N/A"
    end

    -- Check if this looks like a valid Unix timestamp (after 2020)
    if ts > 1577836800 and ts < 4102444800 then
        -- Valid Unix timestamp - format as date/time
        local t = os.date("*t", ts)
        if t then
            return string.format("%04d-%02d-%02d %02d:%02d",
                t.year, t.month, t.day, t.hour, t.min)
        end
    end

    -- Not a valid Unix timestamp - show as uptime
    local secs = math.floor(ts / 1000)
    local mins = math.floor(secs / 60)
    local hours = math.floor(mins / 60)
    if hours > 0 then
        return string.format("%dh %dm ago", hours, mins % 60)
    elseif mins > 0 then
        return string.format("%dm %ds ago", mins, secs % 60)
    else
        return string.format("%ds ago", secs)
    end
end

function TimeSync:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    -- Draw background
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, w, h, colors.BLACK)
    end

    -- Title bar
    TitleBar.draw(display, self.title)

    local list_start_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31

    if self.mode == "list" then
        self:render_list(display, colors, list_start_y)
    else
        self:render_manual(display, colors, list_start_y)
    end
end

function TimeSync:render_list(display, colors, start_y)
    local w = display.width

    -- Current time header
    display.set_font_size("small")
    local t = tdeck.system.get_time()
    local time_str = "Current: Not set"
    if t then
        time_str = string.format("Current: %04d-%02d-%02d %02d:%02d:%02d",
            t.year, t.month, t.day, t.hour, t.minute, t.second)
    end
    display.draw_text(8, start_y, time_str, colors.TEXT_DIM)

    local list_y = start_y + 20

    -- Draw sources list
    display.set_font_size("medium")
    for i = 0, self.VISIBLE_ROWS - 1 do
        local idx = self.scroll_offset + i + 1
        if idx > #self.sources then break end

        local source = self.sources[idx]
        local y = list_y + i * self.ROW_HEIGHT
        local is_selected = (idx == self.selected)

        -- Selection highlight
        if is_selected then
            display.draw_round_rect(4, y - 2, w - 16, self.ROW_HEIGHT - 4, 6, colors.CYAN)
        end

        -- Source name
        local name_color = is_selected and colors.CYAN or colors.WHITE
        display.draw_text(12, y + 2, source.name, name_color)

        -- Timestamp or info
        display.set_font_size("small")
        local info_color = is_selected and colors.TEXT_DIM or colors.DARK_GRAY
        if source.is_manual then
            display.draw_text(12, y + 20, "Enter time manually", info_color)
        else
            -- Show the corrected time (timestamp + age) that will actually be set
            local corrected_time = source.timestamp + (source.age_seconds or 0)
            local info = self:format_timestamp(corrected_time)
            -- Show how old the ADVERT is for reference
            if source.age_seconds then
                if source.age_seconds < 60 then
                    info = info .. string.format("  (heard %ds ago)", source.age_seconds)
                elseif source.age_seconds < 3600 then
                    info = info .. string.format("  (heard %dm ago)", math.floor(source.age_seconds / 60))
                else
                    info = info .. string.format("  (heard %dh ago)", math.floor(source.age_seconds / 3600))
                end
            end
            display.draw_text(12, y + 20, info, info_color)
        end
        display.set_font_size("medium")
    end

    -- Scrollbar
    if #self.sources > self.VISIBLE_ROWS then
        local sb_x = w - 10
        local sb_top = list_y
        local sb_height = self.VISIBLE_ROWS * self.ROW_HEIGHT - 8

        display.fill_round_rect(sb_x, sb_top, 4, sb_height, 2, colors.DARK_GRAY)

        local thumb_height = math.max(12, math.floor(sb_height * self.VISIBLE_ROWS / #self.sources))
        local scroll_range = #self.sources - self.VISIBLE_ROWS
        local thumb_range = sb_height - thumb_height
        local thumb_y = sb_top + math.floor(self.scroll_offset * thumb_range / math.max(1, scroll_range))

        display.fill_round_rect(sb_x, thumb_y, 4, thumb_height, 2, colors.CYAN)
    end

    -- Instructions
    display.set_font_size("small")
    display.draw_text(8, display.height - 16, "ENTER=Select  ESC=Back  R=Refresh", colors.TEXT_DIM)
end

function TimeSync:render_manual(display, colors, start_y)
    local w = display.width

    display.set_font_size("medium")
    display.draw_text(8, start_y, "Set Time Manually:", colors.WHITE)

    local y = start_y + 30

    -- Date row
    local fields = {
        {label = "Year", value = self.manual.year, width = 50},
        {label = "Month", value = self.manual.month, width = 30},
        {label = "Day", value = self.manual.day, width = 30},
    }

    local x = 12
    for i, field in ipairs(fields) do
        local is_selected = (self.manual.field == i)
        local color = is_selected and colors.CYAN or colors.WHITE

        -- Label
        display.set_font_size("small")
        display.draw_text(x, y, field.label, colors.TEXT_DIM)

        -- Value
        display.set_font_size("medium")
        local val_str = string.format("%02d", field.value)
        if i == 1 then val_str = string.format("%04d", field.value) end

        if is_selected then
            display.fill_round_rect(x - 2, y + 14, field.width + 4, 22, 4, colors.CYAN)
            display.draw_text(x, y + 16, val_str, colors.BLACK)
        else
            display.draw_text(x, y + 16, val_str, color)
        end

        x = x + field.width + 20
    end

    y = y + 55

    -- Time row
    local time_fields = {
        {label = "Hour", value = self.manual.hour, width = 30},
        {label = "Min", value = self.manual.minute, width = 30},
        {label = "Sec", value = self.manual.second, width = 30},
    }

    x = 12
    for i, field in ipairs(time_fields) do
        local field_idx = i + 3
        local is_selected = (self.manual.field == field_idx)
        local color = is_selected and colors.CYAN or colors.WHITE

        -- Label
        display.set_font_size("small")
        display.draw_text(x, y, field.label, colors.TEXT_DIM)

        -- Value
        display.set_font_size("medium")
        local val_str = string.format("%02d", field.value)

        if is_selected then
            display.fill_round_rect(x - 2, y + 14, field.width + 4, 22, 4, colors.CYAN)
            display.draw_text(x, y + 16, val_str, colors.BLACK)
        else
            display.draw_text(x, y + 16, val_str, color)
        end

        x = x + field.width + 20
    end

    -- Apply button
    y = y + 55
    local apply_selected = (self.manual.field == 7)
    if apply_selected then
        display.fill_round_rect(w/2 - 50, y, 100, 28, 6, colors.GREEN)
        display.draw_text(w/2 - 25, y + 4, "APPLY", colors.BLACK)
    else
        display.draw_round_rect(w/2 - 50, y, 100, 28, 6, colors.WHITE)
        display.draw_text(w/2 - 25, y + 4, "APPLY", colors.WHITE)
    end

    -- Instructions
    display.set_font_size("small")
    display.draw_text(8, display.height - 16, "UP/DOWN=Adjust  LEFT/RIGHT=Field  ESC=Back", colors.TEXT_DIM)
end

function TimeSync:adjust_scroll()
    if self.selected <= self.scroll_offset then
        self.scroll_offset = self.selected - 1
    elseif self.selected > self.scroll_offset + self.VISIBLE_ROWS then
        self.scroll_offset = self.selected - self.VISIBLE_ROWS
    end
    self.scroll_offset = math.max(0, self.scroll_offset)
    self.scroll_offset = math.min(#self.sources - self.VISIBLE_ROWS, self.scroll_offset)
end

function TimeSync:get_field_limits(field)
    if field == 1 then return 2020, 2100 end  -- year
    if field == 2 then return 1, 12 end       -- month
    if field == 3 then return 1, 31 end       -- day
    if field == 4 then return 0, 23 end       -- hour
    if field == 5 then return 0, 59 end       -- minute
    if field == 6 then return 0, 59 end       -- second
    return 0, 0
end

function TimeSync:get_field_value(field)
    if field == 1 then return self.manual.year end
    if field == 2 then return self.manual.month end
    if field == 3 then return self.manual.day end
    if field == 4 then return self.manual.hour end
    if field == 5 then return self.manual.minute end
    if field == 6 then return self.manual.second end
    return 0
end

function TimeSync:set_field_value(field, value)
    local min_val, max_val = self:get_field_limits(field)
    value = math.max(min_val, math.min(max_val, value))

    if field == 1 then self.manual.year = value
    elseif field == 2 then self.manual.month = value
    elseif field == 3 then self.manual.day = value
    elseif field == 4 then self.manual.hour = value
    elseif field == 5 then self.manual.minute = value
    elseif field == 6 then self.manual.second = value
    end
end

function TimeSync:apply_manual_time()
    local ok = tdeck.system.set_time(
        self.manual.year,
        self.manual.month,
        self.manual.day,
        self.manual.hour,
        self.manual.minute,
        self.manual.second
    )

    if ok then
        if _G.SoundUtils then pcall(_G.SoundUtils.confirm) end
        -- Save to preferences
        tdeck.storage.set_pref("lastTimeSet", tdeck.system.get_time_unix())
    else
        if _G.SoundUtils then pcall(_G.SoundUtils.error) end
    end

    return ok
end

function TimeSync:apply_source(source)
    if source.is_manual then
        -- Switch to manual entry mode
        self.mode = "manual"
        self.manual.field = 1
        ScreenManager.invalidate()
        return
    end

    -- Check if source has a valid Unix timestamp
    if source.timestamp > 1577836800 and source.timestamp < 4102444800 then
        -- Add the age_seconds to account for time elapsed since the ADVERT was received
        -- The timestamp in the ADVERT is when the node sent it, so we add how long ago we heard it
        local corrected_time = source.timestamp + (source.age_seconds or 0)

        local ok = tdeck.system.set_time_unix(corrected_time)
        if ok then
            if _G.SoundUtils then pcall(_G.SoundUtils.confirm) end
            tdeck.storage.set_pref("lastTimeSet", corrected_time)
        else
            if _G.SoundUtils then pcall(_G.SoundUtils.error) end
        end
    else
        -- Timestamp is not valid Unix time
        if _G.SoundUtils then pcall(_G.SoundUtils.error) end
    end
end

function TimeSync:handle_key(key)
    if key.special == "ESCAPE" then
        if self.mode == "manual" then
            -- Go back to list mode
            self.mode = "list"
            ScreenManager.invalidate()
            return "continue"
        end
        return "pop"
    end

    if self.mode == "list" then
        return self:handle_list_key(key)
    else
        return self:handle_manual_key(key)
    end
end

function TimeSync:handle_list_key(key)
    if key.special == "UP" then
        if self.selected > 1 then
            self.selected = self.selected - 1
            self:adjust_scroll()
            if _G.SoundUtils then pcall(_G.SoundUtils.navigate) end
            ScreenManager.invalidate()
        end

    elseif key.special == "DOWN" then
        if self.selected < #self.sources then
            self.selected = self.selected + 1
            self:adjust_scroll()
            if _G.SoundUtils then pcall(_G.SoundUtils.navigate) end
            ScreenManager.invalidate()
        end

    elseif key.special == "ENTER" or key.character == " " then
        local source = self.sources[self.selected]
        if source then
            self:apply_source(source)
        end
        ScreenManager.invalidate()

    elseif key.character == "r" or key.character == "R" then
        self:refresh_sources()
        if _G.SoundUtils then pcall(_G.SoundUtils.click) end
        ScreenManager.invalidate()
    end

    return "continue"
end

function TimeSync:handle_manual_key(key)
    if key.special == "LEFT" then
        if self.manual.field > 1 then
            self.manual.field = self.manual.field - 1
            if _G.SoundUtils then pcall(_G.SoundUtils.navigate) end
            ScreenManager.invalidate()
        end

    elseif key.special == "RIGHT" then
        if self.manual.field < 7 then
            self.manual.field = self.manual.field + 1
            if _G.SoundUtils then pcall(_G.SoundUtils.navigate) end
            ScreenManager.invalidate()
        end

    elseif key.special == "UP" then
        if self.manual.field <= 6 then
            local current = self:get_field_value(self.manual.field)
            self:set_field_value(self.manual.field, current + 1)
            if _G.SoundUtils then pcall(_G.SoundUtils.navigate) end
            ScreenManager.invalidate()
        end

    elseif key.special == "DOWN" then
        if self.manual.field <= 6 then
            local current = self:get_field_value(self.manual.field)
            self:set_field_value(self.manual.field, current - 1)
            if _G.SoundUtils then pcall(_G.SoundUtils.navigate) end
            ScreenManager.invalidate()
        end

    elseif key.special == "ENTER" or key.character == " " then
        if self.manual.field == 7 then
            -- Apply button
            if self:apply_manual_time() then
                self.mode = "list"
            end
            ScreenManager.invalidate()
        else
            -- Move to next field
            if self.manual.field < 7 then
                self.manual.field = self.manual.field + 1
                ScreenManager.invalidate()
            end
        end
    end

    return "continue"
end

function TimeSync:update()
    -- Periodic refresh
    local now = tdeck.system.millis()
    if now - self.last_update > self.UPDATE_INTERVAL then
        self.last_update = now
        if self.mode == "list" then
            self:refresh_sources()
            ScreenManager.invalidate()
        end
    end
end

return TimeSync
