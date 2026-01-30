-- Map Nodes Screen for T-Deck OS
-- Shows discovered nodes with signal strength for map navigation
-- Nodes with location data can be selected to teleport the map

local MapNodes = {
    title = "Nearby Nodes",
    VISIBLE_ROWS = 5,
    ROW_HEIGHT = 38,
}

-- Safe sound helper
local function play_sound(name)
    if _G.SoundUtils and _G.SoundUtils[name] then
        pcall(_G.SoundUtils[name])
    end
end

-- Format RSSI as signal description
local function format_rssi(rssi)
    if not rssi or rssi < -200 then return "?" end
    if rssi > -50 then return "Strong"
    elseif rssi > -70 then return "Good"
    elseif rssi > -85 then return "Fair"
    else return "Weak" end
end

-- Get color for RSSI
local function get_rssi_color(rssi, colors)
    if not rssi or rssi < -200 then return colors.TEXT_MUTED end
    if rssi > -50 then return colors.SUCCESS
    elseif rssi > -70 then return colors.ACCENT
    elseif rssi > -85 then return colors.WARNING
    else return colors.ERROR end
end

function MapNodes:new(on_select_callback)
    local o = {
        selected = 1,
        scroll_offset = 0,
        nodes = {},
        on_select = on_select_callback,
    }
    setmetatable(o, {__index = MapNodes})
    return o
end

function MapNodes:on_enter()
    self:refresh_nodes()
end

