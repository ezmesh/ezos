-- Icons module for T-Deck OS
-- 24x24 1-bit icons, scaled and colorized at runtime

local Icons = {
    SIZE = 24,  -- Native icon size
}

-- 24x24 1-bit icon data (72 bytes each, MSB first, row by row)
-- Each row is 3 bytes (24 bits)

Icons.data = {
    -- Messages: envelope icon (24x24)
    messages = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"..  -- rows 0-3
               "\x7F\xFF\xFE\x40\x00\x02\x60\x00\x06\x70\x00\x0E"..  -- rows 4-7: envelope outline with corners
               "\x58\x00\x1A\x4C\x00\x32\x46\x00\x62\x43\x00\xC2"..  -- rows 8-11: diagonal lines to center
               "\x41\x81\x82\x40\xC3\x02\x40\x66\x02\x40\x3C\x02"..  -- rows 12-15: meeting at center
               "\x40\x00\x02\x40\x00\x02\x40\x00\x02\x7F\xFF\xFE"..  -- rows 16-19: bottom part
               "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",   -- rows 20-23

    -- Channels: hash/grid icon (24x24)
    channels = "\x00\x00\x00\x00\x00\x00\x02\x10\x00\x02\x10\x00"..  -- rows 0-3
               "\x02\x10\x00\x02\x10\x00\x02\x10\x00\x3F\xFF\xC0"..  -- rows 4-7
               "\x02\x10\x00\x02\x10\x00\x02\x10\x00\x02\x10\x00"..  -- rows 8-11
               "\x02\x10\x00\x3F\xFF\xC0\x02\x10\x00\x02\x10\x00"..  -- rows 12-15
               "\x02\x10\x00\x02\x10\x00\x02\x10\x00\x02\x10\x00"..  -- rows 16-19
               "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",   -- rows 20-23

    -- Contacts: person silhouette (24x24)
    contacts = "\x00\x00\x00\x00\x00\x00\x00\x7E\x00\x01\xFF\x80"..  -- rows 0-3: head top
               "\x03\xC3\xC0\x07\x00\xE0\x06\x00\x60\x06\x00\x60"..  -- rows 4-7: head sides
               "\x07\x00\xE0\x03\xC3\xC0\x01\xFF\x80\x00\x7E\x00"..  -- rows 8-11: head bottom
               "\x00\x18\x00\x00\x7E\x00\x01\xFF\x80\x07\xFF\xE0"..  -- rows 12-15: neck and shoulders
               "\x0F\x81\xF0\x1E\x00\x78\x1C\x00\x38\x18\x00\x18"..  -- rows 16-19: body
               "\x18\x00\x18\x18\x00\x18\x00\x00\x00\x00\x00\x00",   -- rows 20-23

    -- Info: i in circle (24x24)
    info = "\x00\x00\x00\x00\x7E\x00\x01\xFF\x80\x07\x81\xE0"..  -- rows 0-3
           "\x0E\x00\x70\x1C\x18\x38\x18\x18\x18\x38\x18\x1C"..  -- rows 4-7
           "\x30\x00\x0C\x30\x00\x0C\x30\x18\x0C\x30\x18\x0C"..  -- rows 8-11
           "\x30\x18\x0C\x30\x18\x0C\x30\x18\x0C\x30\x3C\x0C"..  -- rows 12-15
           "\x38\x00\x1C\x18\x00\x18\x1C\x00\x38\x0E\x00\x70"..  -- rows 16-19
           "\x07\x81\xE0\x01\xFF\x80\x00\x7E\x00\x00\x00\x00",   -- rows 20-23

    -- Settings: gear/cog icon (24x24)
    settings = "\x00\x00\x00\x00\x18\x00\x00\x3C\x00\x00\x3C\x00"..  -- rows 0-3
               "\x0C\x3C\x30\x1E\x7E\x78\x1F\xFF\xF8\x0F\xC3\xF0"..  -- rows 4-7
               "\x03\xC3\xC0\x03\x81\xC0\x33\x81\xCC\x7F\x81\xFE"..  -- rows 8-11
               "\x7F\x81\xFE\x33\x81\xCC\x03\x81\xC0\x03\xC3\xC0"..  -- rows 12-15
               "\x0F\xC3\xF0\x1F\xFF\xF8\x1E\x7E\x78\x0C\x3C\x30"..  -- rows 16-19
               "\x00\x3C\x00\x00\x3C\x00\x00\x18\x00\x00\x00\x00",   -- rows 20-23

    -- Files: folder icon (24x24)
    files = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x1F\xE0\x00"..  -- rows 0-3
            "\x3F\xF0\x00\x60\x18\x00\x7F\xFF\xFC\x40\x00\x04"..  -- rows 4-7
            "\x40\x00\x04\x40\x00\x04\x40\x00\x04\x40\x00\x04"..  -- rows 8-11
            "\x40\x00\x04\x40\x00\x04\x40\x00\x04\x40\x00\x04"..  -- rows 12-15
            "\x40\x00\x04\x7F\xFF\xFC\x00\x00\x00\x00\x00\x00"..  -- rows 16-19
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",   -- rows 20-23

    -- Testing: magnifying glass (24x24)
    testing = "\x00\x00\x00\x00\x00\x00\x00\x7E\x00\x01\xFF\x80"..  -- rows 0-3
              "\x03\x81\xC0\x07\x00\xE0\x0E\x00\x70\x0C\x00\x30"..  -- rows 4-7
              "\x0C\x00\x30\x0C\x00\x30\x0C\x00\x30\x0E\x00\x70"..  -- rows 8-11
              "\x07\x00\xE0\x03\x81\xC0\x01\xFF\xC0\x00\x7F\xE0"..  -- rows 12-15
              "\x00\x03\xF0\x00\x01\xF8\x00\x00\xFC\x00\x00\x7E"..  -- rows 16-19
              "\x00\x00\x3C\x00\x00\x18\x00\x00\x00\x00\x00\x00",   -- rows 20-23

    -- Games: gamepad icon (24x24)
    games = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"..  -- rows 0-3
            "\x1F\xFF\xF8\x3F\xFF\xFC\x7F\xFF\xFE\x61\xE7\x86"..  -- rows 4-7
            "\x61\xE7\x86\xF1\xE7\x8F\xF1\xE7\x8F\xF0\x60\x0F"..  -- rows 8-11
            "\xF0\x60\x0F\xF1\xE7\x8F\xF1\xE7\x8F\x61\xE7\x86"..  -- rows 12-15
            "\x61\xE7\x86\x7F\xFF\xFE\x3F\xFF\xFC\x1F\xFF\xF8"..  -- rows 16-19
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",   -- rows 20-23

    -- Map: folded paper map (24x24)
    map = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x3D\xE7\xBC"..  -- rows 0-3
          "\x24\x24\x24\x24\x24\x24\x34\xE4\x2C\x24\x24\x24"..  -- rows 4-7
          "\x24\x27\xA4\x24\x24\x24\x3D\xE4\x24\x24\x24\x24"..  -- rows 8-11
          "\x24\x24\x24\x24\x27\xBC\x24\x24\x24\x24\xE4\x24"..  -- rows 12-15
          "\x24\x24\x24\x3D\xE7\xBC\x00\x00\x00\x00\x00\x00"..  -- rows 16-19
          "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",   -- rows 20-23

    -- Packets: radio signal/broadcast icon (24x24)
    packets = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x1E\x00"..  -- rows 0-3
              "\x00\x61\x80\x00\xC0\xC0\x01\x80\x60\x03\x1E\x30"..  -- rows 4-7
              "\x02\x61\x90\x06\xC0\xD8\x04\x80\x48\x0C\x9E\x4C"..  -- rows 8-11
              "\x0C\x9E\x4C\x04\x80\x48\x06\xC0\xD8\x02\x61\x90"..  -- rows 12-15
              "\x03\x1E\x30\x01\x80\x60\x00\xC0\xC0\x00\x61\x80"..  -- rows 16-19
              "\x00\x1E\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",   -- rows 20-23

    -- Screenshot: camera icon (24x24)
    screenshot = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\xC0\x00"..  -- rows 0-3: flash
                 "\x03\xC0\x00\x7F\xFF\xFE\xFF\xFF\xFF\xC0\x00\x03"..  -- rows 4-7: top
                 "\xC0\x00\x03\xC0\x7E\x03\xC0\xFF\x03\xC1\x81\x83"..  -- rows 8-11: lens outer
                 "\xC1\x00\x83\xC1\x00\x83\xC1\x00\x83\xC1\x81\x83"..  -- rows 12-15: lens inner
                 "\xC0\xFF\x03\xC0\x7E\x03\xC0\x00\x03\xFF\xFF\xFF"..  -- rows 16-19: bottom
                 "\x7F\xFF\xFE\x00\x00\x00\x00\x00\x00\x00\x00\x00",   -- rows 20-23

    -- Home: house icon (24x24)
    home = "\x00\x00\x00\x00\x00\x00\x00\x18\x00\x00\x3C\x00"..  -- rows 0-3: roof top
           "\x00\x7E\x00\x00\xFF\x00\x01\xE7\x80\x03\xC3\xC0"..  -- rows 4-7: roof
           "\x07\x81\xE0\x0F\x00\xF0\x1E\x00\x78\x3C\x00\x3C"..  -- rows 8-11: roof sides
           "\x7F\xFF\xFE\x60\x00\x06\x60\x00\x06\x60\x3C\x06"..  -- rows 12-15: house body
           "\x60\x3C\x06\x60\x3C\x06\x60\x3C\x06\x60\x3C\x06"..  -- rows 16-19: door
           "\x7F\xFF\xFE\x00\x00\x00\x00\x00\x00\x00\x00\x00",   -- rows 20-23

    -- Terminal: console/command prompt icon (24x24)
    terminal = "\x00\x00\x00\x00\x00\x00\xFF\xFF\xFF\xFF\xFF\xFF"..  -- rows 0-3: top border
               "\xC0\x00\x03\xC0\x00\x03\xC0\x00\x03\xC0\x00\x03"..  -- rows 4-7: window sides
               "\xC1\x80\x03\xC3\x00\x03\xC6\x00\x03\xCC\x00\x03"..  -- rows 8-11: > prompt
               "\xC6\x00\x03\xC3\x00\x03\xC1\x80\x03\xC0\x00\x03"..  -- rows 12-15: > bottom
               "\xC0\x7E\x03\xC0\x00\x03\xC0\x00\x03\xC0\x00\x03"..  -- rows 16-19: cursor line
               "\xFF\xFF\xFF\xFF\xFF\xFF\x00\x00\x00\x00\x00\x00",   -- rows 20-23: bottom
}

