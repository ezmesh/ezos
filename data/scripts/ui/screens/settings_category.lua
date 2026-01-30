-- Settings Category Screen for T-Deck OS
-- Displays settings within a specific category

local SettingsCategory = {
    VISIBLE_ROWS = 4,
    ROW_HEIGHT = 46,
}

-- POSIX TZ string mapping for each timezone option
SettingsCategory.TIMEZONE_POSIX = {
    -- UTC
    ["UTC"] = "UTC0",
    -- Europe (CET = Central European Time, CEST = Central European Summer Time)
    ["London"] = "GMT0BST,M3.5.0/1,M10.5.0",
    ["Amsterdam"] = "CET-1CEST,M3.5.0,M10.5.0/3",
    ["Berlin"] = "CET-1CEST,M3.5.0,M10.5.0/3",
    ["Paris"] = "CET-1CEST,M3.5.0,M10.5.0/3",
    ["Madrid"] = "CET-1CEST,M3.5.0,M10.5.0/3",
    ["Rome"] = "CET-1CEST,M3.5.0,M10.5.0/3",
    ["Helsinki"] = "EET-2EEST,M3.5.0/3,M10.5.0/4",
    ["Athens"] = "EET-2EEST,M3.5.0/3,M10.5.0/4",
    ["Moscow"] = "MSK-3",
    -- Middle East / Africa
    ["Cairo"] = "EET-2",
    ["Jerusalem"] = "IST-2IDT,M3.4.4/26,M10.5.0",
    ["Dubai"] = "GST-4",
    ["Nairobi"] = "EAT-3",
    ["Lagos"] = "WAT-1",
    ["Johannesburg"] = "SAST-2",
    -- Asia
    ["Mumbai"] = "IST-5:30",
    ["Karachi"] = "PKT-5",
    ["Almaty"] = "ALMT-6",
    ["Bangkok"] = "ICT-7",
    ["Jakarta"] = "WIB-7",
    ["Singapore"] = "SGT-8",
    ["Hong Kong"] = "HKT-8",
    ["Shanghai"] = "CST-8",
    ["Manila"] = "PHT-8",
    ["Tokyo"] = "JST-9",
    ["Seoul"] = "KST-9",
    -- Oceania
    ["Perth"] = "AWST-8",
    ["Sydney"] = "AEST-10AEDT,M10.1.0,M4.1.0/3",
    ["Brisbane"] = "AEST-10",
    ["Auckland"] = "NZST-12NZDT,M9.5.0,M4.1.0/3",
    -- Americas (note: POSIX uses + for west of UTC)
    ["Anchorage"] = "AKST9AKDT,M3.2.0,M11.1.0",
    ["Los Angeles"] = "PST8PDT,M3.2.0,M11.1.0",
    ["Denver"] = "MST7MDT,M3.2.0,M11.1.0",
    ["Chicago"] = "CST6CDT,M3.2.0,M11.1.0",
    ["New York"] = "EST5EDT,M3.2.0,M11.1.0",
    ["Toronto"] = "EST5EDT,M3.2.0,M11.1.0",
    ["Halifax"] = "AST4ADT,M3.2.0,M11.1.0",
    ["Sao Paulo"] = "BRT3BRST,M10.3.0/0,M2.3.0/0",
    ["Buenos Aires"] = "ART3"
}

