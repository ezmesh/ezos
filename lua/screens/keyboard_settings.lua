-- Keyboard settings screen
-- Configure key repeat behavior and trackball input mode. Changes apply
-- immediately and are persisted to NVS.

local ui = require("ezui")

local KB = { title = "Keyboard" }

-- Pref keys (NVS limits to 15 chars)
local PREF_REP_ENABLE = "kb_rep_enable"
local PREF_REP_DELAY  = "kb_rep_delay"
local PREF_REP_RATE   = "kb_rep_rate"
local PREF_TB_INTR    = "kb_tb_intr"

function KB.initial_state()
    return {
        repeat_enabled = ez.keyboard.get_repeat_enabled(),
        repeat_delay   = ez.keyboard.get_repeat_delay(),
        repeat_rate    = ez.keyboard.get_repeat_rate(),
        tb_interrupt   = ez.keyboard.get_trackball_mode() == "interrupt",
    }
end

function KB:build(state)
    local items = {}
    items[#items + 1] = ui.title_bar("Keyboard", { back = true })

    local content = {}

    -- Section: Key Repeat
    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Key Repeat", { color = "ACCENT", font = "small" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.toggle("Enabled", state.repeat_enabled, {
            on_change = function(val)
                state.repeat_enabled = val
                ez.keyboard.set_repeat_enabled(val)
                ez.storage.set_pref(PREF_REP_ENABLE, val and "1" or "0")
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.slider({
            label = "Delay",
            value = state.repeat_delay,
            min = 50,
            max = 1000,
            step = 50,
            on_change = function(val)
                state.repeat_delay = val
                ez.keyboard.set_repeat_delay(val)
                ez.storage.set_pref(PREF_REP_DELAY, val)
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.slider({
            label = "Rate",
            value = state.repeat_rate,
            min = 10,
            max = 200,
            step = 10,
            on_change = function(val)
                state.repeat_rate = val
                ez.keyboard.set_repeat_rate(val)
                ez.storage.set_pref(PREF_REP_RATE, val)
            end,
        })
    )

    -- Section: Trackball
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Trackball", { color = "ACCENT", font = "small" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.toggle("Interrupt Mode", state.tb_interrupt, {
            on_change = function(val)
                state.tb_interrupt = val
                ez.keyboard.set_trackball_mode(val and "interrupt" or "polling")
                ez.storage.set_pref(PREF_TB_INTR, val and "1" or "0")
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 8, 8, 8 },
        ui.text_widget(
            "Interrupt mode: lower latency, more CPU. Polling: power efficient.",
            { color = "TEXT_MUTED", font = "tiny" }
        )
    )

    -- Section: Diagnostics
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Diagnostics", { color = "ACCENT", font = "small" })
    )

    content[#content + 1] = ui.list_item({
        title = "Key Matrix",
        subtitle = "Live raw-mode matrix view",
        on_press = function()
            local screen_mod = require("ezui.screen")
            local M = require("screens.matrix_test")
            screen_mod.push(screen_mod.create(M, {}))
        end,
    })

    for _, c in ipairs(content) do items[#items + 1] = c end

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function KB:handle_key(key)
    if key.character == "q" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return KB
