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
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    if not self.node then
        display.draw_text_centered(6 * display.font_height, "No node data", colors.TEXT_DIM)
        return
    end

    local y = 2
    local label_x = 2
    local value_x = 14

    -- Name
    display.draw_text(label_x * display.font_width, y * display.font_height, "Name:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, y * display.font_height,
                     self.node.name or "Unknown", colors.CYAN)
    y = y + 2

    -- Path Hash
    local hash_str = string.format("0x%02X", (self.node.path_hash or 0) % 256)
    display.draw_text(label_x * display.font_width, y * display.font_height, "Path Hash:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, y * display.font_height, hash_str, colors.TEXT)
    y = y + 2

    -- RSSI
    local rssi = self.node.rssi or self.node.last_rssi or -999
    local rssi_str = string.format("%.1f dBm", rssi)
    display.draw_text(label_x * display.font_width, y * display.font_height, "RSSI:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, y * display.font_height, rssi_str, colors.TEXT)
    y = y + 2

    -- SNR
    local snr = self.node.snr or self.node.last_snr or 0
    local snr_str = string.format("%.1f dB", snr)
    display.draw_text(label_x * display.font_width, y * display.font_height, "SNR:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, y * display.font_height, snr_str, colors.TEXT)
    y = y + 2

    -- Hop count
    local hops = self.node.hops or self.node.hop_count or 0
    local hops_str = hops == 0 and "Direct" or tostring(hops)
    display.draw_text(label_x * display.font_width, y * display.font_height, "Hops:", colors.TEXT_DIM)
    display.draw_text(value_x * display.font_width, y * display.font_height, hops_str, colors.TEXT)

    -- Help bar
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[Q]Back", colors.TEXT_DIM)
end

function NodeDetails:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end
    return "continue"
end

return NodeDetails
