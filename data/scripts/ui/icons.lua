-- Icons module for T-Deck OS
-- 16x16 1-bit icons, scaled and colorized at runtime

local Icons = {
    SIZE = 16,  -- Native icon size
}

-- 16x16 1-bit icon data (32 bytes each, MSB first, row by row)
-- Each row is 2 bytes (16 bits)

Icons.data = {
    -- Messages: envelope icon
    messages = "\x00\x00\x00\x00\x7F\xFE\x40\x02\x60\x06\x50\x0A\x48\x12\x44\x22"..
               "\x42\x42\x40\x02\x40\x02\x40\x02\x7F\xFE\x00\x00\x00\x00\x00\x00",

    -- Channels: hash/grid icon
    channels = "\x00\x00\x04\x20\x04\x20\x04\x20\x3F\xFC\x04\x20\x04\x20\x04\x20"..
               "\x04\x20\x3F\xFC\x04\x20\x04\x20\x04\x20\x00\x00\x00\x00\x00\x00",

    -- Contacts: person silhouette
    contacts = "\x00\x00\x03\xC0\x07\xE0\x0C\x30\x0C\x30\x07\xE0\x03\xC0\x01\x80"..
               "\x0F\xF0\x1F\xF8\x38\x1C\x30\x0C\x30\x0C\x30\x0C\x00\x00\x00\x00",

    -- Info: i in circle
    info = "\x00\x00\x07\xE0\x1F\xF8\x38\x1C\x31\x8C\x31\x8C\x38\x1C\x1C\x38"..
           "\x01\x80\x01\x80\x03\xC0\x01\x80\x01\x80\x1F\xF8\x07\xE0\x00\x00",

    -- Settings: gear icon
    settings = "\x00\x00\x01\x80\x03\xC0\x0E\x70\x0C\x30\x3C\x3C\x30\x0C\x30\x0C"..
               "\x30\x0C\x3C\x3C\x0C\x30\x0E\x70\x03\xC0\x01\x80\x00\x00\x00\x00",

    -- Files: folder icon
    files = "\x00\x00\x00\x00\x3E\x00\x7F\x00\x7F\xFE\x40\x02\x40\x02\x40\x02"..
            "\x40\x02\x40\x02\x40\x02\x40\x02\x7F\xFE\x00\x00\x00\x00\x00\x00",

    -- Testing: magnifying glass
    testing = "\x00\x00\x07\xC0\x1F\xF0\x38\x38\x30\x18\x60\x0C\x60\x0C\x60\x0C"..
              "\x30\x18\x38\x38\x1F\xF0\x07\xCC\x00\x0E\x00\x07\x00\x03\x00\x00",

    -- Games: gamepad icon
    games = "\x00\x00\x00\x00\x00\x00\x3F\xFC\x7F\xFE\x67\xE6\xE7\xE7\xE1\x87"..
            "\xE1\x87\xE7\xE7\x67\xE6\x7F\xFE\x3F\xFC\x00\x00\x00\x00\x00\x00",

    -- Map: globe with lat/lon lines
    map = "\x00\x00\x07\xE0\x18\x18\x24\x24\x42\x42\x41\x82\x7F\xFE\x41\x82"..
          "\x41\x82\x7F\xFE\x41\x82\x42\x42\x24\x24\x18\x18\x07\xE0\x00\x00",
}

-- Draw an icon by name
-- @param name Icon name (e.g., "messages")
-- @param display Display object
-- @param x X position
-- @param y Y position
-- @param size Display size (will scale to fit)
-- @param color Optional color (defaults to CYAN)
function Icons.draw(name, display, x, y, size, color)
    local icon_data = Icons.data[name]
    if not icon_data then
        -- Fallback: draw a rectangle
        display.draw_rect(x, y, size or 24, size or 24, color or display.colors.CYAN)
        return
    end

    size = size or 24
    color = color or display.colors.CYAN

    -- Calculate scale factor
    local scale = math.floor(size / Icons.SIZE)
    if scale < 1 then scale = 1 end

    -- Center the icon if scaled size doesn't match requested size
    local actual_size = Icons.SIZE * scale
    local offset = math.floor((size - actual_size) / 2)

    display.draw_bitmap_1bit(x + offset, y + offset, Icons.SIZE, Icons.SIZE, icon_data, scale, color)
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

return Icons
