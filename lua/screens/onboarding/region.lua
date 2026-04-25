-- Onboarding step 3 of 5 — radio region / frequency.
--
-- LoRa is regulated per region. Picking the wrong band is illegal in
-- most countries and won't reach any neighbours anyway. The wizard
-- offers a handful of well-known presets shared with Settings -> Radio
-- via util.regions.

local ui      = require("ezui")
local M       = require("screens.onboarding")
local regions = require("util.regions")

local PATH = "screens.onboarding.region"

local Region = { title = "Region" }

function Region.initial_state()
    return { idx = regions.current_index() }
end

function Region:_commit(idx)
    if regions.apply_index(idx) then
        M.advance(PATH)
    end
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
                        ui.dropdown(regions.LABELS, {
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
