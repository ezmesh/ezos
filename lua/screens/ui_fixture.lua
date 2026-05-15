-- UI fixture screen for per-widget unit tests. The host pytest harness
-- under tools/remote/tests/ui/ pushes this screen, sets a Lua global
-- _G._ui_fixture_build to a function that returns a widget tree, then
-- captures the next rendered frame and asserts on its primitives/text.
--
-- A test typically looks like:
--
--     def test_button_renders_label(mounted):
--         mounted("return ezui.button('Hi')")
--         texts = mounted.device.wait_frame_text()
--         assert any(t['text'] == 'Hi' for t in texts)
--
-- The fixture only renders what the build function returns; there is no
-- title bar, no padding, no global status bar (fullscreen=true). That
-- isolates the widget under test from the rest of the UI.
--
-- _G._ui_fixture_build_err is set to the error string when the build
-- function throws, so a failing test sees the Lua error in its output
-- rather than a silent blank frame.

local ui = require("ezui")

local UiFixture = {
    title           = "UI Fixture",
    fullscreen      = true,
    granular_scroll = false,
}

function UiFixture.initial_state()
    return {}
end

function UiFixture:build(_state)
    local builder = _G._ui_fixture_build
    if type(builder) ~= "function" then
        return ui.vbox({ bg = "BG" }, {
            ui.text_widget("(no fixture builder set)", { color = "TEXT_MUTED" }),
        })
    end
    local ok, result = pcall(builder)
    if not ok then
        _G._ui_fixture_build_err = tostring(result)
        return ui.vbox({ bg = "BG" }, {
            ui.text_widget("fixture error", { color = "DANGER" }),
        })
    end
    _G._ui_fixture_build_err = nil
    -- Allow tests to return either a single node or a vbox-shaped tree.
    if type(result) == "table" and result.type then
        return ui.vbox({ bg = "BG" }, { result })
    end
    return result
end

function UiFixture:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return true  -- swallow everything else; tests own key input via the host harness
end

return UiFixture
