-- General utilities for ezOS
-- Pure functions with no UI dependencies

local Utils = {}

--------------------------------------------------------------------------------
-- Preferences
--------------------------------------------------------------------------------

-- Get a preference value with default fallback
-- @param key Preference key
-- @param default Default value if not found
-- @return The preference value or default
function Utils.get_pref(key, default)
    if ez.storage and ez.storage.get_pref then
        return ez.storage.get_pref(key, default)
    end
    return default
end

-- Set a preference value
-- @param key Preference key
-- @param value Value to store
function Utils.set_pref(key, value)
    if ez.storage and ez.storage.set_pref then
        ez.storage.set_pref(key, value)
    end
end

--------------------------------------------------------------------------------
-- String utilities
--------------------------------------------------------------------------------

-- Sanitize a string to printable ASCII only
-- @param str Input string
-- @return String with only printable ASCII characters (32-126)
function Utils.sanitize_ascii(str)
    if not str then return "" end
    local clean = ""
    for i = 1, #str do
        local b = str:byte(i)
        if b >= 32 and b < 127 then
            clean = clean .. str:sub(i, i)
        end
    end
    return clean
end

-- Trim whitespace from both ends of a string
-- @param str Input string
-- @return Trimmed string
function Utils.trim(str)
    if not str then return "" end
    return str:match("^%s*(.-)%s*$")
end

-- Check if string starts with prefix
-- @param str Input string
-- @param prefix Prefix to check
-- @return true if str starts with prefix
function Utils.starts_with(str, prefix)
    if not str or not prefix then return false end
    return str:sub(1, #prefix) == prefix
end

-- Check if string ends with suffix
-- @param str Input string
-- @param suffix Suffix to check
-- @return true if str ends with suffix
function Utils.ends_with(str, suffix)
    if not str or not suffix then return false end
    return str:sub(-#suffix) == suffix
end

-- Split a string by delimiter
-- @param str Input string
-- @param delimiter Delimiter to split on (default: space)
-- @return Array of substrings
function Utils.split(str, delimiter)
    if not str then return {} end
    delimiter = delimiter or " "
    local result = {}
    local pattern = string.format("([^%s]+)", delimiter)
    for match in str:gmatch(pattern) do
        table.insert(result, match)
    end
    return result
end

--------------------------------------------------------------------------------
-- Table utilities
--------------------------------------------------------------------------------

-- Shallow copy a table
-- @param t Table to copy
-- @return New table with same key-value pairs
function Utils.shallow_copy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = v
    end
    return copy
end

-- Merge two tables (second overwrites first)
-- @param t1 Base table
-- @param t2 Table to merge in
-- @return New merged table
function Utils.merge(t1, t2)
    local result = Utils.shallow_copy(t1 or {})
    if t2 then
        for k, v in pairs(t2) do
            result[k] = v
        end
    end
    return result
end

-- Get table length (works for non-sequential tables)
-- @param t Table to count
-- @return Number of key-value pairs
function Utils.table_length(t)
    if not t then return 0 end
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

-- Check if table contains a value
-- @param t Table to search
-- @param value Value to find
-- @return true if found
function Utils.contains(t, value)
    if not t then return false end
    for _, v in pairs(t) do
        if v == value then return true end
    end
    return false
end

-- Get keys of a table as an array
-- @param t Table
-- @return Array of keys
function Utils.keys(t)
    if not t then return {} end
    local result = {}
    for k in pairs(t) do
        table.insert(result, k)
    end
    return result
end

-- Get values of a table as an array
-- @param t Table
-- @return Array of values
function Utils.values(t)
    if not t then return {} end
    local result = {}
    for _, v in pairs(t) do
        table.insert(result, v)
    end
    return result
end

--------------------------------------------------------------------------------
-- Number utilities
--------------------------------------------------------------------------------

-- Clamp a number between min and max
-- @param value Number to clamp
-- @param min Minimum value
-- @param max Maximum value
-- @return Clamped value
function Utils.clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

-- Linear interpolation
-- @param a Start value
-- @param b End value
-- @param t Interpolation factor (0-1)
-- @return Interpolated value
function Utils.lerp(a, b, t)
    return a + (b - a) * t
end

-- Round to nearest integer
-- @param value Number to round
-- @return Rounded integer
function Utils.round(value)
    return math.floor(value + 0.5)
end

return Utils
