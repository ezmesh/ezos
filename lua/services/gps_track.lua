-- services/gps_track: append-only GPS track recorder.
--
-- The recorder is one long-lived coroutine that polls ez.gps when a
-- session is active. Each new sample is screened against two thresholds
-- (`min_interval_s` AND `min_distance_m`) and appended to disk as a
-- fixed 13-byte record. On stop(), the header's flags byte is rewritten
-- with bit 0 set so future loaders can tell a clean session from a
-- crashed one.
--
-- Storage shape (".eztrack" v1):
--     "EZTRK1"             (6) magic
--     flags                (1) bit0 = closed/finalised
--     reserved             (1) always 0
--     start_unix           (4 LE)
--     label_len            (1)
--     label                (N, ASCII)
--     records...           N * 13 bytes
--
-- Each record:
--     ts_delta_s           (2 LE u16, seconds since start_unix, saturating)
--     lat_e6               (4 LE i32)
--     lon_e6               (4 LE i32)
--     alt_m                (2 LE i16)
--     hdop_t               (1     u8, hdop * 10 clamped to [0,255])
--
-- Privacy: tracks live on SD only. Nothing is transmitted automatically.
-- Sharing happens via the separate file-transfer / share flows.

local gps_svc = require("services.gps")

local M = {}

local TRACK_DIR = "/sd/tracks"
local MAGIC = "EZTRK1"
local FLAG_CLOSED = 0x01
local POLL_MS = 1000        -- sampler tick budget
local DEFAULT_MIN_INTERVAL_S = 5
local DEFAULT_MIN_DISTANCE_M = 5

-- Settings prefs (read on start; not live-watched while recording).
local PREF_MIN_INTERVAL = "trk_interval"
local PREF_MIN_DISTANCE = "trk_distance"
local PREF_AUTOSTART    = "trk_autostart"

-- ---------------------------------------------------------------------------
-- State (in-memory; the on-disk file is the source of truth across reboots)
-- ---------------------------------------------------------------------------

