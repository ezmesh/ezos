-- Main Menu Screen for T-Deck OS
-- Vertical scrollable list interface

local MainMenu = {
    title = "MeshCore",
    selected = 1,
    scroll_offset = 0,

    -- Layout constants
    VISIBLE_ROWS = 4,
    ROW_HEIGHT = 46,
    ICON_SIZE = 24,

    items = {
        {label = "Messages",  description = "View conversations", icon_path = "messages",  unread = 0, enabled = true},
        {label = "Channels",  description = "Group messaging",    icon_path = "channels",  unread = 0, enabled = true},
        {label = "Contacts",  description = "Known nodes",        icon_path = "contacts",  unread = 0, enabled = true},
        {label = "Node Info", description = "Device status",      icon_path = "info",      unread = 0, enabled = true},
        {label = "Map",       description = "Offline maps",       icon_path = "map",       unread = 0, enabled = true},
        {label = "Settings",  description = "Configuration",      icon_path = "settings",  unread = 0, enabled = true},
        {label = "Files",     description = "File browser",       icon_path = "files",     unread = 0, enabled = true},
        {label = "Testing",   description = "Diagnostics",        icon_path = "testing",   unread = 0, enabled = true},
        {label = "Games",     description = "Play games",         icon_path = "games",     unread = 0, enabled = true}
    }
}

function MainMenu:new()
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
            icon_path = item.icon_path,
            unread = item.unread,
            enabled = item.enabled
        }
    end
    setmetatable(o, {__index = MainMenu})
    return o
end

