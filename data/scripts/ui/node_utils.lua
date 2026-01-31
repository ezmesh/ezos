-- Node Utilities for T-Deck OS
-- Shared functions for mesh node display

local NodeUtils = {}

-- Convert RSSI to signal bars (0-4)
function NodeUtils.rssi_to_bars(rssi)
    if not rssi then return 0 end
    if rssi > -60 then return 4
    elseif rssi > -80 then return 3
    elseif rssi > -100 then return 2
    elseif rssi > -110 then return 1
    else return 0
    end
end

-- Draw signal bars indicator
function NodeUtils.draw_signal_bars(display, x, y, rssi, colors)
    local bars = NodeUtils.rssi_to_bars(rssi)
    local bar_width = 3
    local bar_spacing = 1
    local max_height = 12

    for i = 1, 4 do
        local bar_height = i * 3
        local bar_x = x + (i - 1) * (bar_width + bar_spacing)
        local bar_y = y + max_height - bar_height

        if i <= bars then
            display.fill_rect(bar_x, bar_y, bar_width, bar_height, colors.TEXT or colors.WHITE)
        else
            display.fill_rect(bar_x, bar_y, bar_width, bar_height, colors.TEXT_DIM or colors.DARK_GRAY)
        end
    end
end

-- Convert RSSI to indicator string
function NodeUtils.rssi_indicator(rssi)
    local bars = NodeUtils.rssi_to_bars(rssi)
    local filled = string.rep("#", bars)
    local empty = string.rep("-", 4 - bars)
    return "[" .. filled .. empty .. "]"
end

-- Convert role enum to full string
function NodeUtils.role_to_string(role)
    if not ez.mesh or not ez.mesh.ROLE then return nil end

    local ROLE = ez.mesh.ROLE
    if role == ROLE.CLIENT then return "Client"
    elseif role == ROLE.REPEATER then return "Repeater"
    elseif role == ROLE.ROUTER then return "Router"
    elseif role == ROLE.GATEWAY then return "Gateway"
    else return nil
    end
end

-- Convert role enum to abbreviation
function NodeUtils.role_abbrev(role)
    if not ez.mesh or not ez.mesh.ROLE then return "?" end

    local ROLE = ez.mesh.ROLE
    if role == ROLE.CLIENT then return "C"
    elseif role == ROLE.REPEATER then return "R"
    elseif role == ROLE.ROUTER then return "Rt"
    elseif role == ROLE.GATEWAY then return "G"
    else return "?"
    end
end

-- Sanitize a node name for display (ASCII only, truncated)
function NodeUtils.sanitize_name(name, max_width, display)
    if not name then return "Unknown" end

    -- Filter to printable ASCII only
    local clean = ""
    for i = 1, #name do
        local b = name:byte(i)
        if b >= 32 and b < 127 then
            clean = clean .. name:sub(i, i)
        end
    end

    if clean == "" then
        clean = "Unknown"
    end

    -- Truncate to fit width if display provided
    if max_width and display then
        while display.text_width(clean) > max_width and #clean > 1 do
            clean = clean:sub(1, -2)
        end
    end

    return clean
end

-- Format node ID (first 4 bytes of pubkey hex)
function NodeUtils.format_id(pub_key_hex)
    if not pub_key_hex then return "????" end
    return pub_key_hex:sub(1, 8):upper()
end

return NodeUtils
