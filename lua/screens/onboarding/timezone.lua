-- Onboarding step 4 of 5 — timezone.
--
-- Reuses the shared util.timezones table so the same picker shows up
-- here and in Settings → Time. Defaults to UTC (the firmware boot
-- default) until the user picks a real region.

local ui  = require("ezui")
local M   = require("screens.onboarding")
local tzs = require("util.timezones")

local PATH = "screens.onboarding.timezone"

local Timezone = { title = "Timezone" }

function Timezone.initial_state()
    return { idx = tzs.current_index() }
end

function Timezone:_commit(idx)
    tzs.apply_index(idx)
    M.advance(PATH)
end

function Timezone:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Timezone", { back = true, right = M.progress_label(PATH) }),
        ui.scroll({ grow = 1 },
            ui.padding({ 10, 12, 10, 12 },
                ui.vbox({ gap = 6 }, {
                    ui.text_widget("Which timezone are you in?",
                        { color = "TEXT", font = "small_aa", wrap = true }),
                    ui.text_widget(
                        "DST transitions happen automatically. The GPS " ..
                        "service can refine the clock once it has a fix.",
                        { color = "TEXT_MUTED", font = "tiny_aa", wrap = true }),
                    ui.padding({ 6, 0, 0, 0 },
                        ui.dropdown(tzs.LABELS, {
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

function Timezone:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Timezone