-- All settings organized by category
SettingsCategory.ALL_SETTINGS = {
    radio = {
        {name = "node_name", label = "Node Name", value = "MeshNode", type = "text", icon = "contacts"},
        {name = "region", label = "Region", value = 1, type = "option", options = {"EU868", "US915", "AU915", "AS923"}, icon = "channels"},
        {name = "tx_power", label = "TX Power", value = 22, type = "number", min = 0, max = 22, suffix = " dBm", icon = "channels"},
        {name = "ttl", label = "TTL", value = 3, type = "number", min = 1, max = 10, suffix = " hops", icon = "channels"},
        {name = "path_check", label = "Path Check", value = true, type = "toggle", icon = "channels"},
    },
    display = {
        {name = "brightness", label = "Display", value = 200, type = "number", min = 25, max = 255, step = 25, suffix = "%", scale = 100/255, icon = "info"},
        {name = "kb_backlight", label = "KB Light", value = 0, type = "number", min = 0, max = 255, step = 25, suffix = "%", scale = 100/255, icon = "info"},
        {name = "wallpaper", label = "Wallpaper", value = 1, type = "option", options = {"Solid", "Grid", "Dots", "Dense", "H-Lines", "V-Lines", "Diag"}, icon = "settings"},
        {name = "color_theme", label = "Colors", value = 1, type = "option", options = {
            "Default", "Amber", "Ocean", "Sunset", "Forest", "Midnight",
            "Cyberpunk", "Cherry", "Aurora", "Coral", "Volcano", "Arctic",
            "JF", "Daylight", "Latte", "Mint", "Lavender", "Peach",
            "Cream", "Sky", "Rose", "Sage"
        }, icon = "settings"},
        {name = "wallpaper_tint", label = "Wallpaper Tint", value = "", type = "button", icon = "settings"},
        {name = "screen_dim_timeout", label = "Dim After", value = 5, type = "option", options = {"Off", "1 min", "2 min", "5 min", "10 min", "15 min"}, icon = "info"},
        {name = "screen_off_timeout", label = "Off After", value = 4, type = "option", options = {"Off", "5 min", "10 min", "15 min", "30 min"}, icon = "info"},
    },
    time = {
        {name = "time_format", label = "Time", value = 1, type = "option", options = {"24h", "12h AM/PM"}, icon = "info"},
        {name = "timezone", label = "Timezone", value = 1, type = "option", options = {
            "UTC",
            "London", "Amsterdam", "Berlin", "Paris", "Madrid", "Rome",
            "Helsinki", "Athens", "Moscow",
            "Cairo", "Jerusalem", "Dubai", "Nairobi", "Lagos", "Johannesburg",
            "Mumbai", "Karachi", "Almaty", "Bangkok", "Jakarta", "Singapore",
            "Hong Kong", "Shanghai", "Manila", "Tokyo", "Seoul",
            "Perth", "Sydney", "Brisbane", "Auckland",
            "Anchorage", "Los Angeles", "Denver", "Chicago", "New York",
            "Toronto", "Halifax", "Sao Paulo", "Buenos Aires"
        }, icon = "info"},
        {name = "time_sync", label = "Set Clock", value = "", type = "button", icon = "info"},
        {name = "auto_time_sync", label = "Auto Clock Sync", value = true, type = "toggle", icon = "info"},
    },
    input = {
        {name = "trackball", label = "Trackball Sens", value = 1, type = "number", min = 1, max = 10, suffix = "", icon = "settings"},
        {name = "trackball_mode", label = "Trackball Mode", value = 1, type = "option", options = {"Polling", "Interrupt"}, icon = "settings"},
    },
    sound = {
        {name = "ui_sounds", label = "UI Sounds", value = false, type = "toggle", icon = "settings"},
        {name = "ui_sounds_vol", label = "Sound Vol", value = 50, type = "number", min = 0, max = 100, step = 10, suffix = "%", icon = "settings"},
    },
    map = {
        {name = "map_invert_colors", label = "Invert Colors", value = true, type = "toggle", icon = "map"},
        {name = "map_pan_speed", label = "Pan Speed", value = 2, type = "number", min = 1, max = 5, suffix = "", icon = "map"},
    },
    system = {
        {name = "menu_hotkey", label = "Menu Hotkey", value = "", type = "button", icon = "settings"},
        {name = "usb", label = "USB Transfer", value = "", type = "button", icon = "files"},
    }
}

-- Safe sound helper
local function play_sound(name)
    if _G.SoundUtils and _G.SoundUtils[name] then
        pcall(_G.SoundUtils[name])
    end
end

