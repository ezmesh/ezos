-- Wallpaper sub-settings: auto-rotate interval, tiling, panning mode.
--
-- Prefs live under these keys (all <=15 chars — the NVS key limit):
--   wp_rotate       "off" | "boot" | "shown"
--                   "boot"  → advance once per boot, on first desktop show.
--                   "shown" → advance every time the desktop is (re)shown.
--   wp_tile_x       bool
--   wp_tile_y       bool
--   wp_pan          "none" | "bounce_x" | "bounce_y" |
--                   "drift_x" | "drift_y" | "wander"
--   wp_pan_speed    1..10  (linear factor; 1 = slow, 10 = fast)

local ui = require("ezui")

local Wallpaper = { title = "Wallpaper" }

-- Mapping between dropdown indices and pref string values. Keeping the
-- arrays side by side makes it easy to map selected index → pref and
-- pref → index on load.
local ROTATE_LABELS = { "Off", "On boot", "Every time shown" }
local ROTATE_VALUES = { "off", "boot", "shown" }

local PAN_LABELS = {
    "None",
    "Horizontal bounce",
    "Vertical bounce",
    "Horizontal drift",
    "Vertical drift",
    "Wander",
}
local PAN_VALUES = {
    "none", "bounce_x", "bounce_y", "drift_x", "drift_y", "wander",
}

local function index_of(list, value, fallback)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return fallback or 1
end

function Wallpaper.initial_state()
    -- Booleans come back as integer 0/1 from the NVS (bools are stored
    -- as uint8), and Lua's "and/or" treats 0 as truthy — so we have to
    -- compare to 0 explicitly. Falsy keys return the default instead.
    local function pref_bool(key, default)
        local v = ez.storage.get_pref(key, default)
        if type(v) == "number" then return v ~= 0 end
        if type(v) == "boolean" then return v end
        return default and true or false
    end
    return {
        rotate    = ez.storage.get_pref("wp_rotate", "off"),
        tile_x    = pref_bool("wp_tile_x", false),
        tile_y    = pref_bool("wp_tile_y", false),
        pan       = ez.storage.get_pref("wp_pan", "none"),
        pan_speed = tonumber(ez.storage.get_pref("wp_pan_speed", 3)) or 3,
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

    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Tiling", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
        ui.toggle("Tile horizontally", state.tile_x, {
            on_change = function(v)
                state.tile_x = v
                -- Store as int 0/1. The ez.storage.set_pref binding's
                -- boolean path currently round-trips to 0 via putBool,
                -- so integer storage is the reliable workaround.
                ez.storage.set_pref("wp_tile_x", v and 1 or 0)
            end,
        })
    )

    content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
        ui.toggle("Tile vertically", state.tile_y, {
            on_change = function(v)
                state.tile_y = v
                ez.storage.set_pref("wp_tile_y", v and 1 or 0)
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 8, 4, 8 },
        ui.text_widget(
            "Tiling wraps the wallpaper so panning doesn't reveal empty strips.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Auto pan", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.dropdown(PAN_LABELS, {
            value = index_of(PAN_VALUES, state.pan, 1),
            on_change = function(idx)
                local v = PAN_VALUES[idx] or "none"
                state.pan = v
                ez.storage.set_pref("wp_pan", v)
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.slider({
            label = "Speed",
            value = state.pan_speed,
            min = 1, max = 10, step = 1,
            on_change = function(v)
                state.pan_speed = v
                ez.storage.set_pref("wp_pan_speed", v)
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 8, 8, 8 },
        ui.text_widget(
            "Bounce eases back and forth. Drift moves one way and wraps (needs tiling). Wander moves to random spots.",
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
