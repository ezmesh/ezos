-- TimezoneSync Service for T-Deck OS
-- Automatically syncs timezone based on GPS location

local TimezoneSync = {
    enabled = false,
    synced = false,  -- Has timezone been synced this session?
    last_sync_lat = nil,
    last_sync_lon = nil,
    check_interval = nil,  -- Timer ID for periodic checks
}

-- City coordinates for timezone lookup {lat, lon}
-- Duplicated here to avoid circular dependency with settings_category
local TIMEZONE_COORDS = {
    ["UTC"] = {0, 0},
    -- Europe
    ["London"] = {51.51, -0.13},
    ["Amsterdam"] = {52.37, 4.90},
    ["Berlin"] = {52.52, 13.40},
    ["Paris"] = {48.86, 2.35},
    ["Madrid"] = {40.42, -3.70},
    ["Rome"] = {41.90, 12.50},
    ["Helsinki"] = {60.17, 24.94},
    ["Athens"] = {37.98, 23.73},
    ["Moscow"] = {55.76, 37.62},
    -- Middle East / Africa
    ["Cairo"] = {30.04, 31.24},
    ["Jerusalem"] = {31.77, 35.23},
    ["Dubai"] = {25.20, 55.27},
    ["Nairobi"] = {-1.29, 36.82},
    ["Lagos"] = {6.52, 3.38},
    ["Johannesburg"] = {-26.20, 28.04},
    -- Asia
    ["Mumbai"] = {19.08, 72.88},
    ["Karachi"] = {24.86, 67.01},
    ["Almaty"] = {43.24, 76.95},
    ["Bangkok"] = {13.76, 100.50},
    ["Jakarta"] = {-6.21, 106.85},
    ["Singapore"] = {1.35, 103.82},
    ["Hong Kong"] = {22.32, 114.17},
    ["Shanghai"] = {31.23, 121.47},
    ["Manila"] = {14.60, 120.98},
    ["Tokyo"] = {35.68, 139.69},
    ["Seoul"] = {37.57, 126.98},
    -- Oceania
    ["Perth"] = {-31.95, 115.86},
    ["Sydney"] = {-33.87, 151.21},
    ["Brisbane"] = {-27.47, 153.03},
    ["Auckland"] = {-36.85, 174.76},
    -- Americas
    ["Anchorage"] = {61.22, -149.90},
    ["Los Angeles"] = {34.05, -118.24},
    ["Denver"] = {39.74, -104.99},
    ["Chicago"] = {41.88, -87.63},
    ["New York"] = {40.71, -74.01},
    ["Toronto"] = {43.65, -79.38},
    ["Halifax"] = {44.65, -63.57},
    ["Sao Paulo"] = {-23.55, -46.63},
    ["Buenos Aires"] = {-34.60, -58.38},
}

-- POSIX timezone strings for each city
-- ESP32 newlib has issues with some DST rule formats, so we use simplified strings
-- Format: STDoffset[DST[offset],start,end] where times default to 02:00
local TIMEZONE_POSIX = {
    ["UTC"] = "UTC0",
    -- Europe (EU DST: last Sunday March 02:00 -> last Sunday October 03:00)
    -- Using simplified format without explicit times for ESP32 compatibility
    ["London"] = "GMT0BST,M3.5.0,M10.5.0",
    ["Amsterdam"] = "CET-1CEST,M3.5.0,M10.5.0",
    ["Berlin"] = "CET-1CEST,M3.5.0,M10.5.0",
    ["Paris"] = "CET-1CEST,M3.5.0,M10.5.0",
    ["Madrid"] = "CET-1CEST,M3.5.0,M10.5.0",
    ["Rome"] = "CET-1CEST,M3.5.0,M10.5.0",
    ["Helsinki"] = "EET-2EEST,M3.5.0,M10.5.0",
    ["Athens"] = "EET-2EEST,M3.5.0,M10.5.0",
    ["Moscow"] = "MSK-3",
    ["Cairo"] = "EET-2",
    ["Jerusalem"] = "IST-2IDT,M3.5.0,M10.5.0",
    ["Dubai"] = "GST-4",
    ["Nairobi"] = "EAT-3",
    ["Lagos"] = "WAT-1",
    ["Johannesburg"] = "SAST-2",
    ["Mumbai"] = "IST-5:30",
    ["Karachi"] = "PKT-5",
    ["Almaty"] = "ALMT-6",
    ["Bangkok"] = "ICT-7",
    ["Jakarta"] = "WIB-7",
    ["Singapore"] = "SGT-8",
    ["Hong Kong"] = "HKT-8",
    ["Shanghai"] = "CST-8",
    ["Manila"] = "PHT-8",
    ["Tokyo"] = "JST-9",
    ["Seoul"] = "KST-9",
    ["Perth"] = "AWST-8",
    ["Sydney"] = "AEST-10AEDT,M10.1.0,M4.1.0",
    ["Brisbane"] = "AEST-10",
    ["Auckland"] = "NZST-12NZDT,M9.5.0,M4.1.0",
    ["Anchorage"] = "AKST9AKDT,M3.2.0,M11.1.0",
    ["Los Angeles"] = "PST8PDT,M3.2.0,M11.1.0",
    ["Denver"] = "MST7MDT,M3.2.0,M11.1.0",
    ["Chicago"] = "CST6CDT,M3.2.0,M11.1.0",
    ["New York"] = "EST5EDT,M3.2.0,M11.1.0",
    ["Toronto"] = "EST5EDT,M3.2.0,M11.1.0",
    ["Halifax"] = "AST4ADT,M3.2.0,M11.1.0",
    ["Sao Paulo"] = "BRT3BRST,M10.3.0,M2.3.0",
    ["Buenos Aires"] = "ART3",
}

