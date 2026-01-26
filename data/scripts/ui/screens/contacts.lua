-- Contacts Screen for T-Deck OS
-- List of discovered mesh nodes

local Contacts = {
    title = "Contacts",
    selected = 1,
    scroll_offset = 0,
    VISIBLE_ROWS = 5,
    ROW_HEIGHT = 36,
    nodes = {}
}

function Contacts:new()
    local o = {
        title = self.title,
        selected = 1,
        scroll_offset = 0,
        VISIBLE_ROWS = self.VISIBLE_ROWS,
        ROW_HEIGHT = self.ROW_HEIGHT,
        nodes = {}
    }
    setmetatable(o, {__index = Contacts})
    return o
end

function Contacts:on_enter()
    self:refresh_nodes()
end

function Contacts:refresh_nodes()
    self.nodes = {}

    -- Use Contacts service if available (includes cached nodes)
    if _G.Contacts and _G.Contacts.get_discovered then
        self.nodes = _G.Contacts.get_discovered()
    elseif tdeck.mesh.is_initialized() then
        -- Fallback to direct mesh query
        self.nodes = tdeck.mesh.get_nodes() or {}
        -- Sort by last seen (most recent first)
        table.sort(self.nodes, function(a, b)
            return (a.last_seen or 0) > (b.last_seen or 0)
        end)
    end

    -- Clamp selection
    if self.selected > #self.nodes then
        self.selected = math.max(1, #self.nodes)
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
    local now = tdeck.system.millis()
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
    local ROLE = tdeck.mesh.ROLE
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

    if #self.nodes == 0 then
        display.set_font_size("medium")
        display.draw_text_centered(list_start_y + 40, "No nodes discovered", colors.TEXT_DIM)
        display.set_font_size("small")
        display.draw_text_centered(list_start_y + 70, "Nodes appear when they", colors.TEXT_DIM)
        display.draw_text_centered(list_start_y + 85, "send messages nearby", colors.TEXT_DIM)
        return
    end

    -- Draw visible node items
    for i = 0, self.VISIBLE_ROWS - 1 do
        local item_idx = self.scroll_offset + i + 1
        if item_idx > #self.nodes then break end

        local node = self.nodes[item_idx]
        local y = list_start_y + i * self.ROW_HEIGHT
        local is_selected = (item_idx == self.selected)

        -- Selection outline (full row height minus small padding)
        if is_selected then
            display.draw_round_rect(4, y - 2, w - 12 - scrollbar_width, self.ROW_HEIGHT - 2, 6, colors.CYAN)
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

        -- Add star for saved contacts
        local prefix = ""
        if node.is_saved then
            prefix = "* "
        end

        -- Dim cached (offline) nodes
        local name_color
        if node.is_cached then
            name_color = is_selected and colors.TEXT_DIM or colors.DARK_GRAY
        else
            name_color = is_selected and colors.CYAN or colors.WHITE
        end
        display.draw_text(10, y + 2, prefix .. clean_name, name_color)

        -- RSSI on the right side
        local rssi = node.rssi or -999
        local bars = self:rssi_to_bars(rssi)
        local rssi_color
        if bars >= 3 then rssi_color = colors.GREEN
        elseif bars >= 2 then rssi_color = colors.YELLOW
        else rssi_color = colors.RED
        end
        local rssi_str = string.format("%ddB", rssi)
        local rssi_width = display.text_width(rssi_str)
        display.draw_text(w - scrollbar_width - 16 - rssi_width, y + 2, rssi_str, is_selected and colors.CYAN or rssi_color)

        -- Secondary line: role + last seen + hops + cached status
        display.set_font_size("small")
        local info_parts = {}
        if node.is_cached then
            table.insert(info_parts, "(offline)")
        end
        local role_str = self:role_to_string(node.role or 0)
        if role_str then
            table.insert(info_parts, role_str)
        end
        local seen_str = self:format_last_seen(node.last_seen or 0)
        table.insert(info_parts, "Seen: " .. seen_str)
        if node.hops and node.hops > 0 then
            table.insert(info_parts, "Hops: " .. node.hops)
        end
        local info_str = table.concat(info_parts, "  ")
        local info_color = is_selected and colors.TEXT_DIM or colors.DARK_GRAY
        display.draw_text(10, y + 4 + 16, info_str, info_color)
    end

    -- Reset to medium font
    display.set_font_size("medium")

    -- Scrollbar (only show if there are more items than visible)
    if #self.nodes > self.VISIBLE_ROWS then
        local sb_x = w - scrollbar_width - 2
        local sb_top = list_start_y
        local sb_height = self.VISIBLE_ROWS * self.ROW_HEIGHT - 6

        -- Track
        display.fill_rect(sb_x, sb_top, 4, sb_height, colors.DARK_GRAY)

        -- Thumb
        local thumb_height = math.max(12, math.floor(sb_height * self.VISIBLE_ROWS / #self.nodes))
        local scroll_range = #self.nodes - self.VISIBLE_ROWS
        local thumb_range = sb_height - thumb_height
        local thumb_y = sb_top + math.floor(self.scroll_offset * thumb_range / scroll_range)

        display.fill_rect(sb_x, thumb_y, 4, thumb_height, colors.CYAN)
    end
end

function Contacts:handle_key(key)
    if key.special == "UP" then
        self:select_previous()
    elseif key.special == "DOWN" then
        self:select_next()
    elseif key.special == "ENTER" then
        self:view_details()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "m" then
        self:send_message()
    elseif key.character == "p" then
        self:ping()
    elseif key.character == "a" then
        -- Add to saved contacts
        self:add_contact()
    elseif key.character == "d" then
        -- Remove from saved contacts
        self:remove_contact()
    elseif key.character == "r" then
        -- Refresh
        self:refresh_nodes()
        ScreenManager.invalidate()
    end

    return "continue"
end

function Contacts:select_next()
    if #self.nodes == 0 then return end

    if self.selected < #self.nodes then
        self.selected = self.selected + 1
        if self.selected > self.scroll_offset + self.VISIBLE_ROWS then
            self.scroll_offset = self.scroll_offset + 1
        end
        ScreenManager.invalidate()
    end
end

function Contacts:select_previous()
    if #self.nodes == 0 then return end

    if self.selected > 1 then
        self.selected = self.selected - 1
        if self.selected <= self.scroll_offset then
            self.scroll_offset = self.scroll_offset - 1
        end
        ScreenManager.invalidate()
    end
end

function Contacts:view_details()
    if #self.nodes == 0 then return end

    local node = self.nodes[self.selected]
    local NodeDetails = load_module("/scripts/ui/screens/node_details.lua")
    ScreenManager.push(NodeDetails:new(node))
end

function Contacts:send_message()
    if #self.nodes == 0 then return end

    local Compose = load_module("/scripts/ui/screens/compose.lua")
    ScreenManager.push(Compose:new())
end

function Contacts:ping()
    if #self.nodes == 0 then return end

    local node = self.nodes[self.selected]
    tdeck.system.log("Ping " .. (node.name or "unknown"))
    -- TODO: Implement actual ping
end

function Contacts:add_contact()
    if #self.nodes == 0 then return end

    local node = self.nodes[self.selected]
    if not node.pub_key_hex then
        if _G.MessageBox then
            _G.MessageBox.show("Cannot save: no public key", 2000)
        end
        return
    end

    if _G.Contacts and _G.Contacts.add then
        local ok = _G.Contacts.add(node)
        if ok then
            if _G.MessageBox then
                _G.MessageBox.show("Contact saved", 1500)
            end
            self:refresh_nodes()
            ScreenManager.invalidate()
        end
    end
end

function Contacts:remove_contact()
    if #self.nodes == 0 then return end

    local node = self.nodes[self.selected]
    if not node.pub_key_hex or not node.is_saved then
        return
    end

    if _G.Contacts and _G.Contacts.remove then
        local ok = _G.Contacts.remove(node.pub_key_hex)
        if ok then
            if _G.MessageBox then
                _G.MessageBox.show("Contact removed", 1500)
            end
            self:refresh_nodes()
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
            self_ref:refresh_nodes()
            ScreenManager.invalidate()
        end
    })

    if #self.nodes > 0 then
        local node = self.nodes[self.selected]

        -- Add/Remove contact option based on current state
        if node and node.pub_key_hex then
            if node.is_saved then
                table.insert(items, {
                    label = "Remove Contact",
                    action = function()
                        self_ref:remove_contact()
                    end
                })
            else
                table.insert(items, {
                    label = "Add Contact",
                    action = function()
                        self_ref:add_contact()
                    end
                })
            end
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
