-- Node Info Screen for T-Deck OS
-- Show information about the local device

local NodeInfo = {
    title = "Node Info",
    node_id = "",
    node_name = "",
    pub_key = "",
    battery = 0,
    tx_count = 0,
    rx_count = 0,
    uptime_seconds = 0
}

function NodeInfo:new()
    local o = {
        title = "Node Info",
        node_id = "",
        node_name = "",
        pub_key = "",
        battery = 0,
        tx_count = 0,
        rx_count = 0,
        uptime_seconds = 0
    }
    setmetatable(o, {__index = NodeInfo})
    return o
end

function NodeInfo:on_enter()
    self:refresh_info()
end

function NodeInfo:refresh_info()
    if tdeck.mesh.is_initialized() then
        self.node_id = tdeck.mesh.get_node_id() or ""
        self.node_name = tdeck.mesh.get_node_name and tdeck.mesh.get_node_name() or "MeshNode"
        self.pub_key = tdeck.mesh.get_public_key and tdeck.mesh.get_public_key() or ""
        self.tx_count = tdeck.mesh.get_tx_count and tdeck.mesh.get_tx_count() or 0
        self.rx_count = tdeck.mesh.get_rx_count and tdeck.mesh.get_rx_count() or 0
    end

    self.battery = tdeck.system.get_battery_percent()
    self.uptime_seconds = math.floor(tdeck.system.uptime())
end

function NodeInfo:format_uptime()
    local secs = self.uptime_seconds
    local days = math.floor(secs / 86400)
    secs = secs % 86400
    local hours = math.floor(secs / 3600)
    secs = secs % 3600
    local mins = math.floor(secs / 60)

    if days > 0 then
        return string.format("%dd %dh %dm", days, hours, mins)
    elseif hours > 0 then
        return string.format("%dh %dm", hours, mins)
    else
        return string.format("%dm", mins)
    end
end

function NodeInfo:render(display)
    local colors = display.colors

    -- Refresh info each render
    self:refresh_info()

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    local row = 2
    local label_x = 2
    local value_x = 20

    -- Node Name
    display.draw_text(label_x * display.font_width, row * display.font_height, "Name:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, row * display.font_height, self.node_name, colors.CYAN)
    row = row + 1

    -- Node ID
    local display_id = self.node_id
    if #display_id > 24 then
        display_id = string.sub(display_id, 1, 24) .. "..."
    end
    display.draw_text(label_x * display.font_width, row * display.font_height, "ID:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, row * display.font_height, display_id, colors.TEXT)
    row = row + 1

    -- Public Key Fingerprint
    local display_key = self.pub_key
    if #display_key > 24 then
        display_key = string.sub(display_key, 1, 24) .. "..."
    end
    display.draw_text(label_x * display.font_width, row * display.font_height, "PubKey:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, row * display.font_height, display_key, colors.CYAN)
    row = row + 1

    -- Battery
    local batt_str = string.format("%d%%", self.battery)
    local batt_color = self.battery > 20 and colors.GREEN or colors.RED
    display.draw_text(label_x * display.font_width, row * display.font_height, "Battery:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, row * display.font_height, batt_str, batt_color)
    row = row + 1

    -- TX/RX counts
    local stats_str = string.format("TX:%d RX:%d", self.tx_count, self.rx_count)
    display.draw_text(label_x * display.font_width, row * display.font_height, "Packets:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, row * display.font_height, stats_str, colors.TEXT)
    row = row + 1

    -- Uptime
    local uptime_str = self:format_uptime()
    display.draw_text(label_x * display.font_width, row * display.font_height, "Uptime:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, row * display.font_height, uptime_str, colors.TEXT)
    row = row + 1

    -- Free memory
    local heap_kb = math.floor(tdeck.system.get_free_heap() / 1024)
    local psram_kb = math.floor(tdeck.system.get_free_psram() / 1024)
    local mem_str = string.format("%dKB / %dKB", heap_kb, psram_kb)
    display.draw_text(label_x * display.font_width, row * display.font_height, "Memory:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, row * display.font_height, mem_str, colors.TEXT)

    -- Help bar
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[Q]Back", colors.TEXT_DIM)
end

function NodeInfo:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    -- Refresh on any key
    tdeck.screen.invalidate()
    return "continue"
end

return NodeInfo