function MapNodes:refresh_nodes()
    self.nodes = {}

    -- Get all discovered nodes from Contacts service
    if _G.Contacts and _G.Contacts.get_discovered then
        local discovered = _G.Contacts.get_discovered()
        for _, node in ipairs(discovered) do
            table.insert(self.nodes, {
                name = node.name or "Unknown",
                rssi = node.rssi or node.last_rssi,
                hops = node.hops or node.hop_count or 0,
                last_seen = node.last_seen,
                lat = node.lat,
                lon = node.lon,
                has_location = node.has_location or false,
            })
        end
    end

    -- Sort by RSSI (strongest first), then by hops (lowest first)
    table.sort(self.nodes, function(a, b)
        local rssi_a = a.rssi or -999
        local rssi_b = b.rssi or -999
        if rssi_a ~= rssi_b then
            return rssi_a > rssi_b
        end
        return (a.hops or 99) < (b.hops or 99)
    end)

    -- Reset selection if list changed
    if self.selected > #self.nodes then
        self.selected = math.max(1, #self.nodes)
    end
end

function MapNodes:adjust_scroll()
    if self.selected <= self.scroll_offset then
        self.scroll_offset = self.selected - 1
    elseif self.selected > self.scroll_offset + self.VISIBLE_ROWS then
        self.scroll_offset = self.selected - self.VISIBLE_ROWS
    end
    local max_scroll = math.max(0, #self.nodes - self.VISIBLE_ROWS)
    self.scroll_offset = math.max(0, math.min(max_scroll, self.scroll_offset))
end

function MapNodes:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    -- Background
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, w, h, colors.BLACK)
    end

    -- Title bar
    TitleBar.draw(display, self.title)

    local list_start_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31
    local scrollbar_width = 8

    -- Empty state
    if #self.nodes == 0 then
        display.set_font_size("medium")
        display.draw_text_centered(list_start_y + 40, "No nodes discovered", colors.TEXT_SECONDARY)
        display.set_font_size("small")
        display.draw_text_centered(list_start_y + 60, "Nodes will appear when", colors.TEXT_MUTED)
        display.draw_text_centered(list_start_y + 75, "they send announcements", colors.TEXT_MUTED)
        return
    end

    -- Draw node list
    for i = 0, self.VISIBLE_ROWS - 1 do
        local idx = self.scroll_offset + i + 1
        if idx > #self.nodes then break end

        local node = self.nodes[idx]
        local y = list_start_y + i * self.ROW_HEIGHT
        local is_selected = (idx == self.selected)

        -- Selection highlight
        if is_selected then
            display.draw_round_rect(4, y - 1, w - 12 - scrollbar_width, self.ROW_HEIGHT - 4, 6, colors.ACCENT)
        end

        -- Node name
        display.set_font_size("medium")
        local name_color = is_selected and colors.ACCENT or colors.WHITE
        local name = node.name
        if #name > 20 then name = string.sub(name, 1, 19) .. ".." end
        display.draw_text(10, y + 2, name, name_color)

        -- Signal info line
        display.set_font_size("small")
        local info_color = is_selected and colors.TEXT_SECONDARY or colors.TEXT_MUTED

        -- Build info string: RSSI | Hops | Coordinates/No GPS
        local info_parts = {}

        -- RSSI with strength indicator
        local rssi_str = format_rssi(node.rssi)
        if node.rssi and node.rssi > -200 then
            rssi_str = rssi_str .. string.format(" (%ddBm)", math.floor(node.rssi))
        end
        table.insert(info_parts, rssi_str)

        -- Hops
        if node.hops == 0 then
            table.insert(info_parts, "Direct")
        else
            table.insert(info_parts, node.hops .. " hop" .. (node.hops > 1 and "s" or ""))
        end

        -- Coordinates or "No GPS"
        if node.has_location and node.lat and node.lon then
            table.insert(info_parts, string.format("%.2f, %.2f", node.lat, node.lon))
        else
            table.insert(info_parts, "No GPS")
        end

        local info_str = table.concat(info_parts, " | ")
        display.draw_text(10, y + 20, info_str, info_color)

        -- Draw RSSI color bar on right
        local bar_x = w - scrollbar_width - 20
        local bar_y = y + 6
        local bar_w = 12
        local bar_h = self.ROW_HEIGHT - 16
        local rssi_color = get_rssi_color(node.rssi, colors)
        display.fill_rect(bar_x, bar_y, bar_w, bar_h, rssi_color)
    end

    -- Reset font
    display.set_font_size("medium")

    -- Scrollbar
    if #self.nodes > self.VISIBLE_ROWS then
        local sb_x = w - scrollbar_width - 2
        local sb_top = list_start_y
        local sb_height = self.VISIBLE_ROWS * self.ROW_HEIGHT - 6

        display.fill_rect(sb_x, sb_top, 4, sb_height, colors.SURFACE)

        local thumb_height = math.max(12, math.floor(sb_height * self.VISIBLE_ROWS / #self.nodes))
        local scroll_range = #self.nodes - self.VISIBLE_ROWS
        local thumb_range = sb_height - thumb_height
        local thumb_y = sb_top + math.floor(self.scroll_offset * thumb_range / scroll_range)

        display.fill_rect(sb_x, thumb_y, 4, thumb_height, colors.ACCENT)
    end

    -- Help text at bottom
    display.set_font_size("small")
    local help_y = h - 32
    if #self.nodes > 0 then
        local selected_node = self.nodes[self.selected]
        if selected_node and selected_node.has_location then
            display.draw_text_centered(help_y, "Press ENTER to go to location", colors.TEXT_SECONDARY)
        else
            display.draw_text_centered(help_y, "Node has no GPS location", colors.TEXT_MUTED)
        end
    end
    display.set_font_size("medium")
end

function MapNodes:handle_key(key)
    ScreenManager.invalidate()

    if key.special == "UP" then
        if self.selected > 1 then
            self.selected = self.selected - 1
            self:adjust_scroll()
            play_sound("navigate")
        end
    elseif key.special == "DOWN" then
        if self.selected < #self.nodes then
            self.selected = self.selected + 1
            self:adjust_scroll()
            play_sound("navigate")
        end
    elseif key.special == "LEFT" then
        self.selected = math.max(1, self.selected - self.VISIBLE_ROWS)
        self:adjust_scroll()
        play_sound("navigate")
    elseif key.special == "RIGHT" then
        self.selected = math.min(#self.nodes, self.selected + self.VISIBLE_ROWS)
        self:adjust_scroll()
        play_sound("navigate")
    elseif key.special == "ENTER" then
        self:select_node()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "r" or key.character == "R" then
        -- Refresh nodes
        self:refresh_nodes()
        play_sound("click")
    end

    return "continue"
end

function MapNodes:select_node()
    if #self.nodes == 0 then return end

    local node = self.nodes[self.selected]
    if not node then return end

    -- Only allow selection if node has location
    if not node.has_location or not node.lat or not node.lon then
        play_sound("error")
        return
    end

    play_sound("click")

    if self.on_select then
        -- Call callback with location and pop back to map
        self.on_select(node.lat, node.lon)
        ScreenManager.pop()
    end
end

function MapNodes:get_menu_items()
    local self_ref = self
    return {
        {
            label = "Refresh",
            action = function()
                self_ref:refresh_nodes()
                ScreenManager.invalidate()
            end
        }
    }
end

return MapNodes
