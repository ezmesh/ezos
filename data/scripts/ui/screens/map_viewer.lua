-- Map Viewer Screen for T-Deck OS
-- Displays offline map tiles from TDMAP archive on SD card
-- Supports pan (trackball) and zoom (+/-) controls

-- Math helpers for ESP32 Lua (missing hyperbolic functions)
local function sinh(x)
    return (math.exp(x) - math.exp(-x)) / 2
end

local function asinh(x)
    return math.log(x + math.sqrt(x * x + 1))
end

local MapViewer = {
    title = "Map",

    -- Archive file path (check SD card first, then flash)
    archive_path = "/sd/maps/world.tdmap",
    fallback_path = "/maps/alkmaar.tdmap",  -- Test file on flash

    -- Archive metadata (populated on load)
    archive = nil,  -- { path, tile_count, index_offset, data_offset, min_zoom, max_zoom, palette }
    tile_index = nil,  -- Array of { zoom, x, y, offset, size }

    -- View state
    center_x = 0,      -- Center tile X coordinate (float for sub-tile precision)
    center_y = 0,      -- Center tile Y coordinate (float for sub-tile precision)
    zoom = 2,          -- Current zoom level

    -- Display constants
    TILE_SIZE = 256,   -- Tile size in pixels (before any scaling)
    SCREEN_W = 320,
    SCREEN_H = 240,

    -- Tile cache (LRU, max 4 tiles to conserve memory)
    tile_cache = {},
    cache_order = {},
    MAX_CACHE = 4,

    -- Error state
    error_msg = nil,

    -- TDMAP format constants
    HEADER_SIZE = 32,
    PALETTE_SIZE = 16,
    INDEX_ENTRY_SIZE = 11,
}

function MapViewer:new(archive_path)
    local o = {
        archive_path = archive_path or self.archive_path,
        archive = nil,
        tile_index = nil,
        center_x = 0,
        center_y = 0,
        zoom = 2,
        tile_cache = {},
        cache_order = {},
        error_msg = nil,
    }
    setmetatable(o, {__index = MapViewer})
    return o
end

-- Parse little-endian integers from binary string
local function read_u8(data, offset)
    return string.byte(data, offset + 1)
end

local function read_u16(data, offset)
    local b0 = string.byte(data, offset + 1) or 0
    local b1 = string.byte(data, offset + 2) or 0
    return b0 + b1 * 256
end

local function read_u32(data, offset)
    local b0 = string.byte(data, offset + 1) or 0
    local b1 = string.byte(data, offset + 2) or 0
    local b2 = string.byte(data, offset + 3) or 0
    local b3 = string.byte(data, offset + 4) or 0
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

local function read_i8(data, offset)
    local v = read_u8(data, offset)
    if v >= 128 then v = v - 256 end
    return v
end

