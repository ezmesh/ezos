-- Main Menu Screen for T-Deck OS
-- Vertical scrollable list interface

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local MainMenu = {
    title = "MeshCore",
    selected = 1,
    scroll_offset = 0,

    -- Layout constants
    VISIBLE_ROWS = 4,
    ROW_HEIGHT = 46,
    ICON_SIZE = 24,

    -- Shortcut key is optional: if set, that key jumps directly to and activates the item
    -- If not set, first-letter matching is used for navigation only
    items = {
        {label = "Messages",  description = "View conversations", icon_path = "messages",  unread = 0, enabled = true},
        {label = "Channels",  description = "Group messaging",    icon_path = "channels",  unread = 0, enabled = true, shortcut = "C"},
        {label = "Contacts",  description = "Saved contacts",      icon_path = "contacts",  unread = 0, enabled = true, shortcut = "T"},
        {label = "Nodes",     description = "All heard nodes",    icon_path = "contacts",  unread = 0, enabled = true, shortcut = "N"},
        {label = "Node Info", description = "Device status",      icon_path = "info",      unread = 0, enabled = true, shortcut = "I"},
        {label = "Map",       description = "Offline maps",       icon_path = "map",       unread = 0, enabled = true, shortcut = "M"},
        {label = "Packets",   description = "Live packet view",   icon_path = "packets",   unread = 0, enabled = true, shortcut = "P"},
        {label = "Settings",  description = "Configuration",      icon_path = "settings",  unread = 0, enabled = true, shortcut = ","},
        {label = "Storage",   description = "Disk space info",    icon_path = "files",     unread = 0, enabled = true, shortcut = "O"},
        {label = "Files",     description = "File browser",       icon_path = "files",     unread = 0, enabled = false, shortcut = "F"},
        {label = "Diagnostics", description = "Testing tools",     icon_path = "testing",   unread = 0, enabled = true, shortcut = "D"},
        {label = "Games",     description = "Play games",         icon_path = "games",     unread = 0, enabled = true, shortcut = "G"}
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
            enabled = item.enabled,
            shortcut = item.shortcut
        }
    end
    setmetatable(o, {__index = MainMenu})
    return o
end

function MainMenu:on_enter()
    -- Ensure keyboard is in normal mode (safety reset in case a screen didn't clean up)
    ez.keyboard.set_mode("normal")

    -- Update title with node name and path hash
    if ez.mesh.is_initialized() then
        local node_name = ez.mesh.get_node_name() or "Node"
        local path_hash = ez.mesh.get_path_hash() or 0
        self.title = string.format("%s (%02X)", node_name, path_hash)
    else
        self.title = "MeshCore"
    end

    -- Rebuild items array if it was cleared in on_leave
    if #self.items == 0 then
        for i, item in ipairs(MainMenu.items) do
            self.items[i] = {
                label = item.label,
                description = item.description,
                icon_path = item.icon_path,
                unread = item.unread,
                enabled = item.enabled,
                shortcut = item.shortcut
            }
        end
    end

    -- Update direct messages unread count
    if _G.DirectMessages and _G.DirectMessages.get_unread_total then
        self.items[1].unread = _G.DirectMessages.get_unread_total()
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

    -- Update saved contacts count
    if _G.Contacts and _G.Contacts.get_saved then
        local saved = _G.Contacts.get_saved()
        self.items[3].unread = #saved
    end
end

function MainMenu:on_leave()
    -- Clear items array to free memory while another screen is active
    -- They will be rebuilt from the template in on_enter
    self.items = {}
    -- Force garbage collection before loading new screen
    run_gc("collect", "main-menu-leave")
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
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height

    -- Draw themed wallpaper background
    ListMixin.draw_background(display)

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

        -- Check if item is disabled
        local is_disabled = (item.enabled == false)

        -- Selection outline (rounded rect) - narrower to leave room for scrollbar
        -- Use dimmer outline for disabled items
        if is_selected then
            local outline_color = is_disabled and colors.SURFACE or colors.ACCENT
            display.draw_round_rect(4, y - 1, w - 12 - scrollbar_width, self.ROW_HEIGHT - 6, 6, outline_color)
        end

        -- Draw icon using Icons module
        -- Use dimmer color for disabled items
        local icon_y = y + (self.ROW_HEIGHT - self.ICON_SIZE) / 2 - 4
        local icon_color
        if is_disabled then
            icon_color = colors.SURFACE
        elseif is_selected then
            icon_color = colors.ACCENT
        else
            icon_color = colors.WHITE
        end
        if item.icon_path and _G.Icons then
            _G.Icons.draw(item.icon_path, display, icon_margin, icon_y, self.ICON_SIZE, icon_color)
        else
            -- Fallback: colored square outline
            display.draw_rect(icon_margin, icon_y, self.ICON_SIZE, self.ICON_SIZE, icon_color)
        end

        -- Label (main text) - use medium font
        -- Use dimmer color for disabled items
        display.set_font_size("medium")
        local label_color
        if is_disabled then
            label_color = colors.SURFACE
        elseif is_selected then
            label_color = colors.ACCENT
        else
            label_color = colors.WHITE
        end
        local label_y = y + 4
        display.draw_text(text_x, label_y, item.label, label_color)

        -- Unread badge next to label (use text_width for accurate positioning)
        -- Don't show badge for disabled items
        if not is_disabled and item.unread and item.unread > 0 then
            local badge = string.format("(%d)", item.unread)
            local label_width = display.text_width(item.label)
            local badge_x = text_x + label_width + 6
            display.draw_text(badge_x, label_y, badge, colors.WARNING)
        end

        -- Description (secondary text) - use small font
        display.set_font_size("small")
        local desc_color
        if is_disabled then
            desc_color = colors.SURFACE
        elseif is_selected then
            desc_color = colors.TEXT_SECONDARY
        else
            desc_color = colors.TEXT_MUTED
        end
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

        -- First check for explicit shortcuts (activates the item directly)
        for i, item in ipairs(self.items) do
            if item.shortcut and string.upper(item.shortcut) == c and item.enabled then
                self.selected = i
                self:adjust_scroll()
                play_sound("click")
                ScreenManager.invalidate()
                self:activate_selected()
                return "continue"
            end
        end

        -- Fallback: first-letter navigation (just selects, doesn't activate)
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

    -- Map labels to screen paths
    local screens = {
        ["Messages"]    = "/scripts/ui/screens/messages.lua",
        ["Channels"]    = "/scripts/ui/screens/channels.lua",
        ["Contacts"]    = "/scripts/ui/screens/contacts.lua",
        ["Nodes"]       = "/scripts/ui/screens/nodes.lua",
        ["Node Info"]   = "/scripts/ui/screens/node_info.lua",
        ["Map"]         = "/scripts/ui/screens/map_viewer.lua",
        ["Packets"]     = "/scripts/ui/screens/packets.lua",
        ["Settings"]    = "/scripts/ui/screens/settings.lua",
        ["Storage"]     = "/scripts/ui/screens/storage.lua",
        ["Files"]       = "/scripts/ui/screens/files.lua",
        ["Diagnostics"] = "/scripts/ui/screens/testing_menu.lua",
        ["Games"]       = "/scripts/ui/screens/games_menu.lua",
    }

    local path = screens[item.label]
    if not path then return end

    -- Files screen needs initial path argument
    if item.label == "Files" then
        spawn_screen(path, "/")
    else
        spawn_screen(path)
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
