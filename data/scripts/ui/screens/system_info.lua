-- System Info Screen for T-Deck OS
-- Display system information

local SystemInfo = {
    title = "System Info"
}

function SystemInfo:new()
    local o = {
        title = self.title
    }
    setmetatable(o, {__index = SystemInfo})
    return o
end

function SystemInfo:render(display)
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    local y = 2 * display.font_height
    local x = 2 * display.font_width

    -- Chip model
    local chip = tdeck.system.chip_model and tdeck.system.chip_model() or "ESP32-S3"
    display.draw_text(x, y, "Chip: " .. chip, colors.TEXT)
    y = y + display.font_height

    -- CPU frequency
    local cpu_freq = tdeck.system.cpu_freq and tdeck.system.cpu_freq() or 240
    display.draw_text(x, y, string.format("CPU: %d MHz", cpu_freq), colors.TEXT)
    y = y + display.font_height

    -- Heap memory
    local heap = math.floor(tdeck.system.get_free_heap() / 1024)
    local total_heap = tdeck.system.get_total_heap and math.floor(tdeck.system.get_total_heap() / 1024) or 0
    if total_heap > 0 then
        display.draw_text(x, y, string.format("Heap: %d / %d KB", heap, total_heap), colors.TEXT)
    else
        display.draw_text(x, y, string.format("Heap: %d KB free", heap), colors.TEXT)
    end
    y = y + display.font_height

    -- PSRAM
    local psram = math.floor(tdeck.system.get_free_psram() / 1024)
    local total_psram = tdeck.system.get_total_psram and math.floor(tdeck.system.get_total_psram() / 1024) or 0
    if total_psram > 0 then
        display.draw_text(x, y, string.format("PSRAM: %d / %d KB", psram, total_psram), colors.TEXT)
    else
        display.draw_text(x, y, string.format("PSRAM: %d KB free", psram), colors.TEXT)
    end
    y = y + display.font_height

    -- Uptime
    local uptime = tdeck.system.uptime and tdeck.system.uptime() or math.floor(tdeck.system.millis() / 1000)
    display.draw_text(x, y, string.format("Uptime: %d seconds", uptime), colors.TEXT)
    y = y + display.font_height

    -- Battery
    local battery = tdeck.system.get_battery_percent()
    local batt_color = battery > 20 and colors.GREEN or colors.RED
    display.draw_text(x, y, string.format("Battery: %d%%", battery), batt_color)
    y = y + display.font_height

    -- Display info
    display.draw_text(x, y, string.format("Display: %dx%d chars", display.cols, display.rows), colors.TEXT)
    y = y + display.font_height

    display.draw_text(x, y, string.format("Resolution: %dx%d", display.width, display.height), colors.TEXT)

    -- Help text
    display.draw_text(x, (display.rows - 2) * display.font_height,
                    "Press ESC or Q to go back", colors.TEXT_DIM)
end

function SystemInfo:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end
    -- Refresh on any key
    tdeck.screen.invalidate()
    return "continue"
end

return SystemInfo
