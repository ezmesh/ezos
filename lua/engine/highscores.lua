-- Shared high-score store.
--
-- One table per game_key, persisted as a single NVS pref. Each entry
-- is { score, extra, ts } where `extra` is an opaque number a game
-- can use to tag a secondary metric (lines cleared in tetris, levels
-- finished in breakout, waves survived in shooter, etc.).
--
-- Storage layout: the pref value is "score:extra:ts|score:extra:ts|..."
-- so the whole table fits in a single NVS read/write per change. Top
-- N entries are kept (default 5); older or lower-scored entries fall
-- off as new ones arrive.
--
-- The module is intentionally tiny — adding a new game is one call to
-- submit() and one call to get() on the game-over screen.

local M = {}

local PREF_PREFIX = "hs_"
local MAX_DEFAULT = 5

-- In-memory cache keyed by game_key. Reads pull from NVS only once per
-- game + boot; submits flush back to NVS.
local cache = {}

local function pref_key(game_key) return PREF_PREFIX .. game_key end

local function parse(raw)
    local out = {}
    if not raw or raw == "" then return out end
    for entry in raw:gmatch("[^|]+") do
        local s, e, t = entry:match("^(%-?%d+):(%-?%d+):(%-?%d+)$")
        if s then
            out[#out + 1] = {
                score = tonumber(s) or 0,
                extra = tonumber(e) or 0,
                ts    = tonumber(t) or 0,
            }
        end
    end
    return out
end

local function serialise(list)
    local parts = {}
    for _, h in ipairs(list) do
        parts[#parts + 1] = table.concat({ h.score, h.extra or 0,
                                           h.ts    or 0 }, ":")
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
function M.submit(game_key, score, extra, max_entries)
    local max_n = max_entries or MAX_DEFAULT
    local list = M.get(game_key)
    local rec = { score = score, extra = extra or 0,
                  ts = ez.system.millis() }
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
