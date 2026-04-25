-- Test Mode: a blank canvas screen pushed by the host pytest harness so
-- tests own the display and don't have to fight with the live UI. Set as
-- the current screen by tools/remote/tests/conftest.py at session start
-- and popped at session end.
--
-- Properties:
--   * fullscreen — no global status bar, full 320×240 surface available
--   * granular_scroll = false — arrow keys never scroll something behind
--   * handle_key returns true so no key event reaches another screen
--   * build() returns an empty vbox; tests draw directly via ez.display.*

local ui = require("ezui")

local TestMode = {
    title           = "Test Mode",
    fullscreen      = true,
    granular_scroll = false,
}

function TestMode.initial_state()
    return {}
end

function TestMode:build(_state)
    return ui.vbox({ bg = "BG" }, {
        ui.text_widget("ezOS test mode", { color = "TEXT_MUTED" }),
    })
end

function TestMode:handle_key(_key)
    return true  -- swallow everything
end

return TestMode
