-- Main Menu Screen for T-Deck OS
-- 3D Carousel interface with Crystal icons

local Bitmap = dofile("/scripts/ui/bitmap.lua")

local MainMenu = {
    title = "MeshCore",
    selected = 1,
    icons_loaded = false,
    wallpaper = nil,
    items = {
        {label = "Messages",  description = "View conversations", icon_path = "messages",  unread = 0, enabled = true},
        {label = "Channels",  description = "Group messaging",    icon_path = "channels",  unread = 0, enabled = true},
        {label = "Contacts",  description = "Known nodes",        icon_path = "contacts",  unread = 0, enabled = true},
        {label = "Node Info", description = "Device status",      icon_path = "info",      unread = 0, enabled = true},
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
        icons_loaded = false,
        wallpaper = nil,
        items = {}
    }
    for i, item in ipairs(self.items) do
        o.items[i] = {
            label = item.label,
            description = item.description,
            icon_path = item.icon_path,
            unread = item.unread,
            enabled = item.enabled,
            bitmap = nil
        }
    end
    setmetatable(o, {__index = MainMenu})
    return o
end

function MainMenu:load_icons()
    if self.icons_loaded then return end

    for _, item in ipairs(self.items) do
        local path = string.format("/icons/32x32/%s.rgb565", item.icon_path)
        item.bitmap = Bitmap.load(path, 32)
    end

    self.icons_loaded = true
end

function MainMenu:load_wallpaper()
    if self.wallpaper then return end
    -- Load small tile (16x16) for tiling - carbon fiber pattern
    self.wallpaper = Bitmap.load("/wallpapers/carbon.rgb565", 16)
end

function MainMenu:on_enter()
    self:load_icons()
    self:load_wallpaper()

    if tdeck.mesh.is_initialized() then
        local channels = tdeck.mesh.get_channels()
        local total_unread = 0
        for _, ch in ipairs(channels) do
            total_unread = total_unread + (ch.unread_count or 0)
        end
        self.items[2].unread = total_unread
        self.items[3].unread = tdeck.mesh.get_node_count()
    end
end

function MainMenu:get_item(index)
    local n = #self.items
    while index < 1 do index = index + n end
    while index > n do index = index - n end
    return self.items[index]
end

function MainMenu:render(display)
    local colors = display.colors
    local w = display.width
    local h = display.height

    -- Draw tiled wallpaper or black background
    if self.wallpaper then
        local tile_w = self.wallpaper.width
        local tile_h = self.wallpaper.height
        for ty = 0, h - 1, tile_h do
            for tx = 0, w - 1, tile_w do
                Bitmap.draw(self.wallpaper, tx, ty)
            end
        end
    else
        display.fill_rect(0, 0, w, h, colors.BLACK)
    end

    local center_x = w / 2
    local center_y = h / 2 - 25

    -- Carousel slots: position and size for each slot
    local slots = {
        {offset = -2, x = -90,  y = 12, size = 24},
        {offset = -1, x = -45,  y = 6,  size = 28},
        {offset = 0,  x = 0,    y = 0,  size = 32},
        {offset = 1,  x = 45,   y = 6,  size = 28},
        {offset = 2,  x = 90,   y = 12, size = 24},
    }

    -- Draw back to front
    local draw_order = {1, 5, 2, 4, 3}

    for _, idx in ipairs(draw_order) do
        local slot = slots[idx]
        local item = self:get_item(self.selected + slot.offset)
        local bitmap = item.bitmap
        local icon_size = slot.size

        local icon_x = center_x + slot.x - icon_size / 2
        local icon_y = center_y + slot.y - icon_size / 2

        -- Selection highlight for center
        local is_center = (slot.offset == 0)
        if is_center then
            display.fill_rect(icon_x - 6, icon_y - 6, icon_size + 12, icon_size + 12, colors.SELECTION)
        end

        -- Draw icon
        if bitmap then
            Bitmap.draw_transparent(bitmap, icon_x, icon_y)
        else
            local color = is_center and colors.CYAN or colors.DARK_GRAY
            display.fill_rect(icon_x, icon_y, icon_size, icon_size, color)
        end

        -- Selection border
        if is_center then
            local bx, by = icon_x - 3, icon_y - 3
            local bs = icon_size + 6
            display.fill_rect(bx, by, bs, 2, colors.CYAN)
            display.fill_rect(bx, by + bs - 2, bs, 2, colors.CYAN)
            display.fill_rect(bx, by, 2, bs, colors.CYAN)
            display.fill_rect(bx + bs - 2, by, 2, bs, colors.CYAN)
        end
    end

    -- Label and description
    local current = self.items[self.selected]
    local label_y = center_y + 50
    local desc_y = label_y + 18

    display.draw_text_centered(label_y, current.label, colors.WHITE)
    display.draw_text_centered(desc_y, current.description, colors.TEXT_DIM)

    if current.unread and current.unread > 0 then
        local badge = string.format("(%d)", current.unread)
        local badge_x = center_x + #current.label * display.font_width / 2 + 4
        display.draw_text(badge_x, label_y, badge, colors.ORANGE)
    end

    -- Navigation dots
    local dots_y = h - 40
    local dot_spacing = 10
    local dots_width = (#self.items - 1) * dot_spacing
    local dot_start_x = center_x - dots_width / 2

    for i = 1, #self.items do
        local dot_x = dot_start_x + (i - 1) * dot_spacing
        local is_current = (i == self.selected)
        local dot_size = is_current and 6 or 4
        local dot_color = is_current and colors.CYAN or colors.DARK_GRAY
        display.fill_rect(dot_x - dot_size/2, dots_y, dot_size, dot_size, dot_color)
    end

    local help_y = h - 22
    display.draw_text_centered(help_y, "[</>] Navigate  [Enter] Select", colors.TEXT_DIM)
end

function MainMenu:handle_key(key)
    if key.special == "ENTER" then
        self:activate_selected()
        return "continue"
    end

    if key.character == " " then
        self:activate_selected()
        return "continue"
    end

    if key.special == "LEFT" or key.special == "UP" then
        self.selected = self.selected - 1
        if self.selected < 1 then
            self.selected = #self.items
        end
        tdeck.screen.invalidate()

    elseif key.special == "RIGHT" or key.special == "DOWN" then
        self.selected = self.selected + 1
        if self.selected > #self.items then
            self.selected = 1
        end
        tdeck.screen.invalidate()

    elseif key.character then
        local c = string.upper(key.character)
        for i, item in ipairs(self.items) do
            if string.upper(string.sub(item.label, 1, 1)) == c then
                self.selected = i
                tdeck.screen.invalidate()
                break
            end
        end
    end

    return "continue"
end

function MainMenu:activate_selected()
    local item = self.items[self.selected]
    if not item or not item.enabled then return end

    local label = item.label

    if label == "Messages" then
        local Screen = dofile("/scripts/ui/screens/messages.lua")
        tdeck.screen.push(Screen:new())
    elseif label == "Channels" then
        local Screen = dofile("/scripts/ui/screens/channels.lua")
        tdeck.screen.push(Screen:new())
    elseif label == "Contacts" then
        local Screen = dofile("/scripts/ui/screens/contacts.lua")
        tdeck.screen.push(Screen:new())
    elseif label == "Node Info" then
        local Screen = dofile("/scripts/ui/screens/node_info.lua")
        tdeck.screen.push(Screen:new())
    elseif label == "Settings" then
        local Screen = dofile("/scripts/ui/screens/settings.lua")
        tdeck.screen.push(Screen:new())
    elseif label == "Files" then
        local Screen = dofile("/scripts/ui/screens/files.lua")
        tdeck.screen.push(Screen:new("/"))
    elseif label == "Testing" then
        local Screen = dofile("/scripts/ui/screens/testing_menu.lua")
        tdeck.screen.push(Screen:new())
    elseif label == "Games" then
        local Screen = dofile("/scripts/ui/screens/games_menu.lua")
        tdeck.screen.push(Screen:new())
    end
end

function MainMenu:set_message_count(count)
    self.items[1].unread = count
    tdeck.screen.invalidate()
end

function MainMenu:set_channel_count(count)
    self.items[2].unread = count
    tdeck.screen.invalidate()
end

function MainMenu:set_contact_count(count)
    self.items[3].unread = count
    tdeck.screen.invalidate()
end

return MainMenu
