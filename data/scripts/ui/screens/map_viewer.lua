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

    -- Archive file path (on SD card)
    archive_path = "/sd/maps/world.tdmap",

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

    -- Tile cache (LRU - stores indexed data at ~24KB per tile)
    -- Cache size tuned for PSRAM: 16 tiles × 24KB = ~384KB
    -- Increased from 6 to reduce cache churn during panning
    tile_cache = {},       -- key -> {data=tile_data, access=counter, zoom=z}
    cache_counter = 0,     -- Incremented on each access for LRU tracking
    MAX_CACHE = 16,        -- 4x4 grid - allows smooth panning with margin

    -- Pending async tile loads (to avoid duplicate requests)
    pending_tiles = {},
    MAX_PENDING = 4,  -- Increased from 2 for faster tile loading

    -- Pan direction tracking for prefetching
    last_center_x = 0,
    last_center_y = 0,
    pan_dx = 0,  -- Pan velocity for prefetch direction
    pan_dy = 0,

    -- Debug counter for tile searches
    _search_count = 0,

    -- Cache for tiles confirmed not in archive (cleared on zoom change)
    missing_tiles = {},

    -- Error state
    error_msg = nil,

    -- Pan speed (tile units per keypress, lower = slower)
    pan_speed = 0.1,

    -- Feature indices (must match generator)
    F_LAND = 0,
    F_WATER = 1,
    F_PARK = 2,
    F_BUILDING = 3,
    F_ROAD_MINOR = 4,
    F_ROAD_MAJOR = 5,
    F_ROAD_HIGHWAY = 6,
    F_RAILWAY = 7,

    -- Theme setting ("light" or "dark")
    theme = "light",

    -- TDMAP format constants
    HEADER_SIZE = 33,  -- 6+1+1+2+1+4+4+4+1+1+4+4 = 33 bytes
    PALETTE_SIZE = 16,
    INDEX_ENTRY_SIZE = 11,
    LABEL_HEADER_SIZE = 10,  -- Fixed part of label entry (before text)

    -- Label type constants (match Python config.py)
    LABEL_TYPE_CITY = 0,
    LABEL_TYPE_TOWN = 1,
    LABEL_TYPE_VILLAGE = 2,
    LABEL_TYPE_SUBURB = 3,
    LABEL_TYPE_ROAD = 4,
    LABEL_TYPE_WATER = 5,

    -- Label index (v3: per-tile index for lazy loading)
    -- Note: zoom_min in index is actually extraction_zoom (tile coordinate level)
    -- Each label has its own zoom_min for visibility filtering
    label_index = nil,  -- Array of { zoom_min (=extraction_zoom), tile_x, tile_y, offset, count }
    label_index_offset = 0,
    label_index_count = 0,

    -- Label cache (per-tile, keyed by "zoom/x/y")
    label_cache = {},
    label_cache_order = {},
    MAX_LABEL_CACHE = 24,  -- Larger cache to reduce SD reads

    -- Show labels toggle
    show_labels = true,
}

-- Semantic color palettes (RGB565 values)
-- Tiles store feature indices, we map to colors here
local function rgb565(r, g, b)
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
end

local PALETTES = {
    light = {
        [0] = rgb565(255, 255, 255),  -- Land - white
        [1] = rgb565(160, 208, 240),  -- Water - light blue
        [2] = rgb565(200, 230, 200),  -- Park - light green
        [3] = rgb565(208, 208, 208),  -- Building - light gray
        [4] = rgb565(136, 136, 136),  -- Road minor - medium gray
        [5] = rgb565(96, 96, 96),     -- Road major - dark gray
        [6] = rgb565(64, 64, 64),     -- Highway - darker gray
        [7] = rgb565(48, 48, 48),     -- Railway - near black
    },
    dark = {
        [0] = rgb565(26, 26, 46),     -- Land - dark blue-gray
        [1] = rgb565(10, 32, 64),     -- Water - dark blue
        [2] = rgb565(26, 42, 26),     -- Park - dark green
        [3] = rgb565(42, 42, 62),     -- Building - medium dark
        [4] = rgb565(80, 80, 96),     -- Road minor - medium gray
        [5] = rgb565(112, 112, 128),  -- Road major - lighter gray
        [6] = rgb565(144, 144, 160),  -- Highway - light gray
        [7] = rgb565(96, 96, 112),    -- Railway - medium
    },
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
        cache_counter = 0,
        pending_tiles = {},
        missing_tiles = {},
        error_msg = nil,
        pan_speed = 0.1,
        theme = "light",
        loading = false,
        last_center_x = 0,
        last_center_y = 0,
        pan_dx = 0,
        pan_dy = 0,
        label_index = nil,
        label_index_offset = 0,
        label_index_count = 0,
        label_cache = {},
        label_cache_order = {},
        show_labels = true,
    }
    setmetatable(o, {__index = MapViewer})
    return o
end

