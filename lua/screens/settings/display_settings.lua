-- Display sub-settings: backlight, keyboard backlight, accent colour.

local ui        = require("ezui")
local theme     = require("ezui.theme")
local node_mod  = require("ezui.node")
local focus_mod = require("ezui.focus")

-- color_swatch node is also registered by the parent settings screen if
-- the user visits this page first. Guard registration so re-entry doesn't
-- redefine the handler.
if not node_mod.handler("color_swatch") then
    node_mod.register("color_swatch", {
        focusable = true,

        measure = function(n, max_w, max_h)
            local size = n.size or 26
            return size, size
        end,

        draw = function(n, d, x, y, w, h)
            local color = n.color or 0xFFFF
            local focused = n._focused
            local selected = n.selected

            d.fill_round_rect(x + 2, y + 2, w - 4, h - 4, 3, color)
            if focused then
                d.draw_round_rect(x, y, w, h, 4, theme.color("TEXT"))
            elseif selected then
                d.draw_round_rect(x + 1, y + 1, w - 2, h - 2, 3, theme.color("TEXT_SEC"))
            end
        end,

        on_activate = function(n, key)
            if n.on_press then n.on_press() end
            return "handled"
        end,

        on_key = function(n, key)
            if key.special == "LEFT" then
                focus_mod.prev()
                return "handled"
            elseif key.special == "RIGHT" then
                focus_mod.next()
                return "handled"
            elseif key.special == "UP" then
                while focus_mod.index > 1 do
                    focus_mod.prev()
                    local cur = focus_mod.current()
                    if not cur or cur.type ~= "color_swatch" then break end
                end
                return "handled"
            elseif key.special == "DOWN" then
                while focus_mod.index < #focus_mod.chain do
                    focus_mod.next()
                    local cur = focus_mod.current()
                    if not cur or cur.type ~= "color_swatch" then break end
                end
                return "handled"
            end
            return nil
        end,
    })
end

local Display = { title = "Display" }

function Display.initial_state()
    return {
        brightness   = tonumber(ez.storage.get_pref("display_brightness", 200)) or 200,
        kb_backlight = tonumber(ez.storage.get_pref("kb_backlight", 0)) or 0,
    }
end

function Display:build(state)
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Theme", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 4, 6 },
        ui.toggle("Dark mode", theme.name == "dark", {
            on_change = function(on)
                local name = on and "dark" or "light"
                theme.set(name)
                ez.storage.set_pref("theme", name)
                -- Repaint so the surrounding rows pick up the new palette.
                self:set_state({})
            end,
        })
    )

    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Backlights", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.slider({
            label = "Display",
            value = state.brightness,
            min = 10, max = 255, step = 15,
            on_change = function(val)
                ez.display.set_brightness(val)
                ez.storage.set_pref("display_brightness", val)
                state.brightness = val
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.slider({
            label = "Keyboard",
            value = state.kb_backlight,
            min = 0, max = 255, step = 15,
            on_change = function(val)
                ez.keyboard.set_backlight(val)
                ez.storage.set_pref("kb_backlight", val)
                state.kb_backlight = val
            end,
        })
    )

    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Accent colour", { color = "ACCENT", font = "small_aa" })
    )

    local swatches = {}
    local current_accent = theme.color("ACCENT")
    for _, preset in ipairs(theme.ACCENT_PRESETS) do
        swatches[#swatches + 1] = {
            type = "color_swatch",
            color = preset.color,
            selected = (preset.color == current_accent),
            on_press = function()
                theme.save_accent(preset.color)
                self:set_state({})
            end,
        }
    end
    content[#content + 1] = ui.padding({ 4, 8, 8, 8 },
        ui.hbox({ gap = 4 }, swatches)
    )

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Display", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Display:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Display
