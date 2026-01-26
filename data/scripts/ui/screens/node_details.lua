-- Node Details Screen for T-Deck OS
-- Show detailed information about a mesh node

local NodeDetails = {
    title = "Node Details",
    node = nil
}

function NodeDetails:new(node)
    local o = {
        title = "Node Details",
        node = node
    }
    setmetatable(o, {__index = NodeDetails})
    return o
end

function NodeDetails:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    if not self.node then
        display.draw_text_centered(6 * fh, "No node data", colors.TEXT_DIM)
        return
    end

    local y = 2
    local label_x = 2
    local value_x = 14

    -- Name
    display.draw_text(label_x * fw, y * fh, "Name:", colors.TEXT_DIM)
    display.draw_text(value_x * fw, y * fh, self.node.name or "Unknown", colors.CYAN)
    y = y + 2

    -- Path Hash
    local hash_str = string.format("0x%02X", (self.node.path_hash or 0) % 256)
    display.draw_text(label_x * fw, y * fh, "Path Hash:", colors.TEXT_DIM)
    display.draw_text(value_x * fw, y * fh, hash_str, colors.TEXT)
    y = y + 2

    -- RSSI
    local rssi = self.node.rssi or self.node.last_rssi or -999
    local rssi_str = string.format("%.1f dBm", rssi)
    display.draw_text(label_x * fw, y * fh, "RSSI:", colors.TEXT_DIM)
    display.draw_text(value_x * fw, y * fh, rssi_str, colors.TEXT)
    y = y + 2

    -- SNR
    local snr = self.node.snr or self.node.last_snr or 0
    local snr_str = string.format("%.1f dB", snr)
    display.draw_text(label_x * fw, y * fh, "SNR:", colors.TEXT_DIM)
    display.draw_text(value_x * fw, y * fh, snr_str, colors.TEXT)
    y = y + 2

    -- Hop count
    local hops = self.node.hops or self.node.hop_count or 0
    local hops_str = hops == 0 and "Direct" or tostring(hops)
    display.draw_text(label_x * fw, y * fh, "Hops:", colors.TEXT_DIM)
    display.draw_text(value_x * fw, y * fh, hops_str, colors.TEXT)
end

function NodeDetails:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end
    return "continue"
end

return NodeDetails