function SettingsCategory:new(category_key, category_title)
    local o = {
        title = category_title or "Settings",
        category_key = category_key,
        selected = 1,
        scroll_offset = 0,
        editing = false,
        settings = {}
    }

    -- Deep copy settings for this category
    local template = SettingsCategory.ALL_SETTINGS[category_key] or {}
    for i, s in ipairs(template) do
        o.settings[i] = {
            name = s.name,
            label = s.label,
            value = s.value,
            type = s.type,
            options = s.options,
            min = s.min,
            max = s.max,
            step = s.step,
            suffix = s.suffix,
            scale = s.scale,
            icon = s.icon
        }
    end

    setmetatable(o, {__index = SettingsCategory})
    return o
end

function SettingsCategory:on_enter()
    if not _G.Icons then
        _G.Icons = dofile("/scripts/ui/icons.lua")
    end
    self:load_settings()
end

function SettingsCategory:load_settings()
    local function get_pref(key, default)
        if tdeck.storage and tdeck.storage.get_pref then
            return tdeck.storage.get_pref(key, default)
        end
        return default
    end

    for _, setting in ipairs(self.settings) do
        if setting.name == "node_name" then
            setting.value = get_pref("nodeName", "MeshNode")
        elseif setting.name == "region" then
            -- Ensure region is a valid number index (1-4)
            local region = tonumber(get_pref("region", 1)) or 1
            if region < 1 or region > 4 then region = 1 end
            setting.value = region
        elseif setting.name == "tx_power" then
            setting.value = tonumber(get_pref("txPower", 22)) or 22
        elseif setting.name == "ttl" then
            setting.value = tonumber(get_pref("ttl", 3)) or 3
        elseif setting.name == "path_check" then
            setting.value = get_pref("pathCheck", true)
        elseif setting.name == "brightness" then
            setting.value = tonumber(get_pref("brightness", 200)) or 200
        elseif setting.name == "kb_backlight" then
            setting.value = tonumber(get_pref("kbBacklight", 0)) or 0
        elseif setting.name == "wallpaper" then
            if _G.ThemeManager then
                setting.value = _G.ThemeManager.get_wallpaper_index()
            end
        elseif setting.name == "color_theme" then
            if _G.ThemeManager then
                setting.value = _G.ThemeManager.get_color_theme_index()
            end
        elseif setting.name == "time_format" then
            setting.value = tonumber(get_pref("timeFormat", 1)) or 1
        elseif setting.name == "timezone" then
            setting.value = tonumber(get_pref("timezone", 1)) or 1
        elseif setting.name == "auto_time_sync" then
            setting.value = get_pref("autoTimeSyncContacts", true)
        elseif setting.name == "trackball" then
            setting.value = tonumber(get_pref("tbSens", 1)) or 1
        elseif setting.name == "trackball_mode" then
            -- 1 = Polling, 2 = Interrupt
            local mode = get_pref("tbMode", "polling")
            setting.value = (mode == "interrupt") and 2 or 1
        elseif setting.name == "ui_sounds" then
            setting.value = get_pref("uiSoundsEnabled", false)
        elseif setting.name == "ui_sounds_vol" then
            setting.value = tonumber(get_pref("uiSoundsVolume", 50)) or 50
        elseif setting.name == "map_invert_colors" then
            setting.value = get_pref("mapInvertColors", true)
        elseif setting.name == "map_pan_speed" then
            setting.value = tonumber(get_pref("mapPanSpeed", 2)) or 2
        elseif setting.name == "screen_dim_timeout" then
            -- Convert minutes to option index: Off=1, 1=2, 2=3, 5=4, 10=5, 15=6
            local mins = tonumber(get_pref("screenDimTimeout", 5)) or 5
            if mins == 0 then setting.value = 1
            elseif mins == 1 then setting.value = 2
            elseif mins == 2 then setting.value = 3
            elseif mins == 5 then setting.value = 4
            elseif mins == 10 then setting.value = 5
            else setting.value = 6 end
        elseif setting.name == "screen_off_timeout" then
            -- Convert minutes to option index: Off=1, 5=2, 10=3, 15=4, 30=5
            local mins = tonumber(get_pref("screenOffTimeout", 10)) or 10
            if mins == 0 then setting.value = 1
            elseif mins == 5 then setting.value = 2
            elseif mins == 10 then setting.value = 3
            elseif mins == 15 then setting.value = 4
            else setting.value = 5 end
        end
    end
