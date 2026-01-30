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
        display.draw_text_centered(6 * fh, "No node data", colors.TEXT_SECONDARY)
        return
    end

    local y = 2
    local label_x = 2
    local value_x = 14

    -- Name
    display.draw_text(label_x * fw, y * fh, "Name:", colors.TEXT_SECONDARY)
    display.draw_text(value_x * fw, y * fh, self.node.name or "Unknown", colors.ACCENT)
    y = y + 2

    -- Path Hash
    local hash_str = string.format("0x%02X", (self.node.path_hash or 0) % 256)
    display.draw_text(label_x * fw, y * fh, "Path Hash:", colors.TEXT_SECONDARY)
    display.draw_text(value_x * fw, y * fh, hash_str, colors.TEXT)
    y = y + 2

    -- RSSI
    local rssi = self.node.rssi or self.node.last_rssi or -999
    local rssi_str = string.format("%.1f dBm", rssi)
    display.draw_text(label_x * fw, y * fh, "RSSI:", colors.TEXT_SECONDARY)
    display.draw_text(value_x * fw, y * fh, rssi_str, colors.TEXT)
    y = y + 2

    -- SNR
    local snr = self.node.snr or self.node.last_snr or 0
    local snr_str = string.format("%.1f dB", snr)
    display.draw_text(label_x * fw, y * fh, "SNR:", colors.TEXT_SECONDARY)
    display.draw_text(value_x * fw, y * fh, snr_str, colors.TEXT)
    y = y + 2

    -- Hop count
    local hops = self.node.hops or self.node.hop_count or 0
    local hops_str = hops == 0 and "Direct" or tostring(hops)
    display.draw_text(label_x * fw, y * fh, "Hops:", colors.TEXT_SECONDARY)
    display.draw_text(value_x * fw, y * fh, hops_str, colors.TEXT)
end

function NodeDetails:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "m" then
        self:send_message()
    end
    return "continue"
end

function NodeDetails:send_message()
    if not self.node or not self.node.pub_key_hex then
        if _G.MessageBox then
            _G.MessageBox.show({title = "Cannot message", subtitle = "No public key for node"})
        end
        return
    end

    local pub_key_hex = self.node.pub_key_hex
    local name = self.node.name

    load_module_async("/scripts/ui/screens/dm_conversation.lua", function(DMConversation, err)
        if DMConversation then
            ScreenManager.push(DMConversation:new(pub_key_hex, name))
        end
    end)
end

-- Menu items for app menu integration
function NodeDetails:get_menu_items()
    local self_ref = self
    local items = {}

    if self.node and self.node.pub_key_hex then
        table.insert(items, {
            label = "Send Message",
            action = function()
                self_ref:send_message()
            end
        })
    end

    -- Add to contacts option if not already saved
    if self.node and self.node.pub_key_hex then
        local is_saved = _G.Contacts and _G.Contacts.is_saved(self.node.pub_key_hex)
        if not is_saved then
            table.insert(items, {
                label = "Add to Contacts",
                action = function()
                    if _G.Contacts and _G.Contacts.add then
                        local ok = _G.Contacts.add(self_ref.node)
                        if ok and _G.MessageBox then
                            _G.MessageBox.show({title = "Contact added"})
                        end
                    end
                end
            })
        end
    end

    return items
end

return NodeDetails
