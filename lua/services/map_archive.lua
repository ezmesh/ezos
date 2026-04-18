-- services/map_archive: TDMAP v4 reader with async tile loading and LRU cache.
-- Pure data layer consumed by the map_view widget; no rendering here.
--
-- Concurrency model:
--   * open() is synchronous and cheap (header + index + labels).
--   * get_tile() returns cached bytes, "pending" while an async load is in flight,
--     or nil when the tile is known-absent. The async load is driven by a
--     coroutine spawn()-ed on the first miss.
--   * Calls that block on disk use `async_read_bytes` (yields the coroutine on
--     device; runs synchronously in the simulator).
--
-- Memory budget:
--   * Tile cache: 16 tiles × 24,576 bytes ≈ 384 KB of PSRAM (matches old viewer).
--   * Labels: parsed into a flat Lua array at open time. A global archive of
--     ~30 k labels uses ~1 MB; regional archives stay well under that.

local map_archive = {}

-- ---------------------------------------------------------------------------
-- Format constants (TDMAP v4)
-- ---------------------------------------------------------------------------

local HEADER_SIZE       = 33
local PALETTE_SIZE      = 16
local INDEX_ENTRY_SIZE  = 11
local LABEL_FIXED_SIZE  = 11
local MIN_VERSION       = 4
local MAX_VERSION       = 5  -- v5 adds optional TLV metadata after the palette
local TILE_SIZE         = 256
local PACKED_TILE_BYTES = TILE_SIZE * TILE_SIZE * 3 // 8  -- 24,576
local RLE_ESCAPE        = 0xFF

-- Tile compression codecs (mirrors tools/maps/config.py).
local COMPRESSION_RLE  = 1
local COMPRESSION_ZLIB = 2

local DEFAULT_CACHE_SIZE = 16

-- ---------------------------------------------------------------------------
-- Byte helpers. All positions are 1-indexed to match Lua's string.byte.
-- ---------------------------------------------------------------------------

local byte = string.byte
local function u8(s, i) return byte(s, i) end
local function u16(s, i) return byte(s, i) | (byte(s, i + 1) << 8) end
local function u32(s, i)
    return byte(s, i)
         | (byte(s, i + 1) << 8)
         | (byte(s, i + 2) << 16)
         | (byte(s, i + 3) << 24)
end
local function i32(s, i)
    local v = u32(s, i)
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end
local function i8(s, i)
    local b = byte(s, i)
    if b >= 0x80 then return b - 0x100 end
    return b
end

