-- services/gps: user-facing gate around the ez.gps binding.
--
-- The hardware UART is always parsing NMEA on-device (see src/main.cpp),
-- so "on-demand" mode here is a UI gate rather than a power saving — screens
-- that ask for a fix via this service get nil when the user has GPS turned
-- off in settings. Time-sync runs as a long-lived coroutine started at boot.
--
-- Preferences (stored under NVS via ez.storage.get_pref):
--   gps_enabled   : boolean (default true)        power gate
--   gps_sync_mode : "never" | "boot" | "hourly"   clock sync cadence

local gps = {}

local PREF_ENABLED   = "gps_enabled"
local PREF_SYNC_MODE = "gps_sync_mode"

local DEFAULTS = {
    enabled   = true,
    sync_mode = "boot",
}

-- ---------------------------------------------------------------------------
-- Preference helpers
-- ---------------------------------------------------------------------------

local function pref_bool(key, default)
    local v = ez.storage.get_pref(key, nil)
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
    if type(v) == "string" then return v == "1" or v == "true" end
    return default
end

function gps.is_enabled()
    return pref_bool(PREF_ENABLED, DEFAULTS.enabled)
end

function gps.set_enabled(v)
    ez.storage.set_pref(PREF_ENABLED, v and true or false)
end

function gps.get_sync_mode()
    local v = ez.storage.get_pref(PREF_SYNC_MODE, DEFAULTS.sync_mode)
    if v == "never" or v == "boot" or v == "hourly" then return v end
    return DEFAULTS.sync_mode
end

function gps.set_sync_mode(mode)
    ez.storage.set_pref(PREF_SYNC_MODE, mode)
end

-- ---------------------------------------------------------------------------
-- Data access (gated)
-- ---------------------------------------------------------------------------

-- Returns the GPS location table (lat, lon, alt, valid, age) when the user
-- has GPS enabled. Returns nil otherwise — callers should treat nil identically
-- to "no fix" so code paths stay simple.
function gps.get_location()
    if not gps.is_enabled() then return nil end
    return ez.gps.get_location()
end

function gps.get_time()
    if not gps.is_enabled() then return nil end
    return ez.gps.get_time()
end

function gps.get_satellites()
    if not gps.is_enabled() then return nil end
    return ez.gps.get_satellites()
end

-- ---------------------------------------------------------------------------
-- Chip identification + constellation control (UBX)
-- ---------------------------------------------------------------------------
--
-- The T-Deck Plus ships with one of two GPS variants — u-blox MIA-M10Q or
-- Quectel L76K. We probe via UBX-MON-VER on demand and look up the chip's
-- capabilities in CHIP_TABLE. Constellation toggles are written via UBX-
-- CFG-VALSET into RAM + BBR (the M10Q ROM variant won't accept Flash
-- writes), so the change persists across warm boots — the chip's onboard
-- VBAT keeps BBR alive.
--
-- The capability table lists, for each known chip, which constellations
-- the silicon can actually decode. The MIA-M10Q is GPS / Galileo / BeiDou
-- / QZSS / SBAS only — its single L1 RF front-end can't tune GLONASS L1
-- (FDMA at 1602 MHz), so the chip NAKs any VALSET that tries to enable it.

local CHIP_TABLE = {
    -- hwVersion prefix -> capability bundle.
    ["000A"] = {
        name = "u-blox M10",
        constellations = {
            { id = "gps",     label = "GPS",     key = 0x1031001F,
              locked = true,
              hint = "Required for any fix. Can't be disabled." },
            { id = "galileo", label = "Galileo", key = 0x10310021 },
            { id = "beidou",  label = "BeiDou",  key = 0x10310022 },
            { id = "qzss",    label = "QZSS",    key = 0x10310024,
              hint = "Regional augmentation over Asia/Oceania." },
            { id = "sbas",    label = "SBAS",    key = 0x10310020,
              hint = "Wide-area corrections (WAAS/EGNOS). Needs GPS." },
            -- No GLONASS entry: the MIA-M10Q variant on this board's
            -- single L1 front-end can't decode GLONASS L1; VALSET to
            -- enable GLO_ENA gets NAK'd. Other M10 variants (MAX-M10S
            -- etc.) do support it — if we ever ship on those, split
            -- the table by hwVersion + swVersion combo.
        },
    },
}

-- Fallback used when MON-VER doesn't match anything in CHIP_TABLE. We
-- present the M10's constellation list with a warning flag the UI
-- displays so the user knows the rows are best-effort.
local UNKNOWN_CAPS = {
    name = "Unknown",
    unknown = true,
    constellations = CHIP_TABLE["000A"].constellations,
}

