-- ezui.persist: per-screen state storage to LittleFS.
--
-- save(key, data) / load(key, default) write and read plain tables as
-- JSON under /fs/state/<key>.json. Keys are sanitised so screens can
-- pass arbitrary names without worrying about invalid file paths.
--
-- Intended flow for a screen that wants to remember state across pops:
--
--     local persist = require("ezui.persist")
--
--     function Screen.initial_state()
--         local saved = persist.load("my_screen", {})
--         return {
--             cwd = saved.cwd or "/",
--             ... merge other defaults ...
--         }
--     end
--
--     function Screen:on_exit()
--         persist.save("my_screen", {
--             cwd = self._state.cwd,
--             -- ... pick only the fields that should survive ...
--         })
--     end
--
-- Only the screen knows which bits of its state are worth persisting
-- (scroll offsets and transient flags usually aren't), so save/load
-- are explicit rather than automatic. Clear with persist.clear(key).

local persist = {}

local DIR = "/fs/state"

-- Turn an arbitrary label into a safe filename under DIR. Non-word
-- characters collapse to underscores; multiple screens using the same
-- sanitised key will share storage, which is fine for the cases we
-- care about (unique stable names picked by the caller).
local function path_for(key)
    local clean = tostring(key or ""):gsub("[^%w_%-]", "_")
    if clean == "" then clean = "_" end
    return DIR .. "/" .. clean .. ".json"
end

-- Ensure the state directory exists before the first write. Safe to
-- call repeatedly — mkdir is a no-op when the directory is there.
local _dir_ready = false
local function ensure_dir()
    if _dir_ready then return end
    if not ez.storage.exists(DIR) then
        ez.storage.mkdir(DIR)
    end
    _dir_ready = true
end

function persist.save(key, data)
    ensure_dir()
    local ok, err = pcall(ez.storage.json_write, path_for(key), data)
    if not ok then
        ez.log("[persist] save failed for '" .. tostring(key) ..
               "': " .. tostring(err))
    end
    return ok
end

-- Return the loaded table or `default` on any miss (missing file,
-- invalid JSON, empty blob). pcall guards against partial writes
-- from an earlier crash leaving malformed JSON on disk.
function persist.load(key, default)
    local p = path_for(key)
    if not ez.storage.exists(p) then return default end
    local ok, data = pcall(ez.storage.json_read, p)
    if not ok or data == nil then return default end
    return data
end

function persist.clear(key)
    local p = path_for(key)
    if ez.storage.exists(p) then
        ez.storage.remove(p)
    end
end

return persist