end

function SettingsCategory:save_setting(setting)
    local function set_pref(key, value)
        if tdeck.storage and tdeck.storage.set_pref then
            tdeck.storage.set_pref(key, value)
        end
    end

    if setting.name == "node_name" then
        set_pref("nodeName", setting.value)
    elseif setting.name == "region" then
        set_pref("region", setting.value)
    elseif setting.name == "tx_power" then
        set_pref("txPower", setting.value)
    elseif setting.name == "ttl" then
        set_pref("ttl", setting.value)
    elseif setting.name == "path_check" then
        set_pref("pathCheck", setting.value)
    elseif setting.name == "brightness" then
        set_pref("brightness", setting.value)
    elseif setting.name == "kb_backlight" then
        set_pref("kbBacklight", setting.value)
    elseif setting.name == "time_format" then
        set_pref("timeFormat", setting.value)
    elseif setting.name == "timezone" then
        set_pref("timezone", setting.value)
        local tz_name = setting.options[setting.value]
        local tz_posix = SettingsCategory.TIMEZONE_POSIX[tz_name]
        if tz_posix then
            set_pref("timezonePosix", tz_posix)
        end
    elseif setting.name == "auto_time_sync" then
        set_pref("autoTimeSyncContacts", setting.value)
    elseif setting.name == "trackball" then
        set_pref("tbSens", setting.value)
    elseif setting.name == "trackball_mode" then
        -- 1 = Polling, 2 = Interrupt
        local mode = (setting.value == 2) and "interrupt" or "polling"
        set_pref("tbMode", mode)
    elseif setting.name == "ui_sounds" then
        set_pref("uiSoundsEnabled", setting.value)
    elseif setting.name == "ui_sounds_vol" then
        set_pref("uiSoundsVolume", setting.value)
    elseif setting.name == "map_invert_colors" then
        set_pref("mapInvertColors", setting.value)
    elseif setting.name == "map_pan_speed" then
        set_pref("mapPanSpeed", setting.value)
    elseif setting.name == "screen_dim_timeout" then
        -- Convert option index to minutes: Off=0, 1=1, 2=2, 5=5, 10=10, 15=15
        local mins_map = {0, 1, 2, 5, 10, 15}
        set_pref("screenDimTimeout", mins_map[setting.value] or 5)
    elseif setting.name == "screen_off_timeout" then
        -- Convert option index to minutes: Off=0, 5=5, 10=10, 15=15, 30=30
        local mins_map = {0, 5, 10, 15, 30}
        set_pref("screenOffTimeout", mins_map[setting.value] or 10)
    end
end

function SettingsCategory:get_display_value(setting)
    if setting.type == "text" then
        return setting.value
    elseif setting.type == "option" then
        return setting.options[setting.value] or "?"
    elseif setting.type == "number" then
        local val = setting.value
        if setting.scale then
            val = math.floor(val * setting.scale)
        end
        return tostring(val) .. (setting.suffix or "")
    elseif setting.type == "toggle" then
        return setting.value and "On" or "Off"
    elseif setting.type == "button" then
        return ">"
    end
    return ""
end

