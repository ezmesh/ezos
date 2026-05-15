-- Settings -> Security.
--
-- Three states surface here:
--
-- 1. No wrap configured: show "Set passphrase" entry.
-- 2. Wrap configured AND device unlocked (we're inside a session
--    after a successful unlock at boot): show "Change passphrase"
--    and "Remove passphrase" entries.
-- 3. Wrap configured AND device locked: this screen is unreachable
--    in practice because the passphrase prompt at boot blocks the
--    rest of the UI. Defensive: show a read-only "Locked" notice.

local ui            = require("ezui")
local lock          = require("services.identity_lock")
local screen_mod    = require("ezui.screen")
local Passphrase    = require("screens.onboarding.passphrase")

local Security = { title = "Security" }

function Security.initial_state()
    return {
        wrapped = lock.is_wrapped(),
        locked  = lock.is_locked(),
    }
end

function Security:on_enter()
    -- Refresh state after returning from the passphrase screen.
    self:set_state({
        wrapped = lock.is_wrapped(),
        locked  = lock.is_locked(),
    })
end

local function push_passphrase(mode, parent)
    local def = Passphrase
    local state = def.initial_state({
        mode = mode,
        on_done = function()
            screen_mod.pop()
            if parent.set_state then
                parent:set_state({
                    wrapped = lock.is_wrapped(),
                    locked  = lock.is_locked(),
                })
            end
        end,
        on_cancel = function() screen_mod.pop() end,
    })
    screen_mod.push(screen_mod.create(def, state))
end

function Security:build(state)
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Identity key",
            { color = "ACCENT", font = "small_aa" }))

    content[#content + 1] = ui.padding({ 4, 8, 8, 8 },
        ui.text_widget(
            "Your Ed25519 identity key lives in NVS. It signs every " ..
            "ADVERT and decrypts every DM. By default it is stored " ..
            "in plaintext -- anyone with USB / serial access (or a " ..
            "reflash) can read it and impersonate you on the mesh.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" }))

    if not state.wrapped then
        content[#content + 1] = ui.list_item({
            title    = "Set passphrase",
            subtitle = "Encrypt the identity key at rest",
            on_press = function() push_passphrase("set", self) end,
        })
        content[#content + 1] = ui.padding({ 4, 8, 8, 8 },
            ui.text_widget(
                "After setting, the device will require the passphrase " ..
                "at every boot before mesh starts. There is NO recovery " ..
                "if you forget it.",
                { wrap = true, color = "TEXT_MUTED", font = "small_aa" }))
    else
        if state.locked then
            content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
                ui.text_widget("Identity is locked.",
                    { color = "ACCENT", font = "small_aa" }))
            content[#content + 1] = ui.padding({ 0, 8, 8, 8 },
                ui.text_widget(
                    "Unlock at boot to access these controls.",
                    { wrap = true, color = "TEXT_MUTED", font = "small_aa" }))
        else
            content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
                ui.text_widget("Identity is encrypted.",
                    { color = "ACCENT", font = "small_aa" }))
            content[#content + 1] = ui.list_item({
                title    = "Change passphrase",
                subtitle = "Re-wrap with a new passphrase",
                on_press = function() push_passphrase("change", self) end,
            })
            content[#content + 1] = ui.list_item({
                title    = "Remove passphrase",
                subtitle = "Restore the plaintext key to NVS",
                on_press = function() push_passphrase("remove", self) end,
            })
        end
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Security", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Security:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Security
