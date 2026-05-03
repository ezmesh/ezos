-- Radio settings: mesh advertisement controls.
--
-- An ADVERT is a flood-routed packet announcing this node's identity,
-- name, role, and optional location. Neighbouring nodes use them to
-- populate their contact list and build routing hints.
--
-- The firmware ships with auto-advert disabled so a freshly flashed
-- device is silent until the user decides how chatty it should be.
-- This screen exposes two axes:
--   * a toggle for periodic announce (off when interval is 0)
--   * a preset picker for the period (5 min / 30 min / 1 h / 6 h / 24 h)
--   * a "Send advert now" button for a one-shot announce
--
-- Both settings are persisted to NVS and re-applied by boot.lua on the
-- next cold start. See `PREF_ADV_INTERVAL` below for the pref key.

local ui = require("ezui")

local Radio = { title = "Radio" }

-- NVS is limited to 15-char keys, hence the abbreviated name. The value
-- is the announce interval in milliseconds; 0 means "auto-advert off".
-- The same key is read in lua/boot.lua to apply the interval at boot.
local PREF_ADV_INTERVAL = "adv_interval_ms"

-- Radio band presets. Mirrors the four entries the onboarding wizard
-- offers (screens/onboarding/region.lua) so changing the band post-
-- onboarding doesn't require running the wizard again. Keep the two
-- lists in sync if you add a new region; the wizard hard-codes them
-- because it needs them before this screen module is loaded.
local BAND_PRESETS = {
    { label = "EU 869 MHz", mhz = 869.618 },
    { label = "US 915 MHz", mhz = 906.875 },
    { label = "AS 433 MHz", mhz = 433.000 },
    { label = "AU 915 MHz", mhz = 915.000 },
}

local function band_index_for(mhz)
    for i, p in ipairs(BAND_PRESETS) do
        if math.abs(p.mhz - mhz) < 0.01 then return i end
    end
    return 1
end

-- Preset choices kept explicit so the UI label and stored ms value can't
-- drift. Order matches the dropdown display order (shortest first).
local INTERVAL_PRESETS = {
    { label = "5 minutes",  ms =      300000 },
    { label = "30 minutes", ms =     1800000 },
    { label = "1 hour",     ms =     3600000 },
    { label = "6 hours",    ms =    21600000 },
    { label = "24 hours",   ms =    86400000 },
}

-- Map a stored ms value to the closest preset index. Used when rebuilding
-- state from the pref — if a past firmware wrote a custom value that no
-- longer matches any preset, we still pick the nearest one so the UI
-- shows something sensible.
local function preset_index_for(ms)
    if not ms or ms <= 0 then return 1 end
    local best_i, best_delta = 1, math.huge
    for i, p in ipairs(INTERVAL_PRESETS) do
        local d = math.abs(p.ms - ms)
        if d < best_delta then best_i, best_delta = i, d end
    end
    return best_i
end

-- Format the current announce interval for the status line.
local function interval_label(ms)
    if not ms or ms == 0 then return "Off" end
    for _, p in ipairs(INTERVAL_PRESETS) do
        if p.ms == ms then return "Every " .. p.label end
    end
    -- Custom value written by a future screen — just show minutes.
    return string.format("Every %.0f min", ms / 60000)
end

function Radio.initial_state()
    local saved = tonumber(ez.storage.get_pref(PREF_ADV_INTERVAL, 0)) or 0
    -- Stored as string -- ez.storage.set_pref(float) routes through
    -- putFloat which lands as a NVS blob the read-back path can't
    -- decode, so the wizard stringifies and we follow suit.
    local saved_mhz = tonumber(ez.storage.get_pref("radio_freq_mhz", "")) or 0
    return {
        enabled     = saved > 0,
        -- If the toggle is off but the user previously picked a preset,
        -- we remember the choice so flipping the toggle back on restores
        -- the same interval rather than forcing a re-pick.
        preset_idx  = preset_index_for(saved),
        band_idx    = (saved_mhz > 0) and band_index_for(saved_mhz) or 1,
        last_action = nil,  -- "Sent" / "Saved" transient feedback
    }
