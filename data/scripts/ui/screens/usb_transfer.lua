-- USB File Transfer Screen
-- Allows editing scripts on SD card via USB Mass Storage

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local USBTransfer = {
    title = "USB Transfer",
    msc_active = false,
    sd_available = false
}

function USBTransfer:new()
    local o = {
        title = self.title,
        msc_active = false,
        sd_available = ez.system.is_sd_available()
    }
    setmetatable(o, {__index = USBTransfer})
    return o
end

function USBTransfer:on_enter()
    self.sd_available = ez.system.is_sd_available()
    self.msc_active = ez.system.is_usb_msc_active()
end

function USBTransfer:render(display)
    local colors = ListMixin.get_colors(display)

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    local y = 2 * fh

    if not self.sd_available then
        display.draw_text_centered(y, "No SD Card Detected", colors.WARNING)
        y = y + 2 * fh
        display.draw_text_centered(y, "Insert SD card and", colors.TEXT)
        y = y + fh
        display.draw_text_centered(y, "press [R] to retry", colors.TEXT)
    elseif self.msc_active then
        display.draw_text_centered(y, "USB Drive Mode Active", colors.SUCCESS)
        y = y + 2 * fh
        display.draw_text_centered(y, "SD card is accessible", colors.TEXT)
        y = y + fh
        display.draw_text_centered(y, "from your computer", colors.TEXT)
        y = y + 2 * fh
        display.draw_text_centered(y, "Edit files in /scripts/", colors.ACCENT)
        y = y + 2 * fh
        display.draw_text_centered(y, "[S] Stop & Restart", colors.TEXT_SECONDARY)
    else
        display.draw_text_centered(y, "SD Card Ready", colors.SUCCESS)
        y = y + 2 * fh
        display.draw_text_centered(y, "Press [Enter] to start", colors.TEXT)
        y = y + fh
        display.draw_text_centered(y, "USB drive mode", colors.TEXT)
        y = y + 2 * fh
        display.draw_text_centered(y, "Your computer will see", colors.TEXT_SECONDARY)
        y = y + fh
        display.draw_text_centered(y, "the SD card as a drive", colors.TEXT_SECONDARY)
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
            if ez.system.start_usb_msc() then
                self.msc_active = true
                ScreenManager.invalidate()
            end
        end

    elseif key.character == "s" or key.character == "S" then
        if self.msc_active then
            -- Stop MSC and restart to reload scripts
            ez.system.stop_usb_msc()
            ez.system.delay(500)
            ez.system.restart()
        end

    elseif key.character == "r" or key.character == "R" then
        -- Retry SD card detection
        self.sd_available = ez.system.is_sd_available()
        ScreenManager.invalidate()
    end

    return "continue"
end

return USBTransfer
