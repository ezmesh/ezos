-- Packets Screen for T-Deck OS
-- Live view of incoming mesh packets

local Packets = {
    title = "Packets",
    packets = {},
    max_packets = 50,
    scroll_offset = 0,
    auto_scroll = true,
    paused = false,
}

-- Payload type names (from packet.h)
local PAYLOAD_TYPES = {
    [0] = "REQ",
    [1] = "RESP",
    [2] = "TXT",
    [3] = "ACK",
    [4] = "ADVERT",
    [5] = "GRP_TXT",
    [6] = "GRP_DAT",
    [7] = "ANON",
    [8] = "PATH",
    [9] = "TRACE",
    [10] = "MULTI",
    [11] = "CTRL",
    [15] = "RAW",
}

-- Route type names
local ROUTE_TYPES = {
    [0] = "TF",  -- Transport Flood
    [1] = "FL",  -- Flood
    [2] = "DR",  -- Direct
    [3] = "TD",  -- Transport Direct
}

function Packets:new()
    local o = {
        title = self.title,
        packets = {},
        scroll_offset = 0,
        auto_scroll = true,
        paused = false,
        queue_enabled = false,
    }
    setmetatable(o, {__index = Packets})
    return o
end

function Packets:on_enter()
    -- Enable packet queue for polling
    if tdeck.mesh and tdeck.mesh.enable_packet_queue then
        tdeck.mesh.enable_packet_queue(true)
        self.queue_enabled = true
        tdeck.system.log("[Packets] Packet queue enabled")
    else
        tdeck.system.log("[Packets] ERROR: tdeck.mesh.enable_packet_queue not available")
    end

    -- Register update callback to poll packets
    if _G.MainLoop then
        local self_ref = self
        _G.MainLoop.on_update("packets_poll", function()
            self_ref:poll_packets()
        end)
    end
end

function Packets:on_leave()
    -- Unregister update callback
    if _G.MainLoop then
        _G.MainLoop.off_update("packets_poll")
    end

    -- Disable packet queue
    if self.queue_enabled and tdeck.mesh and tdeck.mesh.enable_packet_queue then
        tdeck.mesh.enable_packet_queue(false)
        self.queue_enabled = false
    end
end

function Packets:poll_packets()
    if self.paused then return end
    if not tdeck.mesh or not tdeck.mesh.has_packets then return end

    -- Process all available packets
    local processed = 0
    while tdeck.mesh.has_packets() and processed < 10 do
        local pkt = tdeck.mesh.pop_packet()
        if pkt then
            self:add_packet(pkt)
            processed = processed + 1
        else
            break
        end
    end
end

