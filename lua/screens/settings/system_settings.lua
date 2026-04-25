-- System settings: device-level operations.
--
-- "Repeat onboarding" pushes the wizard root again so a user who
-- skimmed the first run can re-do it without manually clearing the
-- onboarded pref. Future entries (factory reset, backup/restore) can
-- live here too.

local ui    = require("ezui")
local icons = require("ezui.icons")

local System = { title = "System" }

function System:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("System", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, {
            ui.list_item({
                title    = "Repeat onboarding",
                subtitle = "Walk through the first-run wizard again",
                icon     = icons.settings,
                on_press = function()
                    require("screens.onboarding").start()
                end,
            }),
        })),
    })
end

function System:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return System
