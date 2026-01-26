-- Settings Screen for T-Deck OS
-- Device configuration using vertical list style

local Settings = {
    title = "Settings",
    selected = 1,
    scroll_offset = 0,
    editing = false,

    -- Layout constants (match main menu)
    VISIBLE_ROWS = 4,
    ROW_HEIGHT = 46,

    settings = {
        {name = "node_name", label = "Node Name", value = "MeshNode", type = "text", icon = "contacts"},
        {name = "region", label = "Region", value = 1, type = "option", options = {"EU868", "US915", "AU915", "AS923"}, icon = "channels"},
        {name = "tx_power", label = "TX Power", value = 22, type = "number", min = 0, max = 22, suffix = " dBm", icon = "channels"},
        {name = "ttl", label = "TTL", value = 3, type = "number", min = 1, max = 10, suffix = " hops", icon = "channels"},
        {name = "brightness", label = "Display", value = 200, type = "number", min = 25, max = 255, step = 25, suffix = "%", scale = 100/255, icon = "info"},
        {name = "kb_backlight", label = "KB Light", value = 0, type = "number", min = 0, max = 255, step = 25, suffix = "%", scale = 100/255, icon = "info"},
        {name = "wallpaper", label = "Wallpaper", value = 1, type = "option", options = {"Solid", "Grid", "Dots", "Dense", "H-Lines", "V-Lines", "Diag"}, icon = "settings"},
        {name = "icon_theme", label = "Icons", value = 1, type = "option", options = {"Default", "Cyan", "Orange", "Mono"}, icon = "settings"},
        {name = "color_theme", label = "Colors", value = 1, type = "option", options = {
            -- Dark themes (1-12)
            "Default", "Matrix", "Amber", "Nord", "Dracula", "Solarized",
            "Monokai", "Gruvbox", "Ocean", "Sunset", "Forest", "Midnight",
            -- More dark themes (13-18)
            "Cyberpunk", "Hacker", "Cherry", "Slate", "Tokyo", "Emerald",
            -- Light themes (19-24)
            "Paper", "Daylight", "Latte", "Mint", "Lavender", "Peach"
        }, icon = "settings"},
        {name = "wallpaper_tint", label = "Wallpaper Tint", value = "", type = "button", icon = "settings"},
        {name = "time_format", label = "Time", value = 1, type = "option", options = {"24h", "12h AM/PM"}, icon = "info"},
        {name = "time_sync", label = "Set Clock", value = "", type = "button", icon = "info"},
        {name = "auto_time_sync", label = "Auto Time Sync", value = true, type = "toggle", icon = "info"},
        {name = "font_size", label = "Font", value = 3, type = "option", options = {"Tiny", "Small", "Medium", "Large"}, icon = "settings"},
        {name = "trackball", label = "Trackball", value = 1, type = "number", min = 1, max = 10, suffix = "", icon = "settings"},
        {name = "tick_scroll", label = "Tick Scroll", value = true, type = "toggle", icon = "settings"},
        {name = "tick_interval", label = "Tick Rate", value = 20, type = "number", min = 10, max = 200, step = 10, suffix = "ms", icon = "settings"},
        {name = "ui_sounds", label = "UI Sounds", value = false, type = "toggle", icon = "settings"},
        {name = "ui_sounds_vol", label = "Sound Vol", value = 50, type = "number", min = 0, max = 100, step = 10, suffix = "%", icon = "settings"},
        {name = "menu_hotkey", label = "Menu Hotkey", value = "", type = "button", icon = "settings"},
        {name = "usb", label = "USB Transfer", value = "", type = "button", icon = "files"},
        {name = "save", label = "Save Settings", value = "", type = "button", icon = "info"}
    }
}

function Settings:new()
    local o = {
        title = self.title,
        selected = 1,
        scroll_offset = 0,
        editing = false,
        settings = {}
    }

    -- Deep copy settings
    for i, s in ipairs(self.settings) do
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

    setmetatable(o, {__index = Settings})
    return o
