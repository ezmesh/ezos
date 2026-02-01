-- WiFi Test Screen for T-Deck OS
-- Scan, connect, and view WiFi status

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local WiFiTest = {
    title = "WiFi Test",
    VISIBLE_ROWS = 5,
    ROW_HEIGHT = 32,
}

function WiFiTest:new()
    local o = {
        title = self.title,
        mode = "status",  -- "status", "networks", "connecting"
        networks = {},
        selected = 1,
        scroll_offset = 0,
        status = "unknown",
        ssid = "",
        ip = "",
        rssi = 0,
        gateway = "",
        mac = "",
        scan_time = 0,
        connect_start = 0,
        saved_ssid = "",
        saved_password = "",
    }
    setmetatable(o, {__index = WiFiTest})
    return o
end

function WiFiTest:on_enter()
    -- Load saved credentials
    self.saved_ssid = ez.storage.get_pref("wifi_ssid", "")
    self.saved_password = ez.storage.get_pref("wifi_password", "")
    self:refresh()
end

function WiFiTest:refresh()
    if not ez.wifi then return end

    self.status = ez.wifi.get_status()
    self.ssid = ez.wifi.get_ssid()
    self.ip = ez.wifi.get_ip()
    self.rssi = ez.wifi.get_rssi()
    self.gateway = ez.wifi.get_gateway()
    self.mac = ez.wifi.get_mac()
end

function WiFiTest:scan()
    if not ez.wifi then return end

    self.mode = "networks"
    self.networks = {}
    self.selected = 1
    self.scroll_offset = 0

    -- Perform scan
    local results = ez.wifi.scan()
    if results then
        self.networks = results
        self.scan_time = os.time()
    end
end

function WiFiTest:connect_to_network(ssid, password)
    if not ez.wifi then return end

    self.mode = "connecting"
    self.connect_start = os.time()
    ez.wifi.connect(ssid, password)
end

function WiFiTest:get_signal_bars(rssi)
    if rssi >= -50 then return 4
    elseif rssi >= -60 then return 3
    elseif rssi >= -70 then return 2
    elseif rssi >= -80 then return 1
    else return 0 end
end

function WiFiTest:render(display)
    local colors = ListMixin.get_colors(display)

    -- Refresh status
    self:refresh()

    -- Check if connecting finished
    if self.mode == "connecting" then
        if self.status == "connected" then
            self.mode = "status"
        elseif os.time() - self.connect_start > 15 then
            -- Timeout
            self.mode = "status"
        end
    end

    -- Background
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    display.set_font_size("small")
    local fh = display.get_font_height()
    local y = fh + 8
    local col1 = 8
    local col2 = 100

    if self.mode == "status" then
        self:render_status(display, colors, y, fh, col1, col2)
    elseif self.mode == "networks" then
        self:render_networks(display, colors, y, fh)
    elseif self.mode == "connecting" then
        self:render_connecting(display, colors, y, fh, col1)
    end

    -- Help text at bottom
    local help = ""
    if self.mode == "status" then
        help = "S:Scan  C:Connect  D:Disconnect  ESC:Back"
    elseif self.mode == "networks" then
        help = "ENTER:Select  ESC:Back"
    elseif self.mode == "connecting" then
        help = "Connecting..."
    end
    display.draw_text(col1, display.height - fh - 4, help, colors.TEXT_MUTED)
end

function WiFiTest:render_status(display, colors, y, fh, col1, col2)
    -- Status
    local status_color = colors.TEXT_MUTED
    if self.status == "connected" then
        status_color = colors.SUCCESS
    elseif self.status == "connecting" then
        status_color = colors.WARNING
    elseif self.status == "connection_failed" or self.status == "network_not_found" then
        status_color = colors.ERROR
    end

    display.draw_text(col1, y, "Status:", colors.TEXT_SECONDARY)
    display.draw_text(col2, y, self.status, status_color)
    y = y + fh + 2

    -- MAC address
    display.draw_text(col1, y, "MAC:", colors.TEXT_SECONDARY)
    display.draw_text(col2, y, self.mac, colors.TEXT_MUTED)
    y = y + fh + 4

    if self.status == "connected" then
        -- Connected info
        display.draw_text(col1, y, "-- Connection --", colors.ACCENT)
        y = y + fh + 2

        display.draw_text(col1, y, "SSID:", colors.TEXT_SECONDARY)
        display.draw_text(col2, y, self.ssid, colors.WHITE)
        y = y + fh + 2

        display.draw_text(col1, y, "IP:", colors.TEXT_SECONDARY)
        display.draw_text(col2, y, self.ip, colors.WHITE)
        y = y + fh + 2

        display.draw_text(col1, y, "Gateway:", colors.TEXT_SECONDARY)
        display.draw_text(col2, y, self.gateway, colors.WHITE)
        y = y + fh + 2

        -- Signal strength with bars
        local bars = self:get_signal_bars(self.rssi)
        local signal_color = bars >= 3 and colors.SUCCESS or (bars >= 2 and colors.WARNING or colors.ERROR)
        display.draw_text(col1, y, "Signal:", colors.TEXT_SECONDARY)
        display.draw_text(col2, y, string.format("%d dBm (%d/4)", self.rssi, bars), signal_color)
        y = y + fh + 4
    else
        -- Not connected - show saved network if any
        if self.saved_ssid ~= "" then
            display.draw_text(col1, y, "-- Saved Network --", colors.ACCENT)
            y = y + fh + 2

            display.draw_text(col1, y, "SSID:", colors.TEXT_SECONDARY)
            display.draw_text(col2, y, self.saved_ssid, colors.WHITE)
            y = y + fh + 2

            display.draw_text(col1, y, "Press C to connect", colors.TEXT_MUTED)
            y = y + fh + 4
        else
            display.draw_text(col1, y, "Not connected", colors.TEXT_MUTED)
            y = y + fh + 2
            display.draw_text(col1, y, "Press S to scan for networks", colors.TEXT_MUTED)
            y = y + fh + 4
        end
    end
