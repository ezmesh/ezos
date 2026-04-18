-- Map screen: offline TDMAP viewer with GPS integration.
-- Thin screen that composes services/map_archive with the map_view widget.

local ui          = require("ezui")
local theme       = require("ezui.theme")
local screen_mod  = require("ezui.screen")
local map_archive = require("services.map_archive")
local map_view    = require("ezui.widgets.map_view").map_view
local gps_svc     = require("services.gps")

local PREF_KEY     = "map_last_view"
local ARCHIVE_PATH = "/sd/maps/world.tdmap"
-- Fallback center when no saved view exists. Roughly central Netherlands at a
-- zoom that shows the whole country on a 320×240 viewport.
local DEFAULT_VIEW = { lat = 52.1, lon = 5.3, zoom = 6 }

-- Alternate palette order for the T-toggle. Must match keys registered in
-- ezui.theme (built-in: "dark", "light").
local THEMES = { "dark", "light" }

local Map = { title = "Map" }

-- Parse the last-view pref blob: "lat,lon,zoom". Returns nil on any failure so
-- the caller falls back to DEFAULT_VIEW.
local function parse_saved_view(raw)
    if type(raw) ~= "string" then return nil end
    local lat, lon, z = raw:match("^(-?[%d%.]+),(-?[%d%.]+),(%d+)$")
    if not lat then return nil end
    return { lat = tonumber(lat), lon = tonumber(lon), zoom = tonumber(z) }
end

function Map.initial_state()
    local saved = parse_saved_view(ez.storage.get_pref(PREF_KEY, nil))
    local v = saved or DEFAULT_VIEW
    return {
        archive         = nil,
        loading         = true,
        error           = nil,
        center_lat      = v.lat,
        center_lon      = v.lon,
        zoom            = v.zoom,
        show_labels     = true,
        follow_gps      = false,
        used_saved_view = saved ~= nil,  -- If false, snap to archive bounds on load
    }
end

function Map:on_enter()
    local s = self._state
    if s.archive or s.error then return end
    local inst = self
    spawn(function()
        local arc, err = map_archive.open(ARCHIVE_PATH)
        if not arc then
            inst:set_state({ loading = false, error = err or "failed to open archive" })
            return
        end
        -- Clamp the restored zoom against this archive's bounds.
        local z = inst._state.zoom or DEFAULT_VIEW.zoom
        if z < arc.header.min_zoom then z = arc.header.min_zoom end
        if z > arc.header.max_zoom then z = arc.header.max_zoom end

        -- If the user has no saved view and the archive ships v5 bounds,
        -- snap to the archive's center. Avoids the "blank screen outside
        -- archive bounds" footgun on fresh installs.
        local center_lat = inst._state.center_lat
        local center_lon = inst._state.center_lon
        if not inst._state.used_saved_view and arc.header.bounds then
            local b = arc.header.bounds
            center_lat = (b.north + b.south) / 2
            center_lon = (b.east  + b.west ) / 2
        end

        -- Every completed async tile load invalidates the screen. Without
        -- this the first frame sees "pending" everywhere, tiles land in
        -- cache seconds later, and nothing triggers a repaint.
        arc.on_tile_loaded = function() screen_mod.invalidate() end
        inst:set_state({
            archive    = arc,
            loading    = false,
            zoom       = z,
            center_lat = center_lat,
            center_lon = center_lon,
        })
    end)
end

function Map:on_exit()
    local s = self._state
    if s.archive then
        ez.storage.set_pref(PREF_KEY, string.format(
            "%.6f,%.6f,%d", s.center_lat or 0, s.center_lon or 0, s.zoom or DEFAULT_VIEW.zoom))
        s.archive:close()
        s.archive = nil
    end
end

-- Called from screen.update() each frame. Cheap on non-follow frames; when
-- follow_gps is on, pulls the latest fix and recenters the map.
function Map:update()
    local s = self._state
    if not (s.follow_gps and s.archive) then return end
    local loc = gps_svc.get_location()
    if not (loc and loc.valid) then return end
    -- Skip tiny deltas so we don't trigger a rebuild every tick from GPS noise.
    local dlat = math.abs((s.center_lat or 0) - loc.lat)
    local dlon = math.abs((s.center_lon or 0) - loc.lon)
    if dlat < 1e-5 and dlon < 1e-5 then
        screen_mod.invalidate()
        return
    end
    self:set_state({ center_lat = loc.lat, center_lon = loc.lon })
