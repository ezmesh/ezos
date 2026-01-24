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
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    local menu_start_y = 2
    local menu_x = 3

    for i, item in ipairs(self.items) do
        local y = (menu_start_y + i - 1) * display.font_height
        local is_selected = (i == self.selected)

        if is_selected then
            display.fill_rect(display.font_width, y,
                            (display.cols - 2) * display.font_width,
                            display.font_height,
                            colors.SELECTION)
            display.draw_text(display.font_width, y, ">", colors.CYAN)
        end

        local text_color = is_selected and colors.CYAN or colors.TEXT
        display.draw_text(menu_x * display.font_width, y, item.label, text_color)

        -- Description
        local desc_color = is_selected and colors.CYAN or colors.TEXT_DIM
        display.draw_text((menu_x + 14) * display.font_width, y, item.description, desc_color)
    end

    -- Help text
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[Enter] Select  [Q] Back", colors.TEXT_DIM)
end

function TestingMenu:handle_key(key)
    if key.special == "UP" then
        self.selected = self.selected - 1
        if self.selected < 1 then
            self.selected = #self.items
        end
        tdeck.screen.invalidate()
    elseif key.special == "DOWN" then
        self.selected = self.selected + 1
        if self.selected > #self.items then
            self.selected = 1
        end
        tdeck.screen.invalidate()
    elseif key.special == "ENTER" then
        self:activate_selected()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    return "continue"
end

function TestingMenu:activate_selected()
    local item = self.items[self.selected]

    if item.label == "Color Range" then
        local ColorTest = dofile("/scripts/ui/screens/color_test.lua")
        tdeck.screen.push(ColorTest:new())
    elseif item.label == "Bitmap Test" then
        local TestIcon = dofile("/scripts/ui/screens/test_icon.lua")
        tdeck.screen.push(TestIcon:new())
    elseif item.label == "Sound Test" then
        local SoundTest = dofile("/scripts/ui/screens/sound_test.lua")
        tdeck.screen.push(SoundTest:new())
    elseif item.label == "Input Test" then
        local InputTest = dofile("/scripts/ui/screens/input_test.lua")
        tdeck.screen.push(InputTest:new())
    elseif item.label == "Radio Test" then
        local RadioTest = dofile("/scripts/ui/screens/radio_test.lua")
        tdeck.screen.push(RadioTest:new())
    elseif item.label == "System Info" then
        local SystemInfo = dofile("/scripts/ui/screens/system_info.lua")
        tdeck.screen.push(SystemInfo:new())
    end
end

return TestingMenu