local state = {
    active     = false,
    path       = nil,       -- "/sd/tracks/<unix>-<label>.eztrack" when active
    start_unix = nil,
    label      = nil,
    points     = nil,       -- in-progress polyline {{lat, lon}, ...}
    points_cap = 1024,      -- in-RAM polyline ring for the live overlay
    last_point = nil,       -- {ts_ms, lat, lon}
    last_fix_valid = true,  -- false when we lost the fix; a gap is the result
    min_interval_s = DEFAULT_MIN_INTERVAL_S,
    min_distance_m = DEFAULT_MIN_DISTANCE_M,
    sampler_started = false,
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function ascii_slug(s)
    if type(s) ~= "string" or s == "" then return "track" end
    -- Keep alnum + dash + underscore so the resulting filename survives a
    -- copy off SD onto any sensible host filesystem.
    local out = (s:gsub("[^%w_-]", "_"))
    if #out > 24 then out = out:sub(1, 24) end
    if out == "" then return "track" end
    return out
end

local function pack_u16_le(v)
    v = v or 0
    if v < 0 then v = 0 elseif v > 0xFFFF then v = 0xFFFF end
    return string.char(v & 0xFF, (v >> 8) & 0xFF)
end

local function pack_i16_le(v)
    v = v or 0
    if v < -32768 then v = -32768 elseif v > 32767 then v = 32767 end
    if v < 0 then v = v + 0x10000 end
    return string.char(v & 0xFF, (v >> 8) & 0xFF)
end

local function pack_i32_le(v)
    v = v or 0
    if v < 0 then v = v + 0x100000000 end
    return string.char(v & 0xFF, (v >> 8) & 0xFF,
                       (v >> 16) & 0xFF, (v >> 24) & 0xFF)
end

local function unpack_u16_le(s, o)
    return s:byte(o) + s:byte(o + 1) * 256
end

local function unpack_i16_le(s, o)
    local v = unpack_u16_le(s, o)
    if v >= 0x8000 then v = v - 0x10000 end
    return v
end

local function unpack_u32_le(s, o)
    return s:byte(o) + s:byte(o + 1) * 256
         + s:byte(o + 2) * 65536 + s:byte(o + 3) * 16777216
end

local function unpack_i32_le(s, o)
    local v = unpack_u32_le(s, o)
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end

-- Great-circle distance in metres. Plenty of precision for the
-- "did we move 5 m" guard; we don't need the full haversine identity
-- for the small distances this filter cares about, but the simpler
-- equirectangular approximation breaks at the poles. Use the textbook
-- haversine for correctness everywhere.
local function haversine_m(lat1, lon1, lat2, lon2)
    local R = 6371000
    local rad = math.pi / 180
    local p1 = lat1 * rad
    local p2 = lat2 * rad
    local dp = (lat2 - lat1) * rad
    local dl = (lon2 - lon1) * rad
    local a = math.sin(dp / 2) ^ 2
        + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ^ 2
    local c = 2 * math.atan(math.sqrt(a), math.sqrt(1 - a))
    return R * c
end

local function to_e6(v)
    return math.floor(v * 1e6 + (v >= 0 and 0.5 or -0.5))
end

-- ---------------------------------------------------------------------------
-- Pref reads (with defaults). Caller decides when to re-read.
-- ---------------------------------------------------------------------------

local function read_prefs()
    local interval = tonumber(ez.storage.get_pref(PREF_MIN_INTERVAL,
        DEFAULT_MIN_INTERVAL_S)) or DEFAULT_MIN_INTERVAL_S
    local distance = tonumber(ez.storage.get_pref(PREF_MIN_DISTANCE,
        DEFAULT_MIN_DISTANCE_M)) or DEFAULT_MIN_DISTANCE_M
    if interval < 1 then interval = 1 end
    if distance < 0 then distance = 0 end
    return interval, distance
end

function M.get_prefs()
    local i, d = read_prefs()
    return {
        min_interval_s = i,
        min_distance_m = d,
        autostart = ez.storage.get_pref(PREF_AUTOSTART, "0") == "1",
    }
end

function M.set_prefs(opts)
    if type(opts) ~= "table" then return end
    if opts.min_interval_s then
        ez.storage.set_pref(PREF_MIN_INTERVAL, tostring(opts.min_interval_s))
    end
    if opts.min_distance_m then
        ez.storage.set_pref(PREF_MIN_DISTANCE, tostring(opts.min_distance_m))
    end
    if opts.autostart ~= nil then
        ez.storage.set_pref(PREF_AUTOSTART, opts.autostart and "1" or "0")
    end
end

-- ---------------------------------------------------------------------------
-- File header / record helpers
-- ---------------------------------------------------------------------------

local function build_header(start_unix, label, flags)
    label = label or ""
    if #label > 64 then label = label:sub(1, 64) end
    return MAGIC
        .. string.char(flags or 0)
        .. string.char(0)                 -- reserved
        .. pack_i32_le(start_unix)
        .. string.char(#label) .. label
end

-- Read just the header from path. Returns (header_table, body_offset) or
-- (nil, err).
function M.read_header(path)
    if not ez.storage.exists(path) then return nil, "not found" end
    local size = ez.storage.file_size and ez.storage.file_size(path)
        or (#(ez.storage.read_file(path) or ""))
    if not size or size < 13 then return nil, "too short" end

    local prelude
    if ez.storage.read_bytes then
        prelude = ez.storage.read_bytes(path, 0, 13)
    else
        local raw = ez.storage.read_file(path)
        prelude = raw and raw:sub(1, 13)
    end
    if not prelude or #prelude < 13 then return nil, "short read" end
    if prelude:sub(1, 6) ~= MAGIC then return nil, "bad magic" end

    local flags = prelude:byte(7)
    local start_unix = unpack_i32_le(prelude, 9)
    local label_len = prelude:byte(13)

    local label = ""
    if label_len > 0 then
        local label_bytes
        if ez.storage.read_bytes then
            label_bytes = ez.storage.read_bytes(path, 13, label_len)
        else
            local raw = ez.storage.read_file(path)
            label_bytes = raw and raw:sub(14, 13 + label_len)
        end
        label = label_bytes or ""
    end
    label = (label:gsub("[^\32-\126]", "?"))

    return {
        path       = path,
        flags      = flags,
        closed     = (flags & FLAG_CLOSED) ~= 0,
        start_unix = start_unix,
        label      = label,
        body_offset = 13 + label_len,
        size       = size,
    }
end

-- Decode the full polyline from a `.eztrack`. Returns array of:
--   { ts_unix, lat, lon, alt, hdop }
function M.load(path)
    local hdr, err = M.read_header(path)
    if not hdr then return nil, err end

    local body_size = hdr.size - hdr.body_offset
    if body_size <= 0 then
        return { header = hdr, points = {} }
    end
    local blob
    if ez.storage.read_bytes then
        blob = ez.storage.read_bytes(path, hdr.body_offset, body_size)
    else
        local raw = ez.storage.read_file(path)
        blob = raw and raw:sub(hdr.body_offset + 1, hdr.body_offset + body_size)
    end
    if not blob then return nil, "read failed" end

    local out = {}
    local i = 1
    while i + 12 <= #blob do
        local ts_delta = unpack_u16_le(blob, i)
        local lat_e6   = unpack_i32_le(blob, i + 2)
        local lon_e6   = unpack_i32_le(blob, i + 6)
        local alt_m    = unpack_i16_le(blob, i + 10)
        local hdop_t   = blob:byte(i + 12)
        out[#out + 1] = {
            ts_unix = hdr.start_unix + ts_delta,
            lat     = lat_e6 / 1e6,
            lon     = lon_e6 / 1e6,
            alt     = alt_m,
            hdop    = hdop_t / 10,
        }
        i = i + 13
    end

    return { header = hdr, points = out }
end

-- List `.eztrack` files under TRACK_DIR. Each entry: { path, name,
-- size, closed, start_unix, label }. Sorted newest-first by start_unix.
function M.list()
    local out = {}
    if not (ez.storage.list_dir and ez.storage.exists(TRACK_DIR)) then
        return out
    end
    local entries = ez.storage.list_dir(TRACK_DIR) or {}
    for _, e in ipairs(entries) do
        local name = e.name or ""
        if name:sub(-8) == ".eztrack" then
            local path = TRACK_DIR .. "/" .. name
            local hdr = M.read_header(path)
            if hdr then
                out[#out + 1] = {
                    path       = path,
                    name       = name,
                    size       = hdr.size,
                    closed     = hdr.closed,
                    start_unix = hdr.start_unix,
                    label      = hdr.label,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        return (a.start_unix or 0) > (b.start_unix or 0)
    end)
    return out
end

function M.delete(path)
    if not path or not ez.storage.exists(path) then return false end
    return ez.storage.remove(path) and true or false
end

-- ---------------------------------------------------------------------------
-- Recording lifecycle
-- ---------------------------------------------------------------------------

function M.is_active() return state.active end
function M.current()
    if not state.active then return nil end
    return {
        start_unix = state.start_unix,
        label      = state.label,
        path       = state.path,
        points     = state.points,
    }
end

-- Append a record now. Caller decides the gating; this just packs.
local function write_record(lat, lon, alt, hdop)
    if not state.active then return end
    local now = ez.system.get_time_unix and ez.system.get_time_unix() or 0
    local delta = math.max(0, math.min(0xFFFF, now - (state.start_unix or now)))
    local hdop_t = math.floor((hdop or 0) * 10 + 0.5)
    if hdop_t < 0 then hdop_t = 0 elseif hdop_t > 255 then hdop_t = 255 end
    local record = pack_u16_le(delta)
        .. pack_i32_le(to_e6(lat))
        .. pack_i32_le(to_e6(lon))
        .. pack_i16_le(math.floor((alt or 0) + 0.5))
        .. string.char(hdop_t)
    -- Best-effort append. A failed write here means the SD card vanished
    -- or filled up; we keep the in-RAM polyline so the live overlay
    -- doesn't go blank, and let stop() report the failure.
    ez.storage.append_file(state.path, record)

    state.last_point = { ts_ms = ez.system.millis(), lat = lat, lon = lon }
    local pts = state.points
    pts[#pts + 1] = { lat = lat, lon = lon }
    -- Cap the in-RAM ring so a multi-hour session doesn't bloat RAM;
    -- the canonical record lives on disk anyway.
    if #pts > state.points_cap then
        table.remove(pts, 1)
    end
end

-- Spawn the sampler coroutine once. Subsequent start() calls just flip
-- the `active` flag; the loop polls that flag and skips work otherwise.
local function ensure_sampler()
    if state.sampler_started then return end
    state.sampler_started = true
    spawn(function()
        while true do
            if state.active then
                local loc = gps_svc.is_enabled() and ez.gps.get_location() or nil
                if not (loc and loc.valid) then
                    -- Fix lost. Mark the gap so the next valid fix becomes a
                    -- new segment start (no implicit interpolation).
                    state.last_fix_valid = false
                else
                    local take = true
                    local lp = state.last_point
                    if lp then
                        -- Use millis() deltas (independent of any NTP jitter)
                        -- to gate the interval; the on-disk ts_delta is then
                        -- computed from the wall clock at write time.
                        local elapsed_ms = ez.system.millis() - (lp.ts_ms or 0)
                        if elapsed_ms < state.min_interval_s * 1000 then
                            take = false
                        elseif state.last_fix_valid and state.min_distance_m > 0 then
                            local d = haversine_m(lp.lat, lp.lon, loc.lat, loc.lon)
                            if d < state.min_distance_m then
                                take = false
                            end
                        end
                    end
                    if take then
                        local sats = ez.gps.get_satellites and ez.gps.get_satellites()
                        write_record(loc.lat, loc.lon, loc.alt or 0,
                            (sats and sats.hdop) or 0)
                    end
                    state.last_fix_valid = true
                end
            else
                state.last_point = nil
                state.last_fix_valid = true
            end
            local wake = ez.system.millis() + POLL_MS
            while ez.system.millis() < wake do defer() end
        end
    end)
end

-- Patch the on-disk flags byte (offset 6) to FLAG_CLOSED. Uses the
-- byte-level write_at binding so files larger than read_file's 1 MB
-- cap (roughly 22 h of recording at 1 s intervals) still finalise
-- correctly. A failure here leaves the file unfinalised; boot.lua's
-- reaper picks it up on next boot.
local function finalise_on_disk(path)
    if not path then return end
    local hdr = M.read_header(path)
    if not hdr or hdr.closed then return end
    if ez.storage.write_at then
        ez.storage.write_at(path, 6, string.char(FLAG_CLOSED))
        return
    end
    -- Fallback for firmware predating the write_at binding: read,
    -- patch, rewrite via a temp-and-rename so an interrupted write
    -- doesn't destroy the source file. Subject to read_file's 1 MB
    -- cap; sessions past that stay in-progress until the next boot.
    local raw = ez.storage.read_file(path)
    if not raw or #raw < 7 then return end
    local patched = raw:sub(1, 6) .. string.char(FLAG_CLOSED) .. raw:sub(8)
    local tmp = path .. ".tmp"
    if not ez.storage.write_file(tmp, patched) then return end
    -- rename() overwrites the target on the SD FAT layer; a power
    -- loss before rename leaves the tmp behind, which the boot
    -- reaper can clean up alongside its retry pass.
    ez.storage.rename(tmp, path)
end

-- Start a new session. Returns (true) on success or (nil, "reason").
function M.start(opts)
    if state.active then return nil, "already recording" end
    opts = opts or {}

    if not gps_svc.is_enabled() then
        return nil, "GPS is disabled in Settings"
    end

    local now_unix = ez.system.get_time_unix and ez.system.get_time_unix() or 0
    if now_unix <= 0 then
        return nil, "system clock not set"
    end

    ez.storage.mkdir(TRACK_DIR)

    local label = ascii_slug(opts.label or "track")
    local path = string.format("%s/%d-%s.eztrack", TRACK_DIR, now_unix, label)

    local interval = opts.min_interval_s
    local distance = opts.min_distance_m
    if not interval or not distance then
        local pi, pd = read_prefs()
        interval = interval or pi
        distance = distance or pd
    end

    local header = build_header(now_unix, label, 0)
    if not ez.storage.write_file(path, header) then
        return nil, "could not create file"
    end

    state.active     = true
    state.path       = path
    state.start_unix = now_unix
    state.label      = label
    state.points     = {}
    state.last_point = nil
    state.last_fix_valid = true
    state.min_interval_s = interval
    state.min_distance_m = distance

    ensure_sampler()
    return true
end

-- Stop the active session. Returns (info_table, nil) where info_table
-- has { path, points, label } from the just-finished session, or
-- (nil, "reason") if there was nothing to stop.
function M.stop()
    if not state.active then return nil, "not recording" end
    local finished = {
        path       = state.path,
        points     = state.points,
        label      = state.label,
        start_unix = state.start_unix,
    }
    state.active     = false
    finalise_on_disk(finished.path)
    state.path       = nil
    state.start_unix = nil
    state.label      = nil
    state.points     = nil
    return finished
end

-- Reap any unfinalised sessions on disk. Run from boot.lua; sets the
-- closed bit on every file whose flags byte is still zero so the user
-- doesn't see a perpetually "in progress" record after a power cut.
-- Also sweeps up leftover .eztrack.tmp files from a partial rewrite
-- in the write_file fallback path.
function M.reap_unfinalised()
    local entries = M.list()
    for _, e in ipairs(entries) do
        if not e.closed then finalise_on_disk(e.path) end
    end
    if ez.storage.list_dir and ez.storage.exists(TRACK_DIR) then
        for _, raw in ipairs(ez.storage.list_dir(TRACK_DIR) or {}) do
            local name = raw.name or ""
            if name:sub(-12) == ".eztrack.tmp" then
                ez.storage.remove(TRACK_DIR .. "/" .. name)
            end
        end
    end
end

-- Stable accessor for the in-progress polyline so the live overlay
-- doesn't reach into state directly.
function M.live_points()
    if not state.active then return nil end
    return state.points
end

return M
