-- ezui.widgets.map_view: TDMAP v7 vector map renderer.
-- Consumes a services/map_archive handle. Draws filled polygons (land,
-- water, parks, buildings) and stroked polylines (roads, railways) from
-- geometry stored in the archive, then overlays labels filtered by viewport,
-- then runs any caller overlay_fn for pins / GPS dots.
--
-- Why vectors: a single archive serves every zoom level (no raster
-- duplication), themes hot-swap colors per frame (no cache invalidate),
-- and pan/zoom interpolates smoothly because we resample the geometry
-- instead of blitting fixed-resolution tiles.
--
-- Usage (unchanged from the v6 widget):
--   require("ezui.widgets.map_view")
--   {
--       type = "map_view",
--       archive = my_archive,
--       center_lat = 52.37, center_lon = 4.90, zoom = 11,
--       show_labels = true,
--       on_move = function(lat, lon, z) ... end,
--       overlay_fn = function(d, x, y, w, h, project) ... end,
--   }

local node        = require("ezui.node")
local theme       = require("ezui.theme")
local map_archive = require("services.map_archive")

local PAN_STEP_PIXELS = 26

-- Stroke width by feature class. Indexed by F_* values from map_archive.
local STROKE_WIDTH = {
    [map_archive.F_WATER]      = 1,  -- waterways
    [map_archive.F_ROAD_MINOR] = 1,
    [map_archive.F_ROAD_MAJOR] = 2,
    [map_archive.F_HIGHWAY]    = 3,
    [map_archive.F_RAILWAY]    = 1,
}

local LABEL_FONT = {
    [0] = "medium",
    [1] = "small",
    [2] = "small",
    [3] = "tiny_aa",
    [4] = "tiny_aa",
    [5] = "small",
}
local DEFAULT_FONT = "small"

local HALO_OFFSETS = { {0,-1},{-1,0},{1,0},{0,1} }
local HALO_COUNT   = 4

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Web Mercator helper exposed for overlay_fn (GPS dots etc).
local TILE = 256

local function make_projector(n, x, y, w, h)
    local cx_tile, cy_tile = map_archive.lat_lon_to_tile(
        n.center_lat or 0, n.center_lon or 0, n.zoom or 0)
    local origin_tile_x = cx_tile - w / (2 * TILE)
    local origin_tile_y = cy_tile - h / (2 * TILE)
    return function(lat, lon)
        local tx, ty = map_archive.lat_lon_to_tile(lat, lon, n.zoom or 0)
        return x + (tx - origin_tile_x) * TILE,
               y + (ty - origin_tile_y) * TILE
    end, origin_tile_x, origin_tile_y
end

local function pan_by_pixels(n, dx, dy)
    local tiles = 2 ^ (n.zoom or 0)
    local cx_tile, cy_tile = map_archive.lat_lon_to_tile(
        n.center_lat or 0, n.center_lon or 0, n.zoom or 0)
    local new_x = clamp(cx_tile + dx / TILE, 0, tiles)
    local new_y = clamp(cy_tile + dy / TILE, 0, tiles)
    local lat, lon = map_archive.tile_to_lat_lon(new_x, new_y, n.zoom or 0)
    n.center_lat = lat
    n.center_lon = lon
    if n.on_move then n.on_move(lat, lon, n.zoom or 0) end
end

local function set_zoom(n, new_zoom)
    local arc = n.archive
    if not arc then return end
    local zmin = arc.header.min_zoom
    local zmax = arc.header.max_zoom
    new_zoom = clamp(new_zoom, zmin, zmax)
    if new_zoom == n.zoom then return end
    n.zoom = new_zoom
    if n.on_move then n.on_move(n.center_lat, n.center_lon, n.zoom) end
end