function Packets:add_packet(pkt)
    -- Format packet info
    local type_name = PAYLOAD_TYPES[pkt.payload_type] or string.format("%02X", pkt.payload_type)
    local route_name = ROUTE_TYPES[pkt.route_type] or "?"

    -- Convert payload to hex string (first bytes)
    local hex_bytes = {}
    local payload = pkt.payload or ""
    local max_bytes = 12  -- Show up to 12 bytes
    for i = 1, math.min(#payload, max_bytes) do
        table.insert(hex_bytes, string.format("%02X", string.byte(payload, i)))
    end
    local hex_str = table.concat(hex_bytes, " ")
    if #payload > max_bytes then
        hex_str = hex_str .. ".."
    end

    -- Get sender from path (first byte)
    local sender = "??"
    if pkt.path and #pkt.path > 0 then
        sender = string.format("%02X", string.byte(pkt.path, 1))
    end

    local entry = {
        type = type_name,
        route = route_name,
        sender = sender,
        rssi = pkt.rssi,
        hex = hex_str,
        len = #payload,
        time = tdeck.system.millis(),
    }

    table.insert(self.packets, entry)

    -- Limit packet history
    while #self.packets > self.max_packets do
        table.remove(self.packets, 1)
        if self.scroll_offset > 0 then
            self.scroll_offset = self.scroll_offset - 1
        end
    end

    -- Auto-scroll to bottom
    if self.auto_scroll then
        self:scroll_to_bottom()
    end

    ScreenManager.invalidate()
end

function Packets:scroll_to_bottom()
    -- Will be calculated in render based on visible lines
    self.scroll_offset = math.max(0, #self.packets - 10)
end

function Packets:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    -- Fill background
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, w, h, colors.BLACK)
    end

    -- Title bar with status
    local status = self.paused and " [PAUSED]" or ""
    TitleBar.draw(display, self.title .. status)

    -- Use tiny font for packet list (dense display)
    display.set_font_size("tiny")
    local fh = display.get_font_height() + 2  -- Add 2px line spacing
    local fw = display.get_font_width()

    -- Calculate visible area
    local start_y = 26
    local visible_lines = math.floor((h - start_y - 16) / fh)

    -- Update scroll_to_bottom calculation
    if self.auto_scroll then
        self.scroll_offset = math.max(0, #self.packets - visible_lines)
    end

    if #self.packets == 0 then
        display.set_font_size("small")
        display.draw_text_centered(h / 2 - 8, "Waiting for packets...", colors.TEXT_SECONDARY)
        display.set_font_size("tiny")
        local queue_count = tdeck.mesh and tdeck.mesh.packet_count and tdeck.mesh.packet_count() or 0
        display.draw_text_centered(h / 2 + 8, string.format("Queue: %d  [P]ause [Q]uit", queue_count), colors.TEXT_MUTED)
        return
    end

    -- Draw packet list
    local y = start_y
    for i = 1, visible_lines do
        local idx = i + self.scroll_offset
        if idx > #self.packets then break end

        local pkt = self.packets[idx]

        -- Format: TYPE SENDER RSSI HEX...
        -- Example: ADVERT 3F -85 01 02 03 04..
        local rssi_str = string.format("%d", math.floor(pkt.rssi))
        local line = string.format("%-6s %s %4s %s",
            pkt.type, pkt.sender, rssi_str, pkt.hex)

        -- Color based on packet type
        local color = colors.TEXT
        if pkt.type == "ADVERT" then
            color = colors.ACCENT
        elseif pkt.type == "GRP_TXT" then
            color = colors.SUCCESS
        elseif pkt.type == "TXT" then
            color = colors.WARNING
        end

        display.draw_text(2, y, line, color)
        y = y + fh
    end

    -- Scroll indicator
    if #self.packets > visible_lines then
        local total = #self.packets
        local pos = self.scroll_offset
        local pct = pos / math.max(1, total - visible_lines)

        local sb_x = w - 4
        local sb_h = h - start_y - 16
        local thumb_h = math.max(8, math.floor(sb_h * visible_lines / total))
        local thumb_y = start_y + math.floor((sb_h - thumb_h) * pct)

        display.fill_rect(sb_x, start_y, 2, sb_h, colors.SURFACE)
        display.fill_rect(sb_x, thumb_y, 2, thumb_h, colors.TEXT_SECONDARY)
    end

    -- Footer with stats
    display.set_font_size("tiny")
    local footer_y = h - display.get_font_height() - 2
    local stats = string.format("Packets: %d  [P]ause [A]uto [C]lear", #self.packets)
    display.draw_text(2, footer_y, stats, colors.TEXT_MUTED)
end

function Packets:handle_key(key)
    if key.special == "UP" then
        if self.scroll_offset > 0 then
            self.scroll_offset = self.scroll_offset - 1
            self.auto_scroll = false
            ScreenManager.invalidate()
        end
    elseif key.special == "DOWN" then
        self.scroll_offset = self.scroll_offset + 1
        self.auto_scroll = false
        ScreenManager.invalidate()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "p" then
        self.paused = not self.paused
        ScreenManager.invalidate()
    elseif key.character == "a" then
        self.auto_scroll = not self.auto_scroll
        if self.auto_scroll then
            self:scroll_to_bottom()
        end
        ScreenManager.invalidate()
    elseif key.character == "c" then
        self.packets = {}
        self.scroll_offset = 0
        ScreenManager.invalidate()
    end

    return "continue"
end

-- Menu items for app menu integration
function Packets:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = self.paused and "Resume" or "Pause",
        action = function()
            self_ref.paused = not self_ref.paused
            ScreenManager.invalidate()
        end
    })

    table.insert(items, {
        label = "Clear",
        action = function()
            self_ref.packets = {}
            self_ref.scroll_offset = 0
            ScreenManager.invalidate()
        end
    })

    table.insert(items, {
        label = self.auto_scroll and "Manual Scroll" or "Auto Scroll",
        action = function()
            self_ref.auto_scroll = not self_ref.auto_scroll
            if self_ref.auto_scroll then
                self_ref:scroll_to_bottom()
            end
            ScreenManager.invalidate()
        end
    })

    return items
end

return Packets
