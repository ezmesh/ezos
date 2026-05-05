-- Wallpaper sub-settings: auto-rotate interval.
--
-- Pref:
--   wp_rotate       "off" | "boot" | "shown"
--                   "boot"  -> advance once per boot, on first desktop show.
--                   "shown" -> advance every time the desktop is (re)shown.
--
-- The earlier tile / pan controls were removed when the wallpaper-pan
-- feature was retired; what's left is the rotate scheduler.

local ui = require("ezui")

local Wallpaper = { title = "Wallpaper" }

local ROTATE_LABELS = { "Off", "On boot", "Every time shown" }
local ROTATE_VALUES = { "off", "boot", "shown" }

local function index_of(list, value, fallback)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return fallback or 1
end

function Wallpaper.initial_state()
    return {
        rotate = ez.storage.get_pref("wp_rotate", "off"),
    }
end

function Wallpaper:build(state)
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Auto rotate", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.dropdown(ROTATE_LABELS, {
            value = index_of(ROTATE_VALUES, state.rotate, 1),
            on_change = function(idx)
                local v = ROTATE_VALUES[idx] or "off"
                state.rotate = v
                ez.storage.set_pref("wp_rotate", v)
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 8, 8, 8 },
        ui.text_widget(
            "Pick when the desktop should swap to the next built-in " ..
            "wallpaper. The list is fixed (lua/screens/desktop.lua); to " ..
            "set a specific image use Files -> Set as wallpaper.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Wallpaper", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Wallpaper:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Wallpaper
