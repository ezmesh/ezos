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
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    -- Refresh info each render
    self:refresh_info()

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content font
    display.set_font_size("small")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    local row = 2
    local label_x = 1
    local value_x = 10

    -- Calculate max chars that fit in value column
    local max_value_chars = math.floor((display.width - value_x * fw) / fw) - 1

    -- Node Name
    display.draw_text(label_x * fw, row * fh, "Name:", colors.TEXT_SECONDARY)
    display.draw_text(value_x * fw, row * fh, self.node_name, colors.ACCENT)
    row = row + 1

    -- Node ID
    local display_id = self.node_id
    if #display_id > max_value_chars then
        display_id = string.sub(display_id, 1, max_value_chars - 3) .. "..."
    end
    display.draw_text(label_x * fw, row * fh, "ID:", colors.TEXT_SECONDARY)
    display.draw_text(value_x * fw, row * fh, display_id, colors.TEXT)
    row = row + 1

    -- Public Key (base64 encoded, wrapped to value column)
    display.draw_text(label_x * fw, row * fh, "PubKey:", colors.TEXT_SECONDARY)
    if self.pub_key and #self.pub_key > 0 then
        local b64_key = tdeck.crypto.base64_encode(self.pub_key)
        if b64_key then
            -- Wrap pubkey across multiple lines, aligned to value column
            local pos = 1
            while pos <= #b64_key do
                local chunk = string.sub(b64_key, pos, pos + max_value_chars - 1)
                display.draw_text(value_x * fw, row * fh, chunk, colors.ACCENT)
                row = row + 1
                pos = pos + max_value_chars
            end
        else
            row = row + 1
        end
    else
        row = row + 1
    end

    -- Battery
    local batt_str = string.format("%d%%", self.battery)
    local batt_color = self.battery > 20 and colors.SUCCESS or colors.ERROR
    display.draw_text(label_x * fw, row * fh, "Battery:", colors.TEXT_SECONDARY)
    display.draw_text(value_x * fw, row * fh, batt_str, batt_color)
    row = row + 1

    -- TX/RX counts
    local stats_str = string.format("TX:%d RX:%d", self.tx_count, self.rx_count)
    display.draw_text(label_x * fw, row * fh, "Packets:", colors.TEXT_SECONDARY)
    display.draw_text(value_x * fw, row * fh, stats_str, colors.TEXT)
    row = row + 1

    -- Uptime
    local uptime_str = self:format_uptime()
    display.draw_text(label_x * fw, row * fh, "Uptime:", colors.TEXT_SECONDARY)
    display.draw_text(value_x * fw, row * fh, uptime_str, colors.TEXT)
    row = row + 1

    -- Free memory (Heap / PSRAM)
    local heap_kb = math.floor(tdeck.system.get_free_heap() / 1024)
    local psram_kb = math.floor(tdeck.system.get_free_psram() / 1024)
    local mem_str = string.format("H:%dK P:%dK", heap_kb, psram_kb)
    display.draw_text(label_x * fw, row * fh, "Memory:", colors.TEXT_SECONDARY)
    display.draw_text(value_x * fw, row * fh, mem_str, colors.TEXT)
end

function NodeInfo:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    -- Refresh on any key
    ScreenManager.invalidate()
    return "continue"
end

-- Menu items for app menu integration
function NodeInfo:get_menu_items()
    local items = {}

    table.insert(items, {
        label = "Send Advert",
        action = function()
            if tdeck.mesh.is_initialized() then
                local ok = tdeck.mesh.send_announce()
                if ok then
                    tdeck.system.log("[NodeInfo] Sent ADVERT")
                    if _G.MessageBox then
                        _G.MessageBox.show({title = "Advert sent"})
                    end
                else
                    if _G.MessageBox then
                        _G.MessageBox.show({title = "Failed to send"})
                    end
                end
            end
            ScreenManager.invalidate()
        end
    })

    table.insert(items, {
        label = "Log",
        action = function()
            spawn(function()
                local ok, LogViewer = pcall(load_module, "/scripts/ui/screens/log_viewer.lua")
                if ok and LogViewer then
                    ScreenManager.push(LogViewer:new())
                end
            end)
        end
    })

    table.insert(items, {
        label = "Refresh",
        action = function()
            ScreenManager.invalidate()
        end
    })

    return items
end

return NodeInfo
