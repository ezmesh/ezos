-- App Menu Overlay
-- Quick access menu activated by both shift keys
-- Horizontally scrollable action bar at bottom of screen

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local AppMenu = {
    items = {},
    selected = 1,
    scroll_offset = 0,
    active = false,
}

-- Draw 8-bit style left chevron with black background
local function draw_chevron_left(display, x, y, color)
    local size = 9
    display.fill_rect(x, y, size, size, display.colors.BLACK)
    -- Draw < shape (pointing left)
    display.fill_rect(x + 5, y + 1, 1, 1, color)
    display.fill_rect(x + 4, y + 2, 1, 1, color)
    display.fill_rect(x + 3, y + 3, 1, 1, color)
    display.fill_rect(x + 2, y + 4, 1, 1, color)
    display.fill_rect(x + 3, y + 5, 1, 1, color)
    display.fill_rect(x + 4, y + 6, 1, 1, color)
    display.fill_rect(x + 5, y + 7, 1, 1, color)
end

-- Draw 8-bit style right chevron with black background
local function draw_chevron_right(display, x, y, color)
    local size = 9
    display.fill_rect(x, y, size, size, display.colors.BLACK)
    -- Draw > shape (pointing right)
    display.fill_rect(x + 3, y + 1, 1, 1, color)
    display.fill_rect(x + 4, y + 2, 1, 1, color)
    display.fill_rect(x + 5, y + 3, 1, 1, color)
    display.fill_rect(x + 6, y + 4, 1, 1, color)
    display.fill_rect(x + 5, y + 5, 1, 1, color)
    display.fill_rect(x + 4, y + 6, 1, 1, color)
    display.fill_rect(x + 3, y + 7, 1, 1, color)
end

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

    -- Add Screenshot action (always available)
    table.insert(AppMenu.items, {icon = "screenshot", action = function()
        if _G.StatusBar and _G.StatusBar.take_screenshot then
            _G.StatusBar.take_screenshot()
        end
    end})

    -- Add Home action if we're deeper than main menu
    local depth = _G.ScreenManager and _G.ScreenManager.depth() or 0
    if depth > 1 then
        table.insert(AppMenu.items, {icon = "home", action = function()
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

    -- Re-register overlay (was unregistered above) so it can be shown again
    if _G.Overlays then
        _G.Overlays.register("app_menu", AppMenu.render, 200, AppMenu.handle_key)
        _G.Overlays.disable("app_menu")
    end

    run_gc("collect", "app-menu-close")

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
    local icon_size = 16  -- Size for inline icons

    for i, item in ipairs(AppMenu.items) do
        local width
        if item.icon and not item.label then
            -- Icon-only item
            width = icon_size
        else
            -- Text item (with or without icon)
            width = display.text_width(item.label or "")
        end
        positions[i] = {x = x, width = width}
        x = x + width + item_spacing
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

    local colors = ListMixin.get_colors(display)
    local fh = display.get_font_height()
    local w = display.width

    local bar_h = fh + 10
    local y = display.height - bar_h

    -- Background
    display.fill_rect(0, y - 1, w, bar_h + 1, colors.BLACK)
    display.fill_rect(0, y - 2, w, 1, colors.ACCENT)

    local positions = AppMenu.calculate_item_positions(display)
    AppMenu.adjust_scroll(display)

    -- Draw items
    local icon_size = 16
    for i, item in ipairs(AppMenu.items) do
        local pos = positions[i]
        local x = pos.x - AppMenu.scroll_offset
        local is_sel = (i == AppMenu.selected)

        if x + pos.width > 0 and x < w then
            if is_sel then
                local pad = 6
                display.fill_rect(x - pad, y + 1, pos.width + pad * 2, fh + 6, colors.SURFACE_ALT)
            end

            local color = is_sel and colors.ACCENT or colors.TEXT_SECONDARY

            if item.icon and not item.label then
                -- Icon-only item
                local icon_y = y + (fh - icon_size) / 2 + 2
                if _G.Icons then
                    _G.Icons.draw(item.icon, display, x, icon_y, icon_size, color)
                else
                    display.draw_rect(x, icon_y, icon_size, icon_size, color)
                end
            else
                -- Text item
                display.draw_text(x, y + 4, item.label, color)
            end
        end
    end

    -- Scroll indicators (8-bit chevron icons with black background)
    local chevron_y = y + math.floor((bar_h - 9) / 2)
    if AppMenu.scroll_offset > 0 then
        draw_chevron_left(display, 1, chevron_y, colors.ACCENT)
    end
    if positions.total_width - AppMenu.scroll_offset > w then
        draw_chevron_right(display, w - 10, chevron_y, colors.ACCENT)
    end
end

function AppMenu.handle_key(key)
    if not AppMenu.active then return false end

    if key.special == "ESCAPE" or key.character == "q" then
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