end

function WiFiTest:render_networks(display, colors, y, fh)
    local col1 = 8
    local w = display.width

    display.draw_text(col1, y, string.format("Found %d networks:", #self.networks), colors.ACCENT)
    y = y + fh + 4

    local list_start_y = y

    for i = 0, self.VISIBLE_ROWS - 1 do
        local idx = self.scroll_offset + i + 1
        if idx > #self.networks then break end

        local net = self.networks[idx]
        local row_y = list_start_y + i * self.ROW_HEIGHT
        local is_selected = (idx == self.selected)

        -- Selection highlight
        if is_selected then
            display.fill_rect(0, row_y, w, self.ROW_HEIGHT, colors.SELECTED_BG)
        end

        -- Network name
        local ssid_display = net.ssid
        if ssid_display == "" then ssid_display = "(hidden)" end

        local text_color = is_selected and colors.WHITE or colors.TEXT_PRIMARY
        display.draw_text(col1, row_y + 4, ssid_display, text_color)

        -- Security icon and signal
        local secure_text = net.secure and "[*]" or "[ ]"
        local bars = self:get_signal_bars(net.rssi)
        local signal_color = bars >= 3 and colors.SUCCESS or (bars >= 2 and colors.WARNING or colors.ERROR)

        local info_text = string.format("%s %ddBm ch%d", secure_text, net.rssi, net.channel)
        display.draw_text(w - 130, row_y + 4, info_text, is_selected and colors.WHITE or signal_color)
    end

    -- Scrollbar if needed
    if #self.networks > self.VISIBLE_ROWS then
        ListMixin.draw_scrollbar(display, {
            total = #self.networks,
            visible = self.VISIBLE_ROWS,
            offset = self.scroll_offset,
            y = list_start_y,
            height = self.VISIBLE_ROWS * self.ROW_HEIGHT
        }, colors)
    end
end

function WiFiTest:render_connecting(display, colors, y, fh, col1)
    display.draw_text(col1, y, "Connecting...", colors.WARNING)
    y = y + fh + 4

    local elapsed = os.time() - self.connect_start
    display.draw_text(col1, y, string.format("Elapsed: %d seconds", elapsed), colors.TEXT_MUTED)
    y = y + fh + 2

    -- Simple animation
    local dots = string.rep(".", (elapsed % 4) + 1)
    display.draw_text(col1, y, dots, colors.ACCENT)
end

function WiFiTest:adjust_scroll()
    -- Keep selected item visible
    if self.selected <= self.scroll_offset then
        self.scroll_offset = self.selected - 1
    elseif self.selected > self.scroll_offset + self.VISIBLE_ROWS then
        self.scroll_offset = self.selected - self.VISIBLE_ROWS
    end

    self.scroll_offset = math.max(0, self.scroll_offset)
    self.scroll_offset = math.min(math.max(0, #self.networks - self.VISIBLE_ROWS), self.scroll_offset)
end

function WiFiTest:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        if self.mode == "networks" then
            self.mode = "status"
            return "handled"
        end
        return "pop"
    end

    if self.mode == "status" then
        -- Scan for networks
        if key.character == "s" or key.character == "S" then
            self:scan()
            ScreenManager.invalidate()
            return "handled"
        end

        -- Connect to saved network
        if key.character == "c" or key.character == "C" then
            if self.saved_ssid ~= "" then
                self:connect_to_network(self.saved_ssid, self.saved_password)
                ScreenManager.invalidate()
            else
                -- No saved network, go to scan
                self:scan()
                ScreenManager.invalidate()
            end
            return "handled"
        end

        -- Disconnect
        if key.character == "d" or key.character == "D" then
            if ez.wifi then
                ez.wifi.disconnect()
            end
            ScreenManager.invalidate()
            return "handled"
        end

    elseif self.mode == "networks" then
        -- Navigation
        if key.special == "UP" then
            if self.selected > 1 then
                self.selected = self.selected - 1
                self:adjust_scroll()
                ScreenManager.invalidate()
            end
            return "handled"
        end

        if key.special == "DOWN" then
            if self.selected < #self.networks then
                self.selected = self.selected + 1
                self:adjust_scroll()
                ScreenManager.invalidate()
            end
            return "handled"
        end

        -- Select network - prompt for password
        if key.special == "ENTER" then
            local net = self.networks[self.selected]
            if net then
                -- For now, use saved password if SSID matches, otherwise empty
                local password = ""
                if net.ssid == self.saved_ssid then
                    password = self.saved_password
                end

                -- TODO: Could spawn a password input screen here
                -- For now, connect with empty or saved password
                self:connect_to_network(net.ssid, password)
                ScreenManager.invalidate()
            end
            return "handled"
        end
    end

    return "handled"
end

return WiFiTest
