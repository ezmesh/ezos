-- Diagnostics Menu Screen for T-Deck OS
-- Diagnostic tests and demos with vertical list UI

local TestingMenu = {
    title = "Diagnostics",
    selected = 1,
    scroll_offset = 0,

    -- Layout constants (matching games menu style)
    VISIBLE_ROWS = 4,
    ROW_HEIGHT = 46,
    ICON_SIZE = 24,

    items = {
        {label = "GPS Test",    description = "Location & time",   icon_path = "settings"},
        {label = "Radio Test",  description = "LoRa module",       icon_path = "settings"},
        {label = "Color Range", description = "Display colors",    icon_path = "settings"},
        {label = "Fonts Test",  description = "Font sizes",        icon_path = "settings"},
        {label = "Sound Test",  description = "Audio output",      icon_path = "settings"},
        {label = "Trackball",   description = "Draw with trackball", icon_path = "settings"},
        {label = "Key Matrix",  description = "Raw keyboard map",  icon_path = "settings"},
        {label = "Key Repeat",  description = "Test key repeat",   icon_path = "settings"},
        {label = "System Info", description = "Device stats",      icon_path = "settings"},
        {label = "Message Bus", description = "Pub/sub test",      icon_path = "settings"},
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
        scroll_offset = 0,
        items = {}
    }
    for i, item in ipairs(self.items) do
        o.items[i] = {
            label = item.label,
            description = item.description,
            icon_path = item.icon_path
        }
    end
    setmetatable(o, {__index = TestingMenu})
    return o
end

function TestingMenu:on_enter()
    -- Icons are pre-loaded during splash screen
end

function TestingMenu:adjust_scroll()
    -- Keep selected item visible in the window
    if self.selected <= self.scroll_offset then
        self.scroll_offset = self.selected - 1
    elseif self.selected > self.scroll_offset + self.VISIBLE_ROWS then
        self.scroll_offset = self.selected - self.VISIBLE_ROWS
    end

    -- Clamp scroll offset
    self.scroll_offset = math.max(0, self.scroll_offset)
    self.scroll_offset = math.min(#self.items - self.VISIBLE_ROWS, self.scroll_offset)
end

function TestingMenu:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, w, h, colors.BLACK)
    end

    -- Title bar
    TitleBar.draw(display, self.title)

    -- List area starts after title
    local list_start_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31
    local icon_margin = 12
    local text_x = icon_margin + self.ICON_SIZE + 10
    local scrollbar_width = 8

    -- Draw visible menu items
    for i = 0, self.VISIBLE_ROWS - 1 do
        local item_idx = self.scroll_offset + i + 1
        if item_idx > #self.items then break end

        local item = self.items[item_idx]
        if not item then break end
        local y = list_start_y + i * self.ROW_HEIGHT
        local is_selected = (item_idx == self.selected)

        -- Selection outline (rounded rect)
        if is_selected then
            display.draw_round_rect(4, y - 1, w - 12 - scrollbar_width, self.ROW_HEIGHT - 6, 6, colors.ACCENT)
        end

        -- Draw icon using Icons module
        local icon_y = y + (self.ROW_HEIGHT - self.ICON_SIZE) / 2 - 4
        local icon_color = is_selected and colors.ACCENT or colors.WHITE
        if item.icon_path and _G.Icons then
            _G.Icons.draw(item.icon_path, display, icon_margin, icon_y, self.ICON_SIZE, icon_color)
        else
            -- Fallback: colored square outline
            display.draw_rect(icon_margin, icon_y, self.ICON_SIZE, self.ICON_SIZE, icon_color)
        end

        -- Label (main text) - use medium font
        display.set_font_size("medium")
        local label_color = is_selected and colors.ACCENT or colors.WHITE
        local label_y = y + 4
        display.draw_text(text_x, label_y, item.label, label_color)

        -- Description (secondary text) - use small font
        display.set_font_size("small")
        local desc_color = is_selected and colors.TEXT_SECONDARY or colors.TEXT_MUTED
        local desc_y = y + 4 + 18  -- After medium font height
        display.draw_text(text_x, desc_y, item.description, desc_color)
    end

    -- Reset to medium font
    display.set_font_size("medium")

    -- Scrollbar (only show if there are more items than visible)
    if #self.items > self.VISIBLE_ROWS then
        local sb_x = w - scrollbar_width - 2
        local sb_top = list_start_y
        local sb_height = self.VISIBLE_ROWS * self.ROW_HEIGHT - 6

        -- Track (background) with rounded corners
        display.fill_round_rect(sb_x, sb_top, 4, sb_height, 2, colors.SURFACE)

        -- Thumb (current position) with rounded corners
        local thumb_height = math.max(12, math.floor(sb_height * self.VISIBLE_ROWS / #self.items))
        local scroll_range = #self.items - self.VISIBLE_ROWS
        local thumb_range = sb_height - thumb_height
        local thumb_y = sb_top + math.floor(self.scroll_offset * thumb_range / scroll_range)

        display.fill_round_rect(sb_x, thumb_y, 4, thumb_height, 2, colors.ACCENT)
    end
end

function TestingMenu:handle_key(key)
    if key.special == "UP" then
        if self.selected > 1 then
            self.selected = self.selected - 1
            self:adjust_scroll()
            play_sound("navigate")
            ScreenManager.invalidate()
        end
    elseif key.special == "DOWN" then
        if self.selected < #self.items then
            self.selected = self.selected + 1
            self:adjust_scroll()
            play_sound("navigate")
            ScreenManager.invalidate()
        end
    elseif key.special == "ENTER" or key.character == " " then
        play_sound("click")
        self:activate_selected()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character then
        -- Jump to item by first letter
        local c = string.upper(key.character)
        for i, item in ipairs(self.items) do
            if string.upper(string.sub(item.label, 1, 1)) == c then
                self.selected = i
                self:adjust_scroll()
                play_sound("navigate")
                ScreenManager.invalidate()
                break
            end
        end
    end

    return "continue"
end

function TestingMenu:activate_selected()
    local item = self.items[self.selected]

    local screens = {
        ["GPS Test"]    = "/scripts/ui/screens/gps_test.lua",
        ["Radio Test"]  = "/scripts/ui/screens/radio_test.lua",
        ["Color Range"] = "/scripts/ui/screens/color_test.lua",
        ["Fonts Test"]  = "/scripts/ui/screens/font_test.lua",
        ["Sound Test"]  = "/scripts/ui/screens/sound_test.lua",
        ["Trackball"]   = "/scripts/ui/screens/trackball_test.lua",
        ["Key Matrix"]  = "/scripts/ui/screens/keyboard_matrix.lua",
        ["Key Repeat"]  = "/scripts/ui/screens/key_repeat_test.lua",
        ["System Info"] = "/scripts/ui/screens/system_info.lua",
        ["Message Bus"] = "/scripts/ui/screens/bus_test.lua",
    }

    local path = screens[item.label]
    if path then
        spawn_screen(path)
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
