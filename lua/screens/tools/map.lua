-- Map screen: offline TDMAP viewer with GPS integration.
-- Thin screen that composes services/map_archive with the map_view widget.

local ui          = require("ezui")
local theme       = require("ezui.theme")
local screen_mod  = require("ezui.screen")
local map_archive = require("services.map_archive")
local map_view    = require("ezui.widgets.map_view").map_view
local gps_svc     = require("services.gps")
local gps_track   = require("services.gps_track")
local contacts    = require("services.contacts")

-- Peer visibility prefs. Defaults intentionally favour "show nearby
-- infrastructure + my contacts, but not strangers" -- see issue #125.
-- NVS keys are capped at 15 chars; these are deliberately tight.
local PEER_PREF_REPEATERS = "map_peer_inf"  -- repeaters + room servers
local PEER_PREF_CONTACTS  = "map_peer_con"  -- chat nodes I've added
local PEER_PREF_ALL_CHAT  = "map_peer_all"  -- every chat node we've heard
local PEER_PREF_STALE     = "map_peer_stale" -- include 24h-7d old peers

-- Staleness thresholds (seconds since the peer's last ADVERT).
local STALE_DIM_AGE = 24 * 60 * 60      -- 24h: dim
local STALE_HIDE_AGE = 7 * 24 * 60 * 60 -- 7d:  hide entirely

local function pref_on(key, default_on)
    local v = ez.storage.get_pref(key, default_on and "1" or "0")
    return v == "1" or v == 1 or v == true
end

-- Last-view prefs are keyed per archive so switching between, say, a world
-- overview and a city detail archive doesn't strand you outside the new
-- archive's bounds.
local PREF_PREFIX  = "map_last_view:"
-- Fallback center when no saved view exists. Roughly central Netherlands at a
-- zoom that shows the whole country on a 320×240 viewport.
local DEFAULT_VIEW = { lat = 52.1, lon = 5.3, zoom = 6 }

-- Alternate palette order for the T-toggle. Must match keys registered in
-- ezui.theme (built-in: "dark", "light").
local THEMES = { "dark", "light" }

local Map = { title = "Map" }

-- Per-archive pref key. Falls back to a generic key for callers that didn't
-- supply a path (e.g. ad-hoc ui.push_screen during dev).
local function pref_key(path)
    return PREF_PREFIX .. (path or "default")
end

-- Parse the last-view pref blob: "lat,lon,zoom". Returns nil on any failure so
-- the caller falls back to DEFAULT_VIEW.
local function parse_saved_view(raw)
    if type(raw) ~= "string" then return nil end
    local lat, lon, z = raw:match("^(-?[%d%.]+),(-?[%d%.]+),(%d+)$")
    if not lat then return nil end
    return { lat = tonumber(lat), lon = tonumber(lon), zoom = tonumber(z) }
end

-- initial_state(path): the loader screen passes the archive path so the
-- restored view, title, and on-disk pref are all scoped to that archive.
-- A bare call (no path) keeps the legacy /sd/maps/world.tdmap default so
-- direct ui.push_screen invocations during development still work.
function Map.initial_state(archive_path)
    archive_path = archive_path or "/sd/maps/world.tdmap"
    local saved = parse_saved_view(ez.storage.get_pref(pref_key(archive_path), nil))
    local v = saved or DEFAULT_VIEW
    return {
        archive_path    = archive_path,
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
    local path = s.archive_path or "/sd/maps/world.tdmap"
    -- async.task wraps spawn with begin()/done() so the status-bar
    -- spinner reflects this load and clears even if something errors.
    local async = require("ezui.async")
    async.task(function()
        local arc, err = map_archive.open(path)
        if not arc then
            inst:set_state({ loading = false, error = err or "failed to open archive" })
            return
        end
        -- Clamp the restored zoom against this archive's bounds.
        local z = inst._state.zoom or DEFAULT_VIEW.zoom
        if z < arc.header.min_zoom then z = arc.header.min_zoom end
        if z > arc.header.max_zoom then z = arc.header.max_zoom end

        -- Snap to archive center when there's no saved view OR when the
        -- saved view sits outside the archive's bounds (e.g. you panned
        -- around in a Netherlands archive and then opened a Spain one).
        local center_lat = inst._state.center_lat
        local center_lon = inst._state.center_lon
        local b = arc.header.bounds
        local saved_outside = b and (
            (center_lat or 0) < b.south or (center_lat or 0) > b.north
            or (center_lon or 0) < b.west  or (center_lon or 0) > b.east)
        if (not inst._state.used_saved_view and b) or saved_outside then
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
        ez.storage.set_pref(pref_key(s.archive_path), string.format(
            "%.6f,%.6f,%d", s.center_lat or 0, s.center_lon or 0, s.zoom or DEFAULT_VIEW.zoom))
        s.archive:close()
        s.archive = nil
    end
end

-- Called from screen.update() each frame. Cheap on non-follow frames; when
-- follow_gps is on, pulls the latest fix and recenters the map. While a
-- track recording session is active we invalidate every ~1 s so the live
-- polyline tail extends in step with the recorder's sampling cadence.
function Map:update()
    local s = self._state
    if gps_track.is_active() then
        local now = ez.system.millis()
        if (now - (self._last_track_tick or 0)) > 1000 then
            self._last_track_tick = now
            screen_mod.invalidate()
        end
    end
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

-- Alt+M actions on the Map.
--
-- "Set as broadcast home" is the issue #127 entry point: there is no
-- Settings entry and no dedicated picker screen. The user pans the map
-- so the centre crosshair sits on their authored "approximately me"
-- point (town centre, a nearby park -- not their actual home), then
-- commits via this menu. We write decimal-e6 strings into
-- `adv_home_lat` / `adv_home_lon` and `MeshCore::sendAnnounce()`
-- (C++ side) picks them up on the next outgoing ADVERT.
--
-- The "Clear" entry only shows when at least one half is set so the
-- menu doesn't grow useless entries in the default case.
local function home_is_set()
    local lat = ez.storage.get_pref("adv_home_lat", "")
    local lon = ez.storage.get_pref("adv_home_lon", "")
    return (lat ~= "" and lat ~= nil) or (lon ~= "" and lon ~= nil)
end

-- Push a list-of-options menu. Used by the location-sharing actions to
-- pick a destination contact or channel after the user has panned to
-- the point they want to share. Pops itself before invoking on_pick so
-- the user lands back on the map (not on a stale picker) when the
-- destination chat takes over.
local function push_destination_picker(title, items, on_pick)
    local MenuDialog = require("screens.dialog.menu")
    local entries = {}
    for _, item in ipairs(items) do
        entries[#entries + 1] = {
            title = item.title,
            subtitle = item.subtitle,
            on_press = function() on_pick(item.value) end,
        }
    end
    if #entries == 0 then
        entries[#entries + 1] = {
            title = "(nothing to share to)",
            disabled = true,
        }
    end
    screen_mod.push(screen_mod.create(MenuDialog,
        MenuDialog.initial_state(entries, title)))
end

function Map:menu()
    local notifications = require("services.notifications")
    local items = {}

    items[#items + 1] = {
        title    = "Set as broadcast home",
        subtitle = "Broadcast this point in every ADVERT",
        on_press = function()
            local s = self._state
            local lat = s.center_lat
            local lon = s.center_lon
            if type(lat) ~= "number" or type(lon) ~= "number" then
                notifications.post({
                    title  = "Broadcast home not set",
                    body   = "Pan the map first so the centre is on a point.",
                    source = "system",
                })
                return
            end
            -- Decimal-e6 string keeps Lua-side and C++-side parsers
            -- agreed on encoding; the C++ ADVERT path packs the same
            -- integer into the wire format.
            local lat_e6 = math.floor(lat * 1000000 + (lat >= 0 and 0.5 or -0.5))
            local lon_e6 = math.floor(lon * 1000000 + (lon >= 0 and 0.5 or -0.5))
            ez.storage.set_pref("adv_home_lat", tostring(lat_e6))
            ez.storage.set_pref("adv_home_lon", tostring(lon_e6))
            notifications.post({
                title  = "Broadcast home set",
                body   = string.format(
                    "%.4f, %.4f -- this is broadcast in cleartext to " ..
                    "every node that hears your adverts. Treat it as " ..
                    "public.", lat, lon),
                source = "system",
            })
        end,
    }

    if home_is_set() then
        items[#items + 1] = {
            title    = "Clear broadcast home",
            subtitle = "Stop including a location in ADVERTs",
            on_press = function()
                ez.storage.set_pref("adv_home_lat", "")
                ez.storage.set_pref("adv_home_lon", "")
                notifications.post({
                    title  = "Broadcast home cleared",
                    body   = "Your ADVERTs no longer include a location.",
                    source = "system",
                })
            end,
        }
    end

    -- ---- Track recording (issue #108) ----
    if gps_track.is_active() then
        items[#items + 1] = {
            title    = "Stop recording route",
            subtitle = "Finalise and save the current track",
            on_press = function()
                local info = gps_track.stop()
                if info then
                    notifications.post({
                        title = "Track saved",
                        body  = (info.label or "track")
                            .. "  (" .. tostring(#(info.points or {})) .. " points)",
                        source = "system",
                    })
                    -- Force a rebuild so the status strip drops the REC badge.
                    self:set_state({})
                end
            end,
        }
    else
        items[#items + 1] = {
            title    = "Start recording route",
            subtitle = "Append every fix to /sd/tracks/...eztrack",
            on_press = function()
                local ok, err = gps_track.start({})
                if not ok then
                    notifications.post({
                        title = "Cannot start recording",
                        body  = err or "unknown error",
                        source = "system",
                    })
                    return
                end
                notifications.post({
                    title = "Recording started",
                    body  = "Stop via Alt+M when done.",
                    source = "system",
                })
                self:set_state({})
            end,
        }
    end

    items[#items + 1] = {
        title    = "Open saved track...",
        subtitle = "Browse and open previous recordings",
        on_press = function()
            local Viewer = require("screens.tools.track_viewer")
            screen_mod.push(screen_mod.create(Viewer, Viewer.initial_state()))
        end,
    }

    -- Share the current map center (the crosshair) as an ezme.sh
    -- location share. The DM variant encrypts to the recipient; the
    -- channel variant is plaintext. Both flow through the same
    -- chat send pipeline as a regular message, so the recipient sees
    -- a chat bubble they can act on via the standard context menu.
    local sharing_svc = require("services.sharing")

    items[#items + 1] = {
        title    = "Share this point -> DM...",
        subtitle = "Send the map center to a contact (encrypted)",
        on_press = function()
            local s = self._state
            local lat, lon = s.center_lat, s.center_lon
            if type(lat) ~= "number" or type(lon) ~= "number" then
                notifications.post({
                    title = "Cannot share",
                    body = "No map center -- open a map archive first.",
                    source = "system",
                })
                return
            end
            local contacts_svc = require("services.contacts")
            local picker = {}
            for _, c in ipairs(contacts_svc.get_all()) do
                picker[#picker + 1] = {
                    title = c.name or c.pub_key_hex:sub(1, 8),
                    subtitle = c.pub_key_hex:sub(1, 12) .. "...",
                    value = c,
                }
            end
            push_destination_picker("Share location to", picker, function(contact)
                local dm_svc = require("services.direct_messages")
                local url, err = sharing_svc.encode_gps_dm(
                    contact.pub_key_hex, lat, lon, nil)
                if url then
                    dm_svc.send(contact.pub_key_hex, url)
                    notifications.post({
                        title = "Location shared",
                        body = "Sent to " .. (contact.name or "contact"),
                        source = "system",
                    })
                else
                    notifications.post({
                        title = "Share failed",
                        body = err or "unknown error",
                        source = "system",
                    })
                end
            end)
        end,
    }

    items[#items + 1] = {
        title    = "Share this point -> Channel...",
        subtitle = "Post the map center to a channel (visible to all)",
        on_press = function()
            local s = self._state
            local lat, lon = s.center_lat, s.center_lon
            if type(lat) ~= "number" or type(lon) ~= "number" then
                notifications.post({
                    title = "Cannot share",
                    body = "No map center -- open a map archive first.",
                    source = "system",
                })
                return
            end
            local channels_svc = require("services.channels")
            local picker = {}
            for _, ch in ipairs(channels_svc.get_list()) do
                picker[#picker + 1] = {
                    title = ch.name,
                    subtitle = "Post to this channel",
                    value = ch.name,
                }
            end
            push_destination_picker("Share location to", picker, function(channel_name)
                local url, err = sharing_svc.encode_gps_channel(lat, lon, nil)
                if url then
                    channels_svc.send(channel_name, url)
                    notifications.post({
                        title = "Location shared",
                        body = "Posted to " .. channel_name,
                        source = "system",
                    })
                else
                    notifications.post({
                        title = "Share failed",
                        body = err or "unknown error",
                        source = "system",
                    })
                end
            end)
        end,
    }

    return items
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

-- ASCII-sanitize a peer-originated string. Built-in bitmap fonts only
-- cover 0x20..0x7E (see CLAUDE.md). Mirror notifications.lua's policy
-- of replacing the offending byte with '?' rather than dropping it, so
-- the truncation length stays predictable.
local function ascii_safe(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("[^\32-\126]", "?"))
end

-- Build the list of peers to draw, filtered by the user's visibility
-- prefs and the staleness thresholds. Returns an array of:
--   { lat, lon, role, name, stale }
-- `stale` is true when 24h < age < 7d AND the "show stale" pref is on.
-- Sorted infrastructure-last so room/repeater pins occlude chat pins
-- when they overlap (infrastructure is the more useful sighting).
local function gather_peers()
    local show_infra   = pref_on(PEER_PREF_REPEATERS, true)
    local show_contact = pref_on(PEER_PREF_CONTACTS,  true)
    local show_all     = pref_on(PEER_PREF_ALL_CHAT,  false)
    local show_stale   = pref_on(PEER_PREF_STALE,     false)
    if not (show_infra or show_contact or show_all) then return {} end

    local nodes = ez.mesh.get_nodes() or {}
    local out = {}
    for _, n in ipairs(nodes) do
        if n.has_location then
            local age = n.age_seconds or 0
            local stale = age > STALE_DIM_AGE
            local ancient = age > STALE_HIDE_AGE
            local include = false
            if n.role == 2 or n.role == 3 then         -- repeater / room
                include = show_infra
            elseif n.role == 1 or n.role == 0 then     -- chat client (or unknown)
                if show_all then
                    include = true
                elseif show_contact and n.pub_key_hex
                       and contacts.is_contact(n.pub_key_hex) then
                    include = true
                end
            end
            if include and not ancient and (not stale or show_stale) then
                out[#out + 1] = {
                    lat   = n.lat,
                    lon   = n.lon,
                    role  = n.role or 0,
                    name  = ascii_safe(n.name or ""),
                    stale = stale,
                }
            end
        end
    end
    -- Chat first, infrastructure last -- the more important pin paints on top.
    table.sort(out, function(a, b) return (a.role or 0) < (b.role or 0) end)
    return out
end

-- Draw a single peer pin. Shape depends on role; tone depends on
-- staleness so the user can tell at a glance which peers are fresh.
local function draw_peer_pin(d, px, py, peer, ink, halo)
    local ix, iy = math.floor(px), math.floor(py)
    if peer.role == 2 then
        -- Repeater: upward triangle (antenna).
        d.fill_triangle(ix, iy - 5, ix - 4, iy + 3, ix + 4, iy + 3, ink)
        d.draw_triangle(ix, iy - 5, ix - 4, iy + 3, ix + 4, iy + 3, halo)
    elseif peer.role == 3 then
        -- Room server: filled square (hub).
        d.fill_rect(ix - 4, iy - 4, 9, 9, ink)
        d.draw_rect(ix - 4, iy - 4, 9, 9, halo)
    else
        -- Chat node / contact: filled circle.
        d.fill_circle(ix, iy, 3, ink)
        d.draw_circle(ix, iy, 4, halo)
    end
end

-- Peer overlay: pins for every peer with a recent ADVERT location.
local function make_peers_overlay()
    return function(d, x, y, w, h, project)
        local peers = gather_peers()
        if #peers == 0 then return end

        local text_ink  = theme.color("TEXT")
        local muted_ink = theme.color("TEXT_MUTED")
        local accent    = theme.color("ACCENT")
        local bg        = theme.color("BG")

        for _, peer in ipairs(peers) do
            local px, py = project(peer.lat, peer.lon)
            if px >= x - 6 and px <= x + w + 5 and py >= y - 6 and py <= y + h + 5 then
                local ink  = peer.stale and muted_ink or accent
                local halo = peer.stale and bg        or text_ink
                draw_peer_pin(d, px, py, peer, ink, halo)

                if peer.name ~= "" then
                    -- Truncate to ~10 chars per spec; the small font keeps
                    -- labels from crowding the pin at typical zooms.
                    local label = peer.name
                    if #label > 10 then label = label:sub(1, 10) end
                    theme.set_font("tiny_aa")
                    local tw = theme.text_width(label)
                    local lx = math.floor(px - tw / 2)
                    local ly = math.floor(py + 6)
                    if lx + tw > x and lx < x + w and ly < y + h then
                        -- 4-direction halo so the name stays legible on
                        -- any tile color, matching map_view's label style.
                        local label_ink  = peer.stale and muted_ink or text_ink
                        local label_halo = bg
                        d.draw_text(lx - 1, ly,     label, label_halo)
                        d.draw_text(lx + 1, ly,     label, label_halo)
                        d.draw_text(lx,     ly - 1, label, label_halo)
                        d.draw_text(lx,     ly + 1, label, label_halo)
                        d.draw_text(lx,     ly,     label, label_ink)
                    end
                    theme.set_font("medium")
                end
            end
        end
    end
end

-- Polyline overlay used for both the live in-progress recording and the
-- "Open saved track" preview from track_viewer. `pts` is an array of
-- { lat, lon } in chronological order. Draws line segments in the theme
-- accent colour with a small dot at the head (most recent point) so the
-- user can tell direction at a glance.
local function make_track_overlay(pts, opts)
    opts = opts or {}
    local accent_token = opts.color_token or "ACCENT"
    return function(d, x, y, w, h, project)
        if not pts or #pts < 1 then return end
        local ink = theme.color(accent_token)
        local halo = theme.color("BG")
        -- Track previous projected coord so we draw a single segment per
        -- pair. project() returns nil for out-of-archive lookups, in which
        -- case we restart the segment.
        local prev_px, prev_py
        for i, p in ipairs(pts) do
            local px, py = project(p.lat, p.lon)
            if not (px and py) then
                prev_px, prev_py = nil, nil
            else
                if prev_px then
                    -- Clip is cheap relative to redraw, so just draw and
                    -- let the framebuffer ignore off-screen pixels. The
                    -- overlay runs once per frame.
                    d.draw_line(math.floor(prev_px), math.floor(prev_py),
                                math.floor(px), math.floor(py), ink)
                end
                prev_px, prev_py = px, py
            end
            -- Head dot
            if i == #pts and px and py then
                local ix, iy = math.floor(px), math.floor(py)
                d.fill_circle(ix, iy, 3, ink)
                d.draw_circle(ix, iy, 4, halo)
            end
        end
    end
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
    -- "No archive, no error" means the async open() hasn't resolved yet,
    -- regardless of whether the loading flag got seeded. Treat both as
    -- loading so callers that push us with an empty state (e.g. direct
    -- ui.push_screen without initial_state) still see a spinner instead
    -- of the map_view's bare "No map archive loaded" placeholder.
    local path = state.archive_path or "/sd/maps/world.tdmap"
    if state.loading or (not state.archive and not state.error) then
        return ui.vbox({ gap = 0 }, {
            ui.title_bar("Map", { back = true }),
            ui.padding({ 60, 20, 20, 20 },
                ui.hbox({ gap = 8 }, {
                    { type = "spinner", size = 16 },
                    ui.text_widget("Loading " .. path .. "...", { color = "TEXT_SEC" }),
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
                    "Could not open " .. path .. ".",
                    { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
            ),
        })
    end

    -- Status strip: coords, zoom, and GPS follow indicator. The REC
    -- badge appears whenever a track recording session is active so
    -- the user has constant visual confirmation -- compensates for
    -- not having a global indicator outside the map screen.
    local segments = {
        string.format("%.4f,%.4f", state.center_lat or 0, state.center_lon or 0),
        "Z" .. tostring(state.zoom or 0),
    }
    if state.follow_gps then segments[#segments + 1] = "GPS" end
    if gps_track.is_active() then segments[#segments + 1] = "REC" end

    return ui.vbox({ gap = 0 }, {
        ui.title_bar("Map", { back = true }),
        map_view({
            grow        = 1,
            archive     = state.archive,
            center_lat  = state.center_lat,
            center_lon  = state.center_lon,
            zoom        = state.zoom,
            show_labels = state.show_labels,
            overlay_fn  = (function()
                -- Peers paint first, then any track polyline (saved or
                -- in-progress), then the GPS dot on top so the user's
                -- own position is never occluded by a colocated peer
                -- pin or by the track head dot.
                local peers_fn = make_peers_overlay()
                local gps_fn   = make_gps_overlay()
                -- state.track_overlay is set by track_viewer; the live
                -- in-progress polyline is read fresh every frame via
                -- gps_track.live_points() so newly captured points
                -- appear without a state rebuild.
                local viewer_pts = state.track_overlay
                local viewer_fn  = viewer_pts and make_track_overlay(viewer_pts) or nil
                return function(d, x, y, w, h, project)
                    peers_fn(d, x, y, w, h, project)
                    if viewer_fn then viewer_fn(d, x, y, w, h, project) end
                    local live_pts = gps_track.live_points()
                    if live_pts and #live_pts > 0 then
                        make_track_overlay(live_pts)(d, x, y, w, h, project)
                    end
                    gps_fn(d, x, y, w, h, project)
                end
            end)(),
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
                font = "small_aa", color = "TEXT_SEC",
            })
        ),
    })
end

return Map
