-- Boot-time passphrase entry for the locked identity (issue #118).
--
-- Two modes: "unlock" (entered at boot when ez.identity.is_locked()
-- is true) and "set" (offered from Settings -> Security when no
-- wrapped blob exists yet). The screen takes care of input + a basic
-- exponential backoff on unlock failure; the actual crypto lives in
-- services/identity_lock.
--
-- This screen does NOT continue boot on success -- it just calls the
-- caller-supplied `on_unlock` / `on_set` callback. boot.lua's gate is
-- responsible for advancing once the callback fires.

local ui   = require("ezui")
local lock = require("services.identity_lock")

local Passphrase = { title = "Passphrase" }

local FAIL_BACKOFF_MS = { 1000, 2000, 4000, 8000, 16000, 32000, 60000 }

local function backoff_for(fail_count)
    if fail_count <= 0 then return 0 end
    local idx = math.min(fail_count, #FAIL_BACKOFF_MS)
    return FAIL_BACKOFF_MS[idx]
end

function Passphrase.initial_state(opts)
    opts = opts or {}
    return {
        mode        = opts.mode or "unlock",   -- "unlock" / "set" / "change" / "remove"
        on_done     = opts.on_done,
        on_cancel   = opts.on_cancel,
        old_pass    = "",
        pass        = "",
        confirm     = "",
        message     = nil,
        is_error    = false,
        busy        = false,
        fail_count  = 0,
        lockout_until = 0,
    }
end

local function now_ms()
    return (ez.system and ez.system.millis and ez.system.millis()) or 0
end

local function header_text(mode)
    if mode == "set"    then return "Set passphrase"   end
    if mode == "change" then return "Change passphrase" end
    if mode == "remove" then return "Remove passphrase" end
    return "Unlock identity"
end

local function intro_text(mode)
    if mode == "set" then
        return "Pick a passphrase to encrypt your identity key. " ..
               "Without it the device can't sign messages, read your " ..
               "DM history, or join your channels. There is NO " ..
               "recovery if you forget it. Type it twice."
    elseif mode == "change" then
        return "Enter your current passphrase, then a new one twice. " ..
               "The old one stops working as soon as the new one is " ..
               "stored."
    elseif mode == "remove" then
        return "Removes the passphrase and restores the plaintext " ..
               "identity key to NVS. Anyone who picks up the device " ..
               "from now on can sign as you. Type your current " ..
               "passphrase to confirm."
    end
    return "Enter your passphrase to unlock the device. After too " ..
           "many wrong attempts the device will throttle further " ..
           "tries."
end

function Passphrase:build(state)
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget(header_text(state.mode),
            { color = "ACCENT", font = "small_aa" }))

    content[#content + 1] = ui.padding({ 4, 8, 8, 8 },
        ui.text_widget(intro_text(state.mode),
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" }))

    if state.mode == "change" or state.mode == "remove" then
        content[#content + 1] = ui.padding({ 6, 8, 2, 8 },
            ui.text_widget("Current passphrase",
                { font = "small_aa", color = "TEXT_SEC" }))
        content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
            ui.text_input({
                value = state.old_pass or "",
                placeholder = "",
                on_change = function(v) state.old_pass = v end,
            }))
    end

    if state.mode ~= "remove" then
        local label = state.mode == "unlock" and "Passphrase" or "New passphrase"
        content[#content + 1] = ui.padding({ 6, 8, 2, 8 },
            ui.text_widget(label,
                { font = "small_aa", color = "TEXT_SEC" }))
        content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
            ui.text_input({
                value = state.pass or "",
                placeholder = "",
                on_change = function(v) state.pass = v end,
            }))
    end

    if state.mode == "set" or state.mode == "change" then
        content[#content + 1] = ui.padding({ 4, 8, 2, 8 },
            ui.text_widget("Confirm",
                { font = "small_aa", color = "TEXT_SEC" }))
        content[#content + 1] = ui.padding({ 0, 8, 6, 8 },
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

    local locked_ms = state.lockout_until and (state.lockout_until - now_ms())
    local locked_out = locked_ms and locked_ms > 0
    local btn_label
    if state.mode == "set" then     btn_label = "Encrypt key"
    elseif state.mode == "change" then btn_label = "Change passphrase"
    elseif state.mode == "remove" then btn_label = "Remove encryption"
    else                            btn_label = "Unlock"
    end
    if state.busy then btn_label = "Working..." end
    if locked_out then
        btn_label = string.format("Wait %ds", math.ceil(locked_ms / 1000))
    end

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.button(btn_label, {
            on_press = function()
                if state.busy or locked_out then return end
                self:_try(state)
            end,
        }))

    if state.on_cancel then
        content[#content + 1] = ui.padding({ 4, 8, 8, 8 },
            ui.button("Cancel", {
                on_press = function()
                    if state.busy then return end
                    state.on_cancel()
                end,
            }))
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar(header_text(state.mode),
                     state.on_cancel and { back = true } or nil),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Passphrase:_try(state)
    local mode = state.mode
    state.busy = true
    self:set_state({ busy = true, message = "Working...", is_error = false })

    local ok, err
    if mode == "set" then
        if state.pass == "" then
            self:set_state({ busy = false, message = "Passphrase required",
                             is_error = true })
            return
        end
        if state.pass ~= state.confirm then
            self:set_state({ busy = false, message = "Passphrases don't match",
                             is_error = true })
            return
        end
        ok, err = lock.wrap(state.pass)
    elseif mode == "change" then
        if state.pass ~= state.confirm then
            self:set_state({ busy = false, message = "New passphrases don't match",
                             is_error = true })
            return
        end
        ok, err = lock.change(state.old_pass, state.pass)
    elseif mode == "remove" then
        ok, err = lock.remove(state.old_pass)
    else  -- unlock
        ok, err = lock.unlock(state.pass)
    end

    state.busy = false
    if ok then
        if state.on_done then state.on_done() end
        self:set_state({ busy = false, message = "Done", is_error = false })
        return
    end

    -- Failure path. Reset typed passwords so a shoulder-surfer can't
    -- recover what the user typed by re-entering the screen.
    if mode == "unlock" then
        state.fail_count = (state.fail_count or 0) + 1
        local backoff = backoff_for(state.fail_count)
        state.lockout_until = now_ms() + backoff
        self:set_state({
            busy = false,
            message = (err or "Failed") .. string.format(
                "  (#%d, wait %ds)", state.fail_count,
                math.ceil(backoff / 1000)),
            is_error = true,
            pass = "",
        })
    else
        self:set_state({
            busy = false,
            message = err or "Failed",
            is_error = true,
        })
    end
end

function Passphrase:handle_key(key)
    -- Don't pop while typing.
    local focus_mod = require("ezui.focus")
    if not focus_mod.editing then
        if key.special == "BACKSPACE" or key.special == "ESCAPE" then
            if self._state.on_cancel then
                self._state.on_cancel()
                return "consumed"
            end
            -- No cancel callback: this is the boot-time unlock screen
            -- and back has nowhere to go. Swallow the key.
            return "consumed"
        end
    end
    return nil
end

return Passphrase