end

function Settings:on_enter()
    -- Lazy-load Icons module if not already loaded
    if not _G.Icons then
        _G.Icons = dofile("/scripts/ui/icons.lua")
    end
    self:load_settings()
end

function Settings:load_settings()
    local function get_pref(key, default)
        if tdeck.storage and tdeck.storage.get_pref then
            return tdeck.storage.get_pref(key, default)
        end
        return default
    end

    self.settings[1].value = get_pref("nodeName", "MeshNode")
    self.settings[2].value = get_pref("region", 1)
    self.settings[3].value = get_pref("txPower", 22)
    self.settings[4].value = get_pref("ttl", 3)
    self.settings[5].value = get_pref("brightness", 200)
    self.settings[6].value = get_pref("kbBacklight", 0)

    -- Load wallpaper, icon theme, and color theme from ThemeManager
    if _G.ThemeManager then
        self.settings[7].value = _G.ThemeManager.get_wallpaper_index()
        self.settings[8].value = _G.ThemeManager.get_icon_theme_index()
        self.settings[9].value = _G.ThemeManager.get_color_theme_index()
    end

    self.settings[11].value = get_pref("timeFormat", 1)
    -- index 12 is time_sync button (no value to load)
    self.settings[13].value = get_pref("autoTimeSyncContacts", true)
    self.settings[14].value = get_pref("fontSize", 3)
    self.settings[15].value = get_pref("tbSens", 1)
    self.settings[16].value = get_pref("tickScroll", true)
    self.settings[17].value = get_pref("tickInterval", 20)
    self.settings[18].value = get_pref("uiSoundsEnabled", false)
    self.settings[19].value = get_pref("uiSoundsVolume", 50)

    -- Apply keyboard backlight immediately
    if tdeck.keyboard and tdeck.keyboard.set_backlight then
        tdeck.keyboard.set_backlight(self.settings[6].value)
    end

    -- Apply tick-based scrolling settings
    if tdeck.keyboard then
        if tdeck.keyboard.set_tick_scrolling then
            tdeck.keyboard.set_tick_scrolling(self.settings[16].value)
        end
        if tdeck.keyboard.set_scroll_tick_interval then
            tdeck.keyboard.set_scroll_tick_interval(self.settings[17].value)
        end
    end

    -- Apply auto time sync setting to Contacts service
    if _G.Contacts and _G.Contacts.set_auto_time_sync then
        _G.Contacts.set_auto_time_sync(self.settings[13].value)
    end
end

function Settings:save_settings()
    local function set_pref(key, value)
        if tdeck.storage and tdeck.storage.set_pref then
            tdeck.storage.set_pref(key, value)
        end
    end

    set_pref("nodeName", self.settings[1].value)
    set_pref("region", self.settings[2].value)
    set_pref("txPower", self.settings[3].value)
    set_pref("ttl", self.settings[4].value)
    set_pref("brightness", self.settings[5].value)
    set_pref("kbBacklight", self.settings[6].value)
    -- Wallpaper, icon theme, color theme and tint are saved by ThemeManager directly on change
    set_pref("timeFormat", self.settings[11].value)
    -- index 12 is time_sync button (no value to save)
    set_pref("autoTimeSyncContacts", self.settings[13].value)
    set_pref("fontSize", self.settings[14].value)
    set_pref("tbSens", self.settings[15].value)
    set_pref("tickScroll", self.settings[16].value)
    set_pref("tickInterval", self.settings[17].value)
    set_pref("uiSoundsEnabled", self.settings[18].value)
    set_pref("uiSoundsVolume", self.settings[19].value)

    tdeck.system.log("Settings saved")
end

function Settings:get_display_value(setting)
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

