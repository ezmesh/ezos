-- Onboarding step 3 of 5 — radio region / frequency.
--
-- LoRa is regulated per region. Picking the wrong band is illegal in
-- most countries and won't reach any neighbours anyway. The wizard
-- offers four well-known presets; advanced users can fine-tune later
-- via the radio API or the Settings → Radio screen.
--
-- The pick is persisted under `radio_freq_mhz` and re-applied at boot
-- by lua/boot.lua. The hardware change happens immediately so the user
-- gets feedback (mesh is_initialized flips off briefly while the radio
-- re-tunes, then back on).

local ui = require("ezui")
local M  = require("screens.onboarding")

local PATH = "screens.onboarding.region"

local PRESETS = {
    { label = "EU 869 MHz", mhz = 869.618 },
    { label = "US 915 MHz", mhz = 906.875 },
    { label = "AS 433 MHz", mhz = 433.000 },
    { label = "AU 915 MHz", mhz = 915.000 },
}

local LABELS = {}
for i, p in ipairs(PRESETS) do LABELS[i] = p.label end

-- The MHz value is stored as a string (e.g. "869.525") rather than a
-- number: ez.storage.set_pref routes lua floats through putFloat → blob,
-- but the matching get_pref has no float decoder and returns "" for
-- blobs. Stringifying side-steps the round-trip.
local function default_index()
    local raw = ez.storage.get_pref("radio_freq_mhz", "")
    local saved = tonumber(raw) or 0
    if saved > 0 then
        for i, p in ipairs(PRESETS) do
            if math.abs(p.mhz - saved) < 0.01 then return i end
        end
    end
    return 1
end

local Region = { title = "Region" }

function Region.initial_state()
    return { idx = default_index() }
end

function Region:_commit(idx)
    local preset = PRESETS[idx]
    if not preset then return end
    if ez.radio and ez.radio.set_frequency then
        ez.radio.set_frequency(preset.mhz)
    end
    ez.storage.set_pref("radio_freq_mhz", tostring(preset.mhz))
    M.advance(PATH)
end

function Region:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Region", { back = true, right = M.progress_label(PATH) }),
        ui.scroll({ grow = 1 },
            ui.padding({ 10, 12, 10, 12 },
                ui.vbox({ gap = 6 }, {
                    ui.text_widget("Which radio band are you using?",
                        { color = "TEXT", font = "small_aa", wrap = true }),
                    ui.text_widget(
                        "Pick the legal band for your country. All nodes " ..
                        "in your mesh must use the same band.",
                        { color = "TEXT_MUTED", font = "tiny_aa", wrap = true }),
                    ui.padding({ 6, 0, 0, 0 },
                        ui.dropdown(LABELS, {
                            value = state.idx,
                            on_change = function(idx) state.idx = idx end,
                        })
                    ),
                    ui.padding({ 12, 0, 0, 0 },
                        ui.button("Continue", {
                            on_press = function() self:_commit(state.idx) end,
                        })
                    ),
                })
            )
        ),
    })
end

function Region:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Region
