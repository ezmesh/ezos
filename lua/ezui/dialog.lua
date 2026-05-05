-- ezui.dialog: helpers for pushing modal-style dialog screens.
--
-- Currently exposes one function — dialog.prompt — which pushes a
-- single-line text prompt and invokes `on_submit(value)` or
-- `on_cancel()` when the user dismisses it. The prompt is a full
-- screen (not a floating popup); on a 320x240 panel full-screen is
-- lighter to build and still reads as modal because the global back
-- key returns control to the caller.
--
-- Example:
--
--     local dialog = require("ezui.dialog")
--     dialog.prompt({
--         title       = "Save",
--         message     = "Path:",
--         value       = "/fs/scripts/scratch.lua",
--         placeholder = "/fs/scripts/...",
--     }, function(path) ... end, function() ... end)
--
-- The caller keeps its own state alive (ezui.screen stack preserves
-- the caller under the pushed dialog), so callbacks can freely mutate
-- fields on the caller's state table — the changes are picked up when
-- the dialog pops and the caller rebuilds.

local dialog = {}

-- Push a prompt screen. opts shape:
--   { title, message, value, placeholder }
-- Callbacks are passed positionally.
function dialog.prompt(opts, on_submit, on_cancel)
    local screen_mod = require("ezui.screen")
    local PromptDef  = require("screens.dialog.prompt")

    opts = opts or {}
    local state = {
        title       = opts.title,
        message     = opts.message,
        value       = opts.value or "",
        placeholder = opts.placeholder,
        on_submit   = on_submit,
        on_cancel   = on_cancel,
    }
    screen_mod.push(screen_mod.create(PromptDef, state))
end

-- Push a yes/no confirm screen. opts shape:
--   { title, message, ok_label = "OK", cancel_label = "Cancel" }
-- on_ok runs after the dialog pops; on_cancel runs after a cancel
-- press OR a Back/ESC key. Either is optional. Used by the editor
-- and paint apps for "leave without saving?" prompts.
function dialog.confirm(opts, on_ok, on_cancel)
    local screen_mod = require("ezui.screen")
    local ConfirmDef = require("screens.dialog.confirm")
    screen_mod.push(screen_mod.create(ConfirmDef,
        ConfirmDef.initial_state(opts, on_ok, on_cancel)))
end

return dialog
