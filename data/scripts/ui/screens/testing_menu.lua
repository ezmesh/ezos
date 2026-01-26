-- Testing Menu Screen for T-Deck OS
-- Diagnostic tests and demos

local TestingMenu = {
    title = "Testing",
    selected = 1,
    items = {
        {label = "Color Range", description = "Display colors"},
        {label = "Bitmap Test", description = "Image display"},
        {label = "Sound Test", description = "Audio output"},
        {label = "Input Test", description = "Keyboard/trackball"},
        {label = "Key Matrix", description = "Raw keyboard map"},
        {label = "Key Repeat", description = "Test key repeat"},
        {label = "Radio Test", description = "LoRa module"},
        {label = "System Info", description = "Device stats"}
    }
}

function TestingMenu:new()
    local o = {
        title = self.title,
        selected = 1,
        items = self.items
    }
    setmetatable(o, {__index = TestingMenu})
    return o
end

function TestingMenu:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    -- Use small font throughout
    display.set_font_size("small")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    -- Title bar
    TitleBar.draw(display, self.title)

    local menu_start_y = fh + 10
    local menu_x = 3

    for i, item in ipairs(self.items) do
        local y = menu_start_y + (i - 1) * (fh + 2)
        local is_selected = (i == self.selected)

        if is_selected then
            display.fill_rect(fw, y, (display.cols - 2) * fw, fh, colors.SELECTION)
            display.draw_text(fw, y, ">", colors.CYAN)
        end

        local text_color = is_selected and colors.CYAN or colors.TEXT
        display.draw_text(menu_x * fw, y, item.label, text_color)

        -- Description
        local desc_color = is_selected and colors.CYAN or colors.TEXT_DIM
        display.draw_text((menu_x + 14) * fw, y, item.description, desc_color)
    end
end

function TestingMenu:handle_key(key)
    if key.special == "UP" then
        self.selected = self.selected - 1
        if self.selected < 1 then
            self.selected = #self.items
        end
        ScreenManager.invalidate()
    elseif key.special == "DOWN" then
        self.selected = self.selected + 1
        if self.selected > #self.items then
            self.selected = 1
        end
        ScreenManager.invalidate()
    elseif key.special == "ENTER" then
        self:activate_selected()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    return "continue"
end

function TestingMenu:activate_selected()
    local item = self.items[self.selected]

    -- Force garbage collection before loading new screen to free memory
    collectgarbage("collect")

    if item.label == "Color Range" then
        local ColorTest = load_module("/scripts/ui/screens/color_test.lua")
        ScreenManager.push(ColorTest:new())
    elseif item.label == "Bitmap Test" then
        local TestIcon = load_module("/scripts/ui/screens/test_icon.lua")
        ScreenManager.push(TestIcon:new())
    elseif item.label == "Sound Test" then
        local SoundTest = load_module("/scripts/ui/screens/sound_test.lua")
        ScreenManager.push(SoundTest:new())
    elseif item.label == "Input Test" then
        local InputTest = load_module("/scripts/ui/screens/input_test.lua")
        ScreenManager.push(InputTest:new())
    elseif item.label == "Key Matrix" then
        local KeyboardMatrix = load_module("/scripts/ui/screens/keyboard_matrix.lua")
        ScreenManager.push(KeyboardMatrix:new())
    elseif item.label == "Key Repeat" then
        local KeyRepeatTest = load_module("/scripts/ui/screens/key_repeat_test.lua")
        ScreenManager.push(KeyRepeatTest:new())
    elseif item.label == "Radio Test" then
        local RadioTest = load_module("/scripts/ui/screens/radio_test.lua")
        ScreenManager.push(RadioTest:new())
    elseif item.label == "System Info" then
        local SystemInfo = load_module("/scripts/ui/screens/system_info.lua")
        ScreenManager.push(SystemInfo:new())
    end
end

-- Menu items for app menu integration
function TestingMenu:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = "Run",
        action = function()
            self_ref:activate_selected()
        end
    })

    return items
end

return TestingMenu
