-- Onboarding step 1 of 5 — welcome.
--
-- One screen of prose. ENTER advances. BACKSPACE/ESC are deliberately
-- suppressed: until the user commits the required steps, this screen
-- guards the desktop from being reached.

local ui  = require("ezui")
local M   = require("screens.onboarding")

local PATH = "screens.onboarding.welcome"

local Welcome = { title = "Welcome" }

function Welcome:build(state)
    local body =
        "ezOS is the firmware on this T-Deck. It speaks MeshCore, a " ..
        "long-range encrypted radio mesh -- your messages hop from " ..
        "device to device without needing the internet.\n\n" ..
        "The next few screens set the must-haves: your node name, the " ..
        "radio band you're in, your timezone, and your colour scheme. " ..
        "Each of these can be changed later from Settings.\n\n" ..
        "Press ENTER to begin."

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Welcome", { right = M.progress_label(PATH) }),
        ui.scroll({ grow = 1 },
            ui.padding({ 12, 10, 10, 10 },
                ui.vbox({ gap = 6 }, {
                    ui.text_widget("Welcome to ezOS",
                        { color = "ACCENT", font = "medium_aa" }),
                    ui.text_widget(body,
                        { color = "TEXT", font = "small_aa", wrap = true }),
                })
            )
        ),
    })
end

function Welcome:handle_key(key)
    if key.special == "ENTER" then
        M.advance(PATH)
        return "handled"
    end
    -- BACKSPACE / ESCAPE intentionally swallowed: the user must commit
    -- the required steps before they can reach the desktop.
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "handled"
    end
    return nil
end

return Welcome