end

function Map:handle_key(key)
    local ch = key.character
    local s = self._state

    -- Zoom / labels. ezui.focus only routes arrow keys to the focused widget;
    -- character keys fall through to the screen, so zoom lives here rather
    -- than inside map_view's on_key (where it never gets called).
    if ch == "+" or ch == "=" or key.special == "PAGE_UP" then
        local arc = s.archive
        if arc then
            local z = math.min((s.zoom or 0) + 1, arc.header.max_zoom)
            if z ~= s.zoom then
                arc:invalidate_missing()
                self:set_state({ zoom = z })
            end
        end
        return "handled"
    end
    if ch == "-" or ch == "_" or key.special == "PAGE_DOWN" then
        local arc = s.archive
        if arc then
            local z = math.max((s.zoom or 0) - 1, arc.header.min_zoom)
            if z ~= s.zoom then
                arc:invalidate_missing()
                self:set_state({ zoom = z })
            end
        end
        return "handled"
    end
    if ch == "l" or ch == "L" then
        self:set_state({ show_labels = not (s.show_labels ~= false) })
        return "handled"
    end

    -- H = "home": jump once to the current GPS fix without toggling follow-mode.
    -- (G still toggles follow-mode; use H when you just want a one-shot recenter.)
    if ch == "h" or ch == "H" then
        local loc = gps_svc.get_location()
        if loc and loc.valid then
            self:set_state({
                center_lat = loc.lat,
                center_lon = loc.lon,
                follow_gps = false,
            })
        end
        return "handled"
    end

    if ch == "g" or ch == "G" then
        -- First press: jump to current fix if available. Second press: toggle follow-mode.
        local loc = gps_svc.get_location()
        if loc and loc.valid and not s.follow_gps then
            self:set_state({
                follow_gps = true,
                center_lat = loc.lat,
                center_lon = loc.lon,
            })
        else
            self:set_state({ follow_gps = not s.follow_gps })
        end
        return "handled"
    end
    if ch == "t" or ch == "T" then
        local current = theme.name or "dark"
        local next_theme = (current == THEMES[1]) and THEMES[2] or THEMES[1]
        theme.set(next_theme)
        ez.storage.set_pref("theme", next_theme)
        self:set_state({})
        return "handled"
    end
    return nil
end

-- Clip a ray from (cx, cy) through (px, py) to the rectangle [x, x+w] × [y, y+h].
-- Returns the (edge_x, edge_y) where the ray exits the rectangle. Only called
-- when (px, py) is known to be OUTSIDE the rectangle, so a valid exit always
-- exists and we don't need a miss case.
local function ray_to_edge(cx, cy, px, py, x, y, w, h)
    local dx = px - cx
    local dy = py - cy
    -- Parametric t at each potential exit plane; pick the smallest positive.
    local t = math.huge
    if dx > 1e-9 then       t = math.min(t, (x + w - 1 - cx) / dx)
    elseif dx < -1e-9 then  t = math.min(t, (x         - cx) / dx) end
    if dy > 1e-9 then       t = math.min(t, (y + h - 1 - cy) / dy)
    elseif dy < -1e-9 then  t = math.min(t, (y         - cy) / dy) end
    return cx + dx * t, cy + dy * t, dx, dy
end

-- Draw a small triangle arrow with its tip at (ax, ay) pointing in direction
-- (dx, dy). Size is half-length of the arrow in pixels.
local function draw_arrow(d, ax, ay, dx, dy, size, fill_color, outline_color)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then return end
    local ux, uy = dx / len, dy / len       -- forward unit vector
    local vx, vy = -uy, ux                  -- perpendicular (left)
    -- Tip slightly inset so the triangle sits inside the viewport, not on the edge.
    local tx, ty = ax - ux * 2, ay - uy * 2
    -- Base center is behind the tip, base corners extend sideways.
    local bx, by = tx - ux * size, ty - uy * size
    local b1x, b1y = bx + vx * size * 0.6, by + vy * size * 0.6
    local b2x, b2y = bx - vx * size * 0.6, by - vy * size * 0.6
    d.fill_triangle(math.floor(tx), math.floor(ty),
                    math.floor(b1x), math.floor(b1y),
                    math.floor(b2x), math.floor(b2y), fill_color)
    d.draw_triangle(math.floor(tx), math.floor(ty),
                    math.floor(b1x), math.floor(b1y),
                    math.floor(b2x), math.floor(b2y), outline_color)
