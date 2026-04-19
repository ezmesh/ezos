-- Time settings screen
-- System clock readout + timezone / 12-24 format prefs. The system
-- clock itself is set by the GPS sync service (see gps_settings.lua) or
-- by a caller invoking ez.system.set_time directly — this screen only
-- controls how that clock is interpreted and displayed.

local ui = require("ezui")

local Time = { title = "Time" }

-- Pref keys (NVS namespace: 15 char limit)
local PREF_TZ           = "tz_posix"
local PREF_TIME_FORMAT  = "time_format"   -- "12h" | "24h"

-- Common timezones as POSIX TZ strings. DST rules are baked in so the
-- displayed time flips automatically with the wall-clock change — no
-- need to re-sync or edit prefs twice a year. Order is rough "what
-- most users pick" rather than strictly alphabetical.
local TZ_CHOICES = {
    { label = "UTC",              tz = "UTC0" },
    { label = "Amsterdam / CET",  tz = "CET-1CEST,M3.5.0,M10.5.0/3" },
    { label = "London",           tz = "GMT0BST,M3.5.0/1,M10.5.0" },
    { label = "Paris / Berlin",   tz = "CET-1CEST,M3.5.0,M10.5.0/3" },
    { label = "Athens",           tz = "EET-2EEST,M3.5.0/3,M10.5.0/4" },
    { label = "Moscow",           tz = "MSK-3" },
    { label = "New York",         tz = "EST5EDT,M3.2.0,M11.1.0" },
    { label = "Chicago",          tz = "CST6CDT,M3.2.0,M11.1.0" },
    { label = "Denver",           tz = "MST7MDT,M3.2.0,M11.1.0" },
    { label = "Los Angeles",      tz = "PST8PDT,M3.2.0,M11.1.0" },
    { label = "Tokyo",            tz = "JST-9" },
    { label = "Sydney",           tz = "AEST-10AEDT,M10.1.0,M4.1.0/3" },
}

local TZ_LABELS = {}
for i, c in ipairs(TZ_CHOICES) do TZ_LABELS[i] = c.label end

local function current_tz_index()
    local cur = ez.storage.get_pref(PREF_TZ, "UTC0")
    for i, c in ipairs(TZ_CHOICES) do
        if c.tz == cur then return i end
    end
    return 1
end

local function pref_bool(key, default)
    local v = ez.storage.get_pref(key, nil)
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    if type(v) == "string" then return v == "1" or v == "true" end
    return default
end

function Time.initial_state()
    return {
        tz_index    = current_tz_index(),
        format_12h  = ez.storage.get_pref(PREF_TIME_FORMAT, "24h") == "12h",
    }
end

-- Format the system clock for display. Follows the user's 12/24h pref
-- even when the status bar is forced to 24h (that's a separate concern
-- for the bar — here we just show what the clock is reporting).
local function format_time(t, format_12h)
    if not t or not t.hour then return "--:--:--" end
    if format_12h then
        local h = t.hour % 12
        if h == 0 then h = 12 end
        local suffix = t.hour < 12 and "AM" or "PM"
        return string.format("%d:%02d:%02d %s", h, t.minute or 0, t.second or 0, suffix)
    end
    return string.format("%02d:%02d:%02d", t.hour, t.minute or 0, t.second or 0)
end

local function format_date(t)
    if not t or not t.year then return "----" end
    return string.format("%04d-%02d-%02d", t.year, t.month or 0, t.day or 0)
end

function Time:build(state)
    local content = {}

    -- Section: current time
    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Current time", { color = "ACCENT", font = "small_aa" })
    )

    local sys_t = ez.system.get_time and ez.system.get_time()
    local gps_t = ez.gps and ez.gps.get_time and ez.gps.get_time()

    content[#content + 1] = ui.padding({ 2, 8, 2, 8 },
        ui.text_widget(format_time(sys_t, state.format_12h),
            { font = "medium_aa", color = "TEXT" })
    )
    content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.text_widget(format_date(sys_t),
            { font = "small_aa", color = "TEXT_SEC" })
    )

    -- Sync status line. Differentiates "clock is set, not from GPS"
    -- (e.g. via set_time or a previous GPS run in this session) from
    -- "clock is current from GPS right now".
    local sync_line
    if gps_t and gps_t.synced then
        sync_line = "Synced from GPS"
    elseif sys_t then
        sync_line = "Set (no GPS sync yet this boot)"
    else
        sync_line = "Not set — waiting for GPS or manual set"
    end
    content[#content + 1] = ui.padding({ 0, 8, 8, 8 },
        ui.text_widget(sync_line, { font = "tiny_aa", color = "TEXT_MUTED" })
    )

    -- Section: format
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Format", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.toggle("12-hour clock", state.format_12h, {
            on_change = function(val)
                state.format_12h = val
                ez.storage.set_pref(PREF_TIME_FORMAT, val and "12h" or "24h")
            end,
        })
    )
    content[#content + 1] = ui.padding({ 0, 8, 8, 8 },
        ui.text_widget("Affects the status-bar clock and this page.",
            { font = "tiny_aa", color = "TEXT_MUTED" })
    )

    -- Section: timezone
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Timezone", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.dropdown(TZ_LABELS, {
            label = "Region",
            value = state.tz_index,
            on_change = function(idx)
                state.tz_index = idx
                local entry = TZ_CHOICES[idx]
                if entry then
                    ez.storage.set_pref(PREF_TZ, entry.tz)
                    ez.system.set_timezone(entry.tz)
                end
            end,
        })
    )
    content[#content + 1] = ui.padding({ 0, 8, 8, 8 },
        ui.text_widget(
            "DST transitions happen automatically for regions that observe it.",
            { font = "tiny_aa", color = "TEXT_MUTED" })
    )

    -- Section: GPS sync shortcut
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Source", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.list_item({
        title = "GPS clock sync",
        subtitle = "Configure how often the GPS sets the clock",
        on_press = function()
            local screen_mod = require("ezui.screen")
            local GPSScr = require("screens.settings.gps_settings")
            local init = GPSScr.initial_state and GPSScr.initial_state() or {}
            screen_mod.push(screen_mod.create(GPSScr, init))
        end,
    })

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Time", { back = true }),
        ui.scroll({ grow = 1, scroll_offset = state._scroll or 0 },
            ui.vbox({ gap = 0 }, content)),
    })
end

function Time:update()
    -- Refresh the displayed clock once per second. set_state({}) with no
    -- payload still triggers a rebuild because screen.lua's set_state
    -- always calls _rebuild after merging the (empty) partial.
    local now = ez.system.millis()
    if (now - (self._last_refresh or 0)) > 1000 then
        self._last_refresh = now
        self:set_state({})
    end
end

function Time:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return Time
