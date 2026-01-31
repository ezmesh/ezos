-- Storage Info Screen for T-Deck OS
-- Shows disk space for LittleFS, SD card, and firmware

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local StorageInfo = {
    title = "Storage",
}

-- Format bytes to human-readable string
local function format_bytes(bytes)
    if bytes >= 1024 * 1024 * 1024 then
        return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
    elseif bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%d B", bytes)
    end
end

-- Draw a horizontal progress bar
local function draw_bar(display, x, y, width, height, percent, colors)
    -- Background
    display.fill_rect(x, y, width, height, colors.SURFACE)

    -- Fill based on percentage (color changes based on usage)
    local fill_width = math.floor(width * percent / 100)
    local fill_color = colors.SUCCESS
    if percent > 80 then
        fill_color = colors.ERROR
    elseif percent > 60 then
        fill_color = colors.WARNING
    end
    if fill_width > 0 then
        display.fill_rect(x, y, fill_width, height, fill_color)
    end

    -- Border
    display.draw_rect(x, y, width, height, colors.TEXT_SECONDARY)
end

function StorageInfo:new()
    local o = {
        title = self.title,
        flash_info = nil,
        sd_info = nil,
        firmware_info = nil,
    }
    setmetatable(o, {__index = StorageInfo})
    return o
end

function StorageInfo:on_enter()
    self:refresh_info()
end

function StorageInfo:refresh_info()
    -- Get LittleFS info
    if ez.storage and ez.storage.get_flash_info then
        self.flash_info = ez.storage.get_flash_info()
    end

    -- Get SD card info
    if ez.storage and ez.storage.get_sd_info then
        self.sd_info = ez.storage.get_sd_info()
    end

    -- Get firmware info
    if ez.system and ez.system.get_firmware_info then
        self.firmware_info = ez.system.get_firmware_info()
    end

    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end
end

function StorageInfo:render(display)
    local colors = ListMixin.get_colors(display)

    -- Background
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    display.set_font_size("small")
    local fh = display.get_font_height()
    local y = 28
    local bar_width = display.width - 40
    local bar_height = 8
    local section_gap = 8
    local used_fmt = "%s / %s (%d%%)"

    -- Flash Storage (LittleFS)
    display.draw_text(8, y, "Flash (LittleFS)", colors.TEXT)
    y = y + fh + 2

    if self.flash_info then
        local used = self.flash_info.used_bytes or 0
        local total = self.flash_info.total_bytes or 1
        local free = self.flash_info.free_bytes or 0
        local percent = math.floor((used / total) * 100)

        draw_bar(display, 8, y, bar_width, bar_height, percent, colors)
        y = y + bar_height + 2

        local info = string.format(used_fmt, format_bytes(used), format_bytes(total), percent)
        display.draw_text(8, y, info, colors.TEXT_SECONDARY)
        y = y + fh
        display.draw_text(8, y, string.format("%s free", format_bytes(free)), colors.TEXT_MUTED)
    else
        display.draw_text(8, y, "Not available", colors.TEXT_MUTED)
    end
    y = y + fh + section_gap

    -- SD Card
    display.draw_text(8, y, "SD Card", colors.TEXT)
    y = y + fh + 2

    if self.sd_info then
        local used = self.sd_info.used_bytes or 0
        local total = self.sd_info.total_bytes or 1
        local free = self.sd_info.free_bytes or 0
        local percent = math.floor((used / total) * 100)

        draw_bar(display, 8, y, bar_width, bar_height, percent, colors)
        y = y + bar_height + 2

        local info = string.format(used_fmt, format_bytes(used), format_bytes(total), percent)
        display.draw_text(8, y, info, colors.TEXT_SECONDARY)
        y = y + fh
        display.draw_text(8, y, string.format("%s free", format_bytes(free)), colors.TEXT_MUTED)
    else
        display.draw_text(8, y, "Not available", colors.TEXT_MUTED)
    end
    y = y + fh + section_gap

    -- Firmware
    display.draw_text(8, y, "Firmware", colors.TEXT)
    y = y + fh + 2

    if self.firmware_info then
        local app_size = self.firmware_info.app_size or 0
        local partition_size = self.firmware_info.partition_size or 1
        local free = self.firmware_info.free_bytes or 0
        local percent = math.floor((app_size / partition_size) * 100)

        draw_bar(display, 8, y, bar_width, bar_height, percent, colors)
        y = y + bar_height + 2

        local info = string.format("%s / %s partition (%d%%)", format_bytes(app_size), format_bytes(partition_size), percent)
        display.draw_text(8, y, info, colors.TEXT_SECONDARY)
        y = y + fh

        local label = self.firmware_info.partition_label or "app"
        local flash_size = self.firmware_info.flash_chip_size or 0
        display.draw_text(8, y, string.format("Partition: %s, Flash chip: %s", label, format_bytes(flash_size)), colors.TEXT_MUTED)
    else
        display.draw_text(8, y, "Not available", colors.TEXT_MUTED)
    end

    display.set_font_size("medium")
end

function StorageInfo:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "r" or key.special == "ENTER" then
        self:refresh_info()
    end
    return "continue"
end

function StorageInfo:get_menu_items()
    local self_ref = self
    return {
        {label = "Refresh", action = function() self_ref:refresh_info() end},
    }
end

return StorageInfo