function Settings:adjust_scroll()
    -- Keep selected item visible in the window
    if self.selected <= self.scroll_offset then
        self.scroll_offset = self.selected - 1
    elseif self.selected > self.scroll_offset + self.VISIBLE_ROWS then
        self.scroll_offset = self.selected - self.VISIBLE_ROWS
    end

    -- Clamp scroll offset
    self.scroll_offset = math.max(0, self.scroll_offset)
    self.scroll_offset = math.min(#self.settings - self.VISIBLE_ROWS, self.scroll_offset)
end

function Settings:render(display)
    -- Use themed colors if available
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, w, h, colors.BLACK)
    end

    -- Title bar
    TitleBar.draw(display, self.title)

    -- List area starts after title
    local list_start_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31
    local icon_margin = 12
    local icon_size = 24
    local text_x = icon_margin + icon_size + 10
    local scrollbar_width = 8

    -- Draw visible settings items
    for i = 0, self.VISIBLE_ROWS - 1 do
        local item_idx = self.scroll_offset + i + 1
        if item_idx > #self.settings then break end

        local setting = self.settings[item_idx]
        local y = list_start_y + i * self.ROW_HEIGHT
        local is_selected = (item_idx == self.selected)

        -- Selection outline (rounded rect)
        if is_selected then
            local outline_color = self.editing and colors.ORANGE or colors.CYAN
            display.draw_round_rect(4, y - 1, w - 12 - scrollbar_width, self.ROW_HEIGHT - 6, 6, outline_color)
        end

        -- Draw icon
        local icon_y = y + (self.ROW_HEIGHT - icon_size) / 2 - 4
        local icon_color = is_selected and colors.CYAN or colors.WHITE
        if setting.icon and _G.Icons then
            _G.Icons.draw(setting.icon, display, icon_margin, icon_y, icon_size, icon_color)
        end

        -- Label (main text) - use medium font
        display.set_font_size("medium")
        local label_color = is_selected and colors.CYAN or colors.WHITE
        local label_y = y + 4
        display.draw_text(text_x, label_y, setting.label, label_color)

        -- Value (right side or secondary line)
        local value_str = self:get_display_value(setting)

        if setting.type ~= "button" then
            -- Show arrows when editing
            if self.editing and is_selected and setting.type ~= "text" then
                value_str = "< " .. value_str .. " >"
            end

            -- Value on right side of label
            local value_width = display.text_width(value_str)
            local value_x = w - scrollbar_width - 16 - value_width
            local value_color = is_selected and (self.editing and colors.ORANGE or colors.CYAN) or colors.TEXT
            display.draw_text(value_x, label_y, value_str, value_color)
        end

        -- Description/type hint (secondary text) - use small font
        display.set_font_size("small")
        local desc_color = is_selected and colors.TEXT_DIM or colors.DARK_GRAY
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

    -- Reset to medium font
    display.set_font_size("medium")

    -- Scrollbar (only show if there are more items than visible)
    if #self.settings > self.VISIBLE_ROWS then
        local sb_x = w - scrollbar_width - 2
        local sb_top = list_start_y
        local sb_height = self.VISIBLE_ROWS * self.ROW_HEIGHT - 6

        -- Track (background)
        display.fill_rect(sb_x, sb_top, 4, sb_height, colors.DARK_GRAY)

        -- Thumb (current position)
        local thumb_height = math.max(12, math.floor(sb_height * self.VISIBLE_ROWS / #self.settings))
        local scroll_range = #self.settings - self.VISIBLE_ROWS
        local thumb_range = sb_height - thumb_height
        local thumb_y = sb_top + math.floor(self.scroll_offset * thumb_range / scroll_range)

        display.fill_rect(sb_x, thumb_y, 4, thumb_height, colors.CYAN)
    end
end

function Settings:handle_key(key)
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
        end
    elseif key.special == "DOWN" then
        if self.selected < #self.settings then
            self.selected = self.selected + 1
            self:adjust_scroll()
        end
    elseif key.special == "LEFT" then
        -- Page up
        self.selected = math.max(1, self.selected - self.VISIBLE_ROWS)
        self:adjust_scroll()
    elseif key.special == "RIGHT" then
        -- Page down
        self.selected = math.min(#self.settings, self.selected + self.VISIBLE_ROWS)
        self:adjust_scroll()
    elseif key.special == "ENTER" then
        self:start_editing()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    return "continue"
end

function Settings:start_editing()
    local setting = self.settings[self.selected]

    if setting.type == "text" then
        -- TODO: Open text input dialog
        tdeck.system.log("TODO: Text input for " .. setting.name)
    elseif setting.type == "button" then
        -- Execute button action
        if setting.name == "save" then
            self:save_settings()
        elseif setting.name == "usb" then
            local USBTransfer = load_module("/scripts/ui/screens/usb_transfer.lua")
            ScreenManager.push(USBTransfer:new())
        elseif setting.name == "menu_hotkey" then
            local HotkeyConfig = load_module("/scripts/ui/screens/hotkey_config.lua")
            ScreenManager.push(HotkeyConfig:new())
        elseif setting.name == "wallpaper_tint" then
            local ColorPicker = load_module("/scripts/ui/screens/color_picker.lua")
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
        elseif setting.name == "time_sync" then
            local TimeSync = load_module("/scripts/ui/screens/time_sync.lua")
            ScreenManager.push(TimeSync:new())
        end
    else
        self.editing = true
    end
end

function Settings:adjust_value(delta)
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
    elseif setting.name == "icon_theme" then
        if _G.ThemeManager then
            _G.ThemeManager.set_icon_theme_by_index(setting.value)
        end
    elseif setting.name == "color_theme" then
        if _G.ThemeManager then
            _G.ThemeManager.set_color_theme_by_index(setting.value)
        end
    elseif setting.name == "time_format" then
        -- Time format is read by status bar on render, no immediate action needed
    elseif setting.name == "trackball" then
        if tdeck.keyboard and tdeck.keyboard.set_trackball_sensitivity then
            tdeck.keyboard.set_trackball_sensitivity(setting.value)
        end
    elseif setting.name == "tick_scroll" then
        if tdeck.keyboard and tdeck.keyboard.set_tick_scrolling then
            tdeck.keyboard.set_tick_scrolling(setting.value)
        end
    elseif setting.name == "tick_interval" then
        if tdeck.keyboard and tdeck.keyboard.set_scroll_tick_interval then
            tdeck.keyboard.set_scroll_tick_interval(setting.value)
        end
    elseif setting.name == "node_name" then
        if tdeck.mesh and tdeck.mesh.set_node_name then
            tdeck.mesh.set_node_name(setting.value)
        end
    elseif setting.name == "tx_power" then
        if tdeck.radio and tdeck.radio.set_tx_power then
            tdeck.radio.set_tx_power(setting.value)
        end
    elseif setting.name == "ui_sounds" then
        -- Enable/disable UI sounds
        if setting.value then
            -- Load SoundUtils if not already loaded
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
        -- Update Contacts service auto time sync setting
        if _G.Contacts and _G.Contacts.set_auto_time_sync then
            _G.Contacts.set_auto_time_sync(setting.value)
        end
    end
end

-- Menu items for app menu integration
function Settings:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = "Save",
        action = function()
            self_ref:save_settings()
            ScreenManager.invalidate()
        end
    })

    table.insert(items, {
        label = "USB Transfer",
        action = function()
            local USBTransfer = load_module("/scripts/ui/screens/usb_transfer.lua")
            ScreenManager.push(USBTransfer:new())
        end
    })

    table.insert(items, {
        label = "System Log",
        action = function()
            local LogViewer = load_module("/scripts/ui/screens/log_viewer.lua")
            ScreenManager.push(LogViewer:new())
        end
    })

    return items
end

return Settings
