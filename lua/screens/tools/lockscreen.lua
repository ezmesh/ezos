-- The session lockscreen overlay (issue #119). Pushed on top of the
-- screen stack by `services.lockscreen.lock()`. While this screen is
-- on top, the global key path treats it as an exclusive consumer:
-- nothing underneath sees keypresses, and there is no way to dismiss
-- the screen except by entering the right PIN / passphrase.
--
-- The screen knows its mode from `services.lockscreen.get_mode()` so
-- the layout adapts to PIN (dots + numeric input) or passphrase
-- (plain text input).

local ui   = require("ezui")
local lock = require("services.lockscreen")

local Lockscreen = { title = "Locked" }

function Lockscreen.initial_state()
    return {
        input      = "",
        message    = nil,
        is_error   = false,
        busy       = false,
        cooldown_label = nil,
    }
end

local function dot_string(len)
    if len <= 0 then return "" end
    return string.rep("*", len)
end

function Lockscreen:_update_cooldown_label()
    local rem = lock.cooldown_remaining()
    local label = nil
    if rem > 0 then
        label = string.format("Wait %ds before next attempt",
                              math.ceil(rem / 1000))
    end
    if label ~= self._state.cooldown_label then
        self:set_state({ cooldown_label = label })
    end
end

function Lockscreen:on_enter()
    -- Force a periodic rebuild so the cooldown countdown ticks down
    -- visibly. The screen.lua main loop redraws at 30 FPS but state
    -- changes are what trigger rebuilds, so we schedule a timer.
    local function tick()
        if require("ezui.screen").peek() == self then
            self:_update_cooldown_label()
            ez.system.set_timer(500, tick)
        end
    end
    ez.system.set_timer(500, tick)
end

function Lockscreen:build(state)
    local mode = lock.get_mode()
    local items = {}

    items[#items + 1] = ui.padding({ 14, 12, 8, 12 },
        ui.text_widget("Locked", { color = "ACCENT" }))

    items[#items + 1] = ui.padding({ 0, 12, 12, 12 },
        ui.text_widget(
            mode == "pin"
                and "Enter your PIN to continue."
                or  "Enter your passphrase to continue.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" }))

    if mode == "pin" then
        -- PIN: show dots above the input. The input itself is a
        -- numeric text_input; for the v1 we render as text and rely
        -- on the user to type digits via alt+letter.
        items[#items + 1] = ui.padding({ 4, 12, 12, 12 },
            ui.text_widget(dot_string(#(state.input or "")),
                { color = "ACCENT" }))
    end

    items[#items + 1] = ui.padding({ 0, 12, 8, 12 },
        ui.text_input({
            value = state.input or "",
            placeholder = mode == "pin" and "PIN" or "passphrase",
            on_change = function(v) state.input = v end,
        }))

    if state.message then
        items[#items + 1] = ui.padding({ 0, 12, 8, 12 },
            ui.text_widget(state.message,
                { wrap = true, font = "small_aa",
                  color = state.is_error and "ERROR" or "ACCENT" }))
    end

    if state.cooldown_label then
        items[#items + 1] = ui.padding({ 0, 12, 8, 12 },
            ui.text_widget(state.cooldown_label,
                { wrap = true, font = "small_aa", color = "ERROR" }))
    end

    items[#items + 1] = ui.padding({ 4, 12, 12, 12 },
        ui.button("Unlock", {
            on_press = function() self:_try() end,
        }))

    return ui.vbox({ gap = 0, bg = "BG" }, {
        -- No title bar with a back arrow -- there is no escape route.
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, items)),
    })
end

function Lockscreen:_try()
    if self._state.busy then return end
    self:set_state({ busy = true, message = "Checking...", is_error = false })
    local ok, err = lock.try_unlock(self._state.input or "")
    self._state.busy = false
    if ok then
        -- Pop ourselves off the stack. Caller doesn't need to do
        -- anything special; the underlying screens resume.
        require("ezui.screen").pop()
        return
    end
    -- Wipe the typed value so a shoulder-surfer can't recover it.
    self:set_state({
        busy     = false,
        message  = err == "cooldown" and "Slow down" or "Wrong",
        is_error = true,
        input    = "",
    })
end

function Lockscreen:handle_key(key)
    -- ENTER submits even without focusing the button, since the user
    -- is typing into the input field above.
    local focus_mod = require("ezui.focus")
    if key.special == "ENTER" then
        if not focus_mod.editing then
            -- Edge case: focus moved off the field. Pull it back
            -- without losing typed input.
        end
        self:_try()
        return "consumed"
    end
    -- Block BACK / ESCAPE -- there is no exit path here.
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        if not focus_mod.editing then
            return "consumed"
        end
        -- Inside the text input, BACKSPACE deletes a character. Let
        -- the text_input handle it normally.
    end
    return nil
end

return Lockscreen
