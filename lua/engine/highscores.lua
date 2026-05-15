-- Shared high-score store.
--
-- One table per game_key, persisted as a single NVS pref. Each entry
-- is { score, extra, ts, name } where `extra` is an opaque number a
-- game can use to tag a secondary metric (lines cleared in tetris,
-- levels finished in breakout, waves survived in shooter, etc.) and
-- `name` is an optional short attribution string.
--
-- Storage layout: the pref value is
--   "score:extra:ts:name|score:extra:ts:name|..."
-- so the whole table fits in a single NVS read/write per change.
-- Names are stored last so the parser stays simple when reading old
-- 3-field rows written before the name column existed (back-compat:
-- a missing name parses as ""). Top N entries are kept (default 5);
-- older or lower-scored entries fall off as new ones arrive.
--
-- The module is intentionally tiny — adding a new game is one call to
-- submit() and one call to get() on the game-over screen.

local M = {}

local PREF_PREFIX = "hs_"
local MAX_DEFAULT = 5
local NAME_MAX    = 12

-- In-memory cache keyed by game_key. Reads pull from NVS only once per
-- game + boot; submits flush back to NVS.
local cache = {}

local function pref_key(game_key) return PREF_PREFIX .. game_key end

-- Strip everything that would either break the on-disk format (`|`
-- separates entries, `:` separates fields) or fail to render on the
-- device's ASCII-only bitmap fonts. Trim and cap to NAME_MAX.
local function sanitise_name(raw)
    if not raw or raw == "" then return "" end
    local out = {}
    for i = 1, #raw do
        local b = raw:byte(i)
        if b and b >= 0x20 and b <= 0x7E and b ~= 0x7C and b ~= 0x3A then
            out[#out + 1] = string.char(b)
        end
    end
    local s = table.concat(out)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if #s > NAME_MAX then s = s:sub(1, NAME_MAX) end
    return s
end

local function parse(raw)
    local out = {}
    if not raw or raw == "" then return out end
    for entry in raw:gmatch("[^|]+") do
        -- Try the 4-field form first (with name). Fall back to 3-field
        -- for entries written before the name column existed.
        local s, e, t, n = entry:match("^(%-?%d+):(%-?%d+):(%-?%d+):(.*)$")
        if not s then
            s, e, t = entry:match("^(%-?%d+):(%-?%d+):(%-?%d+)$")
            n = ""
        end
        if s then
            out[#out + 1] = {
                score = tonumber(s) or 0,
                extra = tonumber(e) or 0,
                ts    = tonumber(t) or 0,
                name  = n or "",
            }
        end
    end
    return out
end

local function serialise(list)
    local parts = {}
    for _, h in ipairs(list) do
        parts[#parts + 1] = table.concat({ h.score, h.extra or 0,
                                           h.ts    or 0,
                                           h.name  or "" }, ":")
    end
    return table.concat(parts, "|")
end

-- Load the top-N list for `game_key`. Cached — subsequent calls hit
-- memory, not NVS.
function M.get(game_key)
    local list = cache[game_key]
    if list then return list end
    list = parse(ez.storage.get_pref(pref_key(game_key), ""))
    -- Already sorted high-to-low on save; re-sort defensively in case
    -- a hand-edited pref slipped in.
    table.sort(list, function(a, b) return a.score > b.score end)
    cache[game_key] = list
    return list
end

-- Submit a new score. Returns the 1-based rank (1..max) if it made the
-- leaderboard, or nil if it didn't beat the lowest entry on a full
-- board. `extra` is a per-game secondary metric (lines, level, waves).
-- `name` is an optional short attribution string; passed through
-- sanitise_name so games can hand the raw user input straight in.
function M.submit(game_key, score, extra, name, max_entries)
    local max_n = max_entries or MAX_DEFAULT
    local list = M.get(game_key)
    local rec = { score = score, extra = extra or 0,
                  ts = ez.system.millis(),
                  name = sanitise_name(name) }
    list[#list + 1] = rec
    table.sort(list, function(a, b) return a.score > b.score end)
    while #list > max_n do table.remove(list) end

    -- Find our record's rank.
    local rank
    for i, h in ipairs(list) do
        if h == rec then rank = i; break end
    end

    -- Persist. `cache` already holds `list` by reference, so no refresh
    -- needed.
    ez.storage.set_pref(pref_key(game_key), serialise(list))
    return rank
end

-- Clear the leaderboard for one game (used by a "reset scores" option
-- in the prefs editor, not by normal gameplay).
function M.clear(game_key)
    cache[game_key] = {}
    ez.storage.set_pref(pref_key(game_key), "")
end

-- Convenience: render a top-5 list as a table of strings given a
-- per-entry formatter. Keeps game screens free of per-game string
-- formatting boilerplate.
function M.format(game_key, format_fn, max_entries)
    local max_n = max_entries or MAX_DEFAULT
    local list = M.get(game_key)
    local out = {}
    for i = 1, max_n do
        local h = list[i]
        out[i] = h and format_fn(i, h) or string.format("%d.  ---", i)
    end
    return out
end

return M
