-- services/map_archive: TDMAP v7 vector archive reader.
-- Returns a handle exposing geometries-by-cell + labels-by-bounds. Pure
-- data layer; the map_view widget owns rendering.
--
-- v7 changes from v6:
--   * No tiles. Records are polylines or filled polygons with min/max zoom.
--   * A uniform spatial-index grid (grid_dim × grid_dim cells over the
--     archive's BB) lets a viewport query fetch just the cells it touches.
--   * Coordinates encoded as int32 origin + int16 deltas in microdegrees;
--     decoded into flat {x,y,x,y,...} screen-space arrays at draw time.
--   * Per-record zlib payload (decompressed on demand), LRU-cached.

local map_archive = {}

-- ---------------------------------------------------------------------------
-- Format constants (TDMAP v7)
-- ---------------------------------------------------------------------------

local HEADER_SIZE       = 33
local INDEX_ENTRY_SIZE  = 14
local LABEL_FIXED_SIZE  = 11
local TDMAP_VERSION     = 7

-- Decompressed geometry records cap at ~9 KB worst case (255 vertices, ~28
-- bytes each plus origin/header). Reuse one capped buffer per inflate call.
local MAX_GEOM_DECOMP_BYTES = 16384

local DEFAULT_CACHE_SIZE = 64

-- Chunk size for the index + label reads. Tile index in v6 used 512 KB
-- chunks; same logic applies here (multi-megabyte for country archives).
local READ_CHUNK = 524288

local function read_range(path, offset, length)
    if length <= 0 then return "" end
    local co, is_main = coroutine.running()
    if co and not is_main and ez.storage.async_read_bytes then
        local data = ez.storage.async_read_bytes(path, offset, length)
        if data and #data == length then return data end
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

-- Byte helpers (1-indexed, little-endian).
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
local function i16(s, i)
    local v = u16(s, i)
    if v >= 0x8000 then v = v - 0x10000 end
    return v
end

-- ---------------------------------------------------------------------------
-- Archive
-- ---------------------------------------------------------------------------

local Archive = {}
Archive.__index = Archive

-- Decode a compressed geometry record into a flat {lat_e6, lon_e6, ...}
-- array (still microdegree integers so callers can project once with cheap
-- float math). Returns nil on decompression failure.
function Archive:_decode_geometry(entry)
    local raw_comp = ez.storage.async_read_bytes(
        self.path, self.data_offset + entry.data_offset, entry.data_size)
    if not raw_comp then return nil end
    local raw = ez.compression.inflate(raw_comp, MAX_GEOM_DECOMP_BYTES)
    if not raw then return nil end
    local n = u8(raw, 1)
    local origin_lat = i32(raw, 2)
    local origin_lon = i32(raw, 6)
    local verts = { origin_lat, origin_lon }
    local lat = origin_lat
    local lon = origin_lon
    local p = 10
    for _ = 2, n do
        local d_lat = i16(raw, p)
        local d_lon = i16(raw, p + 2)
        lat = lat + d_lat
        lon = lon + d_lon
        verts[#verts + 1] = lat
        verts[#verts + 1] = lon
        p = p + 4
    end
    return verts
end

function Archive:_cache_store(idx, data)
    self._tick = self._tick + 1
    self.geom_cache[idx] = { data = data, access = self._tick }
    local count = 0
    for _ in pairs(self.geom_cache) do count = count + 1 end
    if count <= self.MAX_CACHE then return end
    local candidates = {}
    for k, v in pairs(self.geom_cache) do
        candidates[#candidates + 1] = { k, v.access }
    end
    table.sort(candidates, function(a, b) return a[2] < b[2] end)
    for i = 1, count - self.MAX_CACHE do
        self.geom_cache[candidates[i][1]] = nil
    end
end

-- Get decoded geometry for an index slot, async-decompressing if needed.
-- Returns nil while the load is in flight; the caller is expected to redraw
-- once the on_geometry_loaded hook fires.
function Archive:get_geometry(index_slot)
    local cached = self.geom_cache[index_slot]
    if cached then
        self._tick = self._tick + 1
        cached.access = self._tick
        return cached.data
    end
    if self.pending[index_slot] then return nil end
    self.pending[index_slot] = true

    local entry = self.entries[index_slot]
    if not entry then
        self.pending[index_slot] = nil
        return nil
    end

    local async = require("ezui.async")
    async.task(function()
        local data = self:_decode_geometry(entry)
        self.pending[index_slot] = nil
        if data then self:_cache_store(index_slot, data) end
        if self.on_geometry_loaded then self.on_geometry_loaded() end
    end)
    return nil
end

-- Compute which cell-index entries fall inside a viewport. Returns a list of
-- index_slot integers. The index is sorted by (cell_index, min_zoom), so we
-- binary-search for the first entry in each cell and scan forward.
--
-- viewport: { min_lat, min_lon, max_lat, max_lon } in degrees.
-- zoom:     current display zoom (drops records whose [zmin,zmax] excludes it).
function Archive:viewport_geometries(viewport, zoom)
    local bounds = self.header.bounds
    if not bounds then return {} end
    local grid_dim = self.header.grid_dim
    local west, south = bounds.west, bounds.south
    local east, north = bounds.east, bounds.north
    if east == west or north == south then return {} end

    local function clamp_cell(v)
        if v < 0 then return 0 end
        if v > grid_dim - 1 then return grid_dim - 1 end
        return v
    end

    local col_lo = clamp_cell(math.floor((viewport[2] - west) / (east - west) * grid_dim))
    local col_hi = clamp_cell(math.floor((viewport[4] - west) / (east - west) * grid_dim))
    local row_lo = clamp_cell(math.floor((north - viewport[3]) / (north - south) * grid_dim))
    local row_hi = clamp_cell(math.floor((north - viewport[1]) / (north - south) * grid_dim))
    if col_lo > col_hi then col_lo, col_hi = col_hi, col_lo end
    if row_lo > row_hi then row_lo, row_hi = row_hi, row_lo end

    -- Binary search for the first index slot whose cell_index equals or
    -- exceeds target.
    local function lower_bound(target)
        local lo, hi = 1, #self.entries
        while lo <= hi do
            local mid = (lo + hi) >> 1
            if self.entries[mid].cell_index < target then
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
        return lo
    end

    local result = {}
    for row = row_lo, row_hi do
        local cell_lo = (row << 16) | col_lo
        local cell_hi = (row << 16) | col_hi
        local i = lower_bound(cell_lo)
        local n = #self.entries
        while i <= n do
            local e = self.entries[i]
            if e.cell_index > cell_hi then break end
            if zoom >= e.min_zoom and zoom <= e.max_zoom then
                result[#result + 1] = i
            end
            i = i + 1
        end
    end
    return result
end

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
    self.geom_cache = {}
    self.pending = {}
    self.labels = {}
    self.entries = {}
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
            "unsupported TDMAP version: %d (reader expects v%d; pre-v7 "
            .. "archives are no longer supported -- regenerate with the "
            .. "current writer)",
            version, TDMAP_VERSION)
    end

    local header = {
        version       = version,
        compression   = u8(hdr, 8),
        grid_dim      = u16(hdr, 9),
        reserved      = u8(hdr, 11),
        geom_count    = u32(hdr, 12),
        index_offset  = u32(hdr, 16),
        data_offset   = u32(hdr, 20),
        min_zoom      = i8(hdr, 24),
        max_zoom      = i8(hdr, 25),
        label_offset  = u32(hdr, 26),
        label_count   = u32(hdr, 30),
        region_name     = nil,
        bounds          = nil,
        build_timestamp = nil,
        tool_version    = nil,
    }
    if header.grid_dim == 0 then header.grid_dim = 256 end

    -- Metadata block (length-prefixed TLV) sits right after the header.
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
                        header.region_name = value
                    elseif tag == "BB" and vlen == 16 then
                        local south_e6 = i32(value, 1)
                        local west_e6  = i32(value, 5)
                        local north_e6 = i32(value, 9)
                        local east_e6  = i32(value, 13)
                        header.bounds = {
                            west  = west_e6  / 1e6,
                            south = south_e6 / 1e6,
                            east  = east_e6  / 1e6,
                            north = north_e6 / 1e6,
                        }
                    elseif tag == "TS" and vlen == 8 then
                        header.build_timestamp = u32(value, 1)
                    elseif tag == "TV" then
                        header.tool_version = value
                    end
                    p = vend + 1
                end
            end
        end
    end

    if not header.bounds then
        return nil, "v7 archive missing BB metadata: cannot lay out spatial index"
    end

    -- Read the index block whole. 14 bytes/entry × 200k geoms ~= 2.8 MB
    -- on a Netherlands-scale archive; same memory footprint as the v6 tile
    -- index. We materialise entries into Lua tables here (one per slot) so
    -- callers can chase fields cheaply; the inner search loop is hot enough
    -- that the per-table overhead is preferable to repeated byte unpacking.
    local index_len = header.geom_count * INDEX_ENTRY_SIZE
    local idx_bytes, idx_err = read_range(path, header.index_offset, index_len)
    if not idx_bytes or #idx_bytes < index_len then
        return nil, "cannot read geometry index: " .. tostring(idx_err or "short read")
    end

    local entries = {}
    for i = 0, header.geom_count - 1 do
        local p = i * INDEX_ENTRY_SIZE + 1
        entries[i + 1] = {
            cell_index    = u32(idx_bytes, p),
            feature_class = u8(idx_bytes,  p + 4),
            geom_type     = u8(idx_bytes,  p + 5),
            min_zoom      = u8(idx_bytes,  p + 6),
            max_zoom      = u8(idx_bytes,  p + 7),
            data_offset   = u32(idx_bytes, p + 8),
            data_size     = u16(idx_bytes, p + 12),
        }
    end

    -- Labels (unchanged layout from v6).
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

    local archive = setmetatable({
        path        = path,
        header      = header,
        entries     = entries,
        labels      = labels,
        data_offset = header.data_offset,
        geom_cache  = {},
        pending     = {},
        _tick       = 0,
        MAX_CACHE   = DEFAULT_CACHE_SIZE,
    }, Archive)
    return archive
end

-- ---------------------------------------------------------------------------
-- Coordinate helpers (Web Mercator). Exported so the map_view widget can
-- project consistently across screens.
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
    local lat_rad = math.atan((math.exp(math.pi * (1 - 2 * y / n))
                              - math.exp(-math.pi * (1 - 2 * y / n))) / 2)
    local lat = lat_rad * 180 / math.pi
    return lat, lon
end

map_archive.VERSION = TDMAP_VERSION

-- Feature class constants. Mirror tools/maps/tdmap.py.
map_archive.F_LAND       = 0
map_archive.F_WATER      = 1
map_archive.F_PARK       = 2
map_archive.F_BUILDING   = 3
map_archive.F_ROAD_MINOR = 4
map_archive.F_ROAD_MAJOR = 5
map_archive.F_HIGHWAY    = 6
map_archive.F_RAILWAY    = 7

map_archive.G_POLYLINE = 0
map_archive.G_POLYGON  = 1

return map_archive
