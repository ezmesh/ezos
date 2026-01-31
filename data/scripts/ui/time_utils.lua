-- Time Utilities for T-Deck OS
-- Shared time formatting functions

local TimeUtils = {}

-- Format a timestamp as relative time (e.g., "now", "5m", "2h", "3d")
function TimeUtils.format_relative(timestamp)
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
function TimeUtils.format_time(timestamp)
    if not timestamp then return "?" end

    -- Convert millis to seconds
    local secs = math.floor(timestamp / 1000)
    local hours = math.floor(secs / 3600) % 24
    local mins = math.floor(secs / 60) % 60

    return string.format("%02d:%02d", hours, mins)
end

-- Format a duration in milliseconds as human readable
function TimeUtils.format_duration(ms)
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

return TimeUtils
