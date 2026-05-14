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

local ROTATE_LABELS = { "Off", "On boot", "Every time shown" }
local ROTATE_VALUES = { "off", "boot", "shown" }

local SCREENSAVER_OPTIONS = {
    { label = "Off",     value = 0 },
    { label = "1 min",   value = 60 },
    { label = "2 min",   value = 120 },
    { label = "5 min",   value = 300 },
    { label = "10 min",  value = 600 },
    { label = "30 min",  value = 1800 },
}

-- Panel-off delay is added AFTER the screensaver fires, so the user-
-- visible "turn off screen after" is ss_timeout + this. 0 disables.
local DISPLAY_OFF_OPTIONS = {
    { label = "Never",   value = 0 },
    { label = "1 min",   value = 1 },
    { label = "2 min",   value = 2 },
    { label = "5 min",   value = 5 },
    { label = "15 min",  value = 15 },
    { label = "30 min",  value = 30 },
}

function Display.initial_state()
    local ss_val = tonumber(ez.storage.get_pref("ss_timeout", 0)) or 0
    local ss_idx = 1
    for i, opt in ipairs(SCREENSAVER_OPTIONS) do
        if opt.value == ss_val then ss_idx = i break end
    end
    local off_val = tonumber(ez.storage.get_pref("disp_off_delay", 5)) or 5
    local off_idx = 4  -- default to "5 min"
    for i, opt in ipairs(DISPLAY_OFF_OPTIONS) do
        if opt.value == off_val then off_idx = i break end
    end
    local wp_val = ez.storage.get_pref("wp_rotate", "boot")
    local wp_idx = 1
    for i, v in ipairs(ROTATE_VALUES) do
        if v == wp_val then wp_idx = i break end
    end
    return {
        brightness   = tonumber(ez.storage.get_pref("screen_bright", 200)) or 200,
        kb_backlight = tonumber(ez.storage.get_pref("kb_backlight", 0)) or 0,
        screensaver  = ss_idx,
        autodim      = (ez.storage.get_pref("ss_autodim", "1") == "1"),
        ss_bright    = tonumber(ez.storage.get_pref("ss_bright", 30)) or 30,
        disp_off     = off_idx,
        wp_rotate    = wp_idx,
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
                ez.storage.set_pref("screen_bright", val)
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
        ui.text_widget("Screensaver", { color = "ACCENT", font = "small_aa" })
    )
    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.dropdown(SCREENSAVER_OPTIONS, {
            value = state.screensaver,
            on_change = function(idx)
                local val = SCREENSAVER_OPTIONS[idx].value
                ez.storage.set_pref("ss_timeout", val)
                state.screensaver = idx
            end,
        })
    )
    content[#content + 1] = ui.padding({ 2, 8, 4, 8 },
        ui.text_widget(
            "Cycles animated patterns to exercise all subpixels and "
            .. "prevent LCD image persistence.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 8, 6, 2, 6 },
        ui.toggle("Auto-dim before screensaver", state.autodim, {
            on_change = function(on)
                state.autodim = on
                ez.storage.set_pref("ss_autodim", on and "1" or "0")
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.slider({
            label = "Screensaver brightness %",
            value = state.ss_bright,
            min = 10, max = 100, step = 5,
            on_change = function(val)
                ez.storage.set_pref("ss_bright", val)
                state.ss_bright = val
            end,
        })
    )

    content[#content + 1] = ui.padding({ 8, 8, 2, 8 },
        ui.text_widget("Turn off screen after",
            { color = "TEXT", font = "small_aa" })
    )
    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.dropdown(DISPLAY_OFF_OPTIONS, {
            value = state.disp_off,
            on_change = function(idx)
                local val = DISPLAY_OFF_OPTIONS[idx].value
                ez.storage.set_pref("disp_off_delay", val)
                state.disp_off = idx
            end,
        })
    )
    content[#content + 1] = ui.padding({ 2, 8, 4, 8 },
        ui.text_widget(
            "Added on top of the screensaver timeout. The backlight "
            .. "turns fully off and the display stops rendering until "
            .. "input or a notification wakes it.",
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Wallpaper", { color = "ACCENT", font = "small_aa" })
    )
    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.dropdown(ROTATE_LABELS, {
            value = state.wp_rotate,
            on_change = function(idx)
                local v = ROTATE_VALUES[idx] or "off"
                state.wp_rotate = idx
                ez.storage.set_pref("wp_rotate", v)
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

    -- Mouse-mode toggle. Lives here rather than in its own Touch
    -- screen because the only interactive setting is the on/off
    -- flag; nesting it under Display keeps the settings tree shallow.
    -- The toggle just delegates to touch_input.set_mouse_mode which
    -- handles persistence, cursor reset, and the screen invalidate.
    local touch_input = require("ezui.touch_input")
    if touch_input.touch_enabled() then
        content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
            ui.text_widget("Touch", { color = "ACCENT", font = "small_aa" })
        )
        content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
            ui.toggle("Mouse cursor mode", touch_input.mouse_mode, {
                on_change = function(on)
                    touch_input.set_mouse_mode(on)
                end,
            })
        )
        content[#content + 1] = ui.padding({ 2, 8, 8, 8 },
            ui.text_widget(
                "Drag to move a crosshair instead of tapping the screen "
                .. "directly; tap to click at the crosshair. Useful for "
                .. "small targets but disables drag gestures (slider "
                .. "scrub, paint freehand, drag-scroll).",
                { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
        )
    end

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
