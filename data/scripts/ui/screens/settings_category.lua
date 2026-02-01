-- Settings Category Screen for T-Deck OS
-- Displays settings within a specific category

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local SettingsCategory = {
    VISIBLE_ROWS = 4,
    ROW_HEIGHT = 46,
}

-- POSIX TZ string mapping for each timezone option
-- ESP32 newlib has issues with some DST rule formats, so we use simplified strings
-- Format: STDoffset[DST[offset],start,end] where times default to 02:00
SettingsCategory.TIMEZONE_POSIX = {
    -- UTC
    ["UTC"] = "UTC0",
    -- Europe (EU DST: last Sunday March -> last Sunday October)
    ["London"] = "GMT0BST,M3.5.0,M10.5.0",
    ["Amsterdam"] = "CET-1CEST,M3.5.0,M10.5.0",
    ["Berlin"] = "CET-1CEST,M3.5.0,M10.5.0",
    ["Paris"] = "CET-1CEST,M3.5.0,M10.5.0",
    ["Madrid"] = "CET-1CEST,M3.5.0,M10.5.0",
    ["Rome"] = "CET-1CEST,M3.5.0,M10.5.0",
    ["Helsinki"] = "EET-2EEST,M3.5.0,M10.5.0",
    ["Athens"] = "EET-2EEST,M3.5.0,M10.5.0",
    ["Moscow"] = "MSK-3",
    -- Middle East / Africa
    ["Cairo"] = "EET-2",
    ["Jerusalem"] = "IST-2IDT,M3.5.0,M10.5.0",
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
    ["Sydney"] = "AEST-10AEDT,M10.1.0,M4.1.0",
    ["Brisbane"] = "AEST-10",
    ["Auckland"] = "NZST-12NZDT,M9.5.0,M4.1.0",
    -- Americas (note: POSIX uses + for west of UTC)
    ["Anchorage"] = "AKST9AKDT,M3.2.0,M11.1.0",
    ["Los Angeles"] = "PST8PDT,M3.2.0,M11.1.0",
    ["Denver"] = "MST7MDT,M3.2.0,M11.1.0",
    ["Chicago"] = "CST6CDT,M3.2.0,M11.1.0",
    ["New York"] = "EST5EDT,M3.2.0,M11.1.0",
    ["Toronto"] = "EST5EDT,M3.2.0,M11.1.0",
    ["Halifax"] = "AST4ADT,M3.2.0,M11.1.0",
    ["Sao Paulo"] = "BRT3BRST,M10.3.0,M2.3.0",
    ["Buenos Aires"] = "ART3"
}

-- City coordinates for GPS-based timezone lookup {lat, lon}
SettingsCategory.TIMEZONE_COORDS = {
    ["UTC"] = {0, 0},
    -- Europe
    ["London"] = {51.51, -0.13},
    ["Amsterdam"] = {52.37, 4.90},
    ["Berlin"] = {52.52, 13.40},
    ["Paris"] = {48.86, 2.35},
    ["Madrid"] = {40.42, -3.70},
    ["Rome"] = {41.90, 12.50},
    ["Helsinki"] = {60.17, 24.94},
    ["Athens"] = {37.98, 23.73},
    ["Moscow"] = {55.76, 37.62},
    -- Middle East / Africa
    ["Cairo"] = {30.04, 31.24},
    ["Jerusalem"] = {31.77, 35.23},
    ["Dubai"] = {25.20, 55.27},
    ["Nairobi"] = {-1.29, 36.82},
    ["Lagos"] = {6.52, 3.38},
    ["Johannesburg"] = {-26.20, 28.04},
    -- Asia
    ["Mumbai"] = {19.08, 72.88},
    ["Karachi"] = {24.86, 67.01},
    ["Almaty"] = {43.24, 76.95},
    ["Bangkok"] = {13.76, 100.50},
    ["Jakarta"] = {-6.21, 106.85},
    ["Singapore"] = {1.35, 103.82},
    ["Hong Kong"] = {22.32, 114.17},
    ["Shanghai"] = {31.23, 121.47},
    ["Manila"] = {14.60, 120.98},
    ["Tokyo"] = {35.68, 139.69},
    ["Seoul"] = {37.57, 126.98},
    -- Oceania
    ["Perth"] = {-31.95, 115.86},
    ["Sydney"] = {-33.87, 151.21},
    ["Brisbane"] = {-27.47, 153.03},
    ["Auckland"] = {-36.85, 174.76},
    -- Americas
    ["Anchorage"] = {61.22, -149.90},
    ["Los Angeles"] = {34.05, -118.24},
    ["Denver"] = {39.74, -104.99},
    ["Chicago"] = {41.88, -87.63},
    ["New York"] = {40.71, -74.01},
    ["Toronto"] = {43.65, -79.38},
    ["Halifax"] = {44.65, -63.57},
    ["Sao Paulo"] = {-23.55, -46.63},
    ["Buenos Aires"] = {-34.60, -58.38},
}

