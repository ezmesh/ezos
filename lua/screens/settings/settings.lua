-- Settings: top-level category picker.
-- Each entry pushes its own sub-screen; the concrete controls (sliders,
-- toggles, swatches) live in the sub-screen modules so this page stays
-- short enough to read without scrolling.

local ui    = require("ezui")
local icons = require("ezui.icons")

local Settings = { title = "Settings" }

local function push(mod_name)
    local screen_mod = require("ezui.screen")
    local def = require(mod_name)
    local init = def.initial_state and def.initial_state() or {}
    screen_mod.push(screen_mod.create(def, init))
end

-- ordered list of categories shown in the picker.
local CATEGORIES = {
    { title = "Identity",  subtitle = "Node name, callsign, regenerate", icon = icons.users,        mod = "screens.settings.identity_settings" },
    { title = "Display",   subtitle = "Brightness, accent colour",    icon = icons.settings,      mod = "screens.settings.display_settings" },
    { title = "Wallpaper", subtitle = "Rotate, tile, auto-pan",       icon = icons.grid,          mod = "screens.settings.wallpaper_settings" },
    { title = "Keyboard",  subtitle = "Repeat, trackball",            icon = icons.grid,          mod = "screens.settings.keyboard_settings" },
    { title = "GPS",       subtitle = "Power, clock sync",            icon = icons.map,           mod = "screens.settings.gps_settings" },
    { title = "Time",      subtitle = "Timezone, 12 / 24h format",    icon = icons.info,          mod = "screens.settings.time_settings" },
    { title = "Radio",     subtitle = "Mesh advert, announce cadence",icon = icons.radio_tower,   mod = "screens.settings.radio_settings" },
    { title = "Sound",     subtitle = "UI feedback, volume",          icon = icons.radio_tower,   mod = "screens.settings.sound_settings" },
    { title = "System",    subtitle = "Repeat onboarding",            icon = icons.settings,      mod = "screens.settings.system_settings" },
    { title = "About",     subtitle = "Version, credits",             icon = icons.info,          mod = "screens.about" },
}

function Settings:build(state)
    local rows = {}
    for _, cat in ipairs(CATEGORIES) do
        rows[#rows + 1] = ui.list_item({
            title    = cat.title,
            subtitle = cat.subtitle,
            icon     = cat.icon,
            on_press = function() push(cat.mod) end,
        })
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Settings", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, rows)),
    })
end

function Settings:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Settings
