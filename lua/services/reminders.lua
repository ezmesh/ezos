-- Reminders service
-- Stores a queue of upcoming event reminders (from cal/v1 share cards
-- and any future producer) and fires a notification at `ts - 10min`
-- and again at `ts`.
--
-- Design:
-- - Single periodic tick rather than per-event timers. The C++ side
--   only has 16 timer slots (see src/lua/bindings/system_bindings.cpp,
--   MAX_TIMERS); giving every event its own pair would exhaust that
--   pool quickly. One 30-second sweep is cheap and gives sub-minute
--   accuracy, which is plenty for "meet at 18:00" semantics.
-- - State is persisted to NVS so reminders survive a reboot. The
--   format is a flat semicolon-separated record set; the keys live
--   under PREF_KEY (15-char NVS limit).
-- - Each reminder carries flags noting which fire points have already
--   been delivered, so a tick that runs during the window doesn't
--   spam the queue. Cleared reminders (fully fired + start time in
--   the past) are pruned on save.
--
-- Bus topic emitted on every change so a future "Reminders" screen
-- can rebuild without polling: `reminders/changed`, payload nil.

local reminders = {}

local PREF_KEY = "reminders_v1"
local TICK_MS = 30 * 1000
local PRE_NOTIFY_S = 10 * 60       -- "starts in 10 min" toast
local LATE_KEEP_S = 30 * 60         -- prune reminders this far past start
local MAX_REMINDERS = 16
-- Sanitize free-text title/location to printable ASCII (fonts can't
-- render anything else). Same pattern as services/notifications.lua.
local function ascii_safe(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("[^\32-\126]", "?"))
end

local store = {}        -- list of { id, ts, dur, title, lat?, lon?, pre_done, fire_done }
local initialized = false
local next_id = 1
local timer_id = nil

-- Persistence
--
-- Record layout: id|ts|dur|pre|fire|lat|lon|title
-- - `|` separator forbidden inside title (replaced with `/` on save)
-- - `;` separator between records
-- - lat/lon are e6 ints or "" when absent
local function save()
    local parts = {}
    for _, r in ipairs(store) do
        local title = (r.title or ""):gsub("|", "/"):gsub(";", ",")
        parts[#parts + 1] = table.concat({
            tostring(r.id),
            tostring(r.ts),
            tostring(r.dur or 0),
            r.pre_done and "1" or "0",
            r.fire_done and "1" or "0",
            r.lat and string.format("%d", math.floor(r.lat * 1e6)) or "",
            r.lon and string.format("%d", math.floor(r.lon * 1e6)) or "",
            title,
        }, "|")
    end
    ez.storage.set_pref(PREF_KEY, table.concat(parts, ";"))
end

local function load_saved()
    local raw = ez.storage.get_pref(PREF_KEY, "")
    if raw == "" then return end
    for entry in raw:gmatch("[^;]+") do
        local id, ts, dur, pre, fire, lat, lon, title = entry:match(
            "^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]*)|([^|]*)|(.*)$")
        local nts = tonumber(ts)
        if id and nts then
            local nid = tonumber(id) or next_id
            if nid >= next_id then next_id = nid + 1 end
            local nlat, nlon
            if lat ~= "" then nlat = (tonumber(lat) or 0) / 1e6 end
            if lon ~= "" then nlon = (tonumber(lon) or 0) / 1e6 end
            store[#store + 1] = {
                id = nid,
                ts = nts,
                dur = tonumber(dur) or 0,
                title = ascii_safe(title or ""),
                lat = nlat,
                lon = nlon,
                pre_done = pre == "1",
                fire_done = fire == "1",
            }
        end
    end
end

local function emit_changed()
    if ez and ez.bus and ez.bus.post then
        ez.bus.post("reminders/changed", { count = #store })
    end
end

-- Post a notification for one fire-point. Wrapped so the body lookup
-- and source tag stay consistent.
local function notify(r, when_label)
    local ok, notifications = pcall(require, "services.notifications")
    if not ok then return end
    notifications.post({
        title = r.title or "Event",
        body = when_label,
        source = "calev",
    })
end

-- Format "in 9m" / "now" for the toast body. Negative values mean we
-- ran the tick a bit late, which is fine -- the user still wants to
-- know.
local function relative_label(now, ts)
    local d = ts - now
    if d <= 30 then return "starting now" end
    local m = math.floor(d / 60)
    if m < 60 then return "in " .. m .. "m" end
    local h = math.floor(m / 60)
    local rem = m % 60
    if rem == 0 then return "in " .. h .. "h" end
    return "in " .. h .. "h " .. rem .. "m"
end

local function tick()
    local now = ez.system.get_time_unix() or 0
    if now <= 0 then return end          -- clock not set; nothing to compare

    local changed = false

    for i = #store, 1, -1 do
        local r = store[i]

        if not r.pre_done and (r.ts - now) <= PRE_NOTIFY_S and (r.ts - now) > 0 then
            notify(r, relative_label(now, r.ts))
            r.pre_done = true
            changed = true
        end

        if not r.fire_done and now >= r.ts then
            notify(r, "starting now")
            r.fire_done = true
            changed = true
        end

        if r.fire_done and now > r.ts + LATE_KEEP_S then
            table.remove(store, i)
            changed = true
        end
    end

    if changed then
        save()
        emit_changed()
    end
end

function reminders.init()
    if initialized then return end
    initialized = true
    load_saved()
    -- Snap once at boot in case anything fired while we were off.
    tick()
    timer_id = ez.system.set_interval(TICK_MS, tick)
    ez.log("[Reminders] " .. #store .. " saved, tick every " .. TICK_MS .. "ms")
end

-- Returns a list copy of the current reminders.
function reminders.list()
    local out = {}
    for i, r in ipairs(store) do out[i] = r end
    return out
end

-- Add a new reminder. opts = { ts, dur, title, lat?, lon? }.
-- Returns the new id, or (nil, reason). De-duplicates against an
-- existing reminder with the same (ts, title) so tapping "Add to
-- reminders" twice doesn't create two entries.
function reminders.add(opts)
    opts = opts or {}
    local ts = tonumber(opts.ts)
    local title = ascii_safe(opts.title or "")
    if not ts or ts <= 0 then return nil, "missing start time" end
    if title == "" then return nil, "missing title" end

    for _, r in ipairs(store) do
        if r.ts == ts and r.title == title then
            return r.id, "already scheduled"
        end
    end

    if #store >= MAX_REMINDERS then return nil, "too many reminders" end

    local r = {
        id = next_id,
        ts = ts,
        dur = tonumber(opts.dur) or 0,
        title = title,
        lat = tonumber(opts.lat),
        lon = tonumber(opts.lon),
        pre_done = false,
        fire_done = false,
    }
    next_id = next_id + 1
    store[#store + 1] = r
    save()
    emit_changed()
    return r.id
end

-- True when an entry with this (ts, title) exists already. Used by
-- the share-card action menu to show "Already scheduled" instead of
-- "Add to reminders".
function reminders.has(ts, title)
    title = ascii_safe(title or "")
    ts = tonumber(ts) or 0
    for _, r in ipairs(store) do
        if r.ts == ts and r.title == title then return true end
    end
    return false
end

function reminders.remove(id)
    for i, r in ipairs(store) do
        if r.id == id then
            table.remove(store, i)
            save()
            emit_changed()
            return true
        end
    end
    return false
end

return reminders
