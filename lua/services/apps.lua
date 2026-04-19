-- Apps registry: file-type → handler lookup.
--
-- Any screen that can open a file by path can advertise itself as a
-- handler. The file manager consults the registry when the user picks
-- a file: the default handler opens on plain ENTER, and every handler
-- whose extension list matches shows up under "Open in …" in the
-- context menu.
--
-- An app is a table with:
--   id    -- short stable identifier, used as a key
--   label -- human-readable name shown in menus
--   exts  -- list of lowercase extensions without the dot ({"md","txt"})
--   open  -- function(path) called to open a file; typically pushes a
--            screen configured with `path` in its initial state.
--
-- Extensions are matched case-insensitively; paths with no extension or
-- an unregistered one return no handlers (the caller falls back to the
-- generic action menu).

local M = {}

-- All registered apps, in insertion order. Lookups scan linearly — the
-- list is O(handful) and lives in RAM, so no indexing infrastructure.
local apps = {}

-- Pull the lowercased extension off a path, without the dot. Returns
-- nil for paths like "/foo/bar" or "/foo/.hidden" where there's nothing
-- a handler could match on.
local function extension_of(path)
    if not path then return nil end
    local ext = path:match("%.([%w_]+)$")
    if not ext then return nil end
    return ext:lower()
end

-- Register an app. Later calls with the same id replace an earlier
-- registration (handy during hot-reload development); otherwise the
-- new app is appended to the order, so the first app registered for
-- a given extension wins default_for().
function M.register(app)
    assert(type(app) == "table", "apps.register: expected table")
    assert(app.id and app.open, "apps.register: id and open are required")

    for i, existing in ipairs(apps) do
        if existing.id == app.id then
            apps[i] = app
            return
        end
    end
    apps[#apps + 1] = app
end

-- All apps in registration order. Returned by reference — treat as
-- read-only.
function M.list()
    return apps
end

-- Return the list of apps that declare support for this path's
-- extension, in registration order.
function M.handlers_for(path)
    local ext = extension_of(path)
    if not ext then return {} end
    local out = {}
    for _, app in ipairs(apps) do
        if app.exts then
            for _, e in ipairs(app.exts) do
                if e:lower() == ext then
                    out[#out + 1] = app
                    break
                end
            end
        end
    end
    return out
end

-- First registered app for this extension, or nil if none match.
function M.default_for(path)
    local list = M.handlers_for(path)
    return list[1]
end

-- Convenience: ask the default handler to open a path. Returns true if
-- an app was found and asked to open; the caller can fall back to its
-- own UI (e.g. an action menu) when this returns false.
function M.open(path)
    local app = M.default_for(path)
    if not app then return false end
    app.open(path)
    return true
end

return M
