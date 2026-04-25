-- services/map_archive: TDMAP v6 reader with async tile loading and LRU cache.
-- Pure data layer consumed by the map_view widget; no rendering here.
--
-- Concurrency model:
--   * open() is synchronous and cheap (header + index + labels).
--   * get_tile() returns cached bytes, "pending" while an async load is in flight,
--     or nil when the tile is known-absent. The async load is driven by a
--     coroutine spawn()-ed on the first miss.
--   * Calls that block on disk use `async_read_bytes`, which yields the
--     calling coroutine until the SD driver finishes the read.
--
-- Memory budget:
--   * Tile cache: 16 tiles × 24,576 bytes ≈ 384 KB of PSRAM (matches old viewer).
--   * Labels: parsed into a flat Lua array at open time. A global archive of
--     ~30 k labels uses ~1 MB; regional archives stay well under that.

local map_archive = {}

-- ---------------------------------------------------------------------------
-- Format constants (TDMAP v6)
-- ---------------------------------------------------------------------------

local HEADER_SIZE       = 33
local INDEX_ENTRY_SIZE  = 11
local LABEL_FIXED_SIZE  = 11
local TDMAP_VERSION     = 6
local TILE_SIZE         = 256
local PACKED_TILE_BYTES = TILE_SIZE * TILE_SIZE * 3 // 8  -- 24,576

local DEFAULT_CACHE_SIZE = 16

-- Multi-megabyte reads (tile index, labels) exceed ez.storage.read_bytes's
-- 1 MB per-call ceiling on country-scale archives, so we chunk. Prefer the
-- PSRAM-backed async read (single file open, no per-call cap) when
-- running inside a coroutine; fall back to the sync path with smaller
-- chunks for callers that can't yield. Returns (data, err) — propagate
-- the err upward rather than swallowing it at the call site.
local READ_CHUNK = 524288  -- 512 KB per sync call — well under the 1 MB cap

