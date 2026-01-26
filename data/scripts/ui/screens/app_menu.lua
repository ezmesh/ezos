-- App Menu Overlay
-- Quick access menu activated by both shift keys
-- Horizontally scrollable action bar at bottom of screen

local AppMenu = {
    items = {},
    selected = 1,
    scroll_offset = 0,
    active = false,
}

function AppMenu.init()
    -- Register as overlay with high z-order (above status bar)
    if _G.Overlays then
        _G.Overlays.register("app_menu", AppMenu.render, 200, AppMenu.handle_key)
        _G.Overlays.disable("app_menu")
    end
end

function AppMenu.show()
    if AppMenu.active then return end

    -- Build menu items from current screen
    AppMenu.items = {}
    AppMenu.selected = 1
    AppMenu.scroll_offset = 0

    -- Get items from current screen
    local current = _G.ScreenManager and _G.ScreenManager.peek()
    if current and current.get_menu_items then
        local ok, screen_items = pcall(function() return current:get_menu_items() end)
        if ok and screen_items then
            for _, item in ipairs(screen_items) do
                table.insert(AppMenu.items, item)
            end
        end
    end

    -- Add Home action if we're deeper than main menu
    local depth = _G.ScreenManager and _G.ScreenManager.depth() or 0
    if depth > 1 then
        table.insert(AppMenu.items, {label = "Home", action = function()
            while _G.ScreenManager and _G.ScreenManager.depth() > 1 do
                _G.ScreenManager.pop()
            end
        end})
    end

    -- Disable status bar while menu is active
    if _G.StatusBar then
        _G.StatusBar.disable()
    end

    AppMenu.active = true
    if _G.Overlays then
        _G.Overlays.enable("app_menu")
    end
    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end
end

function AppMenu.hide()
    if not AppMenu.active then return end

    AppMenu.active = false

    -- Unregister overlay completely to free memory
    if _G.Overlays then
        _G.Overlays.unregister("app_menu")
    end

    -- Clear items to free memory
    AppMenu.items = {}

    -- Re-enable status bar
    if _G.StatusBar then
        _G.StatusBar.enable()
    end

    -- Nil out global so it can be garbage collected
    _G.AppMenu = nil
    collectgarbage("collect")

    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end
end

function AppMenu.toggle()
    if AppMenu.active then
        AppMenu.hide()
    else
        AppMenu.show()
    end
end

function AppMenu.is_active()
    return AppMenu.active
end

function AppMenu.calculate_item_positions(display)
    local positions = {}
    local x = 12
    local item_spacing = 16

    for i, item in ipairs(AppMenu.items) do
        local tw = display.text_width(item.label)
        positions[i] = {x = x, width = tw}
        x = x + tw + item_spacing
    end

    positions.total_width = x
    return positions
end

function AppMenu.adjust_scroll(display)
    local positions = AppMenu.calculate_item_positions(display)
    if #positions == 0 then return end

    local sel_pos = positions[AppMenu.selected]
    if not sel_pos then return end

    local visible_width = display.width - 24
    local sel_center = sel_pos.x + sel_pos.width / 2

    local target_offset = sel_center - display.width / 2

    local max_offset = math.max(0, positions.total_width - visible_width)
    AppMenu.scroll_offset = math.max(0, math.min(max_offset, target_offset))
end

function AppMenu.render(display)
    if not AppMenu.active then return end

    -- Ensure medium font
    display.set_font_size("medium")

    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local fh = display.get_font_height()
    local w = display.width

    local bar_h = fh + 10
    local y = display.height - bar_h

    -- Background
    display.fill_rect(0, y - 1, w, bar_h + 1, colors.BLACK)
    display.fill_rect(0, y - 2, w, 1, colors.CYAN)

    local positions = AppMenu.calculate_item_positions(display)
    AppMenu.adjust_scroll(display)

    -- Draw items
    for i, item in ipairs(AppMenu.items) do
        local pos = positions[i]
        local x = pos.x - AppMenu.scroll_offset
        local is_sel = (i == AppMenu.selected)

        if x + pos.width > 0 and x < w then
            if is_sel then
                local pad = 6
                display.fill_rect(x - pad, y + 1, pos.width + pad * 2, fh + 6, colors.SELECTION)
            end

            local color = is_sel and colors.CYAN or colors.TEXT_DIM
            display.draw_text(x, y + 4, item.label, color)
        end
    end

    -- Scroll indicators
    if AppMenu.scroll_offset > 0 then
        display.draw_text(2, y + 4, "<", colors.CYAN)
    end
    if positions.total_width - AppMenu.scroll_offset > w then
        display.draw_text(w - 10, y + 4, ">", colors.CYAN)
    end
end

function AppMenu.handle_key(key)
    if not AppMenu.active then return false end

    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        AppMenu.hide()
        return true
    end

    if key.special == "LEFT" then
        AppMenu.selected = AppMenu.selected - 1
        if AppMenu.selected < 1 then AppMenu.selected = #AppMenu.items end
        if _G.ScreenManager then _G.ScreenManager.invalidate() end
        return true
    end

    if key.special == "RIGHT" then
        AppMenu.selected = AppMenu.selected + 1
        if AppMenu.selected > #AppMenu.items then AppMenu.selected = 1 end
        if _G.ScreenManager then _G.ScreenManager.invalidate() end
        return true
    end

    if key.special == "ENTER" then
        local item = AppMenu.items[AppMenu.selected]
        if item and item.action then
            AppMenu.hide()
            item.action()
        else
            AppMenu.hide()
        end
        return true
    end

    -- Consume all keys while active to prevent screen from getting input
    return true
end

return AppMenu
