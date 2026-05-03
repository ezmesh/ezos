-- System settings: device-level operations.
--
-- "Repeat onboarding" pushes the wizard root again so a user who
-- skimmed the first run can re-do it without manually clearing the
-- onboarded pref. Future entries (factory reset, backup/restore) can
-- live here too.

local ui         = require("ezui")
local icons      = require("ezui.icons")
local screen_mod = require("ezui.screen")

local System = { title = "System" }

local function push_screen(mod_name)
    local def = require(mod_name)
    local init = def.initial_state and def.initial_state() or {}
    screen_mod.push(screen_mod.create(def, init))
end

-- Push a small modal-style confirm. Two buttons: a destructive primary
-- and a Cancel that just pops. We don't have a generic dialog.confirm
-- so we inline a minimal screen def -- saves a new helper file for
-- a single caller, mirrors the pattern in screens/tools/notifications
-- where the action menu is also defined inline.
local function confirm(title, body, ok_label, on_ok)
    local Confirm = { title = title }

    function Confirm:build(_state)
        return ui.vbox({ gap = 0, bg = "BG" }, {
            ui.title_bar(title, { back = true }),
            ui.padding({ 14, 14, 8, 14 },
                ui.text_widget(body,
                    { font = "small_aa", color = "TEXT", wrap = true })),
            ui.padding({ 6, 14, 4, 14 },
                ui.button(ok_label, {
                    on_press = function()
                        screen_mod.pop()
                        on_ok()
                    end,
                })),
            ui.padding({ 4, 14, 4, 14 },
                ui.button("Cancel", {
                    on_press = function() screen_mod.pop() end,
                })),
        })
    end

    function Confirm:handle_key(k)
        if k.special == "BACKSPACE" or k.special == "ESCAPE" then
            return "pop"
        end
        return nil
    end

    screen_mod.push(screen_mod.create(Confirm, {}))
end

local function rollback_action()
    local running = ez.ota and ez.ota.running_partition and
                    ez.ota.running_partition() or "?"
    confirm("Rollback firmware",
        "Marks the running image (" .. running .. ") bad and " ..
        "reboots into the previous slot. Use this if the current " ..
        "build is broken.",
        "Rollback and reboot",
        function()
            if ez.ota and ez.ota.rollback_and_reboot then
                ez.ota.rollback_and_reboot()
                -- Returns only on failure (no other valid slot to
                -- revert to). Surface that to the user instead of
                -- silently leaving them on the same screen.
                confirm("Rollback failed",
                    "No other valid firmware slot is available. " ..
                    "Push a fresh image via Dev OTA first.",
                    "OK", function() end)
            end
        end)
end

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
            ui.list_item({
                title    = "Dev OTA",
                subtitle = "Push firmware over WiFi from a host",
                icon     = icons.settings,
                on_press = function() push_screen("screens.settings.dev_ota") end,
            }),
            ui.list_item({
                title    = "Claude Bot",
                subtitle = "Chat host URL + bearer token",
                icon     = icons.settings,
                on_press = function() push_screen("screens.settings.claude_bot") end,
            }),
            ui.list_item({
                title    = "Rollback firmware",
                subtitle = "Revert to the previous OTA slot and reboot",
                icon     = icons.settings,
                on_press = rollback_action,
            }),
        })),
    })
end

function System:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return System