-- Convert a Lua binary string to a byte array table (for Wasmoon compatibility)
-- Wasmoon may have issues with strings containing null bytes when passed to JS
local function string_to_bytes(str)
    local bytes = {}
    for i = 1, #str do
        bytes[i] = string.byte(str, i)
    end
    return bytes
end

-- Cache of converted byte arrays for icons
Icons._byte_cache = {}

-- Draw an icon by name
-- @param name Icon name (e.g., "messages")
-- @param display Display object
-- @param x X position
-- @param y Y position
-- @param size Display size (will scale to fit)
-- @param color Optional color (defaults to ACCENT)
function Icons.draw(name, display, x, y, size, color)
    local icon_data = Icons.data[name]

    if not icon_data then
        -- Fallback: draw a rectangle
        display.draw_rect(x, y, size or 24, size or 24, color or display.colors.ACCENT)
        return
    end

    size = size or 24
    color = color or display.colors.ACCENT

    -- Calculate scale factor
    local scale = math.floor(size / Icons.SIZE)
    if scale < 1 then scale = 1 end

    -- Center the icon if scaled size doesn't match requested size
    local actual_size = Icons.SIZE * scale
    local offset = math.floor((size - actual_size) / 2)

    -- In simulator mode, convert to byte array for better Wasmoon compatibility
    -- Wasmoon has issues with Lua strings containing null bytes
    if __SIMULATOR__ then
        -- Use cached byte array if available
        if not Icons._byte_cache[name] then
            Icons._byte_cache[name] = string_to_bytes(icon_data)
        end
        display.draw_bitmap_1bit(x + offset, y + offset, Icons.SIZE, Icons.SIZE, Icons._byte_cache[name], scale, color)
    else
        display.draw_bitmap_1bit(x + offset, y + offset, Icons.SIZE, Icons.SIZE, icon_data, scale, color)
    end
