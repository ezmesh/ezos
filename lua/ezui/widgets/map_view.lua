-- ezui.widgets.map_view: Reusable map tile viewer node.
-- Consumes a services/map_archive handle; draws tiles with parent-tile fallback,
-- overlays labels filtered by viewport, and exposes a project(lat, lon) helper
-- to overlay_fn for pins/GPS dots.
--
-- Usage:
--   require("ezui.widgets.map_view")  -- registers the node type
--   {
--       type = "map_view",
--       archive = my_archive,
--       center_lat = 50.85, center_lon = 5.69, zoom = 10,
--       show_labels = true,
--       on_move = function(lat, lon, z) ... end,
--       overlay_fn = function(d, x, y, w, h, project) ... end,
--   }

local node        = require("ezui.node")
local theme       = require("ezui.theme")
local map_archive = require("services.map_archive")

local TILE_SIZE = map_archive.TILE_SIZE

-- Pan step in screen pixels per keypress. Scaled by zoom so coarse zooms don't
-- feel glacial. The old viewer used 0.1 tile units ≈ 26 pixels; we match that.
local PAN_STEP_PIXELS = 26

-- Label fonts by type id (matches config.py: 0=city, 1=town, 2=village,
-- 3=suburb, 4=road, 5=water). Inks are resolved per-frame from the active
-- theme's map palette so a T-toggle from light to dark flips both the
-- tile colors and the labels in the same frame.
local LABEL_FONT = {
    [0] = "medium",   -- City
    [1] = "small",    -- Town
    [2] = "small",    -- Village
    [3] = "tiny_aa",  -- Suburb
    [4] = "tiny_aa",  -- Road
    [5] = "small",    -- Water body
}
local DEFAULT_FONT = "small"

-- 4-direction halo: cardinal neighbours only. Drops diagonal passes (4 fewer
-- draw_text calls per label) for ~45% less label-render time, at the cost of
-- slightly weaker corner contrast.
local HALO_OFFSETS = { {0,-1},{-1,0},{1,0},{0,1} }
local HALO_COUNT   = 4

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Convert a lat/lon + zoom into screen pixel coords relative to the widget's
-- (x, y) top-left. Returns nil if no archive is attached (defensive for first
-- frame during async setup).
local function make_projector(n, x, y, w, h)
    local cx_tile, cy_tile = map_archive.lat_lon_to_tile(
        n.center_lat or 0, n.center_lon or 0, n.zoom or 0)
    local origin_tile_x = cx_tile - w / (2 * TILE_SIZE)
    local origin_tile_y = cy_tile - h / (2 * TILE_SIZE)
    return function(lat, lon)
        local tx, ty = map_archive.lat_lon_to_tile(lat, lon, n.zoom or 0)
        return x + (tx - origin_tile_x) * TILE_SIZE,
               y + (ty - origin_tile_y) * TILE_SIZE
    end, origin_tile_x, origin_tile_y
end