end

-- GPS overlay: user-position dot when visible, edge arrow when off-screen.
-- Nothing if GPS is disabled in settings or no fix is available.
local function make_gps_overlay()
    return function(d, x, y, w, h, project)
        local loc = gps_svc.get_location()
        if not (loc and loc.valid) then return end
        local px, py = project(loc.lat, loc.lon)
        local accent = theme.color("ACCENT")
        local text   = theme.color("TEXT")
        local bg     = theme.color("BG")

        if px >= x and px <= x + w - 1 and py >= y and py <= y + h - 1 then
            -- In-view: target-style marker so it's distinct from other map ink.
            local ix, iy = math.floor(px), math.floor(py)
            d.fill_circle(ix, iy, 4, accent)
            d.draw_circle(ix, iy, 6, text)
            d.draw_circle(ix, iy, 7, bg)    -- halo keeps it legible on any palette
        else
            -- Off-screen: arrow at the viewport edge pointing toward the fix.
            -- Size 18 px: big enough to read on the 320×240 panel but not so
            -- big it dominates the view.
            local cx = x + w / 2
            local cy = y + h / 2
            local ex, ey, dx, dy = ray_to_edge(cx, cy, px, py, x, y, w, h)
            draw_arrow(d, ex, ey, dx, dy, 18, accent, text)
        end
    end
end

function Map:build(state)
    if state.loading then
        return ui.vbox({ gap = 0 }, {
            ui.title_bar("Map", { back = true }),
            ui.padding({ 60, 20, 20, 20 },
                ui.hbox({ gap = 8 }, {
                    { type = "spinner", size = 16 },
                    ui.text_widget("Loading " .. ARCHIVE_PATH .. "...", { color = "TEXT_SEC" }),
                })
            ),
        })
    end

    if state.error then
        return ui.vbox({ gap = 0 }, {
            ui.title_bar("Map", { back = true }),
            ui.padding({ 20, 16, 16, 16 },
                ui.text_widget("Could not open map:\n" .. tostring(state.error), {
                    wrap = true, color = "ERROR",
                })
            ),
            ui.padding({ 12, 16, 16, 16 },
                ui.text_widget(
                    "Copy a .tdmap archive to " .. ARCHIVE_PATH .. " and reopen this screen.",
                    { wrap = true, color = "TEXT_MUTED", font = "small" })
            ),
        })
    end

    -- Status strip: coords, zoom, and GPS follow indicator.
    local segments = {
        string.format("%.4f,%.4f", state.center_lat or 0, state.center_lon or 0),
        "Z" .. tostring(state.zoom or 0),
    }
    if state.follow_gps then segments[#segments + 1] = "GPS" end

    return ui.vbox({ gap = 0 }, {
        ui.title_bar("Map", { back = true }),
        map_view({
            grow        = 1,
            archive     = state.archive,
            center_lat  = state.center_lat,
            center_lon  = state.center_lon,
            zoom        = state.zoom,
            show_labels = state.show_labels,
            overlay_fn  = make_gps_overlay(),
            on_move     = function(lat, lon, z)
                -- Mutate state in place: the widget is re-drawing every frame
                -- anyway and a set_state here would force tree rebuilds at
                -- trackball rate. The status strip catches up on the next
                -- rebuild triggered by a zoom/theme/label change.
                state.center_lat = lat
                state.center_lon = lon
                state.zoom = z
                -- Panning breaks follow-mode: the user is taking over.
                if state.follow_gps then state.follow_gps = false end
            end,
        }),
        ui.padding({ 2, 6, 2, 6 },
            -- Pipe separator: the device font (FreeSans 7pt) covers only ASCII
            -- 0x20..0x7E, so "·" / "•" render as missing-glyph boxes.
            ui.text_widget(table.concat(segments, "  |  "), {
                font = "small", color = "TEXT_SEC",
            })
        ),
    })
end

return Map