local function read_range(path, offset, length)
    if length <= 0 then return "" end

    -- async_read_bytes yields the coroutine; `coroutine.running()` returns
    -- a non-main thread when we can legally yield.
    local co, is_main = coroutine.running()
    if co and not is_main and ez.storage.async_read_bytes then
        local data = ez.storage.async_read_bytes(path, offset, length)
        if data and #data == length then return data end
        -- Fall through to the sync path if async returned nil/short.
    end

    local chunks    = {}
    local cursor    = offset
    local remaining = length
    while remaining > 0 do
        local n = remaining < READ_CHUNK and remaining or READ_CHUNK
        local chunk, err = ez.storage.read_bytes(path, cursor, n)
        if not chunk or #chunk == 0 then
            return nil, err or "short read"
        end
        chunks[#chunks + 1] = chunk
        cursor    = cursor    + #chunk
        remaining = remaining - #chunk
    end
    return table.concat(chunks)
end

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

-- v6 archives are always zlib-compressed. Decoding hands off to
-- ez.compression.inflate (backed by ROM miniz on-device). Returns
-- decompressed bytes or nil. The compression byte from the header is
-- ignored — the writer only ever emits zlib in v6, and pre-v6 archives
-- are rejected at open() time.
local function decompress_tile(_compression, data)
    return ez.compression.inflate(data, PACKED_TILE_BYTES)
end

-- ---------------------------------------------------------------------------
-- Archive
-- ---------------------------------------------------------------------------

local Archive = {}
Archive.__index = Archive

local function tile_key(z, x, y)
    return z * 0x100000000 + x * 0x10000 + y
end

-- Binary search the packed tile index. idx_bytes holds tile_count × 11-byte
-- entries already sorted by (z, x, y) when the archive was written. We
-- decode candidates on the fly instead of materializing 166k Lua tables,
-- which on country-scale z15 archives would otherwise blow the Lua heap.
function Archive:find_tile(z, x, y)
    local idx = self.idx_bytes
    if not idx then return nil end
    local lo, hi = 0, self.header.tile_count - 1
    while lo <= hi do
        local mid  = (lo + hi) >> 1
        local p    = mid * INDEX_ENTRY_SIZE + 1
        local mz   = u8(idx,  p)
        local mx   = u16(idx, p + 1)
        local my   = u16(idx, p + 3)
        if mz == z and mx == x and my == y then
            return {
                z      = mz,
                x      = mx,
                y      = my,
                offset = u32(idx, p + 5),
                size   = u16(idx, p + 9),
            }
        end
        if mz < z or (mz == z and (mx < x or (mx == x and my < y))) then
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
    -- async.task wraps spawn() with begin()/done(); each in-flight
    -- tile load participates in the status-bar busy indicator, and
    -- the counter drops even if a read / decompress errors out.
    local async = require("ezui.async")
    async.task(function()
        local compressed = ez.storage.async_read_bytes(path, entry.offset, entry.size)
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
    self.idx_bytes = nil
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
    if version ~= TDMAP_VERSION then
        return nil, string.format(
            "unsupported TDMAP version: %d (reader expects v%d; pre-v6 "
            .. "archives are no longer supported — regenerate with the "
            .. "current writer)",
            version, TDMAP_VERSION)
    end

    local header = {
        version       = version,
        compression   = u8(hdr, 8),
        tile_size     = u16(hdr, 9),
        palette_count = u8(hdr, 11),  -- always 0 in v6
        tile_count    = u32(hdr, 12),
        index_offset  = u32(hdr, 16),
        data_offset   = u32(hdr, 20),
        min_zoom      = i8(hdr, 24),
        max_zoom      = i8(hdr, 25),
        label_offset  = u32(hdr, 26),
        label_count   = u32(hdr, 30),
        -- TLV metadata, populated below if any tags are set
        region_name     = nil,
        bounds          = nil,
        build_timestamp = nil,
        tool_version    = nil,
    }

    -- Metadata block sits right after the header: 4-byte length + TLV tags.
    -- Parsed eagerly into the header so screens can surface region/bounds.
    local metadata = {}
    local meta_len_bytes = ez.storage.read_bytes(path, HEADER_SIZE, 4)
    if meta_len_bytes and #meta_len_bytes >= 4 then
        local meta_len = u32(meta_len_bytes, 1)
        if meta_len > 0 and meta_len < 0x10000 then
            local meta_payload = ez.storage.read_bytes(path, HEADER_SIZE + 4, meta_len)
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

    -- Tile index. Country-scale archives at z=15 push this past 1.5 MB.
    -- We keep the block as a single immutable string and binary-search it
    -- directly in find_tile; materializing one Lua table per entry would
    -- cost ~100 B × tile_count and easily blow the internal heap on z15
    -- country archives.
    local index_len = header.tile_count * INDEX_ENTRY_SIZE
    local idx_bytes, idx_err = read_range(path, header.index_offset, index_len)
    if not idx_bytes or #idx_bytes < index_len then
        return nil, "cannot read tile index: " .. tostring(idx_err or "short read")
    end

    -- Labels: 1-2 MB at z=15. The same chunked reader handles both cases
    -- — we just need to propagate its error message so silent truncation
    -- surfaces as a real failure instead of a mystery blank map.
    local labels = {}
    if header.label_count > 0 and header.label_offset > 0 then
        local file_size = ez.storage.file_size(path) or 0
        local block_len = file_size - header.label_offset
        if block_len > 0 then
            local block, lbl_err = read_range(path, header.label_offset, block_len)
            if not block then
                return nil, "cannot read label block: " .. tostring(lbl_err or "short read")
            end
            if #block > 0 then
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

    -- Merge metadata into the header for ergonomic access at the screen layer.
    for k, v in pairs(metadata) do header[k] = v end

    local archive = setmetatable({
        path        = path,
        header      = header,
        idx_bytes   = idx_bytes,
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
map_archive.VERSION           = TDMAP_VERSION  -- v6

return map_archive
