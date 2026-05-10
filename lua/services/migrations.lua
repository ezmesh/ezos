-- Migration service
-- Runs one-time upgrade scripts when firmware version changes.
-- Each migration targets a specific version and runs once after the
-- device boots into that version (or any later version) for the first
-- time. Migrations execute in order during boot before the UI starts.
--
-- To add a migration:
--   1. Append an entry to the MIGRATIONS table below.
--   2. Set `version` to the version that introduces the change.
--   3. Write a `run()` function that performs the data/prefs migration.
--
-- Version comparison is numeric per dotted segment (so "0.0.10" sorts
-- after "0.0.9", and "0.10.0" after "0.2.0"). Migrations whose version
-- is <= the last-migrated version are skipped.

local migrations = {}

-- Pref key that stores the last version migrations ran for.
-- 15 chars max for NVS.
local PREF_KEY = "migrated_ver"

-- Compare two dotted version strings numerically. Returns true iff
-- a < b. Missing trailing segments are treated as 0, so "0.1" < "0.1.0"
-- is false (they compare equal). Lex comparison would silently break
-- at any digit-boundary rollover (e.g. "0.0.100" < "0.0.71"); this
-- one stays correct for the project's "0.0.<N>" commit-count tags.
local function version_lt(a, b)
    local function parts(v)
        local t = {}
        for n in v:gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local ai, bi = pa[i] or 0, pb[i] or 0
        if ai ~= bi then return ai < bi end
    end
    return false
end

-- Ordered list of migrations. Each entry:
--   { version = "x.y.z", description = "...", run = function() ... end }
-- IMPORTANT: keep sorted by version ascending.
local MIGRATIONS = {
    -- Example:
    -- {
    --     version = "0.0.80",
    --     description = "Rename wifi_pass pref to wifi_password",
    --     run = function()
    --         local old = ez.storage.get_pref("wifi_pass", "")
    --         if old ~= "" then
    --             ez.storage.set_pref("wifi_password", old)
    --             ez.storage.remove_pref("wifi_pass")
    --         end
    --     end,
    -- },
}

function migrations.run()
    local info = ez.system.get_firmware_info() or {}
    local current = info.version
    if not current or current == "" then
        ez.log("[Migrations] No firmware version, skipping")
        return
    end

    local last = ez.storage.get_pref(PREF_KEY, "")
    local count = 0

    for _, m in ipairs(MIGRATIONS) do
        -- Skip migrations already applied (version <= last migrated)
        if last ~= "" and not version_lt(last, m.version) then
            -- already applied
        else
            ez.log("[Migrations] Running " .. m.version .. ": " .. (m.description or ""))
            local ok, err = pcall(m.run)
            if not ok then
                ez.log("[Migrations] FAILED " .. m.version .. ": " .. tostring(err))
                -- Continue with remaining migrations; a broken migration
                -- shouldn't block the rest.
            end
            count = count + 1
        end
    end

    -- Always stamp the current version so future boots skip everything
    -- up to this point, even if there were no migrations to run.
    if current ~= last then
        ez.storage.set_pref(PREF_KEY, current)
    end

    if count > 0 then
        ez.log("[Migrations] Ran " .. count .. " migration(s)")
    end
end

return migrations
