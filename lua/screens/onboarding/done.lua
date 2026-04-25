-- Onboarding final step — set the onboarded pref and unwind.
--
-- Per the issue, the done screen is the only place that writes the
-- onboarded flag. Earlier steps persist their own field on ENTER so a
-- power loss mid-flow keeps that progress; the gate that says "skip
-- the wizard at boot" only flips here, after the user has actually
-- arrived at the final screen.

local ui = require("ezui")
local M  = require("screens.onboarding")

local Done = { title = "All set!" }

function Done:_finish()
    ez.storage.set_pref(M.PREF_ONBOARDED, "1")
    M.finish()
end

function Done:on_enter()
    -- Mark onboarded as soon as the user reaches this screen — the
    -- only thing left is dismissal, and that shouldn't be re-litigated
    -- on a future boot if e.g. the battery dies before they press a
    -- key. Idempotent on a "Repeat onboarding" run.
    ez.storage.set_pref(M.PREF_ONBOARDED, "1")
end

function Done:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("All set!", { right = M.progress_label("done") }),
        ui.scroll({ grow = 1 },
            ui.padding({ 12, 14, 10, 14 },
                ui.vbox({ gap = 6 }, {
                    ui.text_widget("You're ready to go.",
                        { color = "ACCENT", font = "medium_aa" }),
                    ui.text_widget(
                        "Settings can fine-tune any of these later. " ..
                        "Press ENTER to drop to the desktop.",
                        { color = "TEXT", font = "small_aa", wrap = true }),
                    ui.padding({ 12, 0, 0, 0 },
                        ui.button("Open desktop", {
                            on_press = function() self:_finish() end,
                        })
                    ),
                })
            )
        ),
    })
end

function Done:handle_key(key)
    if key.special == "ENTER" then
        self:_finish()
        return "handled"
    end
    -- Don't let the user back out of "All set!" — the pref is already
    -- written, so backing up would just take them to the optional
    -- identity step from a state that's already complete. Swallow.
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "handled"
    end
    return nil
end

return Done