function MapViewer:load_archive()
    -- Check if archive exists (try SD card first, then flash)
    local path = self.archive_path
    if not tdeck.storage.exists(path) then
        path = self.fallback_path
        if not tdeck.storage.exists(path) then
            self.error_msg = "Map file not found:\n" .. self.archive_path
            return false
        end
    end
    self.archive_path = path  -- Use the path that exists

    -- Read header (32 bytes)
    local header = tdeck.storage.read_bytes(self.archive_path, 0, self.HEADER_SIZE)
    if not header then
        self.error_msg = "Failed to read map header"
        return false
    end

    -- Verify magic
    local magic = string.sub(header, 1, 6)
    if magic ~= "TDMAP\0" then
        self.error_msg = "Invalid map file format"
        return false
    end

    -- Parse header fields
    local version = read_u8(header, 6)
    local compression = read_u8(header, 7)
    local tile_size = read_u16(header, 8)
    local palette_count = read_u8(header, 10)
    local tile_count = read_u32(header, 11)
    local index_offset = read_u32(header, 15)
    local data_offset = read_u32(header, 19)
    local min_zoom = read_i8(header, 23)
    local max_zoom = read_i8(header, 24)

    if version ~= 1 then
        self.error_msg = "Unsupported map version: " .. version
        return false
    end

    -- Read palette (8 RGB565 colors = 16 bytes)
    local palette_data = tdeck.storage.read_bytes(self.archive_path, self.HEADER_SIZE, self.PALETTE_SIZE)
    if not palette_data then
        self.error_msg = "Failed to read palette"
        return false
    end

    local palette = {}
    for i = 0, 7 do
        palette[i + 1] = read_u16(palette_data, i * 2)
    end

    self.archive = {
        path = self.archive_path,
        tile_count = tile_count,
        index_offset = index_offset,
        data_offset = data_offset,
        min_zoom = min_zoom,
        max_zoom = max_zoom,
        palette = palette,
        tile_size = tile_size,
    }

    -- Read tile index (11 bytes per entry)
    local index_size = tile_count * self.INDEX_ENTRY_SIZE
    -- Read in chunks if index is large (limit 64KB per read)
    self.tile_index = {}

    local chunk_size = 60000  -- ~5400 entries per chunk
    local offset = index_offset

    for i = 1, tile_count do
        -- Read entry on demand or in batches
        -- For simplicity, we'll build index lazily during tile lookup
    end

    -- For now, don't pre-load entire index (could be huge)
    -- We'll use binary search with on-demand reading
    self.tile_index = nil  -- Flag that we use lazy loading

    -- Set initial view to center of coverage at middle zoom
    local mid_zoom = math.floor((min_zoom + max_zoom) / 2)
    self.zoom = math.max(min_zoom, math.min(mid_zoom, max_zoom))

    -- Start at Alkmaar coordinates as default (matches test file)
    local lat, lon = 52.63, 4.75
    self.center_x, self.center_y = self:lat_lon_to_tile(lat, lon, self.zoom)

    return true
end

-- Convert lat/lon to tile coordinates
function MapViewer:lat_lon_to_tile(lat, lon, zoom)
    local n = 2 ^ zoom
    local x = (lon + 180.0) / 360.0 * n
    local lat_rad = math.rad(lat)
    local y = (1.0 - math.log(math.tan(lat_rad) + 1/math.cos(lat_rad)) / math.pi) / 2.0 * n
    return x, y
end

-- Convert tile coordinates to lat/lon
function MapViewer:tile_to_lat_lon(x, y, zoom)
    local n = 2 ^ zoom
    local lon = x / n * 360.0 - 180.0
    local lat_rad = math.atan(sinh(math.pi * (1 - 2 * y / n)))
    local lat = math.deg(lat_rad)
    return lat, lon
end

-- Center map on GPS coordinates
function MapViewer:center_on(lat, lon)
    self.center_x, self.center_y = self:lat_lon_to_tile(lat, lon, self.zoom)
    self.tile_cache = {}
    self.cache_order = {}
    ScreenManager.invalidate()
end

-- Find tile in archive using binary search
function MapViewer:find_tile_entry(zoom, x, y)
    if not self.archive then return nil end

    local lo = 0
    local hi = self.archive.tile_count - 1
    local target_key = zoom * 0x100000000 + x * 0x10000 + y

    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)

        -- Read index entry at position mid
        local entry_offset = self.archive.index_offset + mid * self.INDEX_ENTRY_SIZE
        local entry_data = tdeck.storage.read_bytes(self.archive_path, entry_offset, self.INDEX_ENTRY_SIZE)
        if not entry_data then return nil end

        local ez = read_u8(entry_data, 0)
        local ex = read_u16(entry_data, 1)
        local ey = read_u16(entry_data, 3)
        local eoffset = read_u32(entry_data, 5)
        local esize = read_u16(entry_data, 9)

        local entry_key = ez * 0x100000000 + ex * 0x10000 + ey

        if entry_key == target_key then
            return { zoom = ez, x = ex, y = ey, offset = eoffset, size = esize }
        elseif entry_key < target_key then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    return nil
end

