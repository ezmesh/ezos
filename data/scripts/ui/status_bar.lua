-- status_bar.lua - Lua-based status bar rendering
-- Registered as an overlay via the Overlays system

local StatusBar = {
    -- Status data (can be updated by services)
    battery = 100,
    radio_ok = false,
    signal_bars = 0,
    node_count = 0,
    has_unread = false,
    node_id = "------",

    -- Overlay configuration
    OVERLAY_NAME = "status_bar",
    OVERLAY_Z_ORDER = 100  -- High z-order to render on top
}

-- Update status from C++ state
function StatusBar.sync()
    local status = tdeck.screen.get_status()
    if status then
        StatusBar.battery = status.battery or 100
        StatusBar.radio_ok = status.radio_ok or false
        StatusBar.signal_bars = status.signal_bars or 0
        StatusBar.node_count = status.node_count or 0
        StatusBar.has_unread = status.has_unread or false
        StatusBar.node_id = status.node_id or "------"
    end
end

-- Draw battery indicator [####] style
function StatusBar.draw_battery(display, x, y)
    local colors = display.colors
    local percent = StatusBar.battery

    -- Calculate fill level (4 positions)
    local fill_chars = math.floor((percent * 4) / 100)
    if percent > 0 and fill_chars == 0 then
        fill_chars = 1
    end

    -- Choose color based on level
    local color = colors.GREEN
    if percent <= 20 then
        color = colors.RED
    elseif percent <= 40 then
        color = colors.YELLOW
    end

    -- Draw battery outline and fill
    display.draw_text(x, y, "[", colors.BORDER)
    for i = 0, 3 do
        local char = (i < fill_chars) and "#" or "-"
        local char_color = (i < fill_chars) and color or colors.DARK_GRAY
        display.draw_text(x + (1 + i) * display.font_width, y, char, char_color)
    end
    display.draw_text(x + 5 * display.font_width, y, "]", colors.BORDER)
end

-- Draw signal bars
function StatusBar.draw_signal(display, x, y)
    local colors = display.colors
    local bars = StatusBar.signal_bars
    local bar_width = 3
    local spacing = 1
    local max_height = 12

    for i = 0, 3 do
        local bar_height = math.floor((max_height * (i + 1)) / 4)
        local bx = x + i * (bar_width + spacing)
        local by = y + (max_height - bar_height)
        local color = (i < bars) and colors.GREEN or colors.DARK_GRAY
        display.fill_rect(bx, by, bar_width, bar_height, color)
    end
end

-- Main render function - call this at end of screen render
function StatusBar.render(display)
    local colors = display.colors

    -- Sync with C++ status
    StatusBar.sync()

    -- Status bar at bottom of screen
    local y = (display.rows - 1) * display.font_height

    -- Draw separator line
    local sep_y = y - display.font_height / 2
    display.fill_rect(0, sep_y - 1, display.width, 1, colors.BORDER)

    -- Left side: Node ID
    local node_text = "ID:" .. StatusBar.node_id
    display.draw_text(display.font_width, y, node_text, colors.TEXT_DIM)

    -- Middle: Node count
    local nodes_text = StatusBar.node_count .. "N"
    local nodes_x = math.floor((display.cols / 2 - 2) * display.font_width)
    display.draw_text(nodes_x, y, nodes_text, colors.TEXT_DIM)

    -- Unread indicator
    if StatusBar.has_unread then
        local unread_x = nodes_x + #nodes_text * display.font_width + 4
        display.draw_text(unread_x, y, "*", colors.YELLOW)
    end

    -- Right side: Signal and battery
    local right_x = (display.cols - 12) * display.font_width

    -- Radio status indicator
    if StatusBar.radio_ok then
        StatusBar.draw_signal(display, right_x, y + 2)
    else
        display.draw_text(right_x, y, "!RF", colors.RED)
    end

    -- Battery indicator
    local batt_x = (display.cols - 6) * display.font_width
    StatusBar.draw_battery(display, batt_x, y)
end

-- Register with the overlay system
function StatusBar.register()
    if Overlays then
        Overlays.register(StatusBar.OVERLAY_NAME, StatusBar.render, StatusBar.OVERLAY_Z_ORDER)
    end
end

-- Unregister from the overlay system
function StatusBar.unregister()
    if Overlays then
        Overlays.unregister(StatusBar.OVERLAY_NAME)
    end
end

-- Enable/disable the status bar overlay
function StatusBar.enable()
    if Overlays then
        Overlays.enable(StatusBar.OVERLAY_NAME)
    end
end

function StatusBar.disable()
    if Overlays then
        Overlays.disable(StatusBar.OVERLAY_NAME)
    end
end

return StatusBar
