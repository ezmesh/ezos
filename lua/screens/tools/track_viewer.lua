-- Track viewer: lists .eztrack files under /sd/tracks/ and opens one
-- onto the map with the recorded polyline as an overlay. Push actions
-- (Open / Delete / Stats) live behind the Alt+M context menu so a tap
-- on a row doesn't accidentally trigger a destructive action.

local ui          = require("ezui")
local screen_mod  = require("ezui.screen")
local gps_track   = require("services.gps_track")
local dialog      = require("ezui.dialog")

local Viewer = { title = "Tracks" }

local TRACK_DIR = "/sd/tracks"

local function fmt_size(bytes)
    if not bytes then return "" end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%d KB", bytes // 1024)
    end
    return tostring(bytes) .. " B"
end

local function fmt_date(unix_ts)
    if not unix_ts or unix_ts <= 0 then return "?" end
    -- No os.date in the embedded Lua build for arbitrary timestamps;
    -- show a coarse delta + the raw start so the user can find the
    -- file on disk without ambiguity.
    local now = ez.system.get_time_unix and ez.system.get_time_unix() or 0
    if now <= 0 then return tostring(unix_ts) end
    local delta = now - unix_ts
    if delta < 0 then return tostring(unix_ts) end
    if delta < 60 then return delta .. "s ago" end
    if delta < 3600 then return (delta // 60) .. "m ago" end
    if delta < 86400 then return (delta // 3600) .. "h ago" end
    return (delta // 86400) .. "d ago"
end

-- Open the track onto the Map screen as a polyline overlay. Falls back
-- to a no-op if the load returns nil (corrupt header). The map screen
-- pulls the polyline from a shared per-track state passed through
-- initial_state(), so the viewer doesn't need to manage map lifecycle.
local function open_on_map(track_path)
    local loaded, err = gps_track.load(track_path)
    if not loaded or not loaded.points or #loaded.points == 0 then
        dialog.confirm({
            title = "Empty track",
            message = err or "No recorded points in this track.",
            ok_label = "OK",
            cancel_label = "Close",
        }, function() screen_mod.pop() end)
        return
    end

    -- Auto-fit bounds: use the polyline's centre at a zoom that keeps
    -- the whole thing on-screen. We don't have viewport-aware fitting,
    -- so pick a sensible default; the user can zoom further with +/-.
    local min_lat, max_lat = 90, -90
    local min_lon, max_lon = 180, -180
    for _, p in ipairs(loaded.points) do
        if p.lat < min_lat then min_lat = p.lat end
        if p.lat > max_lat then max_lat = p.lat end
        if p.lon < min_lon then min_lon = p.lon end
        if p.lon > max_lon then max_lon = p.lon end
    end
    local span = math.max(max_lat - min_lat, (max_lon - min_lon) * 0.6)
    -- Crude zoom picker: small span -> high zoom. The map clamps to the
    -- archive's range on load.
    local zoom = 16
    if span > 0.0005 then zoom = 15 end
    if span > 0.005  then zoom = 13 end
    if span > 0.05   then zoom = 11 end
    if span > 0.5    then zoom = 8  end
    if span > 5      then zoom = 5  end

    local Map = require("screens.tools.map")
    local state = Map.initial_state()
    state.center_lat = (min_lat + max_lat) / 2
    state.center_lon = (min_lon + max_lon) / 2
    state.zoom = zoom
    state.used_saved_view = true
    state.track_overlay = loaded.points  -- consumed by map.lua's overlay layer
    state.track_label   = loaded.header and loaded.header.label or ""
    screen_mod.push(screen_mod.create(Map, state))
end

local function compute_stats(entry)
    local loaded, err = gps_track.load(entry.path)
    if not loaded or not loaded.points then
        dialog.confirm({
            title = "Cannot read track",
            message = err or "unknown error",
            ok_label = "OK",
            cancel_label = "Close",
        }, function() screen_mod.pop() end)
        return
    end
    local total_m = 0
    local function hav(lat1, lon1, lat2, lon2)
        local R = 6371000
        local rad = math.pi / 180
        local p1 = lat1 * rad
        local p2 = lat2 * rad
        local dp = (lat2 - lat1) * rad
        local dl = (lon2 - lon1) * rad
        local a = math.sin(dp / 2) ^ 2
            + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ^ 2
        return R * 2 * math.atan(math.sqrt(a), math.sqrt(1 - a))
    end
    for i = 2, #loaded.points do
        local a = loaded.points[i - 1]
        local b = loaded.points[i]
        total_m = total_m + hav(a.lat, a.lon, b.lat, b.lon)
    end
    local pts = loaded.points
    local dur_s = 0
    if #pts >= 2 then
        dur_s = (pts[#pts].ts_unix or 0) - (pts[1].ts_unix or 0)
    end
    local km = total_m / 1000
    local minutes = dur_s // 60
    local secs = dur_s % 60
    local msg = string.format(
        "%d points\n%.2f km\n%d min %d s",
        #pts, km, minutes, secs)
    dialog.confirm({
        title = "Stats",
        message = msg,
        ok_label = "OK",
        cancel_label = "Close",
    }, function() screen_mod.pop() end)
end

function Viewer.initial_state()
    return { tracks = nil }
end

function Viewer:on_enter()
    -- Defer the SD scan one frame so the placeholder paints first.
    spawn(function()
        local tracks = gps_track.list()
        self:set_state({ tracks = tracks })
    end)
end

function Viewer:build(state)
    local items = { ui.title_bar("Tracks", { back = true }) }

    if state.tracks == nil then
        items[#items + 1] = ui.padding({ 30, 16, 16, 16 },
            ui.text_widget("Scanning " .. TRACK_DIR .. "...",
                { color = "TEXT_SEC" }))
        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    if #state.tracks == 0 then
        items[#items + 1] = ui.padding({ 30, 16, 6, 16 },
            ui.text_widget("No saved tracks yet.",
                { color = "TEXT_SEC", text_align = "center" }))
        items[#items + 1] = ui.padding({ 6, 16, 16, 16 },
            ui.text_widget(
                "Open Map, press Alt+M, and pick \"Start recording route\""
                .. " to capture one.",
                { wrap = true, color = "TEXT_MUTED", font = "small_aa",
                  text_align = "center" }))
        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    local rows = {}
    for _, t in ipairs(state.tracks) do
        local label = t.label ~= "" and t.label or t.name
        local subtitle = string.format("%s  |  %s%s",
            fmt_date(t.start_unix),
            fmt_size(t.size),
            t.closed and "" or "  (in progress)")
        rows[#rows + 1] = ui.list_item({
            title    = label,
            subtitle = subtitle,
            _track   = t,
            on_press = function()
                open_on_map(t.path)
            end,
        })
    end
    items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, rows))

    items[#items + 1] = ui.padding({ 4, 8, 2, 8 },
        ui.text_widget("ENTER: open  |  Alt+M: actions",
            { color = "TEXT_MUTED", font = "tiny_aa" }))

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

-- Framework dispatches this on Alt+M when a screen exposes a :menu()
-- method; the returned list is rendered as a menu dialog. Acting on the
-- focused row keeps the call site shape the same as the previous bare-m
-- handler.
function Viewer:menu()
    local focus_mod = require("ezui.focus")
    local n = focus_mod.current()
    if not (n and n._track) then return nil end
    local entry = n._track
    local self_ref = self

    return {
        {
            title = "Open on map",
            subtitle = "View the recorded polyline",
            on_press = function() open_on_map(entry.path) end,
        },
        {
            title = "Stats",
            subtitle = "Distance, duration, point count",
            on_press = function() compute_stats(entry) end,
        },
        {
            title = "Delete",
            subtitle = "Remove this track file",
            on_press = function()
                dialog.confirm({
                    title = "Delete track?",
                    message = entry.name,
                    ok_label = "Delete",
                    cancel_label = "Cancel",
                }, function()
                    gps_track.delete(entry.path)
                    if self_ref and self_ref.set_state then
                        self_ref:set_state({})
                    end
                end)
            end,
        },
    }
end

function Viewer:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Viewer
