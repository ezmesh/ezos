-- Persistent log service.
--
-- The C side keeps a 16 KiB in-memory ring buffer of every LOG()
-- and ez.log() call (see src/util/log.cpp). That buffer is great
-- for live debugging but disappears the moment the device reboots.
-- This service teesthe buffer to flash so we can scroll back the
-- last several boots' worth of activity from the on-device shell.
--
-- Strategy:
--   1. Drain the ring every FLUSH_INTERVAL_MS via ez.system.drain_logs().
--   2. Append the new bytes to /fs/logs/system.log.
--   3. When system.log exceeds MAX_FILE_BYTES, rotate it to
--      system.log.old (overwriting whatever was there before) and
--      start a fresh current file. Two-file rotation gives ~2x
--      MAX_FILE_BYTES of history while keeping flash wear bounded.
--   4. On boot, stamp a marker line that records the reset reason --
--      "panic" / "task_wdt" / "brownout" make a previous crash obvious
--      even when the actual stack trace was lost (the panic happens
--      faster than we can flush the ring to flash).
--
-- The shell `logs` command reads back system.log.old + system.log
-- and prints the requested tail.

local M = {}

local LOG_DIR        = "/fs/logs"
local CURRENT_PATH   = LOG_DIR .. "/system.log"
local ROTATED_PATH   = LOG_DIR .. "/system.log.old"

-- Per-file cap. 64 KiB is roughly 1k lines at the typical 60 chars/
-- line average -- enough to span a couple of boot cycles with a
-- comfortable margin of post-boot activity. Two of these (.old +
-- current) means ~128 KiB of on-disk history.
local MAX_FILE_BYTES = 64 * 1024

-- Drain cadence. The C-side panic flush (log_panic_flush in
-- src/util/log.cpp) covers caught Lua errors and graceful
-- shutdowns, so the ring almost always survives even if the
-- periodic flusher is mid-sleep when a crash hits. The cadence
-- below sets the worst-case loss window for *uncaught* panics
-- that bypass both hooks; 1 s feels like the right floor on
-- LittleFS -- tighter intervals start to dominate the flash wear
-- budget without meaningfully shrinking the loss window.
local FLUSH_INTERVAL_MS = 1000

-- Cached current-file size so we don't stat() before every flush.
-- Updated as we append; resync'd when we rotate.
local current_size = 0

local function ensure_dir()
    -- mkdir is idempotent, so it's cheaper than a separate exists()
    -- check + conditional create.
    ez.storage.mkdir(LOG_DIR)
end

local function file_size(path)
    -- ez.storage.size() isn't exposed everywhere, so fall back to
    -- read-and-measure when needed. The current file is small (<=
    -- MAX_FILE_BYTES) so the read is cheap.
    if ez.storage.get_file_size then
        return ez.storage.get_file_size(path) or 0
    end
    local data = ez.storage.read_file(path)
    return data and #data or 0
end

-- Append `chunk` to CURRENT_PATH, rotating first if the new size
-- would push over MAX_FILE_BYTES. We use ez.storage.append_file
-- (LittleFS open with mode "a") rather than read-modify-write
-- because the C-side panic flush also appends to this file --
-- read-modify-write would silently discard panic-appended bytes
-- on the next periodic flush.
local function append_or_rotate(chunk)
    if current_size + #chunk > MAX_FILE_BYTES then
        local old = ez.storage.read_file(CURRENT_PATH)
        if old then
            ez.storage.write_file(ROTATED_PATH, old)
        end
        ez.storage.write_file(CURRENT_PATH, chunk)
        current_size = #chunk
        return
    end
    if ez.storage.append_file(CURRENT_PATH, chunk) then
        current_size = current_size + #chunk
    end
end

local function flush_now()
    -- Loop in case the cumulative pending bytes exceed the per-call
    -- cap (default 4 KiB in the C binding). Bail when drain returns
    -- empty -- guarantees forward progress.
    while true do
        local chunk = ez.system.drain_logs()
        if not chunk or #chunk == 0 then return end
        append_or_rotate(chunk)
    end
end

-- Stamp a single line at the start of every boot session. Records
-- the reset reason (so a previous panic / watchdog / brownout is
-- obvious in the history) and a unix timestamp for human-friendly
-- correlation with the live serial log.
local function write_session_header()
    local reason = "unknown"
    if ez.system.get_reset_reason then
        reason = ez.system.get_reset_reason()
    end
    local ts = ez.system.get_time_unix and ez.system.get_time_unix() or 0
    local marker = string.format(
        "==== boot %s reset=%s uptime_ms=%d ====\n",
        os.date("%Y-%m-%d %H:%M:%S", ts),
        reason,
        ez.system.millis())
    -- Reuse the same append path so rotation logic only lives in
    -- one place. The marker isn't routed through the ring buffer
    -- because a) it'd inherit the [Lua] tag from ez.log, which
    -- would muddy the visual separator, and b) we want it on disk
    -- *before* the rest of the boot session so the structure of
    -- "header, then everything else" is preserved.
    append_or_rotate(marker)
    -- For panic-class reasons, also surface a notification-friendly
    -- log line so the user notices when scrolling the live tail.
    if reason == "panic" or reason == "task_wdt"
       or reason == "int_wdt" or reason == "brownout"
       or reason == "wdt" then
        ez.log("[log_persist] previous boot ended in " .. reason)
    end
end

-- Read both rotated + current and return the last `n` lines. If
-- `n` is nil or 0, returns everything we have.
function M.read_tail(n)
    local old     = ez.storage.read_file(ROTATED_PATH) or ""
    local current = ez.storage.read_file(CURRENT_PATH) or ""
    local all = old .. current
    if not n or n <= 0 then return all end

    -- Split-from-the-back so we don't pay for tokenising the entire
    -- file when the user only wants the last 50 lines.
    local lines = {}
    local pos = #all
    while pos > 0 and #lines < n do
        local nl = all:sub(1, pos):find("\n[^\n]*$")
        if not nl then
            lines[#lines + 1] = all:sub(1, pos)
            break
        end
        lines[#lines + 1] = all:sub(nl + 1, pos)
        pos = nl - 1
    end
    -- Reverse to chronological order.
    local out = {}
    for i = #lines, 1, -1 do out[#out + 1] = lines[i] end
    return table.concat(out, "\n")
end

function M.get_paths()
    return CURRENT_PATH, ROTATED_PATH
end

-- Force an immediate flush. Useful right before something the
-- caller suspects might crash (e.g. firmware OTA apply, an
-- unstable driver init) so the log file has the most recent
-- in-memory bytes already on disk if the device hangs after.
function M.flush()
    flush_now()
end

function M.init()
    ensure_dir()
    current_size = file_size(CURRENT_PATH)
    write_session_header()
    -- Drain whatever the boot sequence has already pushed into the
    -- ring before we go periodic.
    flush_now()
    ez.system.set_interval(FLUSH_INTERVAL_MS, flush_now)
    ez.log("[log_persist] active -> " .. CURRENT_PATH)
end

return M