-- RLE decompress tile data
function MapViewer:rle_decompress(data)
    local result = {}
    local i = 1
    local len = #data

    while i <= len do
        local byte = string.byte(data, i)
        if byte == 0xFF and i + 2 <= len then
            local count = string.byte(data, i + 1)
            local value = string.byte(data, i + 2)
            for _ = 1, count do
                result[#result + 1] = string.char(value)
            end
            i = i + 3
        else
            result[#result + 1] = string.char(byte)
            i = i + 1
        end
    end

    return table.concat(result)
end

-- Get tile data (with caching)
function MapViewer:get_tile(zoom, x, y)
    -- Create cache key
    local key = string.format("%d/%d/%d", zoom, x, y)

    -- Check cache
    if self.tile_cache[key] then
        -- Move to end of LRU order
        for i, k in ipairs(self.cache_order) do
            if k == key then
                table.remove(self.cache_order, i)
                break
            end
        end
        table.insert(self.cache_order, key)
        return self.tile_cache[key]
    end

    -- Find tile in archive
    local entry = self:find_tile_entry(zoom, x, y)
    if not entry then return nil end

    -- Read compressed tile data
    local compressed = tdeck.storage.read_bytes(self.archive_path, entry.offset, entry.size)
    if not compressed then return nil end

    -- Decompress
    local tile_data = self:rle_decompress(compressed)

    -- Add to cache
    self.tile_cache[key] = tile_data
    table.insert(self.cache_order, key)

    -- Evict oldest if cache full
    while #self.cache_order > self.MAX_CACHE do
        local old_key = table.remove(self.cache_order, 1)
        self.tile_cache[old_key] = nil
    end

    return tile_data
end

function MapViewer:on_enter()
    tdeck.keyboard.set_mode("normal")

    if not self.archive then
        self:load_archive()
    end
end

function MapViewer:on_leave()
    -- Clear tile cache to free memory
    self.tile_cache = {}
    self.cache_order = {}
    collectgarbage("collect")
end

function MapViewer:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = self.SCREEN_W
    local h = self.SCREEN_H

    -- Clear background
    display.fill_rect(0, 0, w, h, colors.BLACK)

    if self.error_msg then
        -- Show error message
        display.set_font_size("small")
        display.draw_text_centered(h / 2 - 20, "Map Error", colors.RED)
        display.draw_text_centered(h / 2, self.error_msg, colors.WHITE)
        display.draw_text_centered(h / 2 + 30, "Press ESC to go back", colors.DARK_GRAY)
        return
    end

    if not self.archive then
        display.draw_text_centered(h / 2, "Loading map...", colors.WHITE)
        return
    end

    -- Calculate visible tile range
    -- Screen center is at center_x, center_y in tile coordinates
    local tile_w = self.TILE_SIZE
    local tile_h = self.TILE_SIZE

    -- Number of tiles needed to cover screen
    local tiles_x = math.ceil(w / tile_w) + 1
    local tiles_y = math.ceil(h / tile_h) + 1

    -- Top-left tile coordinates
    local start_tile_x = math.floor(self.center_x - w / (2 * tile_w))
    local start_tile_y = math.floor(self.center_y - h / (2 * tile_h))

    -- Pixel offset for smooth scrolling
    local pixel_offset_x = math.floor((self.center_x - start_tile_x - 0.5) * tile_w - w / 2)
    local pixel_offset_y = math.floor((self.center_y - start_tile_y - 0.5) * tile_h - h / 2)

    -- Max tile index at current zoom
    local max_tile = 2 ^ self.zoom - 1

    -- Draw tiles
    for ty = 0, tiles_y - 1 do
        for tx = 0, tiles_x - 1 do
            local tile_x = start_tile_x + tx
            local tile_y = start_tile_y + ty

            -- Screen position for this tile
            local screen_x = tx * tile_w - pixel_offset_x
            local screen_y = ty * tile_h - pixel_offset_y

            -- Skip if tile is completely off screen
            if screen_x + tile_w < 0 or screen_x >= w or
               screen_y + tile_h < 0 or screen_y >= h then
                goto continue
            end

            -- Check bounds
            if tile_x < 0 or tile_x > max_tile or
               tile_y < 0 or tile_y > max_tile then
                -- Draw placeholder for out-of-bounds
                display.fill_rect(
                    math.max(0, screen_x),
                    math.max(0, screen_y),
                    math.min(tile_w, w - screen_x),
                    math.min(tile_h, h - screen_y),
                    colors.DARK_GRAY
                )
                goto continue
            end

            -- Get tile data
            local tile_data = self:get_tile(self.zoom, tile_x, tile_y)

            if tile_data then
                -- Draw tile using indexed bitmap function
                display.draw_indexed_bitmap(
                    screen_x, screen_y,
                    tile_w, tile_h,
                    tile_data,
                    self.archive.palette
                )
            else
                -- Draw placeholder for missing tile
                display.fill_rect(
                    math.max(0, screen_x),
                    math.max(0, screen_y),
                    math.min(tile_w, w - screen_x),
                    math.min(tile_h, h - screen_y),
                    0x2104  -- Dark gray
                )
                -- Draw X pattern
                display.draw_line(screen_x, screen_y, screen_x + tile_w, screen_y + tile_h, 0x4208)
                display.draw_line(screen_x + tile_w, screen_y, screen_x, screen_y + tile_h, 0x4208)
            end

            ::continue::
        end
    end

    -- Draw UI overlay
    self:draw_overlay(display, colors)
end

function MapViewer:draw_overlay(display, colors)
    local w = self.SCREEN_W
    local h = self.SCREEN_H

    -- Semi-transparent info bar at top
    display.fill_rect(0, 0, w, 18, 0x0000)

    -- Zoom indicator
    display.set_font_size("small")
    local zoom_text = string.format("Z%d", self.zoom)
    display.draw_text(4, 2, zoom_text, colors.CYAN)

    -- Coordinates
    local lat, lon = self:tile_to_lat_lon(self.center_x, self.center_y, self.zoom)
    local coord_text = string.format("%.4f, %.4f", lat, lon)
    display.draw_text(40, 2, coord_text, colors.WHITE)

    -- Controls hint at bottom
    display.fill_rect(0, h - 16, w, 16, 0x0000)
    display.draw_text(4, h - 14, "Pan: Arrows  Zoom: +/-  ESC: Back", colors.DARK_GRAY)
end

function MapViewer:handle_key(key)
    if key.special == "ESC" then
        ScreenManager.pop()
        return "continue"
    end

    if not self.archive then
        return "continue"
    end

    local pan_speed = 0.5  -- Tile units per keypress

    -- Pan controls
    if key.special == "UP" then
        self.center_y = self.center_y - pan_speed
        self:clamp_position()
        ScreenManager.invalidate()
    elseif key.special == "DOWN" then
        self.center_y = self.center_y + pan_speed
        self:clamp_position()
        ScreenManager.invalidate()
    elseif key.special == "LEFT" then
        self.center_x = self.center_x - pan_speed
        self:clamp_position()
        ScreenManager.invalidate()
    elseif key.special == "RIGHT" then
        self.center_x = self.center_x + pan_speed
        self:clamp_position()
        ScreenManager.invalidate()

    -- Zoom controls
    elseif key.character == "+" or key.character == "=" then
        self:zoom_in()
    elseif key.character == "-" or key.character == "_" then
        self:zoom_out()

    -- Quick jump to specific locations
    elseif key.character == "h" or key.character == "H" then
        -- Home: Amsterdam
        self:center_on(52.37, 4.90)
    end

    return "continue"
end

function MapViewer:zoom_in()
    if self.zoom < self.archive.max_zoom then
        -- Convert position to new zoom level
        self.center_x = self.center_x * 2
        self.center_y = self.center_y * 2
        self.zoom = self.zoom + 1
        self:clamp_position()
        -- Clear cache since zoom changed
        self.tile_cache = {}
        self.cache_order = {}
        ScreenManager.invalidate()
    end
end

function MapViewer:zoom_out()
    if self.zoom > self.archive.min_zoom then
        -- Convert position to new zoom level
        self.center_x = self.center_x / 2
        self.center_y = self.center_y / 2
        self.zoom = self.zoom - 1
        self:clamp_position()
        -- Clear cache since zoom changed
        self.tile_cache = {}
        self.cache_order = {}
        ScreenManager.invalidate()
    end
end

function MapViewer:clamp_position()
    local max_tile = 2 ^ self.zoom
    self.center_x = math.max(0, math.min(max_tile, self.center_x))
    self.center_y = math.max(0, math.min(max_tile, self.center_y))
end

return MapViewer
