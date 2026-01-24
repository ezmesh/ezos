-- Contacts Screen for T-Deck OS
-- List of discovered mesh nodes

local Contacts = {
    title = "Contacts",
    selected = 1,
    scroll_offset = 0,
    visible_items = 8,
    nodes = {}
}

function Contacts:new()
    local o = {
        title = self.title,
        selected = 1,
        scroll_offset = 0,
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

    if not tdeck.mesh.is_initialized() then
        return
    end

    local raw_nodes = tdeck.mesh.get_nodes()

    -- Sort by last seen (most recent first)
    table.sort(raw_nodes, function(a, b)
        return (a.last_seen or 0) > (b.last_seen or 0)
    end)

    self.nodes = raw_nodes

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

function Contacts:render(display)
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    if #self.nodes == 0 then
        display.draw_text_centered(5 * display.font_height, "No nodes discovered", colors.TEXT_DIM)
        display.draw_text_centered(7 * display.font_height, "Nodes appear when they", colors.TEXT_DIM)
        display.draw_text_centered(8 * display.font_height, "send messages nearby", colors.TEXT_DIM)
    else
        -- Header row
        display.draw_text(3 * display.font_width, 2 * display.font_height, "Name", colors.TEXT_DIM)
        display.draw_text(20 * display.font_width, 2 * display.font_height, "RSSI", colors.TEXT_DIM)
        display.draw_text(28 * display.font_width, 2 * display.font_height, "Seen", colors.TEXT_DIM)

        -- Node list
        local y = 3
        for i = 1, self.visible_items do
            local idx = i + self.scroll_offset
            if idx > #self.nodes then break end

            local node = self.nodes[idx]
            local is_selected = (idx == self.selected)
            local py = y * display.font_height

            if is_selected then
                display.fill_rect(display.font_width, py,
                                (display.cols - 2) * display.font_width,
                                display.font_height,
                                colors.SELECTION)
                display.draw_text(display.font_width, py, ">", colors.CYAN)
            end

            -- Name (truncated)
            local name_color = is_selected and colors.CYAN or colors.TEXT
            local name = node.name or string.format("%02X", (node.path_hash or 0) % 256)
            if #name > 16 then
                name = string.sub(name, 1, 16)
            end
            display.draw_text(3 * display.font_width, py, name, name_color)

            -- RSSI with color based on signal strength
            local rssi = node.rssi or node.last_rssi or -999
            local bars = self:rssi_to_bars(rssi)
            local rssi_str = string.format("%ddB", rssi)

            local rssi_color
            if bars >= 3 then rssi_color = colors.GREEN
            elseif bars >= 2 then rssi_color = colors.YELLOW
            else rssi_color = colors.RED
            end

            display.draw_text(20 * display.font_width, py, rssi_str,
                            is_selected and colors.CYAN or rssi_color)

            -- Last seen
            local seen_str = self:format_last_seen(node.last_seen or 0)
            display.draw_text(28 * display.font_width, py, seen_str,
                            is_selected and colors.CYAN or colors.TEXT_DIM)

            -- Hop count
            if node.hops and node.hops > 0 then
                local hop_str = string.format("+%d", node.hops)
                display.draw_text(35 * display.font_width, py, hop_str,
                                is_selected and colors.CYAN or colors.TEXT_DIM)
            end

            y = y + 1
        end

        -- Scroll indicators
        if self.scroll_offset > 0 then
            display.draw_text((display.cols - 1) * display.font_width, 3 * display.font_height,
                            "^", colors.CYAN)
        end
        if self.scroll_offset + self.visible_items < #self.nodes then
            display.draw_text((display.cols - 1) * display.font_width,
                            (3 + self.visible_items - 1) * display.font_height,
                            "v", colors.CYAN)
        end

        -- Count
        local count_str = string.format("%d nodes", #self.nodes)
        display.draw_text((display.cols - #count_str - 1) * display.font_width,
                        (display.rows - 3) * display.font_height,
                        count_str, colors.TEXT_DIM)
    end

    -- Help bar
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[M]sg [Enter]Info [Q]Back", colors.TEXT_DIM)
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
    end

    return "continue"
end

function Contacts:select_next()
    if #self.nodes == 0 then return end

    if self.selected < #self.nodes then
        self.selected = self.selected + 1
        if self.selected > self.scroll_offset + self.visible_items then
            self.scroll_offset = self.scroll_offset + 1
        end
        tdeck.screen.invalidate()
    end
end

function Contacts:select_previous()
    if #self.nodes == 0 then return end

    if self.selected > 1 then
        self.selected = self.selected - 1
        if self.selected <= self.scroll_offset then
            self.scroll_offset = self.scroll_offset - 1
        end
        tdeck.screen.invalidate()
    end
end

function Contacts:view_details()
    if #self.nodes == 0 then return end

    local node = self.nodes[self.selected]
    local NodeDetails = dofile("/scripts/ui/screens/node_details.lua")
    tdeck.screen.push(NodeDetails:new(node))
end

function Contacts:send_message()
    if #self.nodes == 0 then return end

    local Compose = dofile("/scripts/ui/screens/compose.lua")
    tdeck.screen.push(Compose:new())
end

function Contacts:ping()
    if #self.nodes == 0 then return end

    local node = self.nodes[self.selected]
    tdeck.system.log("Ping " .. (node.name or "unknown"))
    -- TODO: Implement actual ping
end

return Contacts