end

-- Get list of available icon names
function Icons.list()
    local names = {}
    for name, _ in pairs(Icons.data) do
        table.insert(names, name)
    end
    return names
end

-- Draw 8-bit style left chevron (9x9) with black background
function Icons.draw_chevron_left(display, x, y, color, bg_color)
    local size = 9
    bg_color = bg_color or display.colors.BLACK
    display.fill_rect(x, y, size, size, bg_color)
    -- Draw < shape (pointing left)
    display.fill_rect(x + 5, y + 1, 1, 1, color)
    display.fill_rect(x + 4, y + 2, 1, 1, color)
    display.fill_rect(x + 3, y + 3, 1, 1, color)
    display.fill_rect(x + 2, y + 4, 1, 1, color)
    display.fill_rect(x + 3, y + 5, 1, 1, color)
    display.fill_rect(x + 4, y + 6, 1, 1, color)
    display.fill_rect(x + 5, y + 7, 1, 1, color)
end

-- Draw 8-bit style right chevron (9x9) with black background
function Icons.draw_chevron_right(display, x, y, color, bg_color)
    local size = 9
    bg_color = bg_color or display.colors.BLACK
    display.fill_rect(x, y, size, size, bg_color)
    -- Draw > shape (pointing right)
    display.fill_rect(x + 3, y + 1, 1, 1, color)
    display.fill_rect(x + 4, y + 2, 1, 1, color)
    display.fill_rect(x + 5, y + 3, 1, 1, color)
    display.fill_rect(x + 6, y + 4, 1, 1, color)
    display.fill_rect(x + 5, y + 5, 1, 1, color)
    display.fill_rect(x + 4, y + 6, 1, 1, color)
    display.fill_rect(x + 3, y + 7, 1, 1, color)
