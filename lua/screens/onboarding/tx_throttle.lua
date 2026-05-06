-- Onboarding step -- TX queue spacing.
--
-- Sets the minimum interval between queued packet transmissions. The
-- driver default is 100 ms; this picker offers one step below (faster,
-- heavier on the channel) and a couple above (more polite to
-- neighbours). Stored under `tx_throttle_ms` and re-applied at boot by
-- lua/boot.lua. Mirrors the picker on Settings -> Radio.

local ui = require("ezui")
local M  = require("screens.onboarding")

local PATH = "screens.onboarding.tx_throttle"
local PREF = "tx_throttle_ms"

-- Keep this in sync with TX_THROTTLE_PRESETS in
-- lua/screens/settings/radio_settings.lua.
local PRESETS = {
    { label = "Fast (50 ms)",     ms =  50 },
    { label = "Default (100 ms)", ms = 100 },
    { label = "Relaxed (200 ms)", ms = 200 },
    { label = "Polite (400 ms)",  ms = 400 },
}

local LABELS = {}
for i, p in ipairs(PRESETS) do LABELS[i] = p.label end

local function default_index()
    local saved = tonumber(ez.storage.get_pref(PREF, 0)) or 0
    if saved <= 0 then return 2 end  -- "Default" is index 2
    local best_i, best_delta = 2, math.huge
    for i, p in ipairs(PRESETS) do
        local d = math.abs(p.ms - saved)
        if d < best_delta then best_i, best_delta = i, d end
    end
    return best_i
end

local TxThrottle = { title = "TX spacing" }

function TxThrottle.initial_state()
    return { idx = default_index() }
end

function TxThrottle:_commit(idx)
    local preset = PRESETS[idx]
    if not preset then return end
    if ez.mesh and ez.mesh.set_tx_throttle then
        ez.mesh.set_tx_throttle(preset.ms)
    end
    ez.storage.set_pref(PREF, preset.ms)
    M.advance(PATH)
end

function TxThrottle:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("TX spacing", { back = true, right = M.progress_label(PATH) }),
        ui.scroll({ grow = 1 },
            ui.padding({ 10, 12, 10, 12 },
                ui.vbox({ gap = 6 }, {
                    ui.text_widget("How fast should the radio drain its send queue?",
                        { color = "TEXT", font = "small_aa", wrap = true }),
                    ui.text_widget(
                        "This is the minimum gap between queued " ..
                        "transmissions. Faster = more responsive but " ..
                        "heavier on the channel. You can change this " ..
                        "later under Settings > Radio.",
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

function TxThrottle:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return TxThrottle