-- RLE: escape byte 0xFF introduces a [count, value] pair. Any other byte is literal.
-- Literal runs are coalesced to keep the piece count low for table.concat.
local function rle_decompress(data)
    local pieces = {}
    local len = #data
    local i = 1
    while i <= len do
        local b = byte(data, i)
        if b == RLE_ESCAPE and i + 2 <= len then
            local count = byte(data, i + 1)
            local val   = byte(data, i + 2)
            pieces[#pieces + 1] = string.rep(string.char(val), count)
            i = i + 3
        else
            local start = i
            while i <= len do
                local c = byte(data, i)
                if c == RLE_ESCAPE and i + 2 <= len then break end
                i = i + 1
            end
            pieces[#pieces + 1] = data:sub(start, i - 1)
        end
    end
    return table.concat(pieces)
end

-- Dispatch on the archive's compression byte. zlib decoding hands off to
-- ez.compression.inflate (backed by ROM miniz on-device); RLE stays in Lua
-- for backwards-compat with v4 archives. Returns decompressed bytes or nil.
local function decompress_tile(compression, data)
    if compression == COMPRESSION_ZLIB then
        if ez.compression and ez.compression.inflate then
            local out = ez.compression.inflate(data, PACKED_TILE_BYTES)
            return out
        end
        -- Simulator / host tests don't have the C binding; caller must polyfill.
        return nil
    end
    -- Default: RLE (matches v4 archives that don't even set the byte).
    return rle_decompress(data)
end

-- ---------------------------------------------------------------------------
-- Archive
-- ---------------------------------------------------------------------------

local Archive = {}
Archive.__index = Archive

local function tile_key(z, x, y)
    return z * 0x100000000 + x * 0x10000 + y
end

-- Binary search in sorted self.tiles for (z, x, y). Returns the entry or nil.
function Archive:find_tile(z, x, y)
    local tiles = self.tiles
    local lo, hi = 1, #tiles
    while lo <= hi do
        local mid = (lo + hi) >> 1
        local t = tiles[mid]
        if t.z == z and t.x == x and t.y == y then return t end
        if t.z < z or (t.z == z and (t.x < x or (t.x == x and t.y < y))) then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return nil
end

-- LRU touch: update access counter and evict oldest entries if over capacity.
function Archive:_cache_store(key, data)
    self._tick = self._tick + 1
    self.tile_cache[key] = { data = data, access = self._tick }

    -- Evict-if-needed. We only evict past MAX_CACHE to avoid repeated work.
    local count = 0
    for _ in pairs(self.tile_cache) do count = count + 1 end
    if count <= self.MAX_CACHE then return end

    -- Find the (count - MAX_CACHE) oldest entries and drop them.
    local candidates = {}
    for k, v in pairs(self.tile_cache) do
        candidates[#candidates + 1] = { k, v.access }
    end
    table.sort(candidates, function(a, b) return a[2] < b[2] end)
    for i = 1, count - self.MAX_CACHE do
        self.tile_cache[candidates[i][1]] = nil
    end
end

-- Returns decoded tile bytes (cache hit), the string "pending" (async load in
-- flight), or nil (tile known-absent from archive).
function Archive:get_tile(z, x, y)
    local key = tile_key(z, x, y)

    local cached = self.tile_cache[key]
    if cached then
        self._tick = self._tick + 1
        cached.access = self._tick
        return cached.data
    end

    if self.missing[key] then return nil end
    if self.pending[key] then return "pending" end

    local entry = self:find_tile(z, x, y)
    if not entry then
        self.missing[key] = true
        return nil
    end

    self.pending[key] = true
    local path = self.path
    local compression = self.header.compression
    spawn(function()
        local compressed = async_read_bytes(path, entry.offset, entry.size)
        self.pending[key] = nil
        if not compressed or #compressed == 0 then
            self.missing[key] = true
        else
            local raw = decompress_tile(compression, compressed)
            if raw then
                self:_cache_store(key, raw)
            else
                self.missing[key] = true
            end
        end
        -- Optional hook so the UI layer can schedule a redraw now that the
        -- tile lives in cache. Set by the map screen after open() to avoid
        -- coupling this data module to ezui.screen.
        if self.on_tile_loaded then self.on_tile_loaded() end
    end)
    return "pending"
end

-- Walk up zoom levels for the nearest cached ancestor. Returns
-- (data, src_x, src_y, src_w, src_h) suitable for draw_indexed_bitmap_scaled,
-- or nil if no ancestor is cached.
function Archive:get_parent_fallback(z, x, y)
    local cx, cy = x, y
    local min_zoom = self.header.min_zoom
    for level = z - 1, min_zoom, -1 do
        cx = cx >> 1
        cy = cy >> 1
        local cached = self.tile_cache[tile_key(level, cx, cy)]
        if cached then
            cached.access = self._tick
            local dz = z - level
            local scale = 1 << dz
            local src_w = TILE_SIZE // scale
            local src_h = TILE_SIZE // scale
            local sub_x = x - (cx << dz)
            local sub_y = y - (cy << dz)
            return cached.data, sub_x * src_w, sub_y * src_h, src_w, src_h
        end
    end
    return nil
end

-- Flush the negative cache. Call after zoom changes so known-missing tiles can
-- be re-checked against the archive (they are zoom-level specific).
function Archive:invalidate_missing()
    self.missing = {}
end

-- Linear scan over parsed labels. Archives cap at ~30k labels so this is cheap
-- even at 30 FPS; no spatial index yet.
function Archive:labels_in_bounds(z, min_lat, max_lat, min_lon, max_lon)
    local result = {}
    for i = 1, #self.labels do
        local l = self.labels[i]
        if z >= l.zmin and z <= l.zmax
           and l.lat >= min_lat and l.lat <= max_lat
           and l.lon >= min_lon and l.lon <= max_lon then
            result[#result + 1] = l
        end
    end
    return result
end

function Archive:close()
    self.tile_cache = {}
    self.pending = {}
    self.missing = {}
    self.labels = {}
    self.tiles = {}
end

-- ---------------------------------------------------------------------------
-- open(path) -> archive | nil, error_message
-- ---------------------------------------------------------------------------

function map_archive.open(path)
    local hdr = ez.storage.read_bytes(path, 0, HEADER_SIZE)
    if not hdr or #hdr < HEADER_SIZE then
        return nil, "cannot read TDMAP header: " .. tostring(path)
    end
    if hdr:sub(1, 6) ~= "TDMAP\0" then
        return nil, "not a TDMAP archive: " .. tostring(path)
    end
    local version = u8(hdr, 7)
    if version < MIN_VERSION or version > MAX_VERSION then
        return nil, string.format(
            "unsupported TDMAP version: %d (reader supports %d..%d)",
            version, MIN_VERSION, MAX_VERSION)
    end

    local header = {
        version       = version,
        compression   = u8(hdr, 8),
        tile_size     = u16(hdr, 9),
        palette_count = u8(hdr, 11),
        tile_count    = u32(hdr, 12),
        index_offset  = u32(hdr, 16),
        data_offset   = u32(hdr, 20),
        min_zoom      = i8(hdr, 24),
        max_zoom      = i8(hdr, 25),
        label_offset  = u32(hdr, 26),
        label_count   = u32(hdr, 30),
        -- v5 metadata (nil on v4 archives)
        region_name     = nil,
        bounds          = nil,
        build_timestamp = nil,
        tool_version    = nil,
    }

    -- Palette: 8 RGB565 values immediately after the header.
    local pal_bytes = ez.storage.read_bytes(path, HEADER_SIZE, PALETTE_SIZE)
    if not pal_bytes or #pal_bytes < PALETTE_SIZE then
        return nil, "cannot read palette block"
    end
    -- Palette is passed to ez.display.draw_indexed_bitmap, which reads 1..8.
    local palette = {}
    for i = 1, 8 do
        palette[i] = u16(pal_bytes, (i - 1) * 2 + 1)
    end

    -- v5 metadata block: 4-byte length + TLV tags. Parsed lazily into the
    -- header so screens can surface region/bounds without paying the cost
    -- when they don't care.
    local metadata = {}
    if version >= 5 then
        local meta_offset = HEADER_SIZE + PALETTE_SIZE
        local meta_len_bytes = ez.storage.read_bytes(path, meta_offset, 4)
        if meta_len_bytes and #meta_len_bytes >= 4 then
            local meta_len = u32(meta_len_bytes, 1)
            if meta_len > 0 and meta_len < 0x10000 then
                local meta_payload = ez.storage.read_bytes(path, meta_offset + 4, meta_len)
                if meta_payload then
                    local p = 1
                    local plen = #meta_payload
                    while p + 4 <= plen + 1 do
                        local tag = meta_payload:sub(p, p + 1)
                        local vlen = u16(meta_payload, p + 2)
                        local vstart = p + 4
                        local vend = vstart + vlen - 1
                        if vend > plen then break end
                        local value = meta_payload:sub(vstart, vend)
                        if tag == "RG" then
                            metadata.region_name = value
                        elseif tag == "BB" and vlen == 16 then
                            local south_e6 = i32(value, 1)
                            local west_e6  = i32(value, 5)
                            local north_e6 = i32(value, 9)
                            local east_e6  = i32(value, 13)
                            metadata.bounds = {
                                west  = west_e6  / 1e6,
                                south = south_e6 / 1e6,
                                east  = east_e6  / 1e6,
                                north = north_e6 / 1e6,
                            }
                        elseif tag == "TS" and vlen == 8 then
                            -- uint64 → Lua integer; high 32 bits likely 0 for
                            -- reasonable timestamps, don't bother with bit-shift.
                            metadata.build_timestamp = u32(value, 1)
                        elseif tag == "TV" then
                            metadata.tool_version = value
                        end
                        p = vend + 1
                    end
                end
            end
        end
    end

    -- Tile index.
    local index_len = header.tile_count * INDEX_ENTRY_SIZE
    local idx_bytes = ez.storage.read_bytes(path, header.index_offset, index_len)
    if not idx_bytes or #idx_bytes < index_len then
        return nil, "cannot read tile index"
    end
    local tiles = {}
    for i = 0, header.tile_count - 1 do
        local p = i * INDEX_ENTRY_SIZE + 1
        tiles[i + 1] = {
            z      = u8(idx_bytes,  p),
            x      = u16(idx_bytes, p + 1),
            y      = u16(idx_bytes, p + 3),
            offset = u32(idx_bytes, p + 5),
            size   = u16(idx_bytes, p + 9),
        }
    end

    -- Labels: read the whole block in one go, then parse sequentially.
    local labels = {}
    if header.label_count > 0 and header.label_offset > 0 then
        local file_size = ez.storage.file_size(path) or 0
        local block_len = file_size - header.label_offset
        if block_len > 0 then
            local block = ez.storage.read_bytes(path, header.label_offset, block_len)
            if block and #block > 0 then
                local p = 1
                local block_size = #block
                for _ = 1, header.label_count do
                    if p + LABEL_FIXED_SIZE > block_size then break end
                    local lat   = i32(block, p) / 1e6
                    local lon   = i32(block, p + 4) / 1e6
                    local zmin  = u8(block,  p + 8)
                    local zmax  = u8(block,  p + 9)
                    local ltype = u8(block,  p + 10)
                    local tlen  = u8(block,  p + 11)
                    local text  = block:sub(p + 12, p + 11 + tlen)
                    labels[#labels + 1] = {
                        lat = lat, lon = lon,
                        zmin = zmin, zmax = zmax,
                        type = ltype, text = text,
                    }
                    p = p + LABEL_FIXED_SIZE + 1 + tlen
                end
            end
        end
    end

    -- Merge v5 metadata into the header for ergonomic access at the screen layer.
    for k, v in pairs(metadata) do header[k] = v end

    local archive = setmetatable({
        path        = path,
        header      = header,
        palette     = palette,
        tiles       = tiles,
        labels      = labels,
        tile_cache  = {},
        pending     = {},
        missing     = {},
        _tick       = 0,
        MAX_CACHE   = DEFAULT_CACHE_SIZE,
    }, Archive)
    return archive
end

-- ---------------------------------------------------------------------------
-- Coordinate helpers (Web Mercator). Exported for use by the map_view widget
-- so projection math stays consistent across screens.
-- ---------------------------------------------------------------------------

function map_archive.lat_lon_to_tile(lat, lon, zoom)
    local n = 2 ^ zoom
    local x = (lon + 180) / 360 * n
    local lat_rad = lat * math.pi / 180
    local y = (1 - math.log(math.tan(lat_rad) + 1 / math.cos(lat_rad)) / math.pi) / 2 * n
    return x, y
end

function map_archive.tile_to_lat_lon(x, y, zoom)
    local n = 2 ^ zoom
    local lon = x / n * 360 - 180
    local lat_rad = math.atan((math.exp(math.pi * (1 - 2 * y / n)) - math.exp(-math.pi * (1 - 2 * y / n))) / 2)
    local lat = lat_rad * 180 / math.pi
    return lat, lon
end

map_archive.TILE_SIZE         = TILE_SIZE
map_archive.PACKED_TILE_BYTES = PACKED_TILE_BYTES
map_archive.VERSION           = TDMAP_VERSION

return map_archive