-- Convert byte array (table) to binary string
-- Needed because Wasmoon truncates strings at null bytes
local function bytes_to_string(bytes)
    if type(bytes) == "string" then
        return bytes  -- Already a string (native platform)
    end
    if type(bytes) ~= "table" then
        -- Handle userdata with array-like access (Wasmoon JS arrays)
        if type(bytes) == "userdata" then
            local len = bytes.length or #bytes
            if len and len > 0 then
                local chunks = {}
                local chunk_size = 4096
                -- Wasmoon converts JS arrays to 1-indexed Lua access
                -- Detect by checking if [0] is nil but [1] has a value
                local start_idx = 0
                if bytes[0] == nil and bytes[1] ~= nil then
                    start_idx = 1  -- 1-indexed (Wasmoon)
                end
                for i = start_idx, start_idx + len - 1, chunk_size do
                    local chunk_end = math.min(i + chunk_size - 1, start_idx + len - 1)
                    local chunk_bytes = {}
                    for j = i, chunk_end do
                        local b = bytes[j]
                        -- IMPORTANT: Use type check since 0 is a valid byte value
                        -- but Wasmoon might convert JS 0 to something falsy
                        if type(b) == "number" then
                            chunk_bytes[#chunk_bytes + 1] = b
                        elseif b == nil then
                            -- Skip nil values (missing array elements)
                        else
                            -- Unexpected type - try to convert or skip
                            local num = tonumber(b)
                            if num then
                                chunk_bytes[#chunk_bytes + 1] = num
                            end
                        end
                    end
                    if #chunk_bytes > 0 then
                        chunks[#chunks + 1] = string.char(table.unpack(chunk_bytes))
                    end
                end
                return table.concat(chunks)
            end
        end
        return nil
    end
    -- Convert table of byte values to string using string.char
    -- Process in chunks to avoid stack overflow with large arrays
    local chunks = {}
    local chunk_size = 4096
    for i = 1, #bytes, chunk_size do
        local chunk_end = math.min(i + chunk_size - 1, #bytes)
        local chunk_bytes = {}
        for j = i, chunk_end do
            chunk_bytes[#chunk_bytes + 1] = bytes[j]
        end
        chunks[#chunks + 1] = string.char(table.unpack(chunk_bytes))
    end
    return table.concat(chunks)
end

-- Parse little-endian integers from binary string
local function read_u8(data, offset)
    return string.byte(data, offset + 1) or 0
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

-- Async archive loading (runs in coroutine)
function MapViewer:load_archive_async()
    local self_ref = self

    local function do_load()
        -- Check if archive exists
        if not tdeck.storage.exists(self_ref.archive_path) then
            if _G.StatusBar then _G.StatusBar.hide_loading() end
            self_ref.error_msg = "Map file not found:\n" .. self_ref.archive_path
            self_ref.loading = false
            ScreenManager.invalidate()
            return
        end

        -- Read header asynchronously (32 bytes)
        local header = bytes_to_string(async_read_bytes(self_ref.archive_path, 0, self_ref.HEADER_SIZE))
        if not header then
            if _G.StatusBar then _G.StatusBar.hide_loading() end
            self_ref.error_msg = "Failed to read map header"
            self_ref.loading = false
            ScreenManager.invalidate()
            return
        end

        -- Debug: show header info
        print("[Map] Header length: " .. #header)
        local hex = ""
        for i = 1, math.min(15, #header) do
            hex = hex .. string.format("%02X ", string.byte(header, i))
        end
        print("[Map] Header bytes: " .. hex)

        -- Verify magic (compare first 5 chars without null - more reliable across platforms)
        local magic = string.sub(header, 1, 5)
        if magic ~= "TDMAP" then
            if _G.StatusBar then _G.StatusBar.hide_loading() end
            -- Debug: show what we actually got
            local hex = ""
            for i = 1, math.min(10, #header) do
                hex = hex .. string.format("%02X ", string.byte(header, i))
            end
            print("[Map] Magic check failed. Got: " .. hex)
            self_ref.error_msg = "Invalid map file format"
            self_ref.loading = false
            ScreenManager.invalidate()
            return
        end

        -- Parse header fields
        local version = read_u8(header, 6)
        local tile_size = read_u16(header, 8)
        local tile_count = read_u32(header, 11)
        local index_offset = read_u32(header, 15)
        local data_offset = read_u32(header, 19)
        local min_zoom = read_i8(header, 23)
        local max_zoom = read_i8(header, 24)

        -- v2/v3 fields (labels)
        local label_index_offset = 0
        local label_index_count = 0
        if version >= 2 then
            label_index_offset = read_u32(header, 25)
            label_index_count = read_u32(header, 29)
        end

        if version ~= 1 and version ~= 2 and version ~= 3 then
            if _G.StatusBar then _G.StatusBar.hide_loading() end
            self_ref.error_msg = "Unsupported map version: " .. version
            self_ref.loading = false
            ScreenManager.invalidate()
            return
        end

        -- Use semantic palette based on theme (ignore palette in file)
        local palette = PALETTES[self_ref.theme] or PALETTES.light
        -- Convert to 1-indexed array for draw_indexed_bitmap
        local palette_array = {}
        for i = 0, 7 do
            palette_array[i + 1] = palette[i]
        end

        self_ref.archive = {
            path = self_ref.archive_path,
            version = version,
            tile_count = tile_count,
            index_offset = index_offset,
            data_offset = data_offset,
            min_zoom = min_zoom,
            max_zoom = max_zoom,
            palette = palette_array,
            tile_size = tile_size,
            label_index_offset = label_index_offset,
            label_index_count = label_index_count,
        }

        print(string.format("[Map] Loaded archive: v%d, %d tiles, zoom %d-%d, index@%d, data@%d, tile_size=%d",
            version, tile_count, min_zoom, max_zoom, index_offset, data_offset, tile_size))

        -- Load tile index into memory for fast binary search (avoids SD reads per tile lookup)
        -- Index size: 11 bytes per tile, typically 5-50KB total
        local index_size = tile_count * self_ref.INDEX_ENTRY_SIZE
        print(string.format("[Map] Loading tile index: %d tiles, %d bytes", tile_count, index_size))

        local index_data = bytes_to_string(async_read_bytes(self_ref.archive_path, index_offset, index_size))
        if index_data and #index_data >= index_size then
            -- Parse index into memory table for fast lookup
            self_ref.tile_index = {}
            for i = 0, tile_count - 1 do
                local offset = i * self_ref.INDEX_ENTRY_SIZE
                local z = read_u8(index_data, offset)
                local x = read_u16(index_data, offset + 1)
                local y = read_u16(index_data, offset + 3)
                local data_offset = read_u32(index_data, offset + 5)
                local data_size = read_u16(index_data, offset + 9)
                -- Store with composite key for O(1) lookup
                local key = string.format("%d/%d/%d", z, x, y)
                self_ref.tile_index[key] = { offset = data_offset, size = data_size }
            end
            print(string.format("[Map] Tile index loaded: %d entries", tile_count))
        else
            print("[Map] Warning: Failed to load tile index, falling back to lazy loading")
            self_ref.tile_index = nil
        end

        -- Load label index if present (v3) or all labels (v2)
        print(string.format("[Map] Label info: version=%d count=%d offset=%d", version, label_index_count, label_index_offset))
        if label_index_count > 0 and label_index_offset > 0 then
            if version >= 3 then
                self_ref:load_label_index_async(label_index_offset, label_index_count)
            else
                -- v2: load all labels (legacy, memory-intensive)
                self_ref:load_labels_v2_async(label_index_offset, label_index_count)
            end
        end

        -- Set initial view
        local mid_zoom = math.floor((min_zoom + max_zoom) / 2)
        self_ref.zoom = math.max(min_zoom, math.min(mid_zoom, max_zoom))

        local lat, lon = 52.63, 4.75
        self_ref.center_x, self_ref.center_y = self_ref:lat_lon_to_tile(lat, lon, self_ref.zoom)

        -- Done loading
        if _G.StatusBar then _G.StatusBar.hide_loading() end
        self_ref.loading = false
        ScreenManager.invalidate()
    end

    -- Start coroutine
    spawn(do_load)
end

-- Load label index from archive asynchronously (v3 format)
-- Only loads the index (small), labels are loaded per-tile on demand
function MapViewer:load_label_index_async(index_offset, index_count)
    local self_ref = self

    local function do_load_index()
        -- Label index entry size: 11 bytes (zoom_min:1 + tile_x:2 + tile_y:2 + offset:4 + count:2)
        local index_size = index_count * 11
        local index_data = bytes_to_string(async_read_bytes(self_ref.archive_path, index_offset, index_size))
        if not index_data then
            return
        end

        self_ref.label_index = {}
        local offset = 0

        for i = 1, index_count do
            if offset + 11 > #index_data then
                break
            end

            local zoom_min = read_u8(index_data, offset)
            local tile_x = read_u16(index_data, offset + 1)
            local tile_y = read_u16(index_data, offset + 3)
            local label_offset = read_u32(index_data, offset + 5)
            local label_count = read_u16(index_data, offset + 9)

            table.insert(self_ref.label_index, {
                zoom_min = zoom_min,
                tile_x = tile_x,
                tile_y = tile_y,
                offset = label_offset,
                count = label_count,
            })

            offset = offset + 11
        end

        ScreenManager.invalidate()
    end

    spawn(do_load_index)
end

-- Load labels for a specific tile (v3 format, lazy loading)
-- Index uses extraction_zoom (tile coordinate level), labels have zoom_min for visibility
function MapViewer:load_labels_for_tile(extraction_zoom, tile_x, tile_y)
    if not self.label_index then return nil end

    local key = string.format("%d/%d/%d", extraction_zoom, tile_x, tile_y)

    -- Check cache first
    if self.label_cache[key] then
        return self.label_cache[key]
    end

    -- Binary search for tile in label index (indexed by extraction_zoom)
    local lo, hi = 1, #self.label_index
    local target_key = extraction_zoom * 0x100000000 + tile_x * 0x10000 + tile_y
    local index_entry = nil

    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local entry = self.label_index[mid]
        -- Note: entry.zoom_min is actually extraction_zoom in the new format
        local entry_key = entry.zoom_min * 0x100000000 + entry.tile_x * 0x10000 + entry.tile_y

        if entry_key == target_key then
            index_entry = entry
            break
        elseif entry_key < target_key then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    if not index_entry then
        -- No labels for this tile, cache empty result
        self.label_cache[key] = {}
        return {}
    end

    -- Read labels synchronously (small read, fast)
    -- New v3 format: pixel_x:1 + pixel_y:1 + zoom_min:1 + zoom_max:1 + label_type:1 + text_len:1 + text
    local estimated_size = index_entry.count * 25  -- ~25 bytes avg per label
    local label_data = bytes_to_string(tdeck.storage.read_bytes(self.archive_path, index_entry.offset, estimated_size))
    if not label_data then
        return {}
    end

    local labels = {}
    local offset = 0

    for i = 1, index_entry.count do
        if offset + 6 > #label_data then
            break
        end

        local pixel_x = read_u8(label_data, offset)
        local pixel_y = read_u8(label_data, offset + 1)
        local zoom_min = read_u8(label_data, offset + 2)  -- Visibility threshold
        local zoom_max = read_u8(label_data, offset + 3)
        local label_type = read_u8(label_data, offset + 4)
        local text_len = read_u8(label_data, offset + 5)

        if offset + 6 + text_len > #label_data then
            break
        end

        local text = string.sub(label_data, offset + 7, offset + 6 + text_len)

        table.insert(labels, {
            zoom_min = zoom_min,
            zoom_max = zoom_max,
            tile_x = tile_x,
            tile_y = tile_y,
            pixel_x = pixel_x,
            pixel_y = pixel_y,
            label_type = label_type,
            text = text,
            extraction_zoom = extraction_zoom,
        })

        offset = offset + 6 + text_len
    end

    -- Add to cache
    self.label_cache[key] = labels
    table.insert(self.label_cache_order, key)

    -- Evict oldest if cache full
    while #self.label_cache_order > self.MAX_LABEL_CACHE do
        local old_key = table.remove(self.label_cache_order, 1)
        self.label_cache[old_key] = nil
    end

    return labels
end

-- Load all labels from archive (v2 legacy format, memory-intensive)
function MapViewer:load_labels_v2_async(labels_offset, labels_count)
    local self_ref = self

    local function do_load_labels()
        -- Estimate max label data size (rough: 30 bytes avg per label)
        local estimated_size = labels_count * 30
        local labels_data = bytes_to_string(async_read_bytes(self_ref.archive_path, labels_offset, estimated_size))
        if not labels_data then
            return
        end

        -- For v2, we store labels in label_cache with a special key
        self_ref.label_index = {{zoom_min = 0, tile_x = 0, tile_y = 0, count = labels_count}}
        local all_labels = {}
        local offset = 0

        for i = 1, labels_count do
            if offset + 10 > #labels_data then
                break
            end

            local zoom_min = read_u8(labels_data, offset)
            local zoom_max = read_u8(labels_data, offset + 1)
            local tile_x = read_u16(labels_data, offset + 2)
            local tile_y = read_u16(labels_data, offset + 4)
            local pixel_x = read_u8(labels_data, offset + 6)
            local pixel_y = read_u8(labels_data, offset + 7)
            local label_type = read_u8(labels_data, offset + 8)
            local text_len = read_u8(labels_data, offset + 9)

            if offset + 10 + text_len > #labels_data then
                break
            end

            local text = string.sub(labels_data, offset + 11, offset + 10 + text_len)

            table.insert(all_labels, {
                zoom_min = zoom_min,
                zoom_max = zoom_max,
                tile_x = tile_x,
                tile_y = tile_y,
                pixel_x = pixel_x,
                pixel_y = pixel_y,
                label_type = label_type,
                text = text,
            })

            offset = offset + 10 + text_len
        end

        -- Store as special "all" cache entry for v2 compatibility
        self_ref.label_cache["v2_all"] = all_labels

        ScreenManager.invalidate()
    end

    spawn(do_load_labels)
end

-- Get labels visible at current zoom and position
-- Optimized to check fewer zoom levels and exit early
function MapViewer:get_visible_labels(start_tile_x, start_tile_y, tiles_x, tiles_y)
    if not self.label_index or not self.show_labels then
        return {}
    end

    local visible = {}
    local zoom = self.zoom

    -- v2 legacy: all labels in one cache entry
    if self.label_cache["v2_all"] then
        for _, label in ipairs(self.label_cache["v2_all"]) do
            if zoom >= label.zoom_min and zoom <= label.zoom_max then
                local zoom_diff = zoom - label.zoom_min
                local scale = 2 ^ zoom_diff
                local full_x = (label.tile_x + label.pixel_x / 256) * scale
                local full_y = (label.tile_y + label.pixel_y / 256) * scale
                local tile_x = math.floor(full_x)
                local tile_y = math.floor(full_y)

                if tile_x >= start_tile_x and tile_x < start_tile_x + tiles_x and
                   tile_y >= start_tile_y and tile_y < start_tile_y + tiles_y then
                    local px = (full_x - tile_x) * 256
                    local py = (full_y - tile_y) * 256

                    table.insert(visible, {
                        tile_x = tile_x,
                        tile_y = tile_y,
                        pixel_x = px,
                        pixel_y = py,
                        label_type = label.label_type,
                        text = label.text,
                    })
                end
            end
        end
        return visible
    end

    -- v3: load labels per-tile lazily
    -- Optimization: only check 2-3 most relevant zoom levels instead of all
    local seen = {}
    local min_data_zoom = self.archive.min_zoom
    local max_data_zoom = self.archive.max_zoom

    -- Priority order: current zoom first, then parents (most labels are at current or near zoom)
    local zoom_levels = {}
    for z = math.min(max_data_zoom, zoom), min_data_zoom, -1 do
        table.insert(zoom_levels, z)
        -- Limit to 4 zoom levels to reduce SD reads
        if #zoom_levels >= 4 then break end
    end

    for _, check_zoom in ipairs(zoom_levels) do
        local zoom_diff = zoom - check_zoom
        local scale = 2 ^ zoom_diff

        local src_start_x = math.floor(start_tile_x / scale)
        local src_start_y = math.floor(start_tile_y / scale)
        local src_end_x = math.floor((start_tile_x + tiles_x - 1) / scale)
        local src_end_y = math.floor((start_tile_y + tiles_y - 1) / scale)

        for src_x = src_start_x, src_end_x do
            for src_y = src_start_y, src_end_y do
                local labels = self:load_labels_for_tile(check_zoom, src_x, src_y)
                if labels then
                    for _, label in ipairs(labels) do
                        if zoom >= label.zoom_min and zoom <= label.zoom_max then
                            local full_x = (label.tile_x + label.pixel_x / 256) * scale
                            local full_y = (label.tile_y + label.pixel_y / 256) * scale
                            local tile_x = math.floor(full_x)
                            local tile_y = math.floor(full_y)

                            if tile_x >= start_tile_x and tile_x < start_tile_x + tiles_x and
                               tile_y >= start_tile_y and tile_y < start_tile_y + tiles_y then
                                local px = (full_x - tile_x) * 256
                                local py = (full_y - tile_y) * 256

                                local key = label.text
                                if not seen[key] then
                                    seen[key] = true
                                    table.insert(visible, {
                                        tile_x = tile_x,
                                        tile_y = tile_y,
                                        pixel_x = px,
                                        pixel_y = py,
                                        label_type = label.label_type,
                                        text = label.text,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return visible
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
    -- Reset pan tracking
    self.last_center_x = self.center_x
    self.last_center_y = self.center_y
    self.pan_dx = 0
    self.pan_dy = 0
    -- Clear tile cache but keep parent tiles for fallback
    self:prune_cache_for_zoom(self.zoom)
    self.pending_tiles = {}
    self.label_cache = {}
    self.label_cache_order = {}
    ScreenManager.invalidate()
end

-- Count pending tile loads
function MapViewer:count_pending()
    local count = 0
    for _ in pairs(self.pending_tiles) do
        count = count + 1
    end
    return count
end

-- Start async tile load (runs in coroutine)
-- Uses in-memory tile index for O(1) lookup, only does I/O for tile data
-- Now uses async_rle_read_rgb565 to get pre-decoded RGB565 data for faster drawing
function MapViewer:start_async_tile_load(key, zoom, x, y)
    local self_ref = self

    local function do_load()
        -- Look up tile in memory index (O(1) hash table lookup)
        local entry = nil
        if self_ref.tile_index then
            entry = self_ref.tile_index[key]
        end

        -- Remove from pending
        self_ref.pending_tiles[key] = nil

        if not entry then
            -- Tile not in index, cache as missing
            self_ref.missing_tiles[key] = true
            return
        end

        -- Read and decompress tile data
        -- Use indexed path (24KB) instead of RGB565 (128KB) to reduce memory pressure
        -- The draw_indexed_bitmap function has PSRAM optimization for fast rendering
        local tile_data = async_rle_read(self_ref.archive_path, entry.offset, entry.size)

        if not tile_data then
            return
        end

        -- Add to cache with access counter
        self_ref.cache_counter = self_ref.cache_counter + 1
        self_ref.tile_cache[key] = {
            data = tile_data,
            access = self_ref.cache_counter
        }

        -- Evict least recently used if cache full
        local cache_size = 0
        for _ in pairs(self_ref.tile_cache) do cache_size = cache_size + 1 end

        while cache_size > self_ref.MAX_CACHE do
            -- Find entry with lowest access counter
            local oldest_key = nil
            local oldest_access = math.huge
            for k, v in pairs(self_ref.tile_cache) do
                if v.access < oldest_access then
                    oldest_access = v.access
                    oldest_key = k
                end
            end
            if oldest_key then
                self_ref.tile_cache[oldest_key] = nil
                cache_size = cache_size - 1
            else
                break
            end
        end

        -- Trigger screen refresh to show the loaded tile
        ScreenManager.invalidate()
    end

    -- Start coroutine for async tile load
    local co = spawn(do_load)
    -- In simulator mode, spawn returns nil (runs synchronously)
    -- On real hardware, check if coroutine finished with error
    if co and coroutine.status(co) == "dead" then
        -- Coroutine finished with error, clean up pending state
        self.pending_tiles[key] = nil
    end
end

-- Get parent tile data for fallback rendering
-- Returns {data, src_x, src_y, scale} if a parent tile is cached, nil otherwise
function MapViewer:get_parent_tile_fallback(zoom, x, y)
    if zoom <= self.archive.min_zoom then
        return nil
    end

    -- Check up to 3 zoom levels up for a cached parent
    for dz = 1, 3 do
        local parent_zoom = zoom - dz
        if parent_zoom < self.archive.min_zoom then
            break
        end

        local scale = 2 ^ dz
        local parent_x = math.floor(x / scale)
        local parent_y = math.floor(y / scale)
        local key = string.format("%d/%d/%d", parent_zoom, parent_x, parent_y)

        local entry = self.tile_cache[key]
        if entry then
            -- Calculate which portion of parent tile to use
            local src_x = (x % scale) / scale  -- 0.0 to 1.0 position within parent
            local src_y = (y % scale) / scale
            return {
                data = entry.data,
                src_x = src_x,
                src_y = src_y,
                scale = scale,
                zoom = parent_zoom,
            }
        end
    end
    return nil
end

-- Get tile data (with caching and async loading)
-- Returns tile data if cached, nil if loading/missing
function MapViewer:get_tile(zoom, x, y)
    -- Create cache key
    local key = string.format("%d/%d/%d", zoom, x, y)

    -- Check tile cache (O(1) lookup with counter-based LRU)
    local entry = self.tile_cache[key]
    if entry then
        -- Update access counter for LRU tracking
        self.cache_counter = self.cache_counter + 1
        entry.access = self.cache_counter
        return entry.data
    end

    -- Check if known missing (not in archive)
    if self.missing_tiles[key] then
        return nil
    end

    -- Check if already loading
    if self.pending_tiles[key] then
        return nil
    end

    -- Limit concurrent loads to keep UI responsive
    local pending_count = self:count_pending()
    if pending_count >= self.MAX_PENDING then
        return nil
    end

    -- Check if tile exists in index before starting load
    if not self.tile_index then
        return nil
    end

    local index_entry = self.tile_index[key]
    if not index_entry then
        self.missing_tiles[key] = true
        return nil
    end

    -- Mark as pending and start async load
    self.pending_tiles[key] = true
    self:start_async_tile_load(key, zoom, x, y)

    return nil
end

function MapViewer:on_enter()
    tdeck.keyboard.set_mode("normal")

    -- Initialize pan tracking
    self.last_center_x = self.center_x
    self.last_center_y = self.center_y
    self.pan_dx = 0
    self.pan_dy = 0

    -- Load preferences
    local old_theme = self.theme
    if tdeck.storage and tdeck.storage.get_pref then
        self.theme = tdeck.storage.get_pref("mapTheme", "light")
        -- Pan speed: 1-5 setting maps to 0.05-0.25 tile units
        local speed_setting = tdeck.storage.get_pref("mapPanSpeed", 2)
        self.pan_speed = speed_setting * 0.05
    end

    -- Reload archive if theme changed (to update palette)
    if self.archive and old_theme ~= self.theme then
        -- Update palette without reloading entire archive
        local palette = PALETTES[self.theme] or PALETTES.light
        local palette_array = {}
        for i = 0, 7 do
            palette_array[i + 1] = palette[i]
        end
        self.archive.palette = palette_array
        -- Clear tile cache since RGB565 colors are baked in
        self.tile_cache = {}
        self.cache_counter = 0
        self.pending_tiles = {}
    end

    if not self.archive and not self.loading then
        self.loading = true
        if _G.StatusBar then _G.StatusBar.show_loading("Loading map...") end
        self:load_archive_async()
    end
end

function MapViewer:on_leave()
    -- Clear all caches to free memory
    self.tile_cache = {}
    self.cache_counter = 0
    self.pending_tiles = {}
    self.missing_tiles = {}
    self.label_cache = {}
    self.label_cache_order = {}
    run_gc("collect", "map-cache-clear")
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
        display.draw_text_centered(h / 2 - 20, "Map Error", colors.ERROR)
        display.draw_text_centered(h / 2, self.error_msg, colors.WHITE)
        display.draw_text_centered(h / 2 + 30, "Press ESC to go back", colors.TEXT_MUTED)
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
    -- center_x/center_y should map exactly to screen center (w/2, h/2)
    local pixel_offset_x = math.floor((self.center_x - start_tile_x) * tile_w - w / 2)
    local pixel_offset_y = math.floor((self.center_y - start_tile_y) * tile_h - h / 2)

    -- Max tile index at current zoom
    local max_tile = 2 ^ self.zoom - 1

    -- Track pan direction for prefetching
    local dx = self.center_x - self.last_center_x
    local dy = self.center_y - self.last_center_y
    if dx ~= 0 or dy ~= 0 then
        self.pan_dx = dx
        self.pan_dy = dy
    end
    self.last_center_x = self.center_x
    self.last_center_y = self.center_y

    -- Screen center in tile grid coordinates
    local screen_center_tx = (tiles_x - 1) / 2
    local screen_center_ty = (tiles_y - 1) / 2

    -- Collect all visible tiles with distance from center for priority loading
    local visible_tiles = {}
    for ty = 0, tiles_y - 1 do
        for tx = 0, tiles_x - 1 do
            local tile_x = start_tile_x + tx
            local tile_y = start_tile_y + ty
            local screen_x = tx * tile_w - pixel_offset_x
            local screen_y = ty * tile_h - pixel_offset_y

            -- Skip if completely off screen
            if screen_x + tile_w >= 0 and screen_x < w and
               screen_y + tile_h >= 0 and screen_y < h then
                -- Distance from screen center (for priority)
                local dx = tx - screen_center_tx
                local dy = ty - screen_center_ty
                local dist = dx * dx + dy * dy

                table.insert(visible_tiles, {
                    tx = tx, ty = ty,
                    tile_x = tile_x, tile_y = tile_y,
                    screen_x = screen_x, screen_y = screen_y,
                    dist = dist
                })
            end
        end
    end

    -- Sort by distance from center (closest first for priority loading)
    table.sort(visible_tiles, function(a, b) return a.dist < b.dist end)

    -- Request tiles in priority order (center first)
    for _, t in ipairs(visible_tiles) do
        if t.tile_x >= 0 and t.tile_x <= max_tile and
           t.tile_y >= 0 and t.tile_y <= max_tile then
            -- This triggers async load if not cached
            self:get_tile(self.zoom, t.tile_x, t.tile_y)
        end
    end

    -- Prefetch tiles in pan direction (1-2 tiles ahead)
    if (self.pan_dx ~= 0 or self.pan_dy ~= 0) and self:count_pending() < self.MAX_PENDING then
        local prefetch_dist = 2  -- Tiles ahead to prefetch
        local norm = math.sqrt(self.pan_dx * self.pan_dx + self.pan_dy * self.pan_dy)
        if norm > 0.001 then
            local dir_x = self.pan_dx / norm
            local dir_y = self.pan_dy / norm
            for d = 1, prefetch_dist do
                local px = math.floor(self.center_x + dir_x * d + 0.5)
                local py = math.floor(self.center_y + dir_y * d + 0.5)
                if px >= 0 and px <= max_tile and py >= 0 and py <= max_tile then
                    self:get_tile(self.zoom, px, py)
                end
            end
        end
    end

    -- Draw tiles (in any order, drawing is fast)
    for _, t in ipairs(visible_tiles) do
        local tile_x = t.tile_x
        local tile_y = t.tile_y
        local screen_x = t.screen_x
        local screen_y = t.screen_y

        -- Calculate clamped draw rectangle for partial tiles
        local draw_x = math.max(0, screen_x)
        local draw_y = math.max(0, screen_y)
        local draw_w = math.min(screen_x + tile_w, w) - draw_x
        local draw_h = math.min(screen_y + tile_h, h) - draw_y

        -- Only draw if there's a visible area
        if draw_w > 0 and draw_h > 0 then
            -- Check bounds
            if tile_x < 0 or tile_x > max_tile or
               tile_y < 0 or tile_y > max_tile then
                -- Draw placeholder for out-of-bounds
                display.fill_rect(draw_x, draw_y, draw_w, draw_h, colors.SURFACE)
            else
                -- Get tile data (already requested above, just check cache)
                local key = string.format("%d/%d/%d", self.zoom, tile_x, tile_y)
                local entry = self.tile_cache[key]
                local tile_data = entry and entry.data or nil

                if tile_data then
                    -- Draw tile using indexed bitmap with PSRAM-optimized conversion
                    local data_size = self.archive.tile_size or tile_w
                    display.draw_indexed_bitmap(
                        screen_x, screen_y,
                        data_size, data_size,
                        tile_data,
                        self.archive.palette
                    )
                else
                    -- Try to use parent tile as fallback (scaled up)
                    local fallback = self:get_parent_tile_fallback(self.zoom, tile_x, tile_y)
                    if fallback and display.draw_indexed_bitmap_scaled then
                        -- Draw scaled portion of parent tile
                        local data_size = self.archive.tile_size or tile_w
                        local src_size = math.floor(data_size / fallback.scale)
                        local src_x_px = math.floor(fallback.src_x * data_size)
                        local src_y_px = math.floor(fallback.src_y * data_size)
                        display.draw_indexed_bitmap_scaled(
                            screen_x, screen_y,
                            data_size, data_size,  -- dest size
                            fallback.data,
                            self.archive.palette,
                            src_x_px, src_y_px,    -- source offset
                            src_size, src_size     -- source size
                        )
                    elseif fallback then
                        -- Fallback without scaling support: show blurred placeholder
                        display.fill_rect(draw_x, draw_y, draw_w, draw_h, 0x4208)
                    else
                        -- No fallback: draw placeholder for loading/missing tile
                        display.fill_rect(draw_x, draw_y, draw_w, draw_h, 0x2104)
                        -- Draw X pattern for loading indicator (clipped by display)
                        display.draw_line(screen_x, screen_y, screen_x + tile_w, screen_y + tile_h, 0x4208)
                        display.draw_line(screen_x + tile_w, screen_y, screen_x, screen_y + tile_h, 0x4208)
                    end
                end
            end
        end
    end

    -- Draw labels (v3 uses label_index, v2 uses label_cache["v2_all"])
    if self.show_labels and (self.label_index or self.label_cache["v2_all"]) then
        self:draw_labels(display, colors, start_tile_x, start_tile_y, tiles_x, tiles_y, pixel_offset_x, pixel_offset_y)
    end

    -- Draw location markers (GPS and mesh nodes)
    self:draw_markers(display, colors, start_tile_x, start_tile_y, pixel_offset_x, pixel_offset_y)

    -- Draw UI overlay
    self:draw_overlay(display, colors)
end

-- Draw labels on the map
function MapViewer:draw_labels(display, colors, start_tile_x, start_tile_y, tiles_x, tiles_y, pixel_offset_x, pixel_offset_y)
    local tile_w = self.TILE_SIZE
    local tile_h = self.TILE_SIZE
    local w = self.SCREEN_W
    local h = self.SCREEN_H

    local visible_labels = self:get_visible_labels(start_tile_x, start_tile_y, tiles_x, tiles_y)

    -- Minimum zoom level required to show each label type
    local min_zoom_for_type = {
        [self.LABEL_TYPE_CITY] = 0,      -- Always visible
        [self.LABEL_TYPE_TOWN] = 4,      -- Show at zoom 4+
        [self.LABEL_TYPE_VILLAGE] = 7,   -- Show at zoom 7+
        [self.LABEL_TYPE_SUBURB] = 9,    -- Show at zoom 9+
        [self.LABEL_TYPE_ROAD] = 10,     -- Show at zoom 10+
        [self.LABEL_TYPE_WATER] = 5,     -- Show at zoom 5+
    }

    -- Screen center and radius for proximity filter
    local center_x = w / 2
    local center_y = h / 2
    local max_radius = h / 2  -- 120 pixels from center

    -- Collect and filter labels
    local candidates = {}
    display.set_font_size("small")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    for _, label in ipairs(visible_labels) do
        -- Zoom-based type filter
        local min_zoom = min_zoom_for_type[label.label_type] or 0
        if self.zoom >= min_zoom then
            local tx = label.tile_x - start_tile_x
            local ty = label.tile_y - start_tile_y
            local screen_x = tx * tile_w + label.pixel_x - pixel_offset_x
            local screen_y = ty * tile_h + label.pixel_y - pixel_offset_y

            -- Distance from center filter
            local dx = screen_x - center_x
            local dy = screen_y - center_y
            local dist = math.sqrt(dx * dx + dy * dy)

            if dist <= max_radius then
                table.insert(candidates, {
                    text = label.text,
                    x = math.floor(screen_x),
                    y = math.floor(screen_y),
                    w = #label.text * fw,
                    h = fh,
                    priority = label.label_type,
                    dist = dist,
                })
            end
        end
    end

    -- Sort by priority (lower = more important), then by distance
    table.sort(candidates, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        return a.dist < b.dist
    end)

    -- Draw with occlusion detection
    local drawn_boxes = {}
    local function overlaps(x, y, w, h)
        for _, box in ipairs(drawn_boxes) do
            if not (x + w + 2 < box.x or x > box.x + box.w + 2 or
                    y + h + 1 < box.y or y > box.y + box.h + 1) then
                return true
            end
        end
        return false
    end

    local drawn = 0
    for _, c in ipairs(candidates) do
        if not overlaps(c.x, c.y, c.w, c.h) then
            display.draw_text(c.x, c.y, c.text, colors.WHITE)
            table.insert(drawn_boxes, {x = c.x, y = c.y, w = c.w, h = c.h})
            drawn = drawn + 1
        end
    end
end

-- Draw GPS location and mesh node markers on the map
function MapViewer:draw_markers(display, colors, start_tile_x, start_tile_y, pixel_offset_x, pixel_offset_y)
    local tile_w = self.TILE_SIZE
    local tile_h = self.TILE_SIZE
    local w = self.SCREEN_W
    local h = self.SCREEN_H

    -- Helper to convert lat/lon to screen position
    local function lat_lon_to_screen(lat, lon)
        local tile_x, tile_y = self:lat_lon_to_tile(lat, lon, self.zoom)
        local screen_x = (tile_x - start_tile_x) * tile_w - pixel_offset_x
        local screen_y = (tile_y - start_tile_y) * tile_h - pixel_offset_y
        return math.floor(screen_x), math.floor(screen_y)
    end

    -- Helper to draw a filled circle marker
    local function draw_marker(x, y, radius, color)
        -- Simple filled circle using rectangles
        for dy = -radius, radius do
            local dx = math.floor(math.sqrt(radius * radius - dy * dy))
            display.fill_rect(x - dx, y + dy, dx * 2 + 1, 1, color)
        end
    end

    -- Draw mesh node markers (blue dots for repeaters with location)
    if tdeck.mesh and tdeck.mesh.is_initialized and tdeck.mesh.is_initialized() then
        local nodes = tdeck.mesh.get_nodes() or {}
        -- Use mesh ROLE constants with fallback for simulator compatibility
        local ROLE = tdeck.mesh.ROLE or { CHAT = 1, REPEATER = 2, ROUTER = 3, GATEWAY = 4 }
        for _, node in ipairs(nodes) do
            -- Only draw repeaters/routers with valid location
            if node.has_location and node.lat and node.lon then
                local is_infrastructure = (node.role == ROLE.REPEATER or node.role == ROLE.ROUTER or node.role == ROLE.GATEWAY)
                if is_infrastructure then
                    local sx, sy = lat_lon_to_screen(node.lat, node.lon)
                    -- Only draw if on screen
                    if sx >= -5 and sx < w + 5 and sy >= -5 and sy < h + 5 then
                        draw_marker(sx, sy, 4, colors.INFO or 0x001F)  -- Blue
                        -- Small white center
                        display.fill_rect(sx - 1, sy - 1, 3, 3, colors.WHITE)
                    end
                end
            end
        end
    end

    -- Draw GPS location marker (green dot)
    if tdeck.gps and tdeck.gps.get_location then
        local loc = tdeck.gps.get_location()
        if loc and loc.valid and loc.lat and loc.lon then
            local sx, sy = lat_lon_to_screen(loc.lat, loc.lon)
            -- Only draw if on screen
            if sx >= -5 and sx < w + 5 and sy >= -5 and sy < h + 5 then
                draw_marker(sx, sy, 5, colors.SUCCESS or 0x07E0)  -- Green
                -- White center dot
                display.fill_rect(sx - 1, sy - 1, 3, 3, colors.WHITE)
            end
        end
    end
end

function MapViewer:draw_overlay(display, colors)
    local w = self.SCREEN_W
    local h = self.SCREEN_H

    -- Center crosshair/dot
    local cx = math.floor(w / 2)
    local cy = math.floor(h / 2)
    -- Draw small cross with dot in center
    display.fill_rect(cx - 1, cy - 1, 3, 3, colors.ACCENT)  -- Center dot
    display.draw_line(cx - 6, cy, cx - 2, cy, colors.WHITE)  -- Left arm
    display.draw_line(cx + 2, cy, cx + 6, cy, colors.WHITE)  -- Right arm
    display.draw_line(cx, cy - 6, cx, cy - 2, colors.WHITE)  -- Top arm
    display.draw_line(cx, cy + 2, cx, cy + 6, colors.WHITE)  -- Bottom arm

    -- Semi-transparent info bar at top
    display.fill_rect(0, 0, w, 18, 0x0000)

    -- Zoom indicator
    display.set_font_size("small")
    local zoom_text = string.format("Z%d", self.zoom)
    display.draw_text(4, 2, zoom_text, colors.ACCENT)

    -- Coordinates of center point
    local lat, lon = self:tile_to_lat_lon(self.center_x, self.center_y, self.zoom)
    local coord_text = string.format("%.4f, %.4f", lat, lon)
    display.draw_text(40, 2, coord_text, colors.WHITE)

    -- Labels indicator
    if self.label_index and #self.label_index > 0 then
        local labels_text = self.show_labels and "L" or "l"
        display.draw_text(w - 20, 2, labels_text, self.show_labels and colors.ACCENT or colors.TEXT_MUTED)
    end

    -- Controls hint at bottom
    display.fill_rect(0, h - 16, w, 16, 0x0000)
    display.draw_text(4, h - 14, "Arrows:Pan +/-:Zoom L:Labels ESC:Back", colors.TEXT_MUTED)
end

function MapViewer:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    if not self.archive then
        return "continue"
    end

    -- Pan controls
    if key.special == "UP" then
        self.center_y = self.center_y - self.pan_speed
        self:clamp_position()
        ScreenManager.invalidate()
    elseif key.special == "DOWN" then
        self.center_y = self.center_y + self.pan_speed
        self:clamp_position()
        ScreenManager.invalidate()
    elseif key.special == "LEFT" then
        self.center_x = self.center_x - self.pan_speed
        self:clamp_position()
        ScreenManager.invalidate()
    elseif key.special == "RIGHT" then
        self.center_x = self.center_x + self.pan_speed
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

    -- Toggle labels
    elseif key.character == "l" or key.character == "L" then
        self.show_labels = not self.show_labels
        ScreenManager.invalidate()
    end

    return "continue"
end

function MapViewer:zoom_in()
    if self.zoom < self.archive.max_zoom then
        local old_zoom = self.zoom
        -- Convert position to new zoom level
        self.center_x = self.center_x * 2
        self.center_y = self.center_y * 2
        self.zoom = self.zoom + 1
        self:clamp_position()
        -- Preserve parent tiles (old zoom) for fallback, clear others
        self:prune_cache_for_zoom(old_zoom)
        self.pending_tiles = {}
        self.missing_tiles = {}
        -- Keep label cache (labels work across zoom levels)
        ScreenManager.invalidate()
    end
end

function MapViewer:zoom_out()
    if self.zoom > self.archive.min_zoom then
        local old_zoom = self.zoom
        -- Convert position to new zoom level
        self.center_x = self.center_x / 2
        self.center_y = self.center_y / 2
        self.zoom = self.zoom - 1
        self:clamp_position()
        -- Preserve tiles from new zoom and adjacent levels
        self:prune_cache_for_zoom(old_zoom)
        self.pending_tiles = {}
        self.missing_tiles = {}
        ScreenManager.invalidate()
    end
end

-- Prune cache to keep only tiles useful for current zoom (parents for fallback)
function MapViewer:prune_cache_for_zoom(old_zoom)
    local new_cache = {}
    local kept = 0
    local max_keep = self.MAX_CACHE / 2  -- Keep up to half cache for fallback tiles

    for key, entry in pairs(self.tile_cache) do
        -- Parse zoom from key
        local tile_zoom = tonumber(string.match(key, "^(%d+)/"))
        if tile_zoom then
            -- Keep tiles from current zoom-1, zoom-2, zoom-3 (parents for fallback)
            local zoom_diff = self.zoom - tile_zoom
            if zoom_diff >= 1 and zoom_diff <= 3 and kept < max_keep then
                new_cache[key] = entry
                kept = kept + 1
            end
        end
    end

    self.tile_cache = new_cache
end

function MapViewer:clamp_position()
    local max_tile = 2 ^ self.zoom
    self.center_x = math.max(0, math.min(max_tile, self.center_x))
    self.center_y = math.max(0, math.min(max_tile, self.center_y))
end

function MapViewer:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = "Nodes",
        action = function()
            spawn(function()
                local ok, MapNodes = pcall(load_module, "/scripts/ui/screens/map_nodes.lua")
                if ok and MapNodes then
                    ScreenManager.push(MapNodes:new(function(lat, lon)
                        -- Callback when a node with location is selected
                        self_ref:center_on(lat, lon)
                    end))
                end
            end)
        end
    })

    -- Toggle labels (only show if labels are available)
    if self.label_index and #self.label_index > 0 then
        table.insert(items, {
            label = self.show_labels and "Hide Labels" or "Show Labels",
            action = function()
                self_ref.show_labels = not self_ref.show_labels
                ScreenManager.invalidate()
            end
        })
    end

    table.insert(items, {
        label = "Go Home",
        action = function()
            -- Center on default location (Alkmaar)
            self_ref:center_on(52.63, 4.75)
        end
    })

    return items
end

return MapViewer