-- Project a flat {lat_e6, lon_e6, lat_e6, lon_e6, ...} vector record into a
-- flat screen-space {sx, sy, sx, sy, ...} array for the C fill/draw bindings.
-- Returns nil if every vertex falls outside the widget rect (cheap viewport
-- cull at the polyline level).
--
-- The math is: convert lat/lon to Web Mercator tile coords at the current
-- zoom, then offset by the viewport's origin in tile coords, then scale by
-- TILE (256). We inline the math here rather than going through the per-point
-- projector function because this is the hottest loop on the device — a
-- typical frame projects 10k+ vertices.
local function project_record_to_screen(
    coords, project_origin_x, project_origin_y, screen_x, screen_y,
    n_tiles_factor, lon_offset, zoom)
    local out = {}
    local count = #coords
    local n_pow2 = 2 ^ zoom
    local sin_lat
    local lat_rad
    for i = 1, count, 2 do
        local lat = coords[i]     / 1e6
        local lon = coords[i + 1] / 1e6
        -- lat → mercator y; lon → linear x
        local px = (lon + 180) / 360 * n_pow2
        lat_rad = lat * math.pi / 180
        sin_lat = math.sin(lat_rad)
        local py = (1 - math.log((1 + sin_lat) / (1 - sin_lat)) / (2 * math.pi)) * n_pow2 / 2
        local sx = screen_x + (px - project_origin_x) * TILE
        local sy = screen_y + (py - project_origin_y) * TILE
        out[#out + 1] = math.floor(sx + 0.5)
        out[#out + 1] = math.floor(sy + 0.5)
    end
    return out
end

-- Cheap on-screen test: any vertex within widget rect, or any pair spans it.
local function any_vertex_visible(scr, x, y, w, h)
    for i = 1, #scr, 2 do
        local sx, sy = scr[i], scr[i + 1]
        if sx >= x and sx <= x + w and sy >= y and sy <= y + h then
            return true
        end
    end
    -- Polylines crossing the rect without a vertex inside it: if the
    -- record's bbox spans the rect on both axes we keep it.
    local min_sx, max_sx = math.huge, -math.huge
    local min_sy, max_sy = math.huge, -math.huge
    for i = 1, #scr, 2 do
        local sx, sy = scr[i], scr[i + 1]
        if sx < min_sx then min_sx = sx end
        if sx > max_sx then max_sx = sx end
        if sy < min_sy then min_sy = sy end
        if sy > max_sy then max_sy = sy end
    end
    return max_sx >= x and min_sx <= x + w
        and max_sy >= y and min_sy <= y + h
end

node.register("map_view", {
    focusable = true,

    measure = function(n, max_w, max_h)
        return max_w, max_h
    end,

    draw = function(n, d, x, y, w, h)
        local arc = n.archive
        if not arc then
            d.fill_rect(x, y, w, h, theme.color("SURFACE_ALT"))
            d.draw_text(x + 8, y + 8, "No map archive loaded", theme.color("TEXT_MUTED"))
            return
        end

        d.set_clip_rect(x, y, w, h)

        local map_style = theme.map_palette()
        local palette   = map_style.tiles

        -- Background: paint with the Land color so areas not covered by
        -- explicit Land polygons (rural inland, the ocean off the edge of
        -- the archive bounds) still get a sensible base. Water polygons
        -- will overpaint where needed.
        d.fill_rect(x, y, w, h, palette[1])

        local z = n.zoom or arc.header.min_zoom
        local _, origin_tile_x, origin_tile_y = make_projector(n, x, y, w, h)

        -- Compute geographic viewport from the visible tile range so the
        -- archive's spatial index can return only nearby geometry.
        local br_lat, br_lon = map_archive.tile_to_lat_lon(
            origin_tile_x + w / TILE, origin_tile_y + h / TILE, z)
        local tl_lat, tl_lon = map_archive.tile_to_lat_lon(
            origin_tile_x, origin_tile_y, z)
        local min_lat = math.min(tl_lat, br_lat)
        local max_lat = math.max(tl_lat, br_lat)
        local min_lon = math.min(tl_lon, br_lon)
        local max_lon = math.max(tl_lon, br_lon)

        local visible_slots = arc:viewport_geometries(
            { min_lat, min_lon, max_lat, max_lon }, z)

        -- Two-pass render: filled polygons first (so polylines stroke on
        -- top), then polylines. Within each pass we order by feature class
        -- ascending so e.g. land paints before water paints before park
        -- (correct overdraw order matches v6 raster compositing).
        local polys = {}
        local lines = {}
        for _, slot in ipairs(visible_slots) do
            local entry = arc.entries[slot]
            local coords = arc:get_geometry(slot)
            if coords then
                local scr = project_record_to_screen(
                    coords, origin_tile_x, origin_tile_y, x, y, 0, 0, z)
                if any_vertex_visible(scr, x, y, w, h) then
                    if entry.geom_type == map_archive.G_POLYGON then
                        polys[#polys + 1] = { entry, scr }
                    else
                        lines[#lines + 1] = { entry, scr }
                    end
                end
            end
        end

        table.sort(polys, function(a, b)
            return a[1].feature_class < b[1].feature_class
        end)
        for i = 1, #polys do
            local entry = polys[i][1]
            local color = palette[entry.feature_class + 1] or palette[1]
            d.fill_polygon(polys[i][2], color)
        end

        -- Order polylines by importance so highways stroke over residential.
        table.sort(lines, function(a, b)
            return a[1].feature_class < b[1].feature_class
        end)
        for i = 1, #lines do
            local entry = lines[i][1]
            local color = palette[entry.feature_class + 1] or palette[8]
            local width = STROKE_WIDTH[entry.feature_class] or 1
            d.draw_polyline(lines[i][2], color, width)
        end

        -- Label overlay (unchanged from v6).
        if n.show_labels ~= false then
            local visible = arc:labels_in_bounds(z, min_lat, max_lat, min_lon, max_lon)
            table.sort(visible, function(a, b)
                if a.type ~= b.type then return a.type < b.type end
                if a.lat ~= b.lat then return a.lat < b.lat end
                if a.lon ~= b.lon then return a.lon < b.lon end
                return a.text < b.text
            end)

            local drawn = {}
            local seen_text = {}
            local label_halo  = map_style.label_halo
            local label_water = map_style.label_water
            local label_ink   = map_style.label_ink

            local project = function(lat, lon)
                local tx, ty = map_archive.lat_lon_to_tile(lat, lon, z)
                return x + (tx - origin_tile_x) * TILE,
                       y + (ty - origin_tile_y) * TILE
            end

            for _, lbl in ipairs(visible) do
                if not seen_text[lbl.text] then
                    local font = LABEL_FONT[lbl.type] or DEFAULT_FONT
                    theme.set_font(font)
                    local ink = (lbl.type == 5) and label_water or label_ink
                    local px, py = project(lbl.lat, lbl.lon)
                    local tw = theme.text_width(lbl.text)
                    local lh = theme.font_height()
                    local lx = math.floor(px - tw / 2)
                    local ly = math.floor(py - lh / 2)

                    if lx + tw > x and lx < x + w and ly + lh > y and ly < y + h then
                        local overlaps = false
                        for i = 1, #drawn do
                            local r = drawn[i]
                            if not (lx + tw < r.x or lx > r.x + r.w
                                    or ly + lh < r.y or ly > r.y + r.h) then
                                overlaps = true
                                break
                            end
                        end
                        if not overlaps then
                            for i = 1, HALO_COUNT do
                                local o = HALO_OFFSETS[i]
                                d.draw_text(lx + o[1], ly + o[2], lbl.text, label_halo)
                            end
                            d.draw_text(lx, ly, lbl.text, ink)
                            drawn[#drawn + 1] = { x = lx, y = ly, w = tw, h = lh }
                            seen_text[lbl.text] = true
                        end
                    end
                end
            end
            theme.set_font("medium")
        end

        -- Overlay hook (GPS dot, pins, route lines).
        if n.overlay_fn then
            local project = function(lat, lon)
                local tx, ty = map_archive.lat_lon_to_tile(lat, lon, z)
                return x + (tx - origin_tile_x) * TILE,
                       y + (ty - origin_tile_y) * TILE
            end
            n.overlay_fn(d, x, y, w, h, project)
        end

        -- Centre crosshair (unchanged).
        if n.show_crosshair ~= false then
            local cx = x + math.floor(w / 2)
            local cy = y + math.floor(h / 2)
            local ink  = map_style.label_ink
            local halo = map_style.label_halo
            d.fill_rect(cx - 4, cy, 9, 1, ink)
            d.fill_rect(cx, cy - 4, 1, 9, ink)
            d.fill_rect(cx - 4, cy - 1, 1, 3, halo)
            d.fill_rect(cx + 4, cy - 1, 1, 3, halo)
            d.fill_rect(cx - 1, cy - 4, 3, 1, halo)
            d.fill_rect(cx - 1, cy + 4, 3, 1, halo)
        end

        if n._focused then
            d.draw_rect(x, y, w, h, theme.color("ACCENT"))
        end

        d.set_clip_rect(0, 0, 320, 240)
    end,

    on_key = function(n, key)
        local arc = n.archive
        if not arc then return nil end

        local s = key.special
        if s == "UP"    then pan_by_pixels(n, 0, -PAN_STEP_PIXELS); return "handled" end
        if s == "DOWN"  then pan_by_pixels(n, 0,  PAN_STEP_PIXELS); return "handled" end
        if s == "LEFT"  then pan_by_pixels(n, -PAN_STEP_PIXELS, 0); return "handled" end
        if s == "RIGHT" then pan_by_pixels(n,  PAN_STEP_PIXELS, 0); return "handled" end

        local ch = key.character
        if ch == "+" or ch == "=" or s == "PAGE_UP"   then set_zoom(n, (n.zoom or 0) + 1); return "handled" end
        if ch == "-" or ch == "_" or s == "PAGE_DOWN" then set_zoom(n, (n.zoom or 0) - 1); return "handled" end
        if ch == "l" or ch == "L" then
            n.show_labels = not (n.show_labels ~= false)
            return "handled"
        end
        return nil
    end,
})

local function map_view(props)
    props.type = "map_view"
    return props
end

return {
    map_view = map_view,
}
