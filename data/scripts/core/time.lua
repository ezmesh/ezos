-- Time utilities for ezOS
-- Pure time formatting functions with no UI dependencies

local Time = {}

-- Format a timestamp as relative time (e.g., "now", "5m", "2h", "3d")
-- @param timestamp Timestamp in milliseconds
-- @return Relative time string
function Time.format_relative(timestamp)
    if not timestamp then return "?" end

    local now = ez.system.millis()
    local diff = math.floor((now - timestamp) / 1000)

    if diff < 0 then
        return "future"
    elseif diff < 60 then
        return "now"
    elseif diff < 3600 then
        return string.format("%dm", math.floor(diff / 60))
    elseif diff < 86400 then
        return string.format("%dh", math.floor(diff / 3600))
    else
        return string.format("%dd", math.floor(diff / 86400))
    end
end

-- Format a timestamp as time of day (HH:MM)
-- @param timestamp Timestamp in milliseconds
-- @return Time string in HH:MM format
function Time.format_time(timestamp)
    if not timestamp then return "?" end

    -- Convert millis to seconds
    local secs = math.floor(timestamp / 1000)
    local hours = math.floor(secs / 3600) % 24
    local mins = math.floor(secs / 60) % 60

    return string.format("%02d:%02d", hours, mins)
end

-- Format a duration in milliseconds as human readable
-- @param ms Duration in milliseconds
-- @return Human readable duration string
function Time.format_duration(ms)
    if not ms then return "?" end

    local secs = math.floor(ms / 1000)
    if secs < 60 then
        return string.format("%ds", secs)
    elseif secs < 3600 then
        return string.format("%dm %ds", math.floor(secs / 60), secs % 60)
    else
        local hours = math.floor(secs / 3600)
        local mins = math.floor((secs % 3600) / 60)
        return string.format("%dh %dm", hours, mins)
    end
end

-- Format seconds as MM:SS (for timers, games)
-- @param seconds Number of seconds
-- @return Time string in MM:SS format
function Time.format_mm_ss(seconds)
    if not seconds then return "00:00" end
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%02d:%02d", mins, secs)
end

-- Format a Unix timestamp to date string
-- @param timestamp Unix timestamp in seconds
-- @return Date string in YYYY-MM-DD format
function Time.format_date(timestamp)
    if not timestamp then return "?" end
    -- Use os.date if available (simulator), otherwise basic calculation
    if os.date then
        return os.date("%Y-%m-%d", timestamp)
    end
    -- Fallback: just return the timestamp
    return tostring(timestamp)
end

-- Format a Unix timestamp to datetime string
-- @param timestamp Unix timestamp in seconds
-- @return Datetime string in YYYY-MM-DD HH:MM format
function Time.format_datetime(timestamp)
    if not timestamp then return "?" end
    if os.date then
        return os.date("%Y-%m-%d %H:%M", timestamp)
    end
    return tostring(timestamp)
end

-- Get current time as Unix timestamp in seconds
-- @return Current Unix timestamp
function Time.now()
    if ez.system and ez.system.get_time then
        return ez.system.get_time()
    end
    return os.time and os.time() or 0
end

-- Get current time in milliseconds (monotonic)
-- @return Current time in milliseconds
function Time.millis()
    if ez.system and ez.system.millis then
        return ez.system.millis()
    end
    return 0
end

return Time
