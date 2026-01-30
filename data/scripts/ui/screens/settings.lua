-- Settings Screen for T-Deck OS
-- Category-based settings navigation

local Settings = {
    title = "Settings",
    selected = 1,
    scroll_offset = 0,

    -- Layout constants (match main menu)
    VISIBLE_ROWS = 4,
    ROW_HEIGHT = 46,

    -- Settings categories
    categories = {
        {key = "radio",   label = "Radio",   description = "Node, region, TX power", icon = "channels"},
        {key = "display", label = "Display", description = "Brightness, wallpaper, colors", icon = "info"},
        {key = "time",    label = "Time",    description = "Format, timezone, sync", icon = "info"},
        {key = "input",   label = "Input",   description = "Font, trackball", icon = "settings"},
        {key = "sound",   label = "Sound",   description = "UI sounds, volume", icon = "settings"},
        {key = "map",     label = "Map",     description = "Map viewer options", icon = "map"},
        {key = "hotkeys", label = "Hotkeys", description = "Menu, screenshot shortcuts", icon = "settings"},
        {key = "system",  label = "System",  description = "USB transfer", icon = "settings"},
    }
}

-- Safe sound helper
local function play_sound(name)
    if _G.SoundUtils and _G.SoundUtils[name] then
        pcall(_G.SoundUtils[name])
    end
end

function Settings:new()
    local o = {
        title = self.title,
        selected = 1,
        scroll_offset = 0,
        categories = {}
    }

    -- Copy categories
    for i, cat in ipairs(self.categories) do
        o.categories[i] = {
            key = cat.key,
            label = cat.label,
            description = cat.description,
            icon = cat.icon
        }
    end

    setmetatable(o, {__index = Settings})
    return o
end

function Settings:on_enter()
    -- Icons are pre-loaded during splash screen
end

function Settings:adjust_scroll()
    -- Keep selected item visible in the window
    if self.selected <= self.scroll_offset then
        self.scroll_offset = self.selected - 1
    elseif self.selected > self.scroll_offset + self.VISIBLE_ROWS then
        self.scroll_offset = self.selected - self.VISIBLE_ROWS
    end

    -- Clamp scroll offset
    self.scroll_offset = math.max(0, self.scroll_offset)
    self.scroll_offset = math.min(#self.categories - self.VISIBLE_ROWS, self.scroll_offset)
end

function Settings:render(display)
    -- Use themed colors if available
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
    local icon_size = 24
    local text_x = icon_margin + icon_size + 10
    local scrollbar_width = 8

    -- Draw visible category items
    for i = 0, self.VISIBLE_ROWS - 1 do
        local item_idx = self.scroll_offset + i + 1
        if item_idx > #self.categories then break end

        local category = self.categories[item_idx]
        local y = list_start_y + i * self.ROW_HEIGHT
        local is_selected = (item_idx == self.selected)

        -- Selection outline (rounded rect)
        if is_selected then
            display.draw_round_rect(4, y - 1, w - 12 - scrollbar_width, self.ROW_HEIGHT - 6, 6, colors.ACCENT)
        end

        -- Draw icon
        local icon_y = y + (self.ROW_HEIGHT - icon_size) / 2 - 4
        local icon_color = is_selected and colors.ACCENT or colors.WHITE
        if category.icon and _G.Icons then
            _G.Icons.draw(category.icon, display, icon_margin, icon_y, icon_size, icon_color)
        end

        -- Label (main text) - use medium font
        display.set_font_size("medium")
        local label_color = is_selected and colors.ACCENT or colors.WHITE
        local label_y = y + 4
        display.draw_text(text_x, label_y, category.label, label_color)

        -- Chevron indicator on right side
        local fh = display.get_font_height()
        local chevron_y = label_y + math.floor((fh - 9) / 2)
        local chevron_x = w - scrollbar_width - 20
        if _G.Icons and _G.Icons.draw_chevron_right then
            local chevron_color = is_selected and colors.ACCENT or colors.TEXT_SECONDARY
            _G.Icons.draw_chevron_right(display, chevron_x, chevron_y, chevron_color, nil)
        end

        -- Description (secondary text) - use small font
        display.set_font_size("small")
        local desc_color = is_selected and colors.TEXT_SECONDARY or colors.TEXT_MUTED
        local desc_y = y + 4 + 18
        display.draw_text(text_x, desc_y, category.description, desc_color)
    end

    -- Reset to medium font
    display.set_font_size("medium")

    -- Scrollbar (only show if there are more items than visible)
    if #self.categories > self.VISIBLE_ROWS then
        local sb_x = w - scrollbar_width - 2
        local sb_top = list_start_y
        local sb_height = self.VISIBLE_ROWS * self.ROW_HEIGHT - 6

        -- Track (background)
        display.fill_rect(sb_x, sb_top, 4, sb_height, colors.SURFACE)

        -- Thumb (current position)
        local thumb_height = math.max(12, math.floor(sb_height * self.VISIBLE_ROWS / #self.categories))
        local scroll_range = #self.categories - self.VISIBLE_ROWS
        local thumb_range = sb_height - thumb_height
        local thumb_y = sb_top + math.floor(self.scroll_offset * thumb_range / scroll_range)

        display.fill_rect(sb_x, thumb_y, 4, thumb_height, colors.ACCENT)
    end
end

function Settings:handle_key(key)
    ScreenManager.invalidate()

    if key.special == "UP" then
        if self.selected > 1 then
            self.selected = self.selected - 1
            self:adjust_scroll()
            play_sound("navigate")
        end
    elseif key.special == "DOWN" then
        if self.selected < #self.categories then
            self.selected = self.selected + 1
            self:adjust_scroll()
            play_sound("navigate")
        end
    elseif key.special == "LEFT" then
        -- Page up
        self.selected = math.max(1, self.selected - self.VISIBLE_ROWS)
        self:adjust_scroll()
        play_sound("navigate")
    elseif key.special == "RIGHT" then
        -- Page down
        self.selected = math.min(#self.categories, self.selected + self.VISIBLE_ROWS)
        self:adjust_scroll()
        play_sound("navigate")
    elseif key.special == "ENTER" then
        play_sound("click")
        self:open_category()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    return "continue"
end

function Settings:open_category()
    local category = self.categories[self.selected]
    if not category then return end
    spawn_screen("/scripts/ui/screens/settings_category.lua", category.key, category.label)
end

-- Menu items for app menu integration
function Settings:get_menu_items()
    return {
        {
            label = "USB Transfer",
            action = function()
                spawn_screen("/scripts/ui/screens/usb_transfer.lua")
            end
        },
        {
            label = "System Log",
            action = function()
                spawn_screen("/scripts/ui/screens/log_viewer.lua")
            end
        }
    }
end

return Settings
