-- ezui.transient: in-memory state snapshot store, scoped to one boot.
--
-- Screens that want to "remember" their full state across a close +
-- reopen — the transcript in the terminal, tree view in the file
-- manager, etc. — call save(key, tbl) in on_exit and load(key, default)
-- in initial_state. Values live in a module-level Lua table; a reboot
-- wipes them. For state that must survive power cycles use
-- ezui.persist instead (which serialises to LittleFS).
--
-- save() stores the table by reference, so mutations on the returned
-- value after load() remain visible to later load() calls without
-- needing a second save(). The explicit save() is still encouraged as
-- a "commit point" for readability.

local transient = {}

local _store = {}

function transient.save(key, data)
    _store[key] = data
end

function transient.load(key, default)
    local v = _store[key]
    if v == nil then return default end
    return v
end

function transient.clear(key)
    _store[key] = nil
end

-- Drop every cached entry — useful during development / from tests
-- where the module ends up reloaded via hot-reload.
function transient.reset()
    _store = {}
end

return transient
