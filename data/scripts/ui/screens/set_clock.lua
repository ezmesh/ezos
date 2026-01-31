-- Set Clock Screen for T-Deck OS
-- Manual time/date entry

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local TimeSync = {
    title = "Set Clock",

    -- Manual entry state
    manual = {
        year = 2025,
        month = 1,
        day = 1,
        hour = 12,
        minute = 0,
        second = 0,
        field = 1,  -- 1=year, 2=month, 3=day, 4=hour, 5=min, 6=sec, 7=apply button
    },
}

function TimeSync:new()
    local o = {
        title = self.title,
        manual = {
            year = 2025,
            month = 1,
            day = 1,
            hour = 12,
            minute = 0,
            second = 0,
            field = 1,
        },
    }
    setmetatable(o, {__index = TimeSync})
    return o
end

function TimeSync:on_enter()
    -- Get current time if set
    local t = ez.system.get_time()
    if t then
        self.manual.year = t.year
        self.manual.month = t.month
        self.manual.day = t.day
        self.manual.hour = t.hour
        self.manual.minute = t.minute
        self.manual.second = t.second
    end
end

function TimeSync:render(display)
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height

    -- Draw background
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    local start_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31

    -- Current time display
    display.set_font_size("small")
    local t = ez.system.get_time()
    local time_str = "Current: Not set"
    if t then
        time_str = string.format("Current: %04d-%02d-%02d %02d:%02d:%02d",
            t.year, t.month, t.day, t.hour, t.minute, t.second)
    end
    display.draw_text(8, start_y, time_str, colors.TEXT_SECONDARY)

    local y = start_y + 25

    display.set_font_size("medium")
    display.draw_text(8, y, "Set Date & Time:", colors.WHITE)

    y = y + 28

    -- Date row
    local fields = {
        {label = "Year", value = self.manual.year, width = 50},
        {label = "Month", value = self.manual.month, width = 30},
        {label = "Day", value = self.manual.day, width = 30},
    }

    local x = 12
    for i, field in ipairs(fields) do
        local is_selected = (self.manual.field == i)
        local color = is_selected and colors.ACCENT or colors.WHITE

        -- Label
        display.set_font_size("small")
        display.draw_text(x, y, field.label, colors.TEXT_SECONDARY)

        -- Value
        display.set_font_size("medium")
        local val_str = string.format("%02d", field.value)
        if i == 1 then val_str = string.format("%04d", field.value) end

        if is_selected then
            display.fill_round_rect(x - 2, y + 14, field.width + 4, 22, 4, colors.ACCENT)
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
        local color = is_selected and colors.ACCENT or colors.WHITE

        -- Label
        display.set_font_size("small")
        display.draw_text(x, y, field.label, colors.TEXT_SECONDARY)

        -- Value
        display.set_font_size("medium")
        local val_str = string.format("%02d", field.value)

        if is_selected then
            display.fill_round_rect(x - 2, y + 14, field.width + 4, 22, 4, colors.ACCENT)
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
        display.fill_round_rect(w/2 - 50, y, 100, 28, 6, colors.SUCCESS)
        display.draw_text(w/2 - 25, y + 4, "APPLY", colors.BLACK)
    else
        display.draw_round_rect(w/2 - 50, y, 100, 28, 6, colors.WHITE)
        display.draw_text(w/2 - 25, y + 4, "APPLY", colors.WHITE)
    end

    -- Instructions
    display.set_font_size("small")
    display.draw_text(8, h - 16, "UP/DOWN=Adjust  LEFT/RIGHT=Field  ESC=Back", colors.TEXT_SECONDARY)
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

function TimeSync:apply_time()
    local ok = ez.system.set_time(
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
        ez.storage.set_pref("lastTimeSet", ez.system.get_time_unix())
        if _G.MessageBox then
            _G.MessageBox.show({title = "Clock set"})
        end
    else
        if _G.SoundUtils then pcall(_G.SoundUtils.error) end
        if _G.MessageBox then
            _G.MessageBox.show({title = "Failed to set clock"})
        end
    end

    return ok
end

function TimeSync:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

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
            self:apply_time()
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

return TimeSync
