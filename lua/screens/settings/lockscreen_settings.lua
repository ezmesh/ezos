-- Settings -> Lockscreen.
--
-- Lets the user choose between "Off", "PIN", and "Passphrase" modes,
-- enter the secret, and clear the lock. The actual lockscreen logic
-- lives in services.lockscreen.

local ui   = require("ezui")
local lock = require("services.lockscreen")

local LockSettings = { title = "Lockscreen" }

function LockSettings.initial_state()
    return {
        mode    = lock.get_mode(),
        secret  = "",
        confirm = "",
        message = nil,
        is_error = false,
    }
end

function LockSettings:_apply()
    local mode = self._state.mode
    if mode == "off" then
        lock.clear()
        self:set_state({ message = "Lockscreen disabled", is_error = false })
        return
    end
    if self._state.secret == "" then
        self:set_state({ message = "Enter a secret", is_error = true })
        return
    end
    if self._state.secret ~= self._state.confirm then
        self:set_state({ message = "Confirm doesn't match", is_error = true })
        return
    end
    if mode == "pin" then
        if not self._state.secret:match("^%d+$") then
            self:set_state({ message = "PIN must be digits", is_error = true })
            return
        end
        if #self._state.secret < 4 or #self._state.secret > 8 then
            self:set_state({ message = "PIN length must be 4..8", is_error = true })
            return
        end
    end
    local ok, err = lock.setup(mode, self._state.secret)
    if ok then
        self:set_state({
            message = "Lockscreen enabled. Next idle period will lock.",
            is_error = false,
            secret = "",
            confirm = "",
        })
    else
        self:set_state({
            message = err or "Failed",
            is_error = true,
        })
    end
end

function LockSettings:build(state)
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Mode", { color = "ACCENT", font = "small_aa" }))

    local mode_labels = { "Off", "PIN", "Passphrase" }
    local mode_values = { "off", "pin", "passphrase" }
    local mode_idx = 1
    for i, v in ipairs(mode_values) do
        if v == state.mode then mode_idx = i; break end
    end
    content[#content + 1] = ui.padding({ 2, 8, 8, 8 },
        ui.dropdown(mode_labels, {
            value = mode_idx,
            on_change = function(idx)
                self:set_state({ mode = mode_values[idx],
                                 secret = "", confirm = "" })
            end,
        }))

    if state.mode ~= "off" then
        content[#content + 1] = ui.padding({ 8, 8, 2, 8 },
            ui.text_widget(state.mode == "pin" and "PIN" or "Passphrase",
                { font = "small_aa", color = "TEXT_SEC" }))
        content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
            ui.text_input({
                value = state.secret or "",
                placeholder = state.mode == "pin" and "4-8 digits" or "",
                on_change = function(v) state.secret = v end,
            }))
        content[#content + 1] = ui.padding({ 4, 8, 2, 8 },
            ui.text_widget("Confirm",
                { font = "small_aa", color = "TEXT_SEC" }))
        content[#content + 1] = ui.padding({ 0, 8, 8, 8 },
            ui.text_input({
                value = state.confirm or "",
                placeholder = "",
                on_change = function(v) state.confirm = v end,
            }))
    end

    if state.message then
        content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
            ui.text_widget(state.message,
                { wrap = true, font = "small_aa",
                  color = state.is_error and "ERROR" or "ACCENT" }))
    end

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.button("Apply", { on_press = function() self:_apply() end }))

    content[#content + 1] = ui.padding({ 8, 8, 8, 8 },
        ui.text_widget(
            "PIN matches numbers entered as alt+letter. Once enabled, " ..
            "the device will lock after the screensaver activates and " ..
            "on every boot. Shift+Alt+K from any screen locks immediately.",
            { wrap = true, font = "small_aa", color = "TEXT_MUTED" }))

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Lockscreen", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function LockSettings:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        local focus_mod = require("ezui.focus")
        if not focus_mod.editing then return "pop" end
    end
    return nil
end

return LockSettings