-- Timezone options list (must match settings order)
local TIMEZONE_OPTIONS = {
    "UTC",
    "London", "Amsterdam", "Berlin", "Paris", "Madrid", "Rome",
    "Helsinki", "Athens", "Moscow",
    "Cairo", "Jerusalem", "Dubai", "Nairobi", "Lagos", "Johannesburg",
    "Mumbai", "Karachi", "Almaty", "Bangkok", "Jakarta", "Singapore",
    "Hong Kong", "Shanghai", "Manila", "Tokyo", "Seoul",
    "Perth", "Sydney", "Brisbane", "Auckland",
    "Anchorage", "Los Angeles", "Denver", "Chicago", "New York",
    "Toronto", "Halifax", "Sao Paulo", "Buenos Aires"
}

-- Calculate approximate distance between two coordinates (in km)
-- Uses equirectangular approximation which is fast and accurate enough for timezone selection
local function distance_km(lat1, lon1, lat2, lon2)
    local R = 6371  -- Earth radius in km
    local rad = math.pi / 180
    local x = (lon2 - lon1) * rad * math.cos((lat1 + lat2) / 2 * rad)
    local y = (lat2 - lat1) * rad
    return R * math.sqrt(x * x + y * y)
end

-- Find the nearest timezone city from given coordinates
-- Returns city name and distance in km
function TimezoneSync.find_nearest_timezone(lat, lon)
    local nearest_city = "UTC"
    local nearest_dist = math.huge

    for city, coords in pairs(TIMEZONE_COORDS) do
        local dist = distance_km(lat, lon, coords[1], coords[2])
        if dist < nearest_dist then
            nearest_dist = dist
            nearest_city = city
        end
    end

    return nearest_city, nearest_dist
end

-- Get the index of a timezone city in the options list
local function get_timezone_index(city_name)
    for i, name in ipairs(TIMEZONE_OPTIONS) do
        if name == city_name then
            return i
        end
    end
    return 1  -- Default to UTC
end

-- Sync timezone from current GPS location
-- Returns true if timezone was updated, false otherwise
function TimezoneSync.sync_from_gps()
    if not tdeck.gps or not tdeck.gps.has_fix then
        return false
    end

    if not tdeck.gps.has_fix() then
        tdeck.system.log("[TimezoneSync] No GPS fix, skipping")
        return false
    end

    local lat = tdeck.gps.get_latitude()
    local lon = tdeck.gps.get_longitude()

    if not lat or not lon then
        return false
    end

    -- Check if we've already synced from this location (within ~50km)
    if TimezoneSync.synced and TimezoneSync.last_sync_lat and TimezoneSync.last_sync_lon then
        local moved = distance_km(lat, lon, TimezoneSync.last_sync_lat, TimezoneSync.last_sync_lon)
        if moved < 50 then
            -- Haven't moved significantly, no need to re-sync
            return false
        end
    end

    local nearest_city, dist = TimezoneSync.find_nearest_timezone(lat, lon)
    local tz_posix = TIMEZONE_POSIX[nearest_city]

    if not tz_posix then
        tdeck.system.log("[TimezoneSync] No POSIX string for " .. nearest_city)
        return false
    end

    -- Get current timezone to check if it's different
    local current_tz = tdeck.storage.get_pref("timezonePosix", "UTC0")
    if current_tz == tz_posix then
        -- Already set to this timezone
        TimezoneSync.synced = true
        TimezoneSync.last_sync_lat = lat
        TimezoneSync.last_sync_lon = lon
        return false
    end

    -- Apply the new timezone
    if tdeck.system and tdeck.system.set_timezone then
        tdeck.system.set_timezone(tz_posix)
    end

    -- Save to preferences
    local tz_index = get_timezone_index(nearest_city)
    tdeck.storage.set_pref("timezone", tz_index)
    tdeck.storage.set_pref("timezonePosix", tz_posix)

    TimezoneSync.synced = true
    TimezoneSync.last_sync_lat = lat
    TimezoneSync.last_sync_lon = lon

    tdeck.system.log(string.format("[TimezoneSync] Set timezone to %s (%.0f km away)", nearest_city, dist))

    -- Show toast notification
    if _G.Toast and _G.Toast.show then
        _G.Toast.show("Timezone: " .. nearest_city, 3000)
    end

    return true
end

-- Periodic check for GPS-based timezone sync
local function check_gps_timezone()
    if not TimezoneSync.enabled then
        return
    end

    -- Only sync once per session (unless location changes significantly)
    TimezoneSync.sync_from_gps()
end

-- Initialize the service
function TimezoneSync.init()
    -- Load setting from preferences
    local enabled = tdeck.storage.get_pref("autoTimezoneGps", false)
    TimezoneSync.enabled = (enabled == true or enabled == "true")

    if TimezoneSync.enabled then
        -- Start periodic checks (every 30 seconds)
        TimezoneSync.check_interval = set_interval(check_gps_timezone, 30000)
        tdeck.system.log("[TimezoneSync] Enabled, checking GPS periodically")

        -- Try to sync immediately if GPS already has a fix
        TimezoneSync.sync_from_gps()
    end
end

-- Enable or disable auto timezone sync
function TimezoneSync.set_enabled(enabled)
    TimezoneSync.enabled = enabled

    if enabled then
        -- Start periodic checks if not already running
        if not TimezoneSync.check_interval then
            TimezoneSync.check_interval = set_interval(check_gps_timezone, 30000)
        end
        -- Try to sync immediately
        TimezoneSync.sync_from_gps()
    else
        -- Stop periodic checks
        if TimezoneSync.check_interval then
            clear_interval(TimezoneSync.check_interval)
            TimezoneSync.check_interval = nil
        end
    end
end

-- Register as global
_G.TimezoneSync = TimezoneSync

return TimezoneSync
