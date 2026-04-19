-- Widget kitchen sink.
-- One screen that exposes every reusable widget so changes to ezui can be
-- smoke-tested without jumping between production screens. State is kept
-- local to the screen so closing and re-opening resets everything.

local ui    = require("ezui")
local icons = require("ezui.icons")

-- granular_scroll: plain UP/DOWN pixel-scrolls the viewport (12 px per
-- press) instead of jumping between focusable widgets. Alt+UP/DOWN
-- still runs the linear focus nav, so buttons/toggles/etc. are
-- reachable via the modifier when you want to press them.
local Kitchen = { title = "Widgets", granular_scroll = true }

function Kitchen.initial_state()
    return {
        toggle_a = false,
        toggle_b = true,
        input    = "",
        input_pw = "",
        slider   = 80,
        progress = 0.4,
        dropdown = 2,
    }
end

local function section(label)
    return ui.padding({ 10, 10, 2, 10 },
        ui.text_widget(label, { color = "ACCENT", font = "small_aa" }))
end

function Kitchen:build(state)
    local items = { ui.title_bar("Widgets", { back = true }) }
    local content = {}

    -- Fonts catalogue: one sample per available size, both families.
    -- Mono family uses ASCII only (bitmap fonts ship ASCII 0x20-0x7E).
    content[#content + 1] = section("Fonts - mono (Spleen)")
    local FONTS_MONO = { "tiny", "small", "medium", "large" }
    local FONT_SAMPLE_MONO = "The quick brown fox 0123"
    for _, f in ipairs(FONTS_MONO) do
        content[#content + 1] = ui.padding({ 1, 10, 1, 10 },
            ui.text_widget(f .. "  " .. FONT_SAMPLE_MONO, { font = f }))
    end

    content[#content + 1] = section("Fonts - AA (Inter)")
    local FONTS_AA = { "tiny_aa", "small_aa", "medium_aa", "large_aa" }
    local FONT_SAMPLE_AA = "The quick brown fox 0123"
    for _, f in ipairs(FONTS_AA) do
        content[#content + 1] = ui.padding({ 1, 10, 1, 10 },
            ui.text_widget(f .. "  " .. FONT_SAMPLE_AA, { font = f }))
    end

    -- Text
    content[#content + 1] = section("Text")
    content[#content + 1] = ui.padding({ 4, 10, 2, 10 },
        ui.text_widget("Regular body text - the quick brown fox.", {
            font = "small_aa", wrap = true,
        }))
    content[#content + 1] = ui.padding({ 2, 10, 4, 10 },
        ui.text_widget("Muted secondary line.", {
            font = "small_aa", color = "TEXT_MUTED",
        }))

    -- Button
    content[#content + 1] = section("Button")
    content[#content + 1] = ui.padding({ 4, 10, 4, 10 },
        ui.button("Press me", {
            on_press = function()
                ez.log("[kitchen] button pressed")
            end,
        }))

    -- Toggle
    content[#content + 1] = section("Toggle")
    content[#content + 1] = ui.padding({ 2, 10, 2, 10 },
        ui.toggle("First switch", state.toggle_a, {
            on_change = function(v) state.toggle_a = v end,
        }))
    content[#content + 1] = ui.padding({ 2, 10, 4, 10 },
        ui.toggle("Second (pre-on)", state.toggle_b, {
            on_change = function(v) state.toggle_b = v end,
        }))

    -- Text input
    content[#content + 1] = section("Text input")
    content[#content + 1] = ui.padding({ 4, 10, 2, 10 },
        ui.text_input({
            placeholder = "Normal field",
            value = state.input,
            on_change = function(v) state.input = v end,
        }))
    content[#content + 1] = ui.padding({ 2, 10, 4, 10 },
        ui.text_input({
            placeholder = "Password",
            value = state.input_pw,
            password = true,
            on_change = function(v) state.input_pw = v end,
        }))

    -- Dropdown
    content[#content + 1] = section("Dropdown")
    content[#content + 1] = ui.padding({ 4, 10, 4, 10 },
        ui.dropdown({ "Alpha", "Beta", "Gamma", "Delta" }, {
            value = state.dropdown,
            on_change = function(idx) state.dropdown = idx end,
        }))

    -- Slider
    content[#content + 1] = section("Slider")
    content[#content + 1] = ui.padding({ 4, 10, 4, 10 },
        ui.slider({
            label = "Level",
            value = state.slider, min = 0, max = 255, step = 5,
            on_change = function(v) state.slider = v end,
        }))

    -- Progress
    content[#content + 1] = section("Progress")
    content[#content + 1] = ui.padding({ 4, 10, 2, 10 },
        ui.progress(state.progress, { height = 8 }))
    content[#content + 1] = ui.padding({ 2, 10, 4, 10 },
        ui.text_widget(string.format("%d%%", math.floor(state.progress * 100)),
            { font = "small_aa", color = "TEXT_MUTED" }))

    -- Spinner
    content[#content + 1] = section("Spinner")
    content[#content + 1] = ui.padding({ 4, 10, 4, 10 },
        ui.hbox({ gap = 10 }, {
            { type = "spinner", size = 16 },
            ui.text_widget("Loading...", { font = "small_aa", color = "TEXT_SEC" }),
        }))

    -- List items (regular, compact, icon, disabled)
    content[#content + 1] = section("List items")
    content[#content + 1] = ui.list_item({
        title = "Regular item",
        subtitle = "With a subtitle",
        icon = icons.mail,
        on_press = function() ez.log("[kitchen] regular item") end,
    })
    content[#content + 1] = ui.list_item({
        title = "Compact item",
        compact = true,
        on_press = function() ez.log("[kitchen] compact item") end,
    })
    content[#content + 1] = ui.list_item({
        title = "Disabled item",
        subtitle = "Can't press this",
        icon = icons.folder,
        disabled = true,
        on_press = function() ez.log("[kitchen] should not fire") end,
    })
    content[#content + 1] = ui.list_item({
        title = "Trailing text",
        trailing = "99+",
        icon = icons.message,
        on_press = function() ez.log("[kitchen] trailing") end,
    })

    items[#items + 1] = ui.scroll({ grow = 1,
        scroll_offset = state.scroll or 0,
    }, ui.vbox({ gap = 0 }, content))
    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Kitchen:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Kitchen
