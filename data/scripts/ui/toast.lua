-- Toast - Temporary notification overlay
-- Shows a message at the bottom of the screen that auto-dismisses

local Toast = {
    active = false,
    message = "",
    timer_id = nil,
}

-- Show a toast message
-- @param message Text to display
-- @param duration Time in ms before auto-dismiss (default 2000)
function Toast.show(message, duration)
    duration = duration or 2000
    Toast.message = message or ""
    Toast.active = true

    -- Cancel existing timer
    if Toast.timer_id then
        clear_timeout(Toast.timer_id)
    end

    -- Auto-hide after duration
    Toast.timer_id = set_timeout(function()
        Toast.hide()
    end, duration)

    if _G.Overlays then
        _G.Overlays.enable("toast")
    end
    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end
end

-- Hide the toast
function Toast.hide()
    Toast.active = false
    if Toast.timer_id then
        clear_timeout(Toast.timer_id)
        Toast.timer_id = nil
    end
    if _G.Overlays then
        _G.Overlays.disable("toast")
    end
    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end
end

function Toast.render(display)
    if not Toast.active or not Toast.message or #Toast.message == 0 then
        return
    end

    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    display.set_font_size("small")
    local text_w = display.text_width(Toast.message)
    local fh = display.get_font_height()

    -- Toast dimensions
    local padding = 8
    local toast_w = text_w + padding * 2
    local toast_h = fh + padding
    local toast_x = math.floor((w - toast_w) / 2)
    local toast_y = h - toast_h - 20  -- 20px from bottom

    -- Background
    display.fill_rect(toast_x, toast_y, toast_w, toast_h, colors.SURFACE_ALT or 0x2104)
    display.draw_rect(toast_x, toast_y, toast_w, toast_h, colors.ACCENT)

    -- Text centered
    local text_x = toast_x + padding
    local text_y = toast_y + math.floor(padding / 2)
    display.draw_text(text_x, text_y, Toast.message, colors.TEXT)
end

function Toast.init()
    if _G.Overlays then
        -- Register at high z-order (above most things, but below messagebox)
        _G.Overlays.register("toast", Toast.render, 250)
        _G.Overlays.disable("toast")
    end
end

return Toast