-- Apply a screen-pixel pan. Recomputes center_lat/lon via projection so later
-- frames pick up the new viewport.
local function pan_by_pixels(n, dx, dy)
    local tiles = 2 ^ (n.zoom or 0)
    local dx_tiles = dx / TILE_SIZE
    local dy_tiles = dy / TILE_SIZE
    local cx_tile, cy_tile = map_archive.lat_lon_to_tile(
        n.center_lat or 0, n.center_lon or 0, n.zoom or 0)
    local new_x = clamp(cx_tile + dx_tiles, 0, tiles)
    local new_y = clamp(cy_tile + dy_tiles, 0, tiles)
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
    -- Zoom change invalidates the negative cache (a tile missing at z=10 may
    -- exist at z=11). The LRU stays: those tiles are legitimately different.
    arc:invalidate_missing()
    if n.on_move then n.on_move(n.center_lat, n.center_lon, n.zoom) end
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

        -- Tile palette and label inks come from the active ezui theme. Tiles
        -- store semantic indices only — colors are decided here at draw time
        -- so a theme switch repaints without invalidating the tile cache.
        local map_style = theme.map_palette()
        local palette   = map_style.tiles

        -- Background wipe uses palette index 1 (land) so borders blend.
        d.fill_rect(x, y, w, h, palette[1])

        local z = n.zoom or arc.header.min_zoom
        local project, origin_tile_x, origin_tile_y = make_projector(n, x, y, w, h)

        -- Visible tile range. We nudge outward by 1 tile to cover partial tiles
        -- at the edges without extra arithmetic.
        local start_tx = math.floor(origin_tile_x)
        local start_ty = math.floor(origin_tile_y)
        local tiles_x = math.ceil(w / TILE_SIZE) + 1
        local tiles_y = math.ceil(h / TILE_SIZE) + 1
        local max_tile = (1 << z) - 1

        for ty = 0, tiles_y - 1 do
            for tx = 0, tiles_x - 1 do
                local tile_x = start_tx + tx
                local tile_y = start_ty + ty
                if tile_x >= 0 and tile_x <= max_tile and tile_y >= 0 and tile_y <= max_tile then
                    local screen_x = x + math.floor((tile_x - origin_tile_x) * TILE_SIZE)
                    local screen_y = y + math.floor((tile_y - origin_tile_y) * TILE_SIZE)

                    local data = arc:get_tile(z, tile_x, tile_y)
                    if type(data) == "string" and data ~= "pending" then
                        d.draw_indexed_bitmap(screen_x, screen_y, TILE_SIZE, TILE_SIZE, data, palette)
                    else
                        -- Pending or missing: try a cached ancestor as a blurry
                        -- placeholder so the user sees movement. The archive's
                        -- on_tile_loaded hook will invalidate the screen when
                        -- the real tile lands in cache.
                        local parent_data, sx, sy, sw, sh = arc:get_parent_fallback(z, tile_x, tile_y)
                        if parent_data then
                            d.draw_indexed_bitmap_scaled(
                                screen_x, screen_y, TILE_SIZE, TILE_SIZE,
                                parent_data, palette, sx, sy, sw, sh)
                        end
                    end
                end
            end
        end

        -- Label overlay: filter by current viewport bounds.
        if n.show_labels ~= false then
            local tl_lat, tl_lon = map_archive.tile_to_lat_lon(origin_tile_x, origin_tile_y, z)
            local br_lat, br_lon = map_archive.tile_to_lat_lon(
                origin_tile_x + w / TILE_SIZE, origin_tile_y + h / TILE_SIZE, z)
            local min_lat = math.min(tl_lat, br_lat)
            local max_lat = math.max(tl_lat, br_lat)
            local min_lon = math.min(tl_lon, br_lon)
            local max_lon = math.max(tl_lon, br_lon)

            local visible = arc:labels_in_bounds(z, min_lat, max_lat, min_lon, max_lon)
            -- Lower label_type == higher importance: draw cities before suburbs.
            -- Sort by (type, lat, lon, text) so ties break deterministically and
            -- the occlusion winner stays the same frame-to-frame while panning.
            -- Lua's table.sort isn't stable, so the full ordering key matters.
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

            for _, lbl in ipairs(visible) do
                if not seen_text[lbl.text] then
                    local font = LABEL_FONT[lbl.type] or DEFAULT_FONT
                    theme.set_font(font)
                    -- Type 5 is water bodies; pick the themed water ink so
                    -- the name reads cleanly against the water tile color.
                    local ink = (lbl.type == 5) and label_water or label_ink
                    local px, py = project(lbl.lat, lbl.lon)
                    local tw = theme.text_width(lbl.text)
                    local lh = theme.font_height()
                    -- Anchor labels centered above the point so they don't
                    -- appear to walk sideways as the viewport pans.
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
            -- Restore medium font so the surrounding UI doesn't inherit ours.
            theme.set_font("medium")
        end

        -- Overlay hook: GPS dot, pins, route lines. Runs after tiles/labels so
        -- the caller paints on top, and receives the same projection function.
        if n.overlay_fn then
            n.overlay_fn(d, x, y, w, h, project)
        end

        -- Center crosshair so the user knows what zoom is anchored on.
        -- Suppressed when follow_gps is on (the GPS dot already marks the spot).
        if n.show_crosshair ~= false then
            local cx = x + math.floor(w / 2)
            local cy = y + math.floor(h / 2)
            local ink  = map_style.label_ink
            local halo = map_style.label_halo
            d.fill_rect(cx - 4, cy, 9, 1, ink)
            d.fill_rect(cx, cy - 4, 1, 9, ink)
            -- Two-pixel highlights at each tip so the crosshair stays legible
            -- whether the underlying tile is land, water, or a road.
            d.fill_rect(cx - 4, cy - 1, 1, 3, halo)
            d.fill_rect(cx + 4, cy - 1, 1, 3, halo)
            d.fill_rect(cx - 1, cy - 4, 3, 1, halo)
            d.fill_rect(cx - 1, cy + 4, 3, 1, halo)
        end

        -- Focus indicator: thin rectangle around the widget when focused.
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

-- Convenience constructor for screens that prefer function-style composition.
local function map_view(props)
    props.type = "map_view"
    return props
end

return {
    map_view = map_view,
}
