-- Contacts Screen for T-Deck OS
-- List of saved contacts (user-added from discovered nodes)

local Contacts = {
    title = "Contacts",
    selected = 1,
    scroll_offset = 0,
    VISIBLE_ROWS = 5,
    ROW_HEIGHT = 36,
    contacts = {}  -- Saved contacts only
}

function Contacts:new()
    local o = {
        title = self.title,
        selected = 1,
        scroll_offset = 0,
        VISIBLE_ROWS = self.VISIBLE_ROWS,
        ROW_HEIGHT = self.ROW_HEIGHT,
        contacts = {}
    }
    setmetatable(o, {__index = Contacts})
    return o
end

function Contacts:on_enter()
    self:refresh_contacts()
end

function Contacts:refresh_contacts()
    self.contacts = {}

    -- Get saved contacts only (not discovered nodes)
    if _G.Contacts and _G.Contacts.get_saved then
        local saved = _G.Contacts.get_saved()
        -- Enrich with live node data if available
        local live_map = {}
        if ez.mesh.is_initialized() then
            local live_nodes = ez.mesh.get_nodes() or {}
            for _, node in ipairs(live_nodes) do
                if node.pub_key_hex then
                    live_map[node.pub_key_hex] = node
                end
            end
        end

        -- Merge saved contact info with live data
        for _, contact in ipairs(saved) do
            local entry = {
                name = contact.name,
                path_hash = contact.path_hash,
                pub_key_hex = contact.pub_key_hex,
                notes = contact.notes,
                added_time = contact.added_time,
                is_saved = true,
            }

            -- Add live data if available
            local live = live_map[contact.pub_key_hex]
            if live then
                entry.last_seen = live.last_seen
                entry.rssi = live.rssi
                entry.role = live.role
                entry.hops = live.hops
                entry.is_online = true
            else
                -- Check discovered cache for last seen info
                if _G.Contacts and _G.Contacts.discovered then
                    local cached = _G.Contacts.discovered[contact.pub_key_hex]
                    if cached then
                        entry.last_seen = cached.last_seen
                        entry.rssi = cached.rssi
                        entry.role = cached.role
                        entry.is_online = false
                    end
                end
            end

            table.insert(self.contacts, entry)
        end
    end

    -- Clamp selection
    if self.selected > #self.contacts then
        self.selected = math.max(1, #self.contacts)
    end
end

function Contacts:rssi_to_bars(rssi)
    if rssi > -60 then return 4
    elseif rssi > -80 then return 3
    elseif rssi > -100 then return 2
    elseif rssi > -110 then return 1
    else return 0
    end
end

function Contacts:format_last_seen(timestamp)
    local now = ez.system.millis()
    local diff = math.floor((now - timestamp) / 1000)

    if diff < 60 then
        return "now"
    elseif diff < 3600 then
        return string.format("%dm", math.floor(diff / 60))
    elseif diff < 86400 then
        return string.format("%dh", math.floor(diff / 3600))
    else
        return string.format("%dd", math.floor(diff / 86400))
    end
end

function Contacts:role_to_string(role)
    local ROLE = ez.mesh.ROLE
    if role == ROLE.CLIENT then return "Client"
    elseif role == ROLE.REPEATER then return "Repeater"
    elseif role == ROLE.ROUTER then return "Router"
    elseif role == ROLE.GATEWAY then return "Gateway"
    else return nil  -- Don't show Unknown
    end
end

function Contacts:render(display)
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
    local scrollbar_width = 8

    if #self.contacts == 0 then
        display.set_font_size("medium")
        display.draw_text_centered(list_start_y + 40, "No saved contacts", colors.TEXT_SECONDARY)
        display.set_font_size("small")
        display.draw_text_centered(list_start_y + 70, "Add contacts from the", colors.TEXT_SECONDARY)
        display.draw_text_centered(list_start_y + 85, "Nodes screen", colors.TEXT_SECONDARY)
        return
    end

    -- Draw visible contact items
    for i = 0, self.VISIBLE_ROWS - 1 do
        local item_idx = self.scroll_offset + i + 1
        if item_idx > #self.contacts then break end

        local node = self.contacts[item_idx]
        local y = list_start_y + i * self.ROW_HEIGHT
        local is_selected = (item_idx == self.selected)

        -- Selection outline (full row height minus small padding)
        if is_selected then
            display.draw_round_rect(4, y - 2, w - 12 - scrollbar_width, self.ROW_HEIGHT - 2, 6, colors.ACCENT)
        end

        -- Node name (primary text) - use medium font
        display.set_font_size("medium")
        local name = node.name or string.format("%02X", (node.path_hash or 0) % 256)
        -- Sanitize name - replace non-printable chars
        local clean_name = ""
        for c in name:gmatch(".") do
            local b = string.byte(c)
            if b >= 32 and b < 127 then
                clean_name = clean_name .. c
            end
        end
        if #clean_name == 0 then
            clean_name = string.format("Node %02X", (node.path_hash or 0) % 256)
        end
        if #clean_name > 18 then
            clean_name = string.sub(clean_name, 1, 18)
        end

        -- Color based on online status
        local name_color
        if not node.is_online then
            name_color = is_selected and colors.TEXT_SECONDARY or colors.TEXT_MUTED
        else
            name_color = is_selected and colors.ACCENT or colors.WHITE
        end
        display.draw_text(10, y + 2, clean_name, name_color)

        -- RSSI on the right side
        local rssi = node.rssi or -999
        local bars = self:rssi_to_bars(rssi)
        local rssi_color
        if bars >= 3 then rssi_color = colors.SUCCESS
        elseif bars >= 2 then rssi_color = colors.WARNING
        else rssi_color = colors.ERROR
        end
        local rssi_str = string.format("%ddB", rssi)
        local rssi_width = display.text_width(rssi_str)
        display.draw_text(w - scrollbar_width - 16 - rssi_width, y + 2, rssi_str, is_selected and colors.ACCENT or rssi_color)

        -- Secondary line: online status + role + last seen + hops
        display.set_font_size("small")
        local info_parts = {}
        if not node.is_online then
            table.insert(info_parts, "(offline)")
        end
        local role_str = self:role_to_string(node.role or 0)
        if role_str then
            table.insert(info_parts, role_str)
        end
        if node.last_seen then
            local seen_str = self:format_last_seen(node.last_seen)
            table.insert(info_parts, "Seen: " .. seen_str)
        end
        if node.hops and node.hops > 0 then
            table.insert(info_parts, "Hops: " .. node.hops)
        end
        local info_str = table.concat(info_parts, "  ")
        local info_color = is_selected and colors.TEXT_SECONDARY or colors.TEXT_MUTED
        display.draw_text(10, y + 4 + 16, info_str, info_color)
    end

    -- Reset to medium font
    display.set_font_size("medium")

    -- Scrollbar (only show if there are more items than visible)
    if #self.contacts > self.VISIBLE_ROWS then
        local sb_x = w - scrollbar_width - 2
        local sb_top = list_start_y
        local sb_height = self.VISIBLE_ROWS * self.ROW_HEIGHT - 6

        -- Track
        display.fill_rect(sb_x, sb_top, 4, sb_height, colors.SURFACE)

        -- Thumb
        local thumb_height = math.max(12, math.floor(sb_height * self.VISIBLE_ROWS / #self.contacts))
        local scroll_range = #self.contacts - self.VISIBLE_ROWS
        local thumb_range = sb_height - thumb_height
        local thumb_y = sb_top + math.floor(self.scroll_offset * thumb_range / scroll_range)

        display.fill_rect(sb_x, thumb_y, 4, thumb_height, colors.ACCENT)
    end
end

function Contacts:handle_key(key)
    if key.special == "UP" then
        self:select_previous()
    elseif key.special == "DOWN" then
        self:select_next()
    elseif key.special == "ENTER" then
        -- Open app menu for selected contact actions
        if _G.AppMenu then
            _G.AppMenu.show()
        end
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "m" then
        self:send_message()
    elseif key.character == "p" then
        self:ping()
    elseif key.character == "d" then
        -- Remove from saved contacts
        self:remove_contact()
    elseif key.character == "r" then
        -- Refresh
        self:refresh_contacts()
        ScreenManager.invalidate()
    end

    return "continue"
end

function Contacts:select_next()
    if #self.contacts == 0 then return end

    if self.selected < #self.contacts then
        self.selected = self.selected + 1
        if self.selected > self.scroll_offset + self.VISIBLE_ROWS then
            self.scroll_offset = self.scroll_offset + 1
        end
        ScreenManager.invalidate()
    end
end

function Contacts:select_previous()
    if #self.contacts == 0 then return end

    if self.selected > 1 then
        self.selected = self.selected - 1
        if self.selected <= self.scroll_offset then
            self.scroll_offset = self.scroll_offset - 1
        end
        ScreenManager.invalidate()
    end
end

function Contacts:view_details()
    if #self.contacts == 0 then return end
    spawn_screen("/scripts/ui/screens/node_details.lua", self.contacts[self.selected])
end

function Contacts:send_message()
    if #self.contacts == 0 then return end

    local contact = self.contacts[self.selected]
    if not contact.pub_key_hex then
        if _G.MessageBox then
            _G.MessageBox.show({title = "Cannot message", subtitle = "No public key for contact"})
        end
        return
    end

    spawn_screen("/scripts/ui/screens/dm_conversation.lua", contact.pub_key_hex, contact.name)
end

function Contacts:ping()
    if #self.contacts == 0 then return end

    local contact = self.contacts[self.selected]
    ez.system.log("Ping " .. (contact.name or "unknown"))
    -- TODO: Implement actual ping
end

function Contacts:remove_contact()
    if #self.contacts == 0 then return end

    local contact = self.contacts[self.selected]
    if not contact.pub_key_hex then
        return
    end

    if _G.Contacts and _G.Contacts.remove then
        local ok = _G.Contacts.remove(contact.pub_key_hex)
        if ok then
            if _G.MessageBox then
                _G.MessageBox.show({title = "Contact removed"})
            end
            self:refresh_contacts()
            ScreenManager.invalidate()
        end
    end
end

-- Menu items for app menu integration
function Contacts:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = "Refresh",
        action = function()
            self_ref:refresh_contacts()
            ScreenManager.invalidate()
        end
    })

    if #self.contacts > 0 then
        local contact = self.contacts[self.selected]

        -- Remove contact option (all contacts shown are saved)
        if contact and contact.pub_key_hex then
            table.insert(items, {
                label = "Remove",
                action = function()
                    self_ref:remove_contact()
                end
            })
        end

        table.insert(items, {
            label = "Message",
            action = function()
                self_ref:send_message()
            end
        })

        table.insert(items, {
            label = "Details",
            action = function()
                self_ref:view_details()
            end
        })

        table.insert(items, {
            label = "Ping",
            action = function()
                self_ref:ping()
                ScreenManager.invalidate()
            end
        })
    end

    return items
end

return Contacts
