-- Prompt screen: single-line text input with title + message.
--
-- Callbacks arrive through `state.on_submit(value)` / `state.on_cancel()`
-- which the dialog module sets up when pushing the screen. ENTER runs
-- on_submit and pops; BACKSPACE on an empty field (or the physical
-- back key at any time) runs on_cancel and pops.
--
-- The input row is a custom node so we can control the caret/blink
-- directly and keep the screen's event loop simple — no focus + edit
-- mode dance is needed for a dialog that's always editing.

local ui       = require("ezui")
local theme    = require("ezui.theme")
local node_mod = require("ezui.node")

local Prompt = { title = "Prompt" }

local INPUT_FONT = "small_aa"

if not node_mod.handler("prompt_input") then
    node_mod.register("prompt_input", {
        measure = function(n, max_w, max_h)
            theme.set_font(INPUT_FONT)
            return max_w, theme.font_height() + 10
        end,
        draw = function(n, d, x, y, w, h)
            theme.set_font(INPUT_FONT)
            local fh = theme.font_height()
            local pad = 4

            d.fill_round_rect(x + 2, y + 1, w - 4, h - 2, 4,
                theme.color("SURFACE"))
            d.draw_round_rect(x + 2, y + 1, w - 4, h - 2, 4,
                theme.color("ACCENT"))

            local value = n.value or ""
            local placeholder = n.placeholder
            local tx = x + 2 + pad
            local ty = y + 1 + math.floor((h - 2 - fh) / 2)

            if value == "" and placeholder and placeholder ~= "" then
                d.draw_text(tx, ty, placeholder, theme.color("TEXT_MUTED"))
            else
                d.draw_text(tx, ty, value, theme.color("TEXT"))
            end

            -- Blinking caret at end of value. Invalidate unconditionally
            -- so the blink keeps ticking while the dialog is idle.
            if (ez.system.millis() // 500) % 2 == 0 then
                local cx = tx + theme.text_width(value)
                d.fill_rect(cx, ty, 2, fh, theme.color("ACCENT"))
            end
            require("ezui.screen").invalidate()
        end,
    })
end

function Prompt:build(state)
    local items = {
        ui.title_bar(state.title or "Prompt", { back = true }),
    }
    if state.message and state.message ~= "" then
        items[#items + 1] = ui.padding({ 8, 10, 2, 10 },
            ui.text_widget(state.message, {
                font = INPUT_FONT, color = "TEXT_MUTED", wrap = true,
            }))
    end
    items[#items + 1] = ui.padding({ 4, 10, 4, 10 }, {
        type        = "prompt_input",
        value       = state.value or "",
        placeholder = state.placeholder,
    })
    items[#items + 1] = ui.padding({ 2, 10, 8, 10 },
        ui.text_widget("ENTER to confirm, BACKSPACE to cancel", {
            font = INPUT_FONT, color = "TEXT_MUTED",
        }))
    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Prompt:handle_key(key)
    local state = self._state

    if key.special == "ENTER" then
        local value = state.value or ""
        local cb = state.on_submit
        -- Pop first so the callback runs with the dialog already off
        -- the screen stack — callers usually set status on the caller
        -- screen's state, and we want that reflected on the next frame.
        require("ezui.screen").pop()
        if cb then cb(value) end
        return "handled"
    elseif key.special == "BACKSPACE" then
        if state.value and #state.value > 0 then
            state.value = state.value:sub(1, -2)
            self:set_state({})
            return "handled"
        end
        -- Empty input + BACKSPACE cancels the dialog.
        local cb = state.on_cancel
        require("ezui.screen").pop()
        if cb then cb() end
        return "handled"
    elseif key.character then
        state.value = (state.value or "") .. key.character
        self:set_state({})
        return "handled"
    end
    return nil
end

return Prompt