end

-- Small icons (12x12, 2 bytes per row = 24 bytes total)
Icons.small = {
    -- Bunny/rabbit icon (12x12) for hop count display
    -- Front-facing bunny with ears, eyes, nose, and feet
    bunny = "\x20\x80\x20\x80\x3F\x80\x40\x40\x51\x40\x44\x40\x40\x40\x31\x80\x1F\x00\x04\x00\x0A\x00\x00\x00",
}
Icons.SMALL_SIZE = 12

-- Draw a small icon (12x12) by name
function Icons.draw_small(name, display, x, y, color)
    local icon_data = Icons.small[name]
    if not icon_data then return end
    color = color or display.colors.ACCENT

    -- In simulator mode, convert to byte array for Wasmoon compatibility
    if __SIMULATOR__ then
        local cache_key = "small_" .. name
        if not Icons._byte_cache[cache_key] then
            Icons._byte_cache[cache_key] = string_to_bytes(icon_data)
        end
        display.draw_bitmap_1bit(x, y, Icons.SMALL_SIZE, Icons.SMALL_SIZE, Icons._byte_cache[cache_key], 1, color)
    else
        display.draw_bitmap_1bit(x, y, Icons.SMALL_SIZE, Icons.SMALL_SIZE, icon_data, 1, color)
    end
end

return Icons
