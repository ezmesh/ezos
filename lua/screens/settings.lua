-- Settings screen
-- Device configuration: display brightness, keyboard backlight, accent color.

local ui = require("ezui")
local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local focus_mod = require("ezui.focus")

-- Register color swatch node (selectable color square)
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
            -- Allow LEFT/RIGHT to move between swatches horizontally
            if key.special == "LEFT" then
                focus_mod.prev()
                return "handled"
            elseif key.special == "RIGHT" then
                focus_mod.next()
                return "handled"
            end
            return nil
        end,
    })
end

local Settings = { title = "Settings" }

function Settings:build(state)
    local items = {}
    items[#items + 1] = ui.title_bar("Settings", { back = true })

    local content_items = {}

    -- Section header: Display
    content_items[#content_items + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Display", { color = "ACCENT", font = "small" })
    )

    local brightness = state.brightness or 200
    local kb_bl = state.kb_backlight or 0

    content_items[#content_items + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.slider({
            label = "Brightness",
            value = brightness,
            min = 10,
            max = 255,
            step = 15,
            on_change = function(val)
                ez.display.set_brightness(val)
                ez.storage.set_pref("display_brightness", val)
                state.brightness = val
            end,
        })
    )

    content_items[#content_items + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.slider({
            label = "KB Light",
            value = kb_bl,
            min = 0,
            max = 255,
            step = 15,
            on_change = function(val)
                ez.keyboard.set_backlight(val)
                ez.storage.set_pref("kb_backlight", val)
                state.kb_backlight = val
            end,
        })
    )

    -- Section header: Accent Color
    content_items[#content_items + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Accent Color", { color = "ACCENT", font = "small" })
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

    content_items[#content_items + 1] = ui.padding({ 4, 8, 8, 8 },
        ui.hbox({ gap = 4 }, swatches)
    )

    -- Section header: Input
    content_items[#content_items + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Input", { color = "ACCENT", font = "small" })
    )

    content_items[#content_items + 1] = ui.list_item({
        title = "Keyboard",
        subtitle = "Key repeat, trackball mode",
        on_press = function()
            local screen_mod = require("ezui.screen")
            local KB = require("screens.keyboard_settings")
            local init = KB.initial_state and KB.initial_state() or {}
            screen_mod.push(screen_mod.create(KB, init))
        end,
    })

    for _, ci in ipairs(content_items) do
        items[#items + 1] = ci
    end

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Settings.initial_state()
    return {
        brightness = tonumber(ez.storage.get_pref("display_brightness", 200)) or 200,
        kb_backlight = tonumber(ez.storage.get_pref("kb_backlight", 0)) or 0,
    }
end

function Settings:handle_key(key)
    if key.character == "q" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Settings
