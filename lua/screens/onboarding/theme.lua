-- Onboarding step 5 of 5 — theme + accent.
--
-- Mirrors the controls in Settings → Display so the user gets the same
-- palette they'd choose later. Toggle flips dark/light immediately so
-- the rest of the wizard repaints in the chosen scheme; accent changes
-- repaint the focus ring of the Continue button live.

local ui        = require("ezui")
local theme     = require("ezui.theme")
local node_mod  = require("ezui.node")
local focus_mod = require("ezui.focus")
local M         = require("screens.onboarding")

local PATH = "screens.onboarding.theme"

-- Reuse the swatch node registered by display_settings.lua. If the user
-- hasn't visited that screen yet this run, register it here too —
-- node.register is idempotent on second registration via the guard
-- below, matching the same pattern used in display_settings.lua.
if not node_mod.handler("color_swatch") then
    node_mod.register("color_swatch", {
        focusable = true,
        measure = function(n, max_w, max_h)
            local size = n.size or 26
            return size, size
        end,
        draw = function(n, d, x, y, w, h)
            local color = n.color or 0xFFFF
            d.fill_round_rect(x + 2, y + 2, w - 4, h - 4, 3, color)
            if n._focused then
                d.draw_round_rect(x, y, w, h, 4, theme.color("TEXT"))
            elseif n.selected then
                d.draw_round_rect(x + 1, y + 1, w - 2, h - 2, 3,
                    theme.color("TEXT_SEC"))
            end
        end,
        on_activate = function(n, key)
            if n.on_press then n.on_press() end
            return "handled"
        end,
        on_key = function(n, key)
            if key.special == "LEFT" then focus_mod.prev(); return "handled"
            elseif key.special == "RIGHT" then focus_mod.next(); return "handled"
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

local Theme = { title = "Theme" }

function Theme:_commit()
    M.advance(PATH)
end

function Theme:build(state)
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

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Theme", { back = true, right = M.progress_label(PATH) }),
        ui.scroll({ grow = 1 },
            ui.padding({ 10, 12, 10, 12 },
                ui.vbox({ gap = 8 }, {
                    ui.text_widget("Pick a colour scheme",
                        { color = "TEXT", font = "small_aa", wrap = true }),
                    ui.toggle("Dark mode", theme.name == "dark", {
                        on_change = function(on)
                            local name = on and "dark" or "light"
                            theme.set(name)
                            ez.storage.set_pref("theme", name)
                            self:set_state({})
                        end,
                    }),
                    ui.padding({ 8, 0, 0, 0 },
                        ui.text_widget("Accent colour",
                            { color = "ACCENT", font = "small_aa" })
                    ),
                    ui.hbox({ gap = 4 }, swatches),
                    ui.padding({ 12, 0, 0, 0 },
                        ui.button("Continue", {
                            on_press = function() self:_commit() end,
                        })
                    ),
                })
            )
        ),
    })
end

function Theme:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Theme