function MainMenu:on_enter()
    -- Ensure keyboard is in normal mode (safety reset in case a screen didn't clean up)
    tdeck.keyboard.set_mode("normal")

    -- Lazy-load Icons module if not already loaded
    if not _G.Icons then
        _G.Icons = dofile("/scripts/ui/icons.lua")
    end

    -- Rebuild items array if it was cleared in on_leave
    if #self.items == 0 then
        for i, item in ipairs(MainMenu.items) do
            self.items[i] = {
                label = item.label,
                description = item.description,
                icon_path = item.icon_path,
                unread = item.unread,
                enabled = item.enabled
            }
        end
    end

    -- Update channel unread count from Lua Channels service
    if _G.Channels then
        local channels = _G.Channels.get_all()
        local total_unread = 0
        for _, ch in ipairs(channels) do
            total_unread = total_unread + (ch.unread_count or 0)
        end
        self.items[2].unread = total_unread
    end

    -- Update node count from mesh
    if tdeck.mesh.is_initialized() then
        self.items[3].unread = tdeck.mesh.get_node_count()
    end
end

function MainMenu:on_leave()
    -- Clear items array to free memory while another screen is active
    -- They will be rebuilt from the template in on_enter
    self.items = {}
    -- Force garbage collection before loading new screen
    collectgarbage("collect")
end

function MainMenu:adjust_scroll()
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

function MainMenu:render(display)
    -- Use themed colors if available
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    -- Draw themed wallpaper background
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
    local scrollbar_width = 8  -- Reserve space for scrollbar

    -- Draw visible menu items
    for i = 0, self.VISIBLE_ROWS - 1 do
        local item_idx = self.scroll_offset + i + 1
        if item_idx > #self.items then break end

        local item = self.items[item_idx]
        local y = list_start_y + i * self.ROW_HEIGHT
        local is_selected = (item_idx == self.selected)

        -- Selection outline (rounded rect) - narrower to leave room for scrollbar
        if is_selected then
            display.draw_round_rect(4, y - 1, w - 12 - scrollbar_width, self.ROW_HEIGHT - 6, 6, colors.CYAN)
        end

        -- Draw icon using Icons module
        local icon_y = y + (self.ROW_HEIGHT - self.ICON_SIZE) / 2 - 4
        local icon_color = is_selected and colors.CYAN or colors.WHITE
        if item.icon_path and _G.Icons then
            _G.Icons.draw(item.icon_path, display, icon_margin, icon_y, self.ICON_SIZE, icon_color)
        else
            -- Fallback: colored square outline
            display.draw_rect(icon_margin, icon_y, self.ICON_SIZE, self.ICON_SIZE, icon_color)
        end

        -- Label (main text) - use medium font
        display.set_font_size("medium")
        local label_color = is_selected and colors.CYAN or colors.WHITE
        local label_y = y + 4
        display.draw_text(text_x, label_y, item.label, label_color)

        -- Unread badge next to label (use text_width for accurate positioning)
        if item.unread and item.unread > 0 then
            local badge = string.format("(%d)", item.unread)
            local label_width = display.text_width(item.label)
            local badge_x = text_x + label_width + 6
            display.draw_text(badge_x, label_y, badge, colors.ORANGE)
        end

        -- Description (secondary text) - use small font
        display.set_font_size("small")
        local desc_color = is_selected and colors.TEXT_DIM or colors.DARK_GRAY
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
        display.fill_round_rect(sb_x, sb_top, 4, sb_height, 2, colors.DARK_GRAY)

        -- Thumb (current position) with rounded corners
        local thumb_height = math.max(12, math.floor(sb_height * self.VISIBLE_ROWS / #self.items))
        local scroll_range = #self.items - self.VISIBLE_ROWS
        local thumb_range = sb_height - thumb_height
        local thumb_y = sb_top + math.floor(self.scroll_offset * thumb_range / scroll_range)

        display.fill_round_rect(sb_x, thumb_y, 4, thumb_height, 2, colors.CYAN)
    end
end

-- Safe sound helper that won't break on errors
local function play_sound(name)
    if _G.SoundUtils and _G.SoundUtils[name] then
        pcall(_G.SoundUtils[name])
    end
end

function MainMenu:handle_key(key)
    if key.special == "ENTER" then
        play_sound("click")
        self:activate_selected()
        return "continue"
    end

    if key.character == " " then
        play_sound("click")
        self:activate_selected()
        return "continue"
    end

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

    elseif key.special == "LEFT" then
        -- Page up
        self.selected = math.max(1, self.selected - self.VISIBLE_ROWS)
        self:adjust_scroll()
        play_sound("navigate")
        ScreenManager.invalidate()

    elseif key.special == "RIGHT" then
        -- Page down
        self.selected = math.min(#self.items, self.selected + self.VISIBLE_ROWS)
        self:adjust_scroll()
        play_sound("navigate")
        ScreenManager.invalidate()

    elseif key.character then
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

function MainMenu:activate_selected()
    local item = self.items[self.selected]
    if not item or not item.enabled then return end

    -- Force garbage collection before loading new screen
    collectgarbage("collect")

    local label = item.label

    if label == "Messages" then
        local Screen = load_module("/scripts/ui/screens/messages.lua")
        ScreenManager.push(Screen:new())
    elseif label == "Channels" then
        local Screen = load_module("/scripts/ui/screens/channels.lua")
        ScreenManager.push(Screen:new())
    elseif label == "Contacts" then
        local Screen = load_module("/scripts/ui/screens/contacts.lua")
        ScreenManager.push(Screen:new())
    elseif label == "Node Info" then
        local Screen = load_module("/scripts/ui/screens/node_info.lua")
        ScreenManager.push(Screen:new())
    elseif label == "Map" then
        local Screen = load_module("/scripts/ui/screens/map_viewer.lua")
        ScreenManager.push(Screen:new())
    elseif label == "Settings" then
        local Screen = load_module("/scripts/ui/screens/settings.lua")
        ScreenManager.push(Screen:new())
    elseif label == "Files" then
        local Screen = load_module("/scripts/ui/screens/files.lua")
        ScreenManager.push(Screen:new("/"))
    elseif label == "Testing" then
        local Screen = load_module("/scripts/ui/screens/testing_menu.lua")
        ScreenManager.push(Screen:new())
    elseif label == "Games" then
        local Screen = load_module("/scripts/ui/screens/games_menu.lua")
        ScreenManager.push(Screen:new())
    end
end

function MainMenu:set_message_count(count)
    self.items[1].unread = count
    ScreenManager.invalidate()
end

function MainMenu:set_channel_count(count)
    self.items[2].unread = count
    ScreenManager.invalidate()
end

function MainMenu:set_contact_count(count)
    self.items[3].unread = count
    ScreenManager.invalidate()
end

return MainMenu