-- Category metadata for documentation
-- @settings_categories
SettingsCategory.CATEGORY_INFO = {
    wifi = {
        title = "WiFi",
        desc = "Configure WiFi radio and network connections for internet access and NTP time sync.",
    },
    radio = {
        title = "Radio",
        desc = "Configure LoRa mesh radio settings including frequency band, power, and routing.",
    },
    display = {
        title = "Display",
        desc = "Adjust screen brightness, keyboard backlight, themes, and power saving timeouts.",
    },
    time = {
        title = "Time",
        desc = "Configure clock format, timezone, and automatic time synchronization.",
    },
    input = {
        title = "Input",
        desc = "Adjust trackball sensitivity and input handling mode.",
    },
    sound = {
        title = "Sound",
        desc = "Enable UI feedback sounds and adjust volume.",
    },
    map = {
        title = "Map",
        desc = "Configure offline map viewer appearance and navigation speed.",
    },
    hotkeys = {
        title = "Hotkeys",
        desc = "Configure keyboard shortcuts for quick access to system functions.",
    },
    system = {
        title = "System",
        desc = "System utilities and advanced configuration options.",
    },
}

-- All settings organized by category
-- Each setting has: name (pref key), label (UI), value (default), type, and desc (documentation)
-- @settings
SettingsCategory.ALL_SETTINGS = {
    wifi = {
        {name = "wifi_enabled", label = "WiFi Radio", value = false, type = "toggle", icon = "channels",
         desc = "Enable or disable the ESP32 WiFi radio. When enabled, the device can connect to WiFi networks for internet access and NTP time synchronization. Disabling saves battery."},
        {name = "wifi_ssid", label = "Network SSID", value = "", type = "text", icon = "channels",
         desc = "The name (SSID) of the WiFi network to connect to. Enter the exact network name as it appears in your router settings."},
        {name = "wifi_password", label = "Password", value = "", type = "password", icon = "channels",
         desc = "The password for the WiFi network. Stored securely in device preferences. Leave empty for open networks."},
        {name = "wifi_auto_connect", label = "Auto Connect", value = false, type = "toggle", icon = "channels",
         desc = "Automatically connect to the saved WiFi network on boot. When disabled, you must manually initiate connections."},
        {name = "wifi_test", label = "WiFi Test", value = "", type = "button", icon = "channels",
         desc = "Test the current WiFi configuration by attempting to connect and displaying the connection status."},
    },
    radio = {
        {name = "mesh_node_name", label = "Node Name", value = "MeshNode", type = "text", icon = "contacts",
         desc = "Your node's display name in the mesh network. Other users will see this name when you send messages or advertise your presence."},
        {name = "radio_region", label = "Region", value = 1, type = "option", options = {"EU868", "US915", "AU915", "AS923"}, icon = "channels",
         desc = "LoRa frequency band for your region. Must match other nodes in your mesh. EU868 for Europe, US915 for North America, AU915 for Australia, AS923 for Asia."},
        {name = "radio_tx_power", label = "TX Power", value = 22, type = "number", min = 0, max = 22, suffix = " dBm", icon = "channels",
         desc = "Radio transmission power in dBm. Higher values increase range but use more battery. Maximum 22 dBm (~158mW). Lower for indoor use."},
        {name = "mesh_ttl", label = "TTL", value = 3, type = "number", min = 1, max = 10, suffix = " hops", icon = "channels",
         desc = "Time-to-live for mesh packets. Messages can traverse this many nodes before expiring. Higher values reach further but increase network traffic."},
        {name = "mesh_path_check", label = "Path Check", value = true, type = "toggle", icon = "channels",
         desc = "Verify routing paths are still valid before sending. Improves reliability but adds latency. Disable for faster but less reliable delivery."},
        {name = "mesh_auto_advert", label = "Auto Advert", value = 1, type = "option", options = {"Off", "1 hour", "4 hours", "8 hours", "12 hours", "24 hours"}, icon = "channels",
         desc = "Automatically broadcast your presence to the mesh network at this interval. Other nodes use advertisements to discover you and build routing tables."},
    },
    display = {
        {name = "display_brightness", label = "Display", value = 200, type = "number", min = 25, max = 255, step = 25, suffix = "%", scale = 100/255, icon = "info",
         desc = "LCD backlight brightness level. Lower values save battery. Minimum 25 (10%) to maximum 255 (100%). Changes take effect immediately."},
        {name = "kb_backlight", label = "KB Light", value = 0, type = "number", min = 0, max = 255, step = 25, suffix = "%", scale = 100/255, icon = "info",
         desc = "Keyboard backlight brightness. Set to 0 to disable keyboard illumination and save battery. Useful in dark environments."},
        {name = "wallpaper", label = "Wallpaper", value = 1, type = "option", options = {"Solid", "Grid", "Dots", "Dense", "H-Lines", "V-Lines", "Diag"}, icon = "settings",
         desc = "Background pattern style for the UI. Solid uses a flat color, others add geometric patterns. Combine with wallpaper tint for custom looks."},
        {name = "color_theme", label = "Colors", value = 1, type = "option", options = {
            "Default", "Amber", "Ocean", "Sunset", "Forest", "Midnight",
            "Cyberpunk", "Cherry", "Aurora", "Coral", "Volcano", "Arctic",
            "JF", "Daylight", "Latte", "Mint", "Lavender", "Peach",
            "Cream", "Sky", "Rose", "Sage"
        }, icon = "settings",
         desc = "Color scheme for the UI. Each theme defines accent colors, text colors, and background tints. Changes apply immediately to all screens."},
        {name = "wallpaper_tint", label = "Wallpaper Tint", value = "", type = "button", icon = "settings",
         desc = "Open the color picker to choose a custom tint color for the wallpaper pattern. Use 'Auto' to derive the tint from the current color theme."},
        {name = "screen_dim_timeout", label = "Dim After", value = 5, type = "option", options = {"Off", "1 min", "2 min", "5 min", "10 min", "15 min"}, icon = "info",
         desc = "Automatically dim the display after this period of inactivity. Saves battery while keeping the screen readable. Set to Off to disable."},
        {name = "screen_off_timeout", label = "Off After", value = 4, type = "option", options = {"Off", "5 min", "10 min", "15 min", "30 min"}, icon = "info",
         desc = "Turn off the display completely after this period of inactivity (after dimming). Press any key to wake. Set to Off to keep screen always on."},
        {name = "display_show_fps", label = "FPS Counter", value = false, type = "toggle", icon = "info",
         desc = "Show frames-per-second counter in the status bar. Useful for debugging UI performance. The target is 30 FPS."},
    },
    time = {
        {name = "time_format", label = "Time", value = 1, type = "option", options = {"24h", "12h AM/PM"}, icon = "info",
         desc = "Time display format. 24-hour format (00:00-23:59) or 12-hour format with AM/PM indicator."},
        {name = "time_zone", label = "Timezone", value = 1, type = "option", options = {
            "UTC",
            "London", "Amsterdam", "Berlin", "Paris", "Madrid", "Rome",
            "Helsinki", "Athens", "Moscow",
            "Cairo", "Jerusalem", "Dubai", "Nairobi", "Lagos", "Johannesburg",
            "Mumbai", "Karachi", "Almaty", "Bangkok", "Jakarta", "Singapore",
            "Hong Kong", "Shanghai", "Manila", "Tokyo", "Seoul",
            "Perth", "Sydney", "Brisbane", "Auckland",
            "Anchorage", "Los Angeles", "Denver", "Chicago", "New York",
            "Toronto", "Halifax", "Sao Paulo", "Buenos Aires"
        }, icon = "info",
         desc = "Local timezone for displaying times. Includes automatic daylight saving time adjustments for supported regions. UTC is Coordinated Universal Time (no offset)."},
        {name = "time_sync", label = "Set Clock", value = "", type = "button", icon = "info",
         desc = "Manually set the system clock. Opens a date/time picker to enter the current time. Use when GPS or NTP sync is unavailable."},
        {name = "time_auto_sync", label = "Auto Clock Sync", value = true, type = "toggle", icon = "info",
         desc = "Automatically synchronize the clock from GPS satellites or NTP servers (when WiFi is connected). Provides accurate time without manual adjustment."},
        {name = "time_auto_zone_gps", label = "Auto Timezone (GPS)", value = false, type = "toggle", icon = "map",
         desc = "Automatically detect timezone based on GPS location. Uses the nearest city's timezone. Useful when traveling across time zones."},
    },
    input = {
        {name = "tb_sensitivity", label = "Trackball Sens", value = 1, type = "number", min = 1, max = 10, suffix = "", icon = "settings",
         desc = "Trackball movement sensitivity. Higher values make the cursor move faster. Start at 1 and increase if scrolling feels too slow."},
        {name = "tb_mode", label = "Trackball Mode", value = 1, type = "option", options = {"Polling", "Interrupt"}, icon = "settings",
         desc = "Trackball input method. Polling checks for movement periodically (reliable). Interrupt responds to hardware signals (lower latency but may miss rapid movements)."},
    },
    sound = {
        {name = "sound_enabled", label = "UI Sounds", value = false, type = "toggle", icon = "settings",
         desc = "Enable audio feedback for UI interactions. Plays tones for navigation, selection, errors, and confirmations through the built-in speaker."},
        {name = "sound_volume", label = "Sound Vol", value = 50, type = "number", min = 0, max = 100, step = 10, suffix = "%", icon = "settings",
         desc = "Volume level for UI sounds. 0% is silent, 100% is maximum. Only applies when UI Sounds is enabled."},
    },
    map = {
        {name = "map_theme", label = "Theme", value = 1, type = "option", options = {"Light", "Dark"}, icon = "map",
         desc = "Color scheme for the offline map viewer. Light theme has white background, dark theme has black background. Choose based on lighting conditions."},
        {name = "map_pan_speed", label = "Pan Speed", value = 2, type = "number", min = 1, max = 5, suffix = "", icon = "map",
         desc = "How fast the map moves when panning with the trackball. Higher values cover more ground per movement but reduce precision."},
    },
    hotkeys = {
        {name = "hotkey_menu", label = "Menu Hotkey", value = "", type = "button", icon = "settings",
         desc = "Configure the key combination to open the application menu from any screen. Default is Left Shift + Right Shift pressed together."},
        {name = "hotkey_screenshot", label = "Screenshot", value = "", type = "button", icon = "screenshot",
         desc = "Configure the key combination to take a screenshot. Screenshots are saved to the SD card in PNG format."},
    },
    system = {
        {name = "usb", label = "USB Transfer", value = "", type = "button", icon = "files",
         desc = "Enter USB mass storage mode to transfer files between the SD card and a computer. The device acts as a USB drive while in this mode."},
        {name = "system_loop_delay", label = "Loop Delay", value = 0, type = "number", min = 0, max = 100, step = 1, suffix = " ms", icon = "settings",
         desc = "Add artificial delay to the main loop (advanced). Can reduce CPU usage and heat but makes the UI less responsive. 0 for no delay."},
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
    -- Icons are pre-loaded during splash screen
    self:load_settings()
end

function SettingsCategory:load_settings()
    local function get_pref(key, default)
        if ez.storage and ez.storage.get_pref then
            return ez.storage.get_pref(key, default)
        end
        return default
    end

    for _, setting in ipairs(self.settings) do
        if setting.name == "wifi_enabled" then
            setting.value = get_pref("wifi_enabled", false)
        elseif setting.name == "wifi_ssid" then
            setting.value = get_pref("wifi_ssid", "")
        elseif setting.name == "wifi_password" then
            setting.value = get_pref("wifi_password", "")
        elseif setting.name == "wifi_auto_connect" then
            setting.value = get_pref("wifi_auto_connect", false)
        elseif setting.name == "mesh_node_name" then
            setting.value = get_pref("mesh_node_name", "MeshNode")
        elseif setting.name == "radio_region" then
            -- Ensure region is a valid number index (1-4)
            local region = tonumber(get_pref("radio_region", 1)) or 1
            if region < 1 or region > 4 then region = 1 end
            setting.value = region
        elseif setting.name == "radio_tx_power" then
            setting.value = tonumber(get_pref("radio_tx_power", 22)) or 22
        elseif setting.name == "mesh_ttl" then
            setting.value = tonumber(get_pref("mesh_ttl", 3)) or 3
        elseif setting.name == "mesh_path_check" then
            setting.value = get_pref("mesh_path_check", true)
        elseif setting.name == "mesh_auto_advert" then
            setting.value = tonumber(get_pref("mesh_auto_advert", 1)) or 1  -- Default: Off
        elseif setting.name == "display_brightness" then
            setting.value = tonumber(get_pref("display_brightness", 200)) or 200
        elseif setting.name == "kb_backlight" then
            setting.value = tonumber(get_pref("kb_backlight", 0)) or 0
        elseif setting.name == "wallpaper" then
            if _G.ThemeManager then
                setting.value = _G.ThemeManager.get_wallpaper_index()
            end
        elseif setting.name == "color_theme" then
            if _G.ThemeManager then
                setting.value = _G.ThemeManager.get_color_theme_index()
            end
        elseif setting.name == "time_format" then
            setting.value = tonumber(get_pref("time_format", 1)) or 1
        elseif setting.name == "time_zone" then
            setting.value = tonumber(get_pref("time_zone", 1)) or 1
        elseif setting.name == "time_auto_sync" then
            setting.value = get_pref("time_auto_sync", true)
        elseif setting.name == "time_auto_zone_gps" then
            setting.value = get_pref("time_auto_zone_gps", false)
        elseif setting.name == "tb_sensitivity" then
            setting.value = tonumber(get_pref("tb_sensitivity", 1)) or 1
        elseif setting.name == "tb_mode" then
            -- 1 = Polling, 2 = Interrupt
            local mode = get_pref("tb_mode", "polling")
            setting.value = (mode == "interrupt") and 2 or 1
        elseif setting.name == "sound_enabled" then
            setting.value = get_pref("sound_enabled", false)
        elseif setting.name == "sound_volume" then
            setting.value = tonumber(get_pref("sound_volume", 50)) or 50
        elseif setting.name == "map_theme" then
            -- Convert theme string to option index: light=1, dark=2
            local theme = get_pref("map_theme", "light")
            setting.value = (theme == "dark") and 2 or 1
        elseif setting.name == "map_pan_speed" then
            setting.value = tonumber(get_pref("map_pan_speed", 2)) or 2
        elseif setting.name == "screen_dim_timeout" then
            -- Convert minutes to option index: Off=1, 1=2, 2=3, 5=4, 10=5, 15=6
            local mins = tonumber(get_pref("screen_dim_timeout", 5)) or 5
            if mins == 0 then setting.value = 1
            elseif mins == 1 then setting.value = 2
            elseif mins == 2 then setting.value = 3
            elseif mins == 5 then setting.value = 4
            elseif mins == 10 then setting.value = 5
            else setting.value = 6 end
        elseif setting.name == "screen_off_timeout" then
            -- Convert minutes to option index: Off=1, 5=2, 10=3, 15=4, 30=5
            local mins = tonumber(get_pref("screen_off_timeout", 10)) or 10
            if mins == 0 then setting.value = 1
            elseif mins == 5 then setting.value = 2
            elseif mins == 10 then setting.value = 3
            elseif mins == 15 then setting.value = 4
            else setting.value = 5 end
        elseif setting.name == "display_show_fps" then
            setting.value = get_pref("display_show_fps", false)
        elseif setting.name == "system_loop_delay" then
            setting.value = tonumber(get_pref("system_loop_delay", 0)) or 0
        end
    end
end

function SettingsCategory:save_setting(setting)
    local function set_pref(key, value)
        if ez.storage and ez.storage.set_pref then
            ez.storage.set_pref(key, value)
        end
    end

    -- Publish setting changed event
    if ez.bus and ez.bus.post then
        local value_str = tostring(setting.value)
        ez.bus.post("settings/changed", setting.name .. "=" .. value_str)
    end

    if setting.name == "wifi_enabled" then
        set_pref("wifi_enabled", setting.value)
        -- Apply immediately
        if ez.wifi then
            ez.wifi.set_power(setting.value)
        end
    elseif setting.name == "wifi_ssid" then
        set_pref("wifi_ssid", setting.value)
    elseif setting.name == "wifi_password" then
        set_pref("wifi_password", setting.value)
    elseif setting.name == "wifi_auto_connect" then
        set_pref("wifi_auto_connect", setting.value)
    elseif setting.name == "mesh_node_name" then
        set_pref("mesh_node_name", setting.value)
    elseif setting.name == "radio_region" then
        set_pref("radio_region", setting.value)
    elseif setting.name == "radio_tx_power" then
        set_pref("radio_tx_power", setting.value)
    elseif setting.name == "mesh_ttl" then
        set_pref("mesh_ttl", setting.value)
    elseif setting.name == "mesh_path_check" then
        set_pref("mesh_path_check", setting.value)
    elseif setting.name == "mesh_auto_advert" then
        set_pref("mesh_auto_advert", setting.value)
    elseif setting.name == "display_brightness" then
        set_pref("display_brightness", setting.value)
    elseif setting.name == "kb_backlight" then
        set_pref("kb_backlight", setting.value)
    elseif setting.name == "time_format" then
        set_pref("time_format", setting.value)
    elseif setting.name == "time_zone" then
        set_pref("time_zone", setting.value)
        local tz_name = setting.options[setting.value]
        local tz_posix = SettingsCategory.TIMEZONE_POSIX[tz_name]
        if tz_posix then
            set_pref("time_zone_posix", tz_posix)
        end
    elseif setting.name == "time_auto_sync" then
        set_pref("time_auto_sync", setting.value)
    elseif setting.name == "time_auto_zone_gps" then
        set_pref("time_auto_zone_gps", setting.value)
    elseif setting.name == "tb_sensitivity" then
        set_pref("tb_sensitivity", setting.value)
    elseif setting.name == "tb_mode" then
        -- 1 = Polling, 2 = Interrupt
        local mode = (setting.value == 2) and "interrupt" or "polling"
        set_pref("tb_mode", mode)
    elseif setting.name == "sound_enabled" then
        set_pref("sound_enabled", setting.value)
    elseif setting.name == "sound_volume" then
        set_pref("sound_volume", setting.value)
    elseif setting.name == "map_theme" then
        -- Convert option index to theme string: 1=light, 2=dark
        local theme = (setting.value == 2) and "dark" or "light"
        set_pref("map_theme", theme)
    elseif setting.name == "map_pan_speed" then
        set_pref("map_pan_speed", setting.value)
    elseif setting.name == "screen_dim_timeout" then
        -- Convert option index to minutes: Off=0, 1=1, 2=2, 5=5, 10=10, 15=15
        local mins_map = {0, 1, 2, 5, 10, 15}
        set_pref("screen_dim_timeout", mins_map[setting.value] or 5)
    elseif setting.name == "screen_off_timeout" then
        -- Convert option index to minutes: Off=0, 5=5, 10=10, 15=15, 30=30
        local mins_map = {0, 5, 10, 15, 30}
        set_pref("screen_off_timeout", mins_map[setting.value] or 10)
    elseif setting.name == "display_show_fps" then
        set_pref("display_show_fps", setting.value)
    elseif setting.name == "system_loop_delay" then
        set_pref("system_loop_delay", setting.value)
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
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height

    ListMixin.draw_background(display)

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

    if setting.type == "text" or setting.type == "password" then
        -- Spawn text input screen
        local self_ref = self
        local setting_ref = setting
        spawn(function()
            local ok, TextInputScreen = pcall(load_module, "/scripts/ui/screens/text_input_screen.lua")
            if not ok or not TextInputScreen then
                ez.log("Failed to load text input screen")
                return
            end
            ScreenManager.push(TextInputScreen:new({
                title = setting_ref.label,
                label = setting_ref.label .. ":",
                value = setting_ref.value or "",
                placeholder = setting_ref.type == "password" and "Enter password" or "Enter value",
                password_mode = (setting_ref.type == "password"),
                on_submit = function(value)
                    setting_ref.value = value
                    self_ref:save_setting(setting_ref)
                end
            }))
        end)
    elseif setting.type == "button" then
        if setting.name == "usb" then
            spawn_screen("/scripts/ui/screens/usb_transfer.lua")
        elseif setting.name == "hotkey_menu" then
            spawn_screen("/scripts/ui/screens/hotkey_config.lua", "menu", "Menu Hotkey", "hotkey_menu")
        elseif setting.name == "hotkey_screenshot" then
            spawn_screen("/scripts/ui/screens/hotkey_config.lua", "screenshot", "Screenshot Key", "hotkey_screenshot")
        elseif setting.name == "wallpaper_tint" then
            -- Color picker needs complex options, use spawn directly
            spawn(function()
                local ok, ColorPicker = pcall(load_module, "/scripts/ui/screens/color_picker.lua")
                if not ok or not ColorPicker then return end
                local current_tint = _G.ThemeManager and _G.ThemeManager.get_wallpaper_tint()
                ScreenManager.push(ColorPicker:new({
                    title = "Wallpaper Tint",
                    color = current_tint or 0x1082,
                    allow_auto = true,
                    is_auto = (current_tint == nil),
                    on_select = function(color, is_auto)
                        if _G.ThemeManager then
                            _G.ThemeManager.set_wallpaper_tint(is_auto and nil or color)
                        end
                    end
                }))
            end)
        elseif setting.name == "time_sync" then
            spawn_screen("/scripts/ui/screens/set_clock.lua")
        elseif setting.name == "wifi_test" then
            spawn_screen("/scripts/ui/screens/wifi_test.lua")
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
    if setting.name == "display_brightness" then
        if ez.display and ez.display.set_brightness then
            ez.display.set_brightness(setting.value)
        end
    elseif setting.name == "kb_backlight" then
        if ez.keyboard and ez.keyboard.set_backlight then
            ez.keyboard.set_backlight(setting.value)
        end
    elseif setting.name == "wallpaper" then
        if _G.ThemeManager then
            _G.ThemeManager.set_wallpaper_by_index(setting.value)
        end
    elseif setting.name == "color_theme" then
        if _G.ThemeManager then
            _G.ThemeManager.set_color_theme_by_index(setting.value)
        end
    elseif setting.name == "time_zone" then
        local tz_name = setting.options[setting.value]
        local tz_posix = SettingsCategory.TIMEZONE_POSIX[tz_name]
        if tz_posix then
            if ez.system and ez.system.set_timezone then
                ez.system.set_timezone(tz_posix)
            end
            if ez.storage and ez.storage.set_pref then
                ez.storage.set_pref("time_zone_posix", tz_posix)
            end
        end
    elseif setting.name == "tb_sensitivity" then
        if ez.keyboard and ez.keyboard.set_trackball_sensitivity then
            ez.keyboard.set_trackball_sensitivity(setting.value)
        end
    elseif setting.name == "tb_mode" then
        if ez.keyboard and ez.keyboard.set_trackball_mode then
            local mode = (setting.value == 2) and "interrupt" or "polling"
            ez.keyboard.set_trackball_mode(mode)
        end
    elseif setting.name == "mesh_node_name" then
        if ez.mesh and ez.mesh.set_node_name then
            ez.mesh.set_node_name(setting.value)
        end
    elseif setting.name == "radio_tx_power" then
        if ez.radio and ez.radio.set_tx_power then
            ez.radio.set_tx_power(setting.value)
        end
    elseif setting.name == "mesh_path_check" then
        if ez.mesh and ez.mesh.set_path_check then
            ez.mesh.set_path_check(setting.value)
        end
    elseif setting.name == "mesh_auto_advert" then
        if ez.mesh and ez.mesh.set_announce_interval then
            -- Convert option index to milliseconds: 1=Off, 2=1h, 3=4h, 4=8h, 5=12h, 6=24h
            local intervals = {0, 3600000, 14400000, 28800000, 43200000, 86400000}
            local ms = intervals[setting.value] or 0
            ez.mesh.set_announce_interval(ms)
        end
    elseif setting.name == "sound_enabled" then
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
    elseif setting.name == "sound_volume" then
        if _G.SoundUtils and _G.SoundUtils.set_volume then
            pcall(function() _G.SoundUtils.set_volume(setting.value) end)
            if _G.SoundUtils.is_enabled and _G.SoundUtils.is_enabled() then
                pcall(function() _G.SoundUtils.click() end)
            end
        end
    elseif setting.name == "time_auto_sync" then
        if _G.Contacts and _G.Contacts.set_auto_time_sync then
            _G.Contacts.set_auto_time_sync(setting.value)
        end
    elseif setting.name == "time_auto_zone_gps" then
        -- Enable/disable the TimezoneSync service
        if _G.TimezoneSync and _G.TimezoneSync.set_enabled then
            _G.TimezoneSync.set_enabled(setting.value)
        end
    elseif setting.name == "screen_dim_timeout" or setting.name == "screen_off_timeout" then
        -- Reload timeout settings in the running ScreenTimeout service
        if _G.ScreenTimeout and _G.ScreenTimeout.load_settings then
            _G.ScreenTimeout.load_settings()
        end
    elseif setting.name == "display_show_fps" then
        -- Update the StatusBar FPS display setting
        if _G.StatusBar then
            _G.StatusBar.show_fps = setting.value
        end
    elseif setting.name == "system_loop_delay" then
        -- Update the C++ main loop delay
        if ez.system and ez.system.set_loop_delay then
            ez.system.set_loop_delay(setting.value)
        end
    end

    self:save_setting(setting)
end

return SettingsCategory
