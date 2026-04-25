-- Shared timezone presets and lookup helpers.
--
-- The full POSIX-TZ table lives here so both the Time settings screen and
-- the first-run onboarding wizard can offer the same picker without
-- duplicating the table. Order is "what most users pick" rather than
-- strictly alphabetical; DST rules are baked in so the displayed time
-- flips automatically with the wall-clock change.

local M = {}

M.PREF_KEY = "tz_posix"

M.CHOICES = {
    { label = "UTC",                        tz = "UTC0" },
    { label = "Amsterdam / Paris / Berlin", tz = "CET-1CEST,M3.5.0,M10.5.0/3" },
    { label = "London",                     tz = "GMT0BST,M3.5.0/1,M10.5.0" },
    { label = "Athens",                     tz = "EET-2EEST,M3.5.0/3,M10.5.0/4" },
    { label = "Moscow",           tz = "MSK-3" },
    { label = "New York",         tz = "EST5EDT,M3.2.0,M11.1.0" },
    { label = "Chicago",          tz = "CST6CDT,M3.2.0,M11.1.0" },
    { label = "Denver",           tz = "MST7MDT,M3.2.0,M11.1.0" },
    { label = "Los Angeles",      tz = "PST8PDT,M3.2.0,M11.1.0" },
    { label = "Tokyo",            tz = "JST-9" },
    { label = "Sydney",           tz = "AEST-10AEDT,M10.1.0,M4.1.0/3" },
}

M.LABELS = {}
for i, c in ipairs(M.CHOICES) do M.LABELS[i] = c.label end

-- Returns the index in CHOICES that matches the saved tz_posix pref, or 1
-- (UTC) if the saved value is missing or no longer matches a preset.
function M.current_index()
    local cur = ez.storage.get_pref(M.PREF_KEY, "UTC0")
    for i, c in ipairs(M.CHOICES) do
        if c.tz == cur then return i end
    end
    return 1
end

-- Persist the picked index and apply it to the system clock.
function M.apply_index(idx)
    local entry = M.CHOICES[idx]
    if not entry then return false end
    ez.storage.set_pref(M.PREF_KEY, entry.tz)
    if ez.system.set_timezone then
        ez.system.set_timezone(entry.tz)
    end
    return true
end

return M
