-- USB File Transfer Screen
-- Allows editing scripts on SD card via USB Mass Storage

local USBTransfer = {
    title = "USB Transfer",
    msc_active = false,
    sd_available = false
}

function USBTransfer:new()
    local o = {
        title = self.title,
        msc_active = false,
        sd_available = tdeck.system.is_sd_available()
    }
    setmetatable(o, {__index = USBTransfer})
    return o
end

function USBTransfer:on_enter()
    self.sd_available = tdeck.system.is_sd_available()
    self.msc_active = tdeck.system.is_usb_msc_active()
end

function USBTransfer:render(display)
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

    local y = 2 * fh

    if not self.sd_available then
        display.draw_text_centered(y, "No SD Card Detected", colors.ORANGE)
        y = y + 2 * fh
        display.draw_text_centered(y, "Insert SD card and", colors.TEXT)
        y = y + fh
        display.draw_text_centered(y, "press [R] to retry", colors.TEXT)
    elseif self.msc_active then
        display.draw_text_centered(y, "USB Drive Mode Active", colors.GREEN)
        y = y + 2 * fh
        display.draw_text_centered(y, "SD card is accessible", colors.TEXT)
        y = y + fh
        display.draw_text_centered(y, "from your computer", colors.TEXT)
        y = y + 2 * fh
        display.draw_text_centered(y, "Edit files in /scripts/", colors.CYAN)
        y = y + 2 * fh
        display.draw_text_centered(y, "[S] Stop & Restart", colors.TEXT_DIM)
    else
        display.draw_text_centered(y, "SD Card Ready", colors.GREEN)
        y = y + 2 * fh
        display.draw_text_centered(y, "Press [Enter] to start", colors.TEXT)
        y = y + fh
        display.draw_text_centered(y, "USB drive mode", colors.TEXT)
        y = y + 2 * fh
        display.draw_text_centered(y, "Your computer will see", colors.TEXT_DIM)
        y = y + fh
        display.draw_text_centered(y, "the SD card as a drive", colors.TEXT_DIM)
    end
end

function USBTransfer:handle_key(key)
    if key.special == "ESCAPE" then
        if self.msc_active then
            -- Don't allow exit while MSC is active
            return "continue"
        end
        return "pop"

    elseif key.special == "ENTER" then
        if self.sd_available and not self.msc_active then
            -- Start MSC mode
            if tdeck.system.start_usb_msc() then
                self.msc_active = true
                ScreenManager.invalidate()
            end
        end

    elseif key.character == "s" or key.character == "S" then
        if self.msc_active then
            -- Stop MSC and restart to reload scripts
            tdeck.system.stop_usb_msc()
            tdeck.system.delay(500)
            tdeck.system.restart()
        end

    elseif key.character == "r" or key.character == "R" then
        -- Retry SD card detection
        self.sd_available = tdeck.system.is_sd_available()
        ScreenManager.invalidate()
    end

    return "continue"
end

return USBTransfer
