-- Map sub-settings: which peers to draw on the offline map.
-- Each toggle writes a single NVS pref; the map screen reads them
-- every frame via pref_on() so changes take effect immediately on
-- back-out (no service restart needed).

local ui = require("ezui")

local Map = { title = "Map" }

-- Keep these in sync with lua/screens/tools/map.lua (PEER_PREF_*).
-- Duplicating the literals beats adding a public surface on a screen
-- module that the rest of the codebase has no reason to import.
local PREF_INFRA   = "map_peer_inf"
local PREF_CONTACT = "map_peer_con"
local PREF_ALL     = "map_peer_all"
local PREF_STALE   = "map_peer_stale"

local function pref_on(key, default_on)
    local v = ez.storage.get_pref(key, default_on and "1" or "0")
    return v == "1" or v == 1 or v == true
end

local function set_pref_bool(key, on)
    ez.storage.set_pref(key, on and "1" or "0")
end

function Map.initial_state()
    return {
        show_infra   = pref_on(PREF_INFRA,   true),
        show_contact = pref_on(PREF_CONTACT, true),
        show_all     = pref_on(PREF_ALL,     false),
        show_stale   = pref_on(PREF_STALE,   false),
    }
end

function Map:build(state)
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Show on map", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 8, 2, 8 },
        ui.toggle("Repeaters and room servers", state.show_infra, {
            on_change = function(v)
                state.show_infra = v
                set_pref_bool(PREF_INFRA, v)
            end,
        })
    )
    content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.text_widget(
            "Infrastructure peers with a known location.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 8, 2, 8 },
        ui.toggle("My contacts", state.show_contact, {
            on_change = function(v)
                state.show_contact = v
                set_pref_bool(PREF_CONTACT, v)
            end,
        })
    )
    content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.text_widget(
            "Chat nodes you have added as contacts.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 8, 2, 8 },
        ui.toggle("All chat nodes", state.show_all, {
            on_change = function(v)
                state.show_all = v
                set_pref_bool(PREF_ALL, v)
            end,
        })
    )
    content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.text_widget(
            "Every chat node we have heard from. Off by default for privacy.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Staleness", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 8, 2, 8 },
        ui.toggle("Show stale peers", state.show_stale, {
            on_change = function(v)
                state.show_stale = v
                set_pref_bool(PREF_STALE, v)
            end,
        })
    )
    content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.text_widget(
            "Peers last heard 1-7 days ago render dimmer. Older than 7 days are always hidden.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Map", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Map:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Map