end

local function apply_interval(state)
    local ms = state.enabled and INTERVAL_PRESETS[state.preset_idx].ms or 0
    ez.mesh.set_announce_interval(ms)
    ez.storage.set_pref(PREF_ADV_INTERVAL, ms)
end

function Radio:build(state)
    local content = {}

    -- Section: Band picker. Switching here applies the new frequency
    -- to the radio immediately so the user gets feedback (mesh
    -- briefly drops + re-tunes) and persists `radio_freq_mhz` so
    -- boot.lua restores the choice on the next cold start.
    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Band", { color = "ACCENT", font = "small_aa" })
    )

    do
        local band_labels = {}
        for _, p in ipairs(BAND_PRESETS) do
            band_labels[#band_labels + 1] = p.label
        end
        content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
            ui.dropdown(band_labels, {
                value = state.band_idx,
                on_change = function(idx)
                    local preset = BAND_PRESETS[idx]
                    if not preset then return end
                    state.band_idx = idx
                    if ez.radio and ez.radio.set_frequency then
                        ez.radio.set_frequency(preset.mhz)
                    end
                    ez.storage.set_pref("radio_freq_mhz",
                        tostring(preset.mhz))
                    state.last_action = "Band: " .. preset.label
                    self:set_state({})
                end,
            })
        )
    end

    content[#content + 1] = ui.padding({ 2, 8, 8, 8 },
        ui.text_widget(
            "All nodes in your mesh must use the same band. " ..
            "Switching here re-tunes the radio immediately and the " ..
            "choice persists across reboots.",
            { wrap = true, color = "TEXT_MUTED", font = "tiny_aa" }
        )
    )

    -- Section: Auto-advert toggle + interval picker
    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Auto-advert", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.toggle("Enabled", state.enabled, {
            on_change = function(val)
                state.enabled = val
                apply_interval(state)
                state.last_action = val and "Auto-advert on" or "Auto-advert off"
                self:set_state({})
            end,
        })
    )

    -- Interval presets. The dropdown is only meaningful when the toggle
    -- is on; we still let the user pick while off so the choice sticks
    -- for when they re-enable it.
    local options = {}
    for _, p in ipairs(INTERVAL_PRESETS) do
        options[#options + 1] = p.label
    end
    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.dropdown(options, {
            value = state.preset_idx,
            on_change = function(idx)
                state.preset_idx = idx
                apply_interval(state)
                state.last_action = "Interval set to " .. INTERVAL_PRESETS[idx].label
                self:set_state({})
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 8, 6, 8 },
        ui.text_widget(
            "Current: " .. interval_label(state.enabled
                and INTERVAL_PRESETS[state.preset_idx].ms or 0),
            { color = "TEXT_MUTED", font = "tiny_aa" }
        )
    )

    -- Section: one-shot
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Manual", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.list_item({
        title = "Send advert now",
        subtitle = "One-shot flood announce",
        on_press = function()
            local ok = ez.mesh.send_announce()
            state.last_action = ok and "Advert sent"
                or "Advert failed (radio not ready?)"
            self:set_state({})
        end,
    })

    if state.last_action then
        content[#content + 1] = ui.padding({ 8, 8, 8, 8 },
            ui.text_widget(state.last_action, {
                color = "TEXT_SEC", font = "tiny_aa",
            })
        )
    end

    -- Section: explanation
    content[#content + 1] = ui.padding({ 12, 8, 8, 8 },
        ui.text_widget(
            "Adverts announce this node to the mesh. Disabled by default " ..
            "to keep a fresh device silent; enable to let neighbours " ..
            "discover you automatically.",
            { color = "TEXT_MUTED", font = "tiny_aa", wrap = true }
        )
    )

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Radio", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Radio:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Radio
