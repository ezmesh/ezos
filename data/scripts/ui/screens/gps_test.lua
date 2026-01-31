-- GPS Test Screen for T-Deck OS
-- Displays GPS status, satellites, location, and time

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local GPSTest = {
    title = "GPS Test",
}

function GPSTest:new()
    local o = {
        title = self.title,
        initialized = false,
        has_fix = false,
        satellites = 0,
        hdop = 99.9,
        latitude = 0,
        longitude = 0,
        altitude = 0,
        speed = 0,
        course = 0,
        gps_time = nil,
        time_synced = false,
        chars_processed = 0,
        sentences = 0,
        failed_checksums = 0,
        last_update = 0,
    }
    setmetatable(o, {__index = GPSTest})
    return o
end

function GPSTest:on_enter()
    -- Initialize GPS if not already done
    if ez.gps and ez.gps.init then
        ez.gps.init()
    end
    self:refresh()
end

function GPSTest:refresh()
    if not ez.gps then
        self.initialized = false
        return
    end

    -- Get stats
    local stats = ez.gps.get_stats()
    if stats then
        self.initialized = stats.initialized
        self.chars_processed = stats.chars or 0
        self.sentences = stats.sentences or 0
        self.failed_checksums = stats.failed or 0
    end

    -- Get satellite info
    local sat = ez.gps.get_satellites()
    if sat then
        self.satellites = sat.count or 0
        self.hdop = sat.hdop or 99.9
    end

    -- Get location
    local loc = ez.gps.get_location()
    if loc then
        self.has_fix = loc.valid or false
        self.latitude = loc.lat or 0
        self.longitude = loc.lon or 0
        self.altitude = loc.alt or 0
    end

    -- Get movement
    local mov = ez.gps.get_movement()
    if mov then
        self.speed = mov.speed or 0
        self.course = mov.course or 0
    end

    -- Get time
    local t = ez.gps.get_time()
    if t then
        self.gps_time = t
        self.time_synced = t.synced or false
    end

    self.last_update = os.time()
end

function GPSTest:render(display)
    local colors = ListMixin.get_colors(display)

    -- Refresh data each render
    self:refresh()

    -- Background
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    display.set_font_size("small")
    local fh = display.get_font_height()
    local y = fh + 8
    local col1 = 8
    local col2 = 110

    -- Status section
    local status_color = self.initialized and colors.SUCCESS or colors.ERROR
    local status_text = self.initialized and "Initialized" or "Not initialized"
    display.draw_text(col1, y, "Status:", colors.TEXT_SECONDARY)
    display.draw_text(col2, y, status_text, status_color)
    y = y + fh + 2

    -- Fix status
    local fix_color = self.has_fix and colors.SUCCESS or colors.WARNING
    local fix_text = self.has_fix and "Valid Fix" or "No Fix"
    display.draw_text(col1, y, "Fix:", colors.TEXT_SECONDARY)
    display.draw_text(col2, y, fix_text, fix_color)
    y = y + fh + 2

    -- Satellites
    local sat_color = self.satellites >= 4 and colors.SUCCESS or (self.satellites > 0 and colors.WARNING or colors.TEXT_MUTED)
    display.draw_text(col1, y, "Satellites:", colors.TEXT_SECONDARY)
    display.draw_text(col2, y, string.format("%d  HDOP: %.1f", self.satellites, self.hdop), sat_color)
    y = y + fh + 4

    -- Location section
    display.draw_text(col1, y, "-- Location --", colors.ACCENT)
    y = y + fh + 2

    if self.has_fix then
        display.draw_text(col1, y, "Lat:", colors.TEXT_SECONDARY)
        display.draw_text(col2, y, string.format("%.6f", self.latitude), colors.WHITE)
        y = y + fh + 2

        display.draw_text(col1, y, "Lon:", colors.TEXT_SECONDARY)
        display.draw_text(col2, y, string.format("%.6f", self.longitude), colors.WHITE)
        y = y + fh + 2

        display.draw_text(col1, y, "Alt:", colors.TEXT_SECONDARY)
        display.draw_text(col2, y, string.format("%.1f m", self.altitude), colors.WHITE)
        y = y + fh + 2

        display.draw_text(col1, y, "Speed:", colors.TEXT_SECONDARY)
        display.draw_text(col2, y, string.format("%.1f km/h", self.speed), colors.WHITE)
        y = y + fh + 2
    else
        display.draw_text(col1, y, "Waiting for fix...", colors.TEXT_MUTED)
        y = y + fh + 2
    end
    y = y + 2

    -- Time section
    display.draw_text(col1, y, "-- GPS Time (UTC) --", colors.ACCENT)
    y = y + fh + 2

    if self.gps_time and self.gps_time.valid then
        local time_str = string.format("%04d-%02d-%02d %02d:%02d:%02d",
            self.gps_time.year, self.gps_time.month, self.gps_time.day,
            self.gps_time.hour, self.gps_time.min, self.gps_time.sec)
        display.draw_text(col1, y, time_str, colors.WHITE)
        y = y + fh + 2

        local sync_color = self.time_synced and colors.SUCCESS or colors.TEXT_MUTED
        local sync_text = self.time_synced and "System synced" or "Not synced"
        display.draw_text(col1, y, sync_text, sync_color)
        y = y + fh + 2
    else
        display.draw_text(col1, y, "Waiting for time...", colors.TEXT_MUTED)
        y = y + fh + 2
    end
    y = y + 2

    -- Debug stats
    display.draw_text(col1, y, "-- Debug --", colors.ACCENT)
    y = y + fh + 2

    display.draw_text(col1, y, string.format("Chars: %d  Sentences: %d  Errors: %d",
        self.chars_processed, self.sentences, self.failed_checksums), colors.TEXT_MUTED)

    -- Help text at bottom
    display.draw_text(col1, display.height - fh - 4, "ESC: Back  S: Sync time", colors.TEXT_MUTED)
end

function GPSTest:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    -- Manual time sync
    if key.character == "s" or key.character == "S" then
        if ez.gps and ez.gps.sync_time then
            local success = ez.gps.sync_time()
            if success then
                ez.system.log("[GPS] Time synced manually")
            else
                ez.system.log("[GPS] Time sync failed (no valid time)")
            end
        end
        ScreenManager.invalidate()
    end

    return "handled"
end

return GPSTest
