-- Diagnostics Menu Screen for T-Deck OS
-- Diagnostic tests and demos

local TestingMenu = {
    title = "Diagnostics",
    selected = 1,
    items = {
        {label = "GPS Test", description = "Location & time"},
        {label = "Radio Test", description = "LoRa module"},
        {label = "Color Range", description = "Display colors"},
        {label = "Bitmap Test", description = "Image display"},
        {label = "Sound Test", description = "Audio output"},
        {label = "Trackball", description = "Draw with trackball"},
        {label = "Key Matrix", description = "Raw keyboard map"},
        {label = "Key Repeat", description = "Test key repeat"},
        {label = "System Info", description = "Device stats"},
        {label = "Message Bus", description = "Pub/sub test"}
    }
}

-- Safe sound helper
local function play_sound(name)
    if _G.SoundUtils and _G.SoundUtils[name] then
        pcall(_G.SoundUtils[name])
    end
end

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
            display.fill_rect(fw, y, (display.cols - 2) * fw, fh, colors.SURFACE_ALT)
            -- Draw chevron selection indicator
            local chevron_y = y + math.floor((fh - 9) / 2)
            if _G.Icons and _G.Icons.draw_chevron_right then
                _G.Icons.draw_chevron_right(display, fw, chevron_y, colors.ACCENT, colors.SURFACE_ALT)
            else
                display.draw_text(fw, y, ">", colors.ACCENT)
            end
        end

        local text_color = is_selected and colors.ACCENT or colors.TEXT
        display.draw_text(menu_x * fw, y, item.label, text_color)

        -- Description
        local desc_color = is_selected and colors.ACCENT or colors.TEXT_SECONDARY
        display.draw_text((menu_x + 14) * fw, y, item.description, desc_color)
    end
end

function TestingMenu:handle_key(key)
    if key.special == "UP" then
        self.selected = self.selected - 1
        if self.selected < 1 then
            self.selected = #self.items
        end
        play_sound("navigate")
        ScreenManager.invalidate()
    elseif key.special == "DOWN" then
        self.selected = self.selected + 1
        if self.selected > #self.items then
            self.selected = 1
        end
        play_sound("navigate")
        ScreenManager.invalidate()
    elseif key.special == "ENTER" then
        play_sound("click")
        self:activate_selected()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    return "continue"
end

function TestingMenu:activate_selected()
    local item = self.items[self.selected]

    local screens = {
        ["GPS Test"]    = "/scripts/ui/screens/gps_test.lua",
        ["Radio Test"]  = "/scripts/ui/screens/radio_test.lua",
        ["Color Range"] = "/scripts/ui/screens/color_test.lua",
        ["Bitmap Test"] = "/scripts/ui/screens/test_icon.lua",
        ["Sound Test"]  = "/scripts/ui/screens/sound_test.lua",
        ["Trackball"]   = "/scripts/ui/screens/trackball_test.lua",
        ["Key Matrix"]  = "/scripts/ui/screens/keyboard_matrix.lua",
        ["Key Repeat"]  = "/scripts/ui/screens/key_repeat_test.lua",
        ["System Info"] = "/scripts/ui/screens/system_info.lua",
        ["Message Bus"] = "/scripts/ui/screens/bus_test.lua",
    }

    local path = screens[item.label]
    if not path then return end

    spawn(function()
        local ok, Screen = pcall(load_module, path)
        if not ok then
            tdeck.system.log("[TestingMenu] Load error: " .. tostring(Screen))
            return
        end
        if Screen then
            ScreenManager.push(Screen:new())
        end
    end)
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
