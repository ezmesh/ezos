-- Onboarding optional — callsign.
--
-- Free-text, max 16 chars, ASCII only. Skipping clears the pref so a
-- user who picked a callsign on a prior run, then ran "Repeat
-- onboarding" and skipped this step, doesn't keep the stale value.

local ui = require("ezui")
local M  = require("screens.onboarding")

local PATH = "screens.onboarding.callsign"
local MAX_LEN = 16

local Callsign = { title = "Callsign" }

function Callsign.initial_state()
    local current = ez.storage.get_pref("callsign", "")
    return { value = M.ascii_only(current or "") }
end

function Callsign:_commit(raw)
    local value = M.ascii_only(raw or "")
    ez.storage.set_pref("callsign", value)
    M.advance(PATH)
end

function Callsign:_skip()
    ez.storage.set_pref("callsign", "")
    M.advance(PATH)
end

function Callsign:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Callsign", { back = true, right = M.progress_label(PATH) }),
        ui.scroll({ grow = 1 },
            ui.padding({ 10, 12, 10, 12 },
                ui.vbox({ gap = 6 }, {
                    ui.text_widget("Optional: pick a callsign",
                        { color = "TEXT", font = "small_aa", wrap = true }),
                    ui.text_widget(
                        "Some chat and DM screens show this next to your " ..
                        "name. Leave blank to skip; you can set it later " ..
                        "from Settings.",
                        { color = "TEXT_MUTED", font = "tiny_aa", wrap = true }),
                    ui.padding({ 4, 0, 0, 0 },
                        ui.text_input({
                            value = state.value or "",
                            max_length = MAX_LEN,
                            placeholder = "Callsign",
                            on_change = function(v) state.value = v end,
                            on_submit = function(v) self:_commit(v) end,
                        })
                    ),
                    ui.padding({ 12, 0, 0, 0 },
                        ui.hbox({ gap = 8 }, {
                            ui.button("Continue", {
                                on_press = function() self:_commit(state.value) end,
                            }),
                            ui.button("Skip", {
                                on_press = function() self:_skip() end,
                            }),
                        })
                    ),
                })
            )
        ),
    })
end

function Callsign:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Callsign
