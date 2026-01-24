-- Radio Test Screen for T-Deck OS
-- Test LoRa radio module

local RadioTest = {
    title = "Radio Test",
    last_rssi = -999,
    last_snr = 0,
    tx_count = 0,
    rx_count = 0,
    status = "idle"
}

function RadioTest:new()
    local o = {
        title = self.title,
        last_rssi = -999,
        last_snr = 0,
        tx_count = 0,
        rx_count = 0,
        status = "idle"
    }
    setmetatable(o, {__index = RadioTest})
    return o
end

function RadioTest:on_enter()
    self:refresh_status()
end

function RadioTest:refresh_status()
    if tdeck.radio and tdeck.radio.is_initialized then
        if tdeck.radio.is_initialized() then
            self.status = "OK"
            if tdeck.radio.get_last_rssi then
                self.last_rssi = tdeck.radio.get_last_rssi()
            end
            if tdeck.radio.get_last_snr then
                self.last_snr = tdeck.radio.get_last_snr()
            end
        else
            self.status = "NOT INITIALIZED"
        end
    else
        self.status = "NO RADIO API"
    end

    if tdeck.mesh and tdeck.mesh.is_initialized then
        if tdeck.mesh.is_initialized() then
            if tdeck.mesh.get_tx_count then
                self.tx_count = tdeck.mesh.get_tx_count()
            end
            if tdeck.mesh.get_rx_count then
                self.rx_count = tdeck.mesh.get_rx_count()
            end
        end
    end
end

function RadioTest:render(display)
    local colors = display.colors

    -- Refresh each render
    self:refresh_status()

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    local y = 2 * display.font_height
    local x = 2 * display.font_width
    local val_x = 16 * display.font_width

    -- Status
    display.draw_text(x, y, "Status:", colors.TEXT_DIM)
    local status_color = self.status == "OK" and colors.GREEN or colors.RED
    display.draw_text(val_x, y, self.status, status_color)
    y = y + display.font_height * 2

    -- RSSI
    display.draw_text(x, y, "Last RSSI:", colors.TEXT_DIM)
    local rssi_str = string.format("%d dBm", self.last_rssi)
    local rssi_color
    if self.last_rssi > -70 then rssi_color = colors.GREEN
    elseif self.last_rssi > -100 then rssi_color = colors.YELLOW
    else rssi_color = colors.RED
    end
    display.draw_text(val_x, y, rssi_str, rssi_color)
    y = y + display.font_height

    -- SNR
    display.draw_text(x, y, "Last SNR:", colors.TEXT_DIM)
    local snr_str = string.format("%.1f dB", self.last_snr)
    display.draw_text(val_x, y, snr_str, colors.TEXT)
    y = y + display.font_height * 2

    -- Packet counts
    display.draw_text(x, y, "TX Packets:", colors.TEXT_DIM)
    display.draw_text(val_x, y, tostring(self.tx_count), colors.TEXT)
    y = y + display.font_height

    display.draw_text(x, y, "RX Packets:", colors.TEXT_DIM)
    display.draw_text(val_x, y, tostring(self.rx_count), colors.TEXT)
    y = y + display.font_height * 2

    -- Signal strength visualization
    display.draw_text(x, y, "Signal:", colors.TEXT_DIM)
    local bars = 0
    if self.last_rssi > -70 then bars = 4
    elseif self.last_rssi > -85 then bars = 3
    elseif self.last_rssi > -100 then bars = 2
    elseif self.last_rssi > -115 then bars = 1
    end

    local bar_str = string.rep("|", bars) .. string.rep(".", 4 - bars)
    display.draw_text(val_x, y, bar_str, bars >= 3 and colors.GREEN or (bars >= 2 and colors.YELLOW or colors.RED))

    -- Help text
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[R]efresh [Q]Back", colors.TEXT_DIM)
end

function RadioTest:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "r" then
        self:refresh_status()
        tdeck.screen.invalidate()
    end

    return "continue"
end

return RadioTest
