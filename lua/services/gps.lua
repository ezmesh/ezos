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
