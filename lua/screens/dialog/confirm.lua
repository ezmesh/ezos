-- Generic confirm dialog. Pushed by ezui.dialog.confirm({ ... }, on_ok, on_cancel).
--
-- Two buttons (one primary destructive, one cancel) plus a wrapped
-- body line. Designed for "leave without saving?", "delete this
-- file?", "rollback firmware?" style prompts; not for in-place
-- yes/no questions where the answer is followed by more screens
-- (those should branch from a menu instead).

local ui         = require("ezui")
local screen_mod = require("ezui.screen")

local M = { title = "Confirm" }

function M.initial_state(opts, on_ok, on_cancel)
    opts = opts or {}
    return {
        title       = opts.title or "Confirm",
        message     = opts.message or "Are you sure?",
        ok_label    = opts.ok_label or "OK",
        cancel_label = opts.cancel_label or "Cancel",
        on_ok       = on_ok,
        on_cancel   = on_cancel,
    }
end

function M:build(state)
    -- Override the screen-level title so the global status bar
    -- shows the caller's prompt (e.g. "Leave Paint?") instead of the
    -- generic "Confirm" baked into the screen def.
    self.title = state.title or "Confirm"
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar(state.title, { back = true }),
        ui.padding({ 14, 14, 8, 14 },
            ui.text_widget(state.message, {
                font = "small_aa", color = "TEXT", wrap = true,
            })),
        ui.padding({ 6, 14, 4, 14 },
            ui.button(state.ok_label, {
                on_press = function()
                    -- Pop first so the on_ok callback sees the
                    -- caller's screen on top -- otherwise pushing
                    -- another screen from inside on_ok would stack
                    -- on top of this dialog instead of the caller.
                    screen_mod.pop()
                    if state.on_ok then state.on_ok() end
                end,
            })),
        ui.padding({ 4, 14, 4, 14 },
            ui.button(state.cancel_label, {
                on_press = function()
                    screen_mod.pop()
                    if state.on_cancel then state.on_cancel() end
                end,
            })),
    })
end

function M:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        if self._state.on_cancel then self._state.on_cancel() end
        return "pop"
    end
    return nil
end

return M
