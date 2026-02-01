-- Logger service for T-Deck OS
-- Writes logs to file in FIFO manner

local Logger = {
    -- Log levels
    LEVELS = {
        DEBUG = 1,
        INFO = 2,
        WARN = 3,
        ERROR = 4,
    },

    -- Configuration
    level = 2,  -- INFO default
    file_path = "/system.log",
    max_lines = 100,
    max_line_len = 80,

    -- Cached log entries (in memory for viewer)
    entries = {},
    initialized = false,
}

-- Level names for display
local LEVEL_NAMES = {"DBG", "INF", "WRN", "ERR"}

function Logger.init()
    if Logger.initialized then return end

    -- Load existing log file
    Logger.entries = {}
    local content = ez.storage.read(Logger.file_path)
    if content then
        for line in content:gmatch("[^\n]+") do
            table.insert(Logger.entries, line)
        end
    end

    Logger.initialized = true
    Logger.info("Logger initialized")
end

function Logger.set_level(level)
    if type(level) == "string" then
        level = Logger.LEVELS[level:upper()] or Logger.LEVELS.INFO
    end
    Logger.level = level
end

function Logger._log(level, msg)
    if level < Logger.level then return end

    -- Format: [HH:MM:SS] LVL message
    local uptime = ez.system.uptime()
    local h = math.floor(uptime / 3600) % 24
    local m = math.floor(uptime / 60) % 60
    local s = uptime % 60
    local timestamp = string.format("[%02d:%02d:%02d]", h, m, s)

    local level_name = LEVEL_NAMES[level] or "???"
    local line = timestamp .. " " .. level_name .. " " .. msg

    -- Truncate if too long
    if #line > Logger.max_line_len then
        line = line:sub(1, Logger.max_line_len - 3) .. "..."
    end

    -- Also log to serial
    ez.log(line)

    -- Add to in-memory buffer
    table.insert(Logger.entries, line)

    -- Trim FIFO
    while #Logger.entries > Logger.max_lines do
        table.remove(Logger.entries, 1)
    end
end

function Logger.debug(msg) Logger._log(Logger.LEVELS.DEBUG, msg) end
function Logger.info(msg) Logger._log(Logger.LEVELS.INFO, msg) end
function Logger.warn(msg) Logger._log(Logger.LEVELS.WARN, msg) end
function Logger.error(msg) Logger._log(Logger.LEVELS.ERROR, msg) end

-- Alias for compatibility with ez.log pattern
function Logger.log(msg) Logger._log(Logger.LEVELS.INFO, msg) end

-- Save log to file (call periodically or on exit)
function Logger.save()
    local content = table.concat(Logger.entries, "\n")
    ez.storage.write(Logger.file_path, content)
end

-- Get all log entries (for viewer)
function Logger.get_entries()
    return Logger.entries
end

-- Clear log
function Logger.clear()
    Logger.entries = {}
    ez.storage.write(Logger.file_path, "")
    Logger.info("Log cleared")
end

return Logger