local _chip_info = nil  -- last successful query_chip() result, with .capabilities attached

-- Look the chip up in CHIP_TABLE by hwVersion prefix.
local function match_caps(info)
    if not info or not info.hw then return nil end
    for prefix, caps in pairs(CHIP_TABLE) do
        if info.hw:sub(1, #prefix) == prefix then return caps end
    end
    return nil
end

-- Probe the GPS via UBX-MON-VER and cache the result. Returns the table
-- { hw, sw, capabilities } or nil if the module didn't reply (e.g. it's
-- the L76K variant, which doesn't speak UBX).
function gps.identify_chip(timeout_ms)
    if _chip_info then return _chip_info end
    local info = ez.gps.query_chip(timeout_ms or 1000)
    if not info then return nil end
    info.capabilities = match_caps(info) or UNKNOWN_CAPS
    _chip_info = info
    return info
end

-- Cached result without re-probing.
function gps.get_chip_info()
    return _chip_info or ez.gps.get_chip_info()
end

-- The capability table for the detected chip. Returns UNKNOWN_CAPS if
-- detection has run but didn't recognise the chip, or nil if detection
-- hasn't run yet.
function gps.get_capabilities()
    local info = _chip_info or gps.identify_chip(500)
    if not info then return nil end
    return info.capabilities
end

local function find_constellation(id)
    local caps = gps.get_capabilities()
    if not caps then return nil end
    for _, c in ipairs(caps.constellations) do
        if c.id == id then return c end
    end
    return nil
end

-- Read a constellation's current state from the chip. Returns true,
-- false, or nil (timeout / unknown id).
function gps.read_constellation(id)
    local c = find_constellation(id)
    if not c then return nil end
    return ez.gps.get_signal_enabled(c.key, 300)
end

-- Toggle a constellation; returns true on ACK, false on NAK / timeout.
-- Setting `gps` off is rejected at this layer because every fix
-- depends on it — even an accidental toggle shouldn't kill the
-- receiver until the user manually re-enables in u-center.
function gps.write_constellation(id, on)
    local c = find_constellation(id)
    if not c then return false end
    if c.locked and not on then return false end
    return ez.gps.set_signal_enabled(c.key, on, 800)
end

-- ---------------------------------------------------------------------------
-- Time sync background loop
-- ---------------------------------------------------------------------------

local HOUR_MS = 3600 * 1000
local POLL_MS = 2000    -- how often to check for a fix

-- Internal state so multiple start() calls don't stack coroutines.
local _sync_started = false

local function try_sync_once(max_wait_ms)
    local started = ez.system.millis()
    while ez.system.millis() - started < max_wait_ms do
        if gps.is_enabled() then
            -- Time doesn't need a position fix — the module emits a valid
            -- UTC in GPRMC/GPZDA as soon as it's decoded the time-of-week
            -- from any tracked satellite, usually well before enough sats
            -- are locked for a 2D/3D fix. The year >= 2024 guard rejects
            -- the parser's initial "valid but zeroed" state.
            local t = ez.gps.get_time()
            if t and t.valid and (t.year or 0) >= 2024 then
                local ok = ez.gps.sync_time()
                if ok then
                    ez.log("[gps] synced system clock to GPS time")
                    return true
                end
            end
        end
        -- Sleep in small chunks so toggling the enable flag takes effect quickly.
        local wake = ez.system.millis() + POLL_MS
        while ez.system.millis() < wake do defer() end
    end
    return false
end

-- Start the sync coroutine. Idempotent — safe to call from boot.
function gps.start_sync_loop()
    if _sync_started then return end
    _sync_started = true

    spawn(function()
        while true do
            local mode = gps.get_sync_mode()
            if mode == "boot" then
                try_sync_once(5 * 60 * 1000)
                -- After a successful or failed boot sync, park forever —
                -- user can re-sync by toggling the mode in settings.
                while gps.get_sync_mode() == "boot" do
                    local wake = ez.system.millis() + 30 * 1000
                    while ez.system.millis() < wake do defer() end
                end
            elseif mode == "hourly" then
                try_sync_once(2 * 60 * 1000)
                local next_sync = ez.system.millis() + HOUR_MS
                while ez.system.millis() < next_sync and gps.get_sync_mode() == "hourly" do
                    local wake = ez.system.millis() + 30 * 1000
                    while ez.system.millis() < wake do defer() end
                end
            else
                -- "never" — poll the mode occasionally in case the user enables it.
                local wake = ez.system.millis() + 30 * 1000
                while ez.system.millis() < wake do defer() end
            end
        end
    end)
end

return gps