function SettingsCategory:adjust_scroll()
    if self.selected <= self.scroll_offset then
        self.scroll_offset = self.selected - 1
    elseif self.selected > self.scroll_offset + self.VISIBLE_ROWS then
        self.scroll_offset = self.selected - self.VISIBLE_ROWS
    end
    -- Clamp scroll_offset: must be >= 0 and account for categories with fewer items than visible rows
    local max_scroll = math.max(0, #self.settings - self.VISIBLE_ROWS)
    self.scroll_offset = math.max(0, math.min(max_scroll, self.scroll_offset))
end

function SettingsCategory:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, w, h, colors.BLACK)
    end

    TitleBar.draw(display, self.title)

    local list_start_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31
    local icon_margin = 12
    local icon_size = 24
    local text_x = icon_margin + icon_size + 10
    local scrollbar_width = 8

    for i = 0, self.VISIBLE_ROWS - 1 do
        local item_idx = self.scroll_offset + i + 1
        if item_idx > #self.settings then break end

        local setting = self.settings[item_idx]
        if not setting then break end

        local y = list_start_y + i * self.ROW_HEIGHT
        local is_selected = (item_idx == self.selected)

        if is_selected then
            local outline_color = self.editing and colors.WARNING or colors.ACCENT
            display.draw_round_rect(4, y - 1, w - 12 - scrollbar_width, self.ROW_HEIGHT - 6, 6, outline_color)
        end

        local icon_y = y + (self.ROW_HEIGHT - icon_size) / 2 - 4
        local icon_color = is_selected and colors.ACCENT or colors.WHITE
        if setting.icon and _G.Icons then
            _G.Icons.draw(setting.icon, display, icon_margin, icon_y, icon_size, icon_color)
        end

        display.set_font_size("medium")
        local label_color = is_selected and colors.ACCENT or colors.WHITE
        local label_y = y + 4
        display.draw_text(text_x, label_y, setting.label, label_color)

        local value_str = self:get_display_value(setting)

        if setting.type ~= "button" then
            local value_width = display.text_width(value_str)
            local fh = display.get_font_height()
            local chevron_size = 9
            local chevron_pad = 4

            if self.editing and is_selected and setting.type ~= "text" then
                local total_width = chevron_size + chevron_pad + value_width + chevron_pad + chevron_size
                local value_x = w - scrollbar_width - 16 - total_width

                local bg_pad = 2
                display.fill_rect(value_x - bg_pad, label_y - bg_pad,
                                 total_width + bg_pad * 2, fh + bg_pad * 2,
                                 colors.SURFACE_ALT)

                local chevron_y = label_y + math.floor((fh - chevron_size) / 2)
                if _G.Icons and _G.Icons.draw_chevron_left then
                    _G.Icons.draw_chevron_left(display, value_x, chevron_y, colors.WARNING, colors.SURFACE_ALT)
                else
                    display.draw_text(value_x, label_y, "<", colors.WARNING)
                end

                local text_x_val = value_x + chevron_size + chevron_pad
                display.draw_text(text_x_val, label_y, value_str, colors.WARNING)

                local right_chevron_x = text_x_val + value_width + chevron_pad
                if _G.Icons and _G.Icons.draw_chevron_right then
                    _G.Icons.draw_chevron_right(display, right_chevron_x, chevron_y, colors.WARNING, colors.SURFACE_ALT)
                else
                    display.draw_text(right_chevron_x, label_y, ">", colors.WARNING)
                end
            else
                local value_x = w - scrollbar_width - 16 - value_width
                local value_color = is_selected and colors.ACCENT or colors.TEXT
                display.draw_text(value_x, label_y, value_str, value_color)
            end
        end

        display.set_font_size("small")
        local desc_color = is_selected and colors.TEXT_SECONDARY or colors.TEXT_MUTED
        local desc_y = y + 4 + 18
        local desc = ""
        if setting.type == "number" then
            desc = string.format("Range: %d - %d", setting.min or 0, setting.max or 100)
        elseif setting.type == "option" then
            desc = string.format("Option %d of %d", setting.value, #setting.options)
        elseif setting.type == "toggle" then
            desc = "Toggle on/off"
        elseif setting.type == "button" then
            desc = "Press Enter"
        elseif setting.type == "text" then
            desc = "Text input"
        end
        display.draw_text(text_x, desc_y, desc, desc_color)
    end

    display.set_font_size("medium")

    if #self.settings > self.VISIBLE_ROWS then
        local sb_x = w - scrollbar_width - 2
        local sb_top = list_start_y
        local sb_height = self.VISIBLE_ROWS * self.ROW_HEIGHT - 6

        display.fill_rect(sb_x, sb_top, 4, sb_height, colors.SURFACE)

        local thumb_height = math.max(12, math.floor(sb_height * self.VISIBLE_ROWS / #self.settings))
        local scroll_range = #self.settings - self.VISIBLE_ROWS
        local thumb_range = sb_height - thumb_height
        local thumb_y = sb_top + math.floor(self.scroll_offset * thumb_range / scroll_range)

        display.fill_rect(sb_x, thumb_y, 4, thumb_height, colors.ACCENT)
    end
end

function SettingsCategory:handle_key(key)
    ScreenManager.invalidate()

    if self.editing then
        if key.special == "LEFT" then
            self:adjust_value(-1)
        elseif key.special == "RIGHT" then
            self:adjust_value(1)
        elseif key.special == "ENTER" or key.special == "ESCAPE" then
            self.editing = false
        end
        return "continue"
    end

    if key.special == "UP" then
        if self.selected > 1 then
            self.selected = self.selected - 1
            self:adjust_scroll()
            play_sound("navigate")
        end
    elseif key.special == "DOWN" then
        if self.selected < #self.settings then
            self.selected = self.selected + 1
            self:adjust_scroll()
            play_sound("navigate")
        end
    elseif key.special == "LEFT" then
        self.selected = math.max(1, self.selected - self.VISIBLE_ROWS)
        self:adjust_scroll()
        play_sound("navigate")
    elseif key.special == "RIGHT" then
        self.selected = math.min(#self.settings, self.selected + self.VISIBLE_ROWS)
        self:adjust_scroll()
        play_sound("navigate")
    elseif key.special == "ENTER" then
        play_sound("click")
        self:start_editing()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    return "continue"
end

function SettingsCategory:start_editing()
    local setting = self.settings[self.selected]

    if setting.type == "text" then
        tdeck.system.log("TODO: Text input for " .. setting.name)
    elseif setting.type == "button" then
        if setting.name == "usb" then
            load_module_async("/scripts/ui/screens/usb_transfer.lua", function(USBTransfer, err)
                if USBTransfer then
                    ScreenManager.push(USBTransfer:new())
                end
            end)
        elseif setting.name == "menu_hotkey" then
            load_module_async("/scripts/ui/screens/hotkey_config.lua", function(HotkeyConfig, err)
                if HotkeyConfig then
                    ScreenManager.push(HotkeyConfig:new())
                end
            end)
        elseif setting.name == "wallpaper_tint" then
            load_module_async("/scripts/ui/screens/color_picker.lua", function(ColorPicker, err)
                if not ColorPicker then return end
                local current_tint = _G.ThemeManager and _G.ThemeManager.get_wallpaper_tint()
                local picker = ColorPicker:new({
                    title = "Wallpaper Tint",
                    color = current_tint or 0x1082,
                    allow_auto = true,
                    is_auto = (current_tint == nil),
                    on_select = function(color, is_auto)
                        if _G.ThemeManager then
                            if is_auto then
                                _G.ThemeManager.set_wallpaper_tint(nil)
                            else
                                _G.ThemeManager.set_wallpaper_tint(color)
                            end
                        end
                    end
                })
                ScreenManager.push(picker)
            end)
        elseif setting.name == "time_sync" then
            load_module_async("/scripts/ui/screens/set_clock.lua", function(SetClock, err)
                if SetClock then
                    ScreenManager.push(SetClock:new())
                end
            end)
        end
    else
        self.editing = true
    end
end

function SettingsCategory:adjust_value(delta)
    local setting = self.settings[self.selected]

    if setting.type == "option" then
        local count = #setting.options
        setting.value = ((setting.value - 1 + delta) % count) + 1
    elseif setting.type == "number" then
        local step = setting.step or 1
        setting.value = setting.value + delta * step
        if setting.min then
            setting.value = math.max(setting.min, setting.value)
        end
        if setting.max then
            setting.value = math.min(setting.max, setting.value)
        end
    elseif setting.type == "toggle" then
        setting.value = not setting.value
    end

    -- Apply changes immediately for certain settings
    if setting.name == "brightness" then
        if tdeck.display and tdeck.display.set_brightness then
            tdeck.display.set_brightness(setting.value)
        end
    elseif setting.name == "kb_backlight" then
        if tdeck.keyboard and tdeck.keyboard.set_backlight then
            tdeck.keyboard.set_backlight(setting.value)
        end
    elseif setting.name == "wallpaper" then
        if _G.ThemeManager then
            _G.ThemeManager.set_wallpaper_by_index(setting.value)
        end
    elseif setting.name == "color_theme" then
        if _G.ThemeManager then
            _G.ThemeManager.set_color_theme_by_index(setting.value)
        end
    elseif setting.name == "timezone" then
        local tz_name = setting.options[setting.value]
        local tz_posix = SettingsCategory.TIMEZONE_POSIX[tz_name]
        if tz_posix then
            if tdeck.system and tdeck.system.set_timezone then
                tdeck.system.set_timezone(tz_posix)
            end
            if tdeck.storage and tdeck.storage.set_pref then
                tdeck.storage.set_pref("timezonePosix", tz_posix)
            end
        end
    elseif setting.name == "trackball" then
        if tdeck.keyboard and tdeck.keyboard.set_trackball_sensitivity then
            tdeck.keyboard.set_trackball_sensitivity(setting.value)
        end
    elseif setting.name == "trackball_mode" then
        if tdeck.keyboard and tdeck.keyboard.set_trackball_mode then
            local mode = (setting.value == 2) and "interrupt" or "polling"
            tdeck.keyboard.set_trackball_mode(mode)
        end
    elseif setting.name == "node_name" then
        if tdeck.mesh and tdeck.mesh.set_node_name then
            tdeck.mesh.set_node_name(setting.value)
        end
    elseif setting.name == "tx_power" then
        if tdeck.radio and tdeck.radio.set_tx_power then
            tdeck.radio.set_tx_power(setting.value)
        end
    elseif setting.name == "path_check" then
        if tdeck.mesh and tdeck.mesh.set_path_check then
            tdeck.mesh.set_path_check(setting.value)
        end
    elseif setting.name == "ui_sounds" then
        if setting.value then
            if not _G.SoundUtils then
                local ok, result = pcall(dofile, "/scripts/ui/sound_utils.lua")
                if ok then
                    _G.SoundUtils = result
                    pcall(function() _G.SoundUtils.init() end)
                end
            end
            if _G.SoundUtils and _G.SoundUtils.set_enabled then
                pcall(function() _G.SoundUtils.set_enabled(true) end)
                pcall(function() _G.SoundUtils.confirm() end)
            end
        else
            if _G.SoundUtils and _G.SoundUtils.set_enabled then
                pcall(function() _G.SoundUtils.set_enabled(false) end)
            end
        end
    elseif setting.name == "ui_sounds_vol" then
        if _G.SoundUtils and _G.SoundUtils.set_volume then
            pcall(function() _G.SoundUtils.set_volume(setting.value) end)
            if _G.SoundUtils.is_enabled and _G.SoundUtils.is_enabled() then
                pcall(function() _G.SoundUtils.click() end)
            end
        end
    elseif setting.name == "auto_time_sync" then
        if _G.Contacts and _G.Contacts.set_auto_time_sync then
            _G.Contacts.set_auto_time_sync(setting.value)
        end
    elseif setting.name == "screen_dim_timeout" or setting.name == "screen_off_timeout" then
        -- Reload timeout settings in the running ScreenTimeout service
        if _G.ScreenTimeout and _G.ScreenTimeout.load_settings then
            _G.ScreenTimeout.load_settings()
        end
    end

    self:save_setting(setting)
end

return SettingsCategory
