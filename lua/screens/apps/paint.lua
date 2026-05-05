-- Paint -- mspaint-style bitmap editor.
--
-- A backing canvas sprite (selectable size) is rendered into a
-- viewport on screen with optional pan + integer zoom. The header
-- strip (palette + hint line) can be hidden to reclaim the full
-- viewport for the canvas. A rectangular selection plus an
-- in-memory clipboard support copy / cut / paste / delete; paste
-- treats the clipboard's "background" pixels (slot 1 = white) as
-- transparent, so a stamp from a white-background canvas blits
-- naturally onto a coloured area.
--
-- Direct keys (active any time):
--   Arrows / trackball   move cursor (1 px; Alt = 8 px steps)
--   SPACE                paint at cursor with current tool
--   1..8                 pick palette colour
--   B                    cycle brush size (1, 2, 4, 6 px)
--   E                    toggle eraser tool
--   Y                    toggle spra-Y tool (random aerosol)
--   R                    toggle rectangle-select tool
--   F                    flood-fill cursor's region (scanline)
--   C                    clear canvas
--   U                    undo last action (up to 8 steps)
--   H                    toggle the menu / palette bar
--   M                    toggle mouse mode (relative cursor; toolbar
--                        + canvas hit-test against the cursor instead
--                        of the finger)
--   Z / X                zoom in / out (1x .. 8x integer)
--   Shift + arrows       pan the view (canvas larger than viewport)
--   Back                 leave (BACKSPACE; T-Deck has no Esc key)
--
-- Alt + M opens the action menu (Copy / Cut / Paste / Move / Delete
-- selection / Clear selection / Canvas size / Pick custom colour /
-- Hide menu bar). Selection-only entries vanish when no selection
-- is active.
--
-- Stroke continuity: touch drag samples interpolate brush stamps
-- between successive points so a fast finger sweep produces a
-- continuous stroke rather than a chain of dots.

local ui         = require("ezui")
local node       = require("ezui.node")
local theme      = require("ezui.theme")
local screen_mod = require("ezui.screen")

-- fullscreen=true drops the global status bar so the canvas can claim
-- the entire 240 px panel height. The title bar (with the Back hint)
-- still draws inside the screen vbox; toggling H also hides the
-- header strip for an even bigger surface.
local Paint = { title = "Paint", fullscreen = true }

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- Header size: compact 40 px on a no-touch unit (the original
-- trackball/keyboard layout) but 80 px when the GT911 came up so each
-- toolbar button sits comfortably above MIN_TARGET_H. The header is
-- hideable via H, so the canvas-size cost when shown is bearable.
local HEADER_H_KEYS  = 40
local HEADER_H_TOUCH = 80
local function header_height()
    local ti = require("ezui.touch_input")
    return ti.touch_enabled() and HEADER_H_TOUCH or HEADER_H_KEYS
end
local PALETTE = {
    { 250, 250, 250 },   -- 1: white (also "transparent" colour for paste)
    {  10,  10,  10 },   -- 2: black
    { 230,  60,  60 },   -- 3: red
    { 250, 170,  60 },   -- 4: orange
    { 250, 220,  60 },   -- 5: yellow
    {  60, 200,  90 },   -- 6: green
    {  60, 140, 240 },   -- 7: blue
    { 200, 100, 220 },   -- 8: purple
}
local BRUSH_SIZES      = { 1, 2, 4, 6 }
local SPRAY_DENSITY    = 14
local SPRAY_RADIUS_MUL = 4

local SIZE_PRESETS = {
    { label = "Tiny 80x60",     w =  80, h =  60 },
    { label = "Small 160x120",  w = 160, h = 120 },
    { label = "Standard 320x240", w = 320, h = 240 },
    { label = "Large 480x360",  w = 480, h = 360 },
    { label = "Huge 640x480",   w = 640, h = 480 },
}
-- Default to the panel-native 320x240 so a freshly opened canvas
-- exactly fills the viewport at zoom 1; users who want more room go
-- to Alt+M -> Canvas size.
local DEFAULT_SIZE_IDX = 3
local PAN_STEP_PX      = 16

-- Viewport allocation (max we'd ever need). The canvas node measures
-- to the available height each frame; the underlying view sprite is
-- sized once at boot to the worst case so we don't reallocate on
-- header-toggle. With fullscreen=true the canvas can use the entire
-- 240 px panel height when both the global status bar and the
-- in-screen header are absent.
local VIEWPORT_W       = 320
local VIEWPORT_H_MAX   = 240

-- Undo history depth. Each entry is the full canvas raw (RGB565,
-- canvas_w * canvas_h * 2 bytes), so eight entries on the largest
-- canvas (640x480 = 614 KiB) is ~4.8 MiB in PSRAM -- well within the
-- 8 MiB budget but capped here so a long session doesn't drift up
-- against the wallpaper sprite + fonts + other allocs.
local UNDO_DEPTH       = 8

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function rgb565_from_triple(p)
    return ez.display.rgb(p[1], p[2], p[3])
end

-- ---------------------------------------------------------------------------
-- Undo (defined as Paint:_xxx below). Snapshots are full RGB565 raw
-- buffers stored in a ring of size UNDO_DEPTH. We snapshot at the
-- *start* of each logical action -- a single touch stroke from down
-- to up, one SPACE press, one fill, one paste, one delete-selection,
-- one clear -- so a single Undo rolls back the whole gesture rather
-- than a dot at a time.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Canvas node: measures to the viewport size, draws the (possibly
-- panned + zoomed) canvas, and overlays the cursor / selection rect.
-- ---------------------------------------------------------------------------

if not node.handler("paint_canvas") then
    node.register("paint_canvas", {
        focusable = false,
        measure = function(n, max_w, max_h)
            return max_w, max_h
        end,
        draw = function(n, d, x, y, w, h)
            -- Stash the viewport's screen position so the touch
            -- handler can convert raw screen coords back into
            -- canvas-internal pixels.
            n._screen_x  = x
            n._screen_y  = y
            n._viewport_w = w
            n._viewport_h = h

            local paint = n.paint
            if not paint then return end
            local zoom = paint._state.zoom
            local view_x, view_y = paint._state.view_x, paint._state.view_y

            -- Background of the viewport. The canvas may be smaller
            -- than the viewport (rare) or just panned; either way the
            -- gutter outside the canvas is filled with BG.
            d.fill_rect(x, y, w, h, theme.color("SURFACE_ALT"))

            -- Push pixels.
            d.set_clip_rect(x, y, w, h)
            if zoom == 1 then
                -- Direct push at a (possibly negative) offset. LGFX
                -- clips automatically against the clip rect we set
                -- above so off-screen parts of the canvas vanish.
                if paint._canvas then
                    paint._canvas:push(x - view_x, y - view_y)
                end
            else
                if paint._view_dirty then
                    paint:_refresh_view_sprite()
                    paint._view_dirty = false
                end
                if paint._view_sprite then
                    paint._view_sprite:push(x, y)
                end
            end
            d.clear_clip_rect()

            -- Selection rectangle (in screen coords).
            if paint._selection then
                local sx0, sy0 = paint:_canvas_to_screen(
                    paint._selection.x, paint._selection.y)
                local sx1, sy1 = paint:_canvas_to_screen(
                    paint._selection.x + paint._selection.w,
                    paint._selection.y + paint._selection.h)
                if sx0 and sy0 and sx1 and sy1 then
                    -- Two single-pixel rects offset by 1 px gives a
                    -- two-tone outline that reads on light + dark
                    -- backgrounds without an alpha channel.
                    d.draw_rect(sx0, sy0, sx1 - sx0, sy1 - sy0,
                        theme.color("ACCENT"))
                    d.draw_rect(sx0 - 1, sy0 - 1,
                        (sx1 - sx0) + 2, (sy1 - sy0) + 2,
                        theme.color("BG"))
                end
            end

            -- Live drag rectangle while the user is mid-drag with
            -- the select tool. A faint outline so it's distinguishable
            -- from a finalised selection.
            if paint._drag_sel then
                local dr = paint._drag_sel
                local sx0, sy0 = paint:_canvas_to_screen(dr.x0, dr.y0)
                local sx1, sy1 = paint:_canvas_to_screen(dr.x1, dr.y1)
                if sx0 and sy0 and sx1 and sy1 then
                    local rx, ry = math.min(sx0, sx1), math.min(sy0, sy1)
                    local rw, rh = math.abs(sx1 - sx0), math.abs(sy1 - sy0)
                    d.draw_rect(rx, ry, rw, rh, theme.color("ACCENT"))
                end
            end

            -- Cursor reticle. Hidden when mouse mode is on -- the
            -- screen-level white arrow already shows the position
            -- and drawing both is redundant + visually busy.
            local ti = require("ezui.touch_input")
            if not ti.mouse_mode then
                local cx, cy = paint._state.cursor_x, paint._state.cursor_y
                local sx, sy = paint:_canvas_to_screen(cx, cy)
                if sx and sy then
                    d.draw_line(sx - 4, sy, sx + 4, sy, theme.color("ACCENT"))
                    d.draw_line(sx, sy - 4, sx, sy + 4, theme.color("ACCENT"))
                end
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Header node: tool indicator + palette swatches.
-- ---------------------------------------------------------------------------

if not node.handler("paint_header") then
    -- Single-letter glyphs for the toolbar buttons. Letters match the
    -- keyboard shortcuts (E eraser, Y spray, R rectangle-select)
    -- so the toolbar reads as a visible reminder of the keys.
    local TOOL_BTNS = {
        { label = "P", tool = "pencil" },
        { label = "E", tool = "eraser" },
        { label = "Y", tool = "spray"  },
        { label = "R", tool = "select" },
    }

    -- Tiny helper that paints a single labelled button. `active` swaps
    -- the colour scheme so the current tool reads as pressed. Size
    -- comes from the caller because touch-mode and key-mode use
    -- different button geometries.
    local function draw_button(d, bx, by, bw, bh, label, active, font)
        local bg     = active and theme.color("ACCENT") or theme.color("SURFACE_ALT")
        local fg     = active and theme.color("BG")     or theme.color("TEXT")
        local border = active and theme.color("ACCENT") or theme.color("BORDER")
        d.fill_rect(bx, by, bw, bh, bg)
        d.draw_rect(bx, by, bw, bh, border)
        theme.set_font(font or "small_aa")
        local fh = theme.font_height()
        local lw = theme.text_width(label)
        d.draw_text(bx + (bw - lw) // 2,
                    by + (bh - fh) // 2, label, fg)
    end

    node.register("paint_header", {
        focusable = false,
        measure = function(n, max_w, max_h)
            return max_w, header_height()
        end,
        draw = function(n, d, x, y, w, h)
            d.fill_rect(x, y, w, h, theme.color("SURFACE"))
            d.fill_rect(x, y + h - 1, w, 1, theme.color("BORDER"))

            -- Pick row geometry per input mode. In touch mode the
            -- toolbar buttons grow above MIN_TARGET_H = 32 px (we
            -- pick 36 so they sit comfortably above the floor) and
            -- the palette / brush row gets a 32-px hit zone -- the
            -- visible swatches stay small and centred so the row
            -- still reads as a colour picker, but a finger landing
            -- anywhere in the inflated zone selects the colour.
            local ti = require("ezui.touch_input")
            local big = ti.touch_enabled()
            local btn_w   = big and 32 or 18
            local btn_h   = big and 36 or 14
            local font    = big and "medium_aa" or "small_aa"
            local sw      = big and 22 or 18    -- palette swatch width
            local sh      = big and 14 or 14    -- palette swatch visual height
            local row2_h  = big and 32 or 14    -- palette/brush hit zone height
            local cell_w  = big and 26 or 20    -- brush cell width

            -- ----- Row 1: action toolbar (tools + zoom + undo) -----
            local row1_y = y + (big and 6 or 3)
            local cursor_x = x + 6

            -- Tool selector. Active tool wears the accent fill so the
            -- user can read the current mode at a glance even though
            -- the cursor reticle on the canvas already gives a hint.
            local tool_cells = {}
            for i, t in ipairs(TOOL_BTNS) do
                local bx = cursor_x + (i - 1) * (btn_w + 2)
                draw_button(d, bx, row1_y, btn_w, btn_h,
                    t.label, n.tool == t.tool, font)
                tool_cells[i] = {
                    x = bx, y = row1_y, w = btn_w, h = btn_h,
                    tool = t.tool,
                }
            end
            n._tool_cells = tool_cells
            cursor_x = cursor_x + (#TOOL_BTNS) * (btn_w + 2) + 8

            -- Zoom buttons. Plain action buttons (no active state);
            -- the current zoom level appears as a tiny label between
            -- + and - so a user sees the value while picking.
            local zoom_in = { x = cursor_x, y = row1_y, w = btn_w, h = btn_h, dir = 1 }
            draw_button(d, zoom_in.x, zoom_in.y, btn_w, btn_h, "+", false, font)
            cursor_x = cursor_x + btn_w + 2
            -- Zoom level readout, vertically centred in the row.
            theme.set_font(font)
            local fh = theme.font_height()
            local zoom_label = string.format("%dx", n.zoom or 1)
            local zlw = theme.text_width(zoom_label)
            d.draw_text(cursor_x + 2, row1_y + (btn_h - fh) // 2,
                zoom_label, theme.color("TEXT"))
            cursor_x = cursor_x + zlw + 6
            local zoom_out = { x = cursor_x, y = row1_y, w = btn_w, h = btn_h, dir = -1 }
            draw_button(d, zoom_out.x, zoom_out.y, btn_w, btn_h, "-", false, font)
            cursor_x = cursor_x + btn_w + 8
            n._zoom_cells = { zoom_in, zoom_out }

            -- Undo. Disabled-look when there's nothing on the stack.
            local can_undo = (n.undo_depth or 0) > 0
            local undo_bg = can_undo and theme.color("SURFACE_ALT") or theme.color("SURFACE")
            local undo_fg = can_undo and theme.color("TEXT") or theme.color("TEXT_MUTED")
            d.fill_rect(cursor_x, row1_y, btn_w, btn_h, undo_bg)
            d.draw_rect(cursor_x, row1_y, btn_w, btn_h, theme.color("BORDER"))
            theme.set_font(font)
            local ulw = theme.text_width("U")
            d.draw_text(cursor_x + (btn_w - ulw) // 2,
                row1_y + (btn_h - fh) // 2, "U", undo_fg)
            n._undo_cell = {
                x = cursor_x, y = row1_y, w = btn_w, h = btn_h,
                enabled = can_undo,
            }
            cursor_x = cursor_x + btn_w + 8

            -- Right-aligned canvas-size readout. Just a mute reminder
            -- of how big the surface is; the toolbar itself carries
            -- all the interactive state.
            theme.set_font("small_aa")
            local sfh = theme.font_height()
            local size_text = string.format("%dx%d",
                n.canvas_w or 0, n.canvas_h or 0)
            local stw = theme.text_width(size_text)
            d.draw_text(x + w - stw - 6,
                row1_y + (btn_h - sfh) // 2,
                size_text, theme.color("TEXT_MUTED"))

            -- ----- Row 2: palette + brush-size selector -----
            local row2_y = row1_y + btn_h + 4

            local palette = n.palette or PALETTE
            local palette_cells = {}
            for i, p in ipairs(palette) do
                local sx = x + 6 + (i - 1) * (sw + 2)
                -- Inflate the hit zone vertically to row2_h so a finger
                -- has a finger-sized target; the visible swatch stays
                -- centred at sh px tall to keep the picker readable.
                local visual_y = row2_y + (row2_h - sh) // 2
                d.fill_rect(sx, visual_y, sw, sh,
                    ez.display.rgb(p[1], p[2], p[3]))
                if i == n.color_idx then
                    d.draw_rect(sx - 1, visual_y - 1, sw + 2, sh + 2,
                        theme.color("ACCENT"))
                end
                palette_cells[i] = {
                    x = sx, y = row2_y, w = sw, h = row2_h, idx = i,
                }
            end
            n._palette_cells = palette_cells

            -- Brush-size selector: filled circles sized to the actual
            -- brush radius. Same vertical inflation -- the dot icon
            -- stays small but a finger anywhere in the cell selects.
            local sizes = n.brush_sizes or BRUSH_SIZES
            local cells_x = x + 6 + (#palette) * (sw + 2) + 8
            local cells = {}
            local visual_h = sh
            local visual_y = row2_y + (row2_h - visual_h) // 2
            for i, r in ipairs(sizes) do
                local cx = cells_x + (i - 1) * (cell_w + 2)
                d.fill_rect(cx, visual_y, cell_w, visual_h,
                    theme.color("SURFACE_ALT"))
                local dot_x = cx + cell_w // 2
                local dot_y = visual_y + visual_h // 2
                local dot_color = (i == n.brush_idx)
                    and theme.color("ACCENT")
                    or  theme.color("TEXT")
                d.fill_circle(dot_x, dot_y,
                    math.min(r, visual_h // 2 - 1), dot_color)
                if i == n.brush_idx then
                    d.draw_rect(cx - 1, visual_y - 1,
                        cell_w + 2, visual_h + 2, theme.color("ACCENT"))
                end
                cells[i] = {
                    x = cx, y = row2_y, w = cell_w, h = row2_h,
                }
            end
            n._brush_cells = cells
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Screen state
-- ---------------------------------------------------------------------------

function Paint.initial_state()
    return {
        cursor_x      = SIZE_PRESETS[DEFAULT_SIZE_IDX].w // 2,
        cursor_y      = SIZE_PRESETS[DEFAULT_SIZE_IDX].h // 2,
        brush_idx     = 1,
        color_idx     = 2,        -- black
        tool          = "pencil",
        size_idx      = DEFAULT_SIZE_IDX,
        zoom          = 1,
        view_x        = 0,
        view_y        = 0,
        header_hidden = false,
    }
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function Paint:on_enter()
    self._palette = self._palette or {}
    for i = 1, #PALETTE do
        self._palette[i] = self._palette[i] or { table.unpack(PALETTE[i]) }
    end

    self:_alloc_canvas()
    self:_alloc_view_sprite()

    self._touch_subs = self._touch_subs or {}
    if #self._touch_subs == 0 then
        self:_install_touch_handlers()
    end

    self:set_state({})
end

function Paint:on_exit()
    if self._touch_subs then
        for _, id in ipairs(self._touch_subs) do
            ez.bus.unsubscribe(id)
        end
        self._touch_subs = nil
    end
    if self._canvas and self._canvas.destroy then
        self._canvas:destroy()
    end
    if self._view_sprite and self._view_sprite.destroy then
        self._view_sprite:destroy()
    end
    self._canvas      = nil
    self._view_sprite = nil
    self._clipboard   = nil
    self._selection   = nil
end

-- ---------------------------------------------------------------------------
-- Sprite allocation / canvas resize
-- ---------------------------------------------------------------------------

function Paint:_alloc_canvas()
    local preset = SIZE_PRESETS[self._state.size_idx] or SIZE_PRESETS[DEFAULT_SIZE_IDX]
    if self._canvas
        and self._canvas_w == preset.w
        and self._canvas_h == preset.h then
        return
    end
    if self._canvas and self._canvas.destroy then
        self._canvas:destroy()
    end
    self._canvas   = ez.display.create_sprite(preset.w, preset.h)
    self._canvas_w = preset.w
    self._canvas_h = preset.h
    if self._canvas then
        self._canvas:clear(rgb565_from_triple(self._palette[1]))
    end
    -- Reset view + cursor when the canvas dimensions changed.
    self._state.view_x = 0
    self._state.view_y = 0
    if self._state.cursor_x >= preset.w then self._state.cursor_x = preset.w - 1 end
    if self._state.cursor_y >= preset.h then self._state.cursor_y = preset.h - 1 end
    self._selection = nil
    self._view_dirty = true
end

function Paint:_alloc_view_sprite()
    if self._view_sprite then return end
    self._view_sprite = ez.display.create_sprite(VIEWPORT_W, VIEWPORT_H_MAX)
    if self._view_sprite then
        self._view_sprite:clear(theme.color("SURFACE_ALT"))
    end
end

-- ---------------------------------------------------------------------------
-- Coordinate mapping
-- ---------------------------------------------------------------------------

-- Returns the screen-space position of a canvas pixel, or nil if the
-- pixel falls outside the current viewport.
function Paint:_canvas_to_screen(cx, cy)
    local cv = self._canvas_node
    if not cv or not cv._screen_x then return nil end
    local zoom = self._state.zoom
    local sx = cv._screen_x + (cx - self._state.view_x) * zoom
    local sy = cv._screen_y + (cy - self._state.view_y) * zoom
    if sx < cv._screen_x or sy < cv._screen_y then return nil end
    if sx >= cv._screen_x + (cv._viewport_w or 0) then return nil end
    if sy >= cv._screen_y + (cv._viewport_h or 0) then return nil end
    return sx, sy
end

-- Inverse: screen → canvas. Returns nil when the screen point is
-- outside the viewport or maps outside the canvas bounds.
function Paint:_screen_to_canvas(sx, sy)
    local cv = self._canvas_node
    if not cv or not cv._screen_x then return nil end
    local rel_x = sx - cv._screen_x
    local rel_y = sy - cv._screen_y
    if rel_x < 0 or rel_y < 0 then return nil end
    if rel_x >= (cv._viewport_w or 0) then return nil end
    if rel_y >= (cv._viewport_h or 0) then return nil end
    local zoom = self._state.zoom
    local cx = self._state.view_x + (rel_x // zoom)
    local cy = self._state.view_y + (rel_y // zoom)
    if cx < 0 or cx >= self._canvas_w then return nil end
    if cy < 0 or cy >= self._canvas_h then return nil end
    return cx, cy
end

-- ---------------------------------------------------------------------------
-- View sprite refresh (zoom > 1)
-- ---------------------------------------------------------------------------

-- Re-render the viewport sprite from the canvas. Iterates the visible
-- canvas pixels and stamps each as a zoom x zoom block on the view
-- sprite. Skipped at zoom == 1 (the canvas is pushed directly with a
-- negative offset). Only runs when self._view_dirty so a still frame
-- after a paint costs nothing.
function Paint:_refresh_view_sprite()
    if not self._view_sprite or not self._canvas then return end
    local zoom = self._state.zoom
    if zoom <= 1 then return end
    local raw = self._canvas:get_raw()
    if not raw then return end
    local stride = self._canvas_w * 2
    local cv = self._canvas_node
    local vw = (cv and cv._viewport_w) or VIEWPORT_W
    local vh = (cv and cv._viewport_h) or VIEWPORT_H_MAX

    self._view_sprite:fill_rect(0, 0, vw, vh, theme.color("SURFACE_ALT"))

    local view_x, view_y = self._state.view_x, self._state.view_y
    local cx_count = math.floor(vw / zoom) + 1
    local cy_count = math.floor(vh / zoom) + 1
    local cx_end = math.min(self._canvas_w, view_x + cx_count)
    local cy_end = math.min(self._canvas_h, view_y + cy_count)
    local cx_start = math.max(0, view_x)
    local cy_start = math.max(0, view_y)

    for cy = cy_start, cy_end - 1 do
        local row_base = cy * stride
        local sy = (cy - view_y) * zoom
        for cx = cx_start, cx_end - 1 do
            local i = row_base + cx * 2 + 1
            local hi = raw:byte(i)
            local lo = raw:byte(i + 1)
            local color = (hi << 8) | lo
            local sx = (cx - view_x) * zoom
            self._view_sprite:fill_rect(sx, sy, zoom, zoom, color)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Painting primitives
-- ---------------------------------------------------------------------------

function Paint:_current_paint_color()
    if self._state.tool == "eraser" then
        return rgb565_from_triple(self._palette[1])
    end
    return rgb565_from_triple(self._palette[self._state.color_idx] or self._palette[2])
end

function Paint:_paint_at(x, y)
    if not self._canvas then return end
    if x < 0 or x >= self._canvas_w or y < 0 or y >= self._canvas_h then
        return
    end
    -- Track that the canvas has been modified, so the back-key
    -- handler can prompt the user before discarding.
    self._dirty = true
    local s   = self._state
    local col = self:_current_paint_color()
    local r   = BRUSH_SIZES[s.brush_idx] or 1
    if s.tool == "spray" then
        local spray_r = r * SPRAY_RADIUS_MUL
        for _ = 1, SPRAY_DENSITY do
            local angle = math.random() * math.pi * 2
            local dist  = math.sqrt(math.random()) * spray_r
            local px = math.floor(x + math.cos(angle) * dist)
            local py = math.floor(y + math.sin(angle) * dist)
            if px >= 0 and px < self._canvas_w
                    and py >= 0 and py < self._canvas_h then
                self._canvas:fill_rect(px, py, 1, 1, col)
            end
        end
    elseif r <= 1 then
        self._canvas:fill_rect(x, y, 1, 1, col)
    else
        self._canvas:fill_circle(x, y, r, col)
    end
    self._view_dirty = true
end

function Paint:_paint_line(x0, y0, x1, y1)
    local dx = x1 - x0
    local dy = y1 - y0
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then
        self:_paint_at(x1, y1)
        return
    end
    local r = BRUSH_SIZES[self._state.brush_idx] or 1
    local step
    if self._state.tool == "spray" then
        step = 2
    else
        step = math.max(1, math.floor(r / 2))
    end
    local n_steps = math.max(1, math.floor(dist / step))
    for i = 0, n_steps do
        local t = i / n_steps
        self:_paint_at(math.floor(x0 + dx * t), math.floor(y0 + dy * t))
    end
end

function Paint:_clear()
    if self._canvas then
        self:_snapshot()
        self._canvas:clear(rgb565_from_triple(self._palette[1]))
        self._view_dirty = true
        self._dirty = true
    end
end

-- Push a copy of the current canvas onto the undo stack. Called once
-- per logical action (see _begin_action) so the stack matches the
-- user's sense of a "step", not the per-pixel granularity of the
-- internal paint primitives. Drops the oldest entry if the stack
-- exceeds UNDO_DEPTH.
function Paint:_snapshot()
    if not self._canvas or not self._canvas.get_raw then return end
    self._undo = self._undo or {}
    local snap = self._canvas:get_raw()
    if not snap then return end
    self._undo[#self._undo + 1] = snap
    while #self._undo > UNDO_DEPTH do
        table.remove(self._undo, 1)
    end
end

-- Snapshot once at the start of a multi-step action. Subsequent calls
-- inside the same action are no-ops until the action ends. Touch
-- strokes call this on touch/down and clear the flag on touch/up;
-- single-shot actions (fill, paste) just snapshot directly via
-- _snapshot() above.
function Paint:_begin_action()
    if not self._action_in_progress then
        self:_snapshot()
        self._action_in_progress = true
    end
end

function Paint:_end_action()
    self._action_in_progress = false
end

function Paint:_undo_step()
    if not self._undo or #self._undo == 0 or not self._canvas then return end
    local snap = table.remove(self._undo)
    self._canvas:set_raw(snap)
    self._view_dirty = true
    -- A canvas restored to its earlier state is "no longer the same
    -- as the empty initial canvas", so the dirty flag for the
    -- exit-confirm path stays true. The user can keep undoing past
    -- the very first stroke (the snapshot of the cleared canvas);
    -- that one returns the canvas to pristine and we could clear
    -- _dirty too, but it's safer to leave it set so a subsequent
    -- BACKSPACE still prompts.
end

-- Scanline-style flood fill on the canvas. The earlier 4-way DFS with
-- a `seen` set hit a 16k-cell hard cap that produced striped fills on
-- larger uniform regions: the LIFO stack ran depth-first up the
-- screen, exhausted the iteration budget on the way, and left a tail
-- of pushed-but-never-popped pixels behind as unfilled columns.
--
-- Scanline fill is the standard fix: for each seed, walk left + right
-- to find the entire connected run on that row, fill it with one
-- fill_rect, then scan the adjacent rows for transitions into target
-- and seed exactly one entry per new connected run (Foley & van Dam,
-- "Painters Algorithm" variant). The work is O(filled_pixels) and the
-- stack typically holds < 100 seeds even for full-canvas fills.
--
-- "Already filled" is tracked in a per-row run table rather than by
-- refreshing the canvas raw after each write -- get_raw allocates a
-- fresh Lua string of canvas_w x canvas_h x 2 bytes (128 KB on a
-- 320x200 canvas, 512 KB on the 640x400 max), and one alloc per
-- fill_rect would tank performance on the bigger canvases. Looking
-- up "is this cell inside one of the runs we already filled on this
-- row" is O(runs_per_row), in practice 1 or 2.
function Paint:_flood_fill(sx, sy)
    if not self._canvas or not self._canvas.get_raw then return end
    local cw, ch = self._canvas_w, self._canvas_h
    if sx < 0 or sx >= cw or sy < 0 or sy >= ch then return end
    local raw = self._canvas:get_raw()
    if not raw or #raw < cw * ch * 2 then return end
    local stride = cw * 2
    local fill   = self:_current_paint_color()

    -- runs[y] = ordered list of {left, right} segments already filled
    -- on row y. is_filled does a linear scan (cheap because
    -- runs_per_row is tiny in practice).
    local runs = {}
    local function is_filled(x, y)
        local row = runs[y]
        if not row then return false end
        for i = 1, #row do
            local r = row[i]
            if x >= r[1] and x <= r[2] then return true end
        end
        return false
    end
    local function record_run(y, left, right)
        local row = runs[y]
        if not row then row = {}; runs[y] = row end
        row[#row + 1] = { left, right }
    end

    -- pixel(x, y) returns the colour the algorithm should compare
    -- against target. Filled cells are reported as fill (i.e. NOT
    -- target) so a re-pop or a row scan that crosses an earlier run
    -- bails out without re-walking it.
    local function pixel(x, y)
        if is_filled(x, y) then return fill end
        local i = y * stride + x * 2 + 1
        return (raw:byte(i) << 8) | raw:byte(i + 1)
    end

    local target = pixel(sx, sy)
    if target == fill then return end

    -- Snapshot the pre-fill canvas so undo rolls back the whole
    -- flooded region in one step. Done after the target == fill
    -- early-return so a redundant fill doesn't push a phantom
    -- snapshot that consumes a slot of the bounded ring.
    self:_snapshot()

    local stack = { { sx, sy } }
    -- Generous safety cap so a runaway fill on a corrupted canvas
    -- can't lock the UI; in normal operation a full 640x400 fill
    -- terminates in a couple thousand iterations.
    local iters = 0
    local MAX_ITERS = 100000

    while #stack > 0 and iters < MAX_ITERS do
        iters = iters + 1
        local p = stack[#stack]
        stack[#stack] = nil
        local x, y = p[1], p[2]
        if y >= 0 and y < ch and pixel(x, y) == target then
            -- Walk left + right to find the run extent.
            local left = x
            while left > 0 and pixel(left - 1, y) == target do
                left = left - 1
            end
            local right = x
            while right < cw - 1 and pixel(right + 1, y) == target do
                right = right + 1
            end
            -- Fill the run in one call.
            self._canvas:fill_rect(left, y, right - left + 1, 1, fill)
            record_run(y, left, right)
            -- Seed adjacent rows. Only push a seed when the row
            -- transitions from non-target into target so each
            -- connected run gets exactly one seed -- otherwise a
            -- 320-wide run would push 320 redundant seeds per row.
            local function seed_row(yn)
                if yn < 0 or yn >= ch then return end
                local in_run = false
                for cx = left, right do
                    if pixel(cx, yn) == target then
                        if not in_run then
                            stack[#stack + 1] = { cx, yn }
                            in_run = true
                        end
                    else
                        in_run = false
                    end
                end
            end
            seed_row(y - 1)
            seed_row(y + 1)
        end
    end

    self._view_dirty = true
    self._dirty      = true
    -- Snapshot AFTER the read pass so the saved bytes are the pre-fill
    -- state (we read raw at the top, walked extents from it, then
    -- finally fill_rect'd through the recorded runs). The snapshot
    -- captures the canvas as it was BEFORE this fill so undo rolls
    -- back the whole flooded region in one step.
end

-- ---------------------------------------------------------------------------
-- Selection / clipboard
-- ---------------------------------------------------------------------------

local function normalise_rect(x0, y0, x1, y1)
    local x = math.min(x0, x1)
    local y = math.min(y0, y1)
    local w = math.abs(x1 - x0) + 1
    local h = math.abs(y1 - y0) + 1
    return x, y, w, h
end

function Paint:_finalise_selection()
    local d = self._drag_sel
    if not d then return end
    local x, y, w, h = normalise_rect(d.x0, d.y0, d.x1, d.y1)
    if w >= 2 and h >= 2 then
        -- Clamp to canvas bounds.
        if x < 0 then w = w + x; x = 0 end
        if y < 0 then h = h + y; y = 0 end
        if x + w > self._canvas_w then w = self._canvas_w - x end
        if y + h > self._canvas_h then h = self._canvas_h - y end
        if w >= 2 and h >= 2 then
            self._selection = { x = x, y = y, w = w, h = h }
        end
    end
    self._drag_sel = nil
end

-- Copy the selected canvas region into the clipboard. Pixels are
-- stored as a raw RGB565 byte string (big-endian, the same layout
-- get_raw() returns) so paste can read them with the same byte
-- arithmetic the flood-fill uses.
function Paint:_copy()
    if not self._selection or not self._canvas then return end
    local raw = self._canvas:get_raw()
    if not raw then return end
    local stride = self._canvas_w * 2
    local sel = self._selection
    local out = {}
    for cy = sel.y, sel.y + sel.h - 1 do
        local base = cy * stride + sel.x * 2 + 1
        out[#out + 1] = raw:sub(base, base + sel.w * 2 - 1)
    end
    self._clipboard = {
        w    = sel.w,
        h    = sel.h,
        data = table.concat(out),
    }
end

-- Cut == copy + delete the selected region (paint the bg colour).
function Paint:_cut()
    self:_copy()
    self:_delete_selection()
end

function Paint:_delete_selection()
    if not self._selection or not self._canvas then return end
    self:_snapshot()
    local sel = self._selection
    self._canvas:fill_rect(sel.x, sel.y, sel.w, sel.h,
        rgb565_from_triple(self._palette[1]))
    self._view_dirty = true
    self._dirty      = true
end

-- Paste the clipboard with its top-left at (cx, cy). Pixels matching
-- the "background" palette slot 1 are skipped, giving a transparent-
-- background blit. Out-of-bounds pixels are clipped.
function Paint:_paste_at(cx, cy)
    local cb = self._clipboard
    if not cb or not self._canvas then return end
    self:_snapshot()
    local stride = cb.w * 2
    local bg = rgb565_from_triple(self._palette[1])
    for j = 0, cb.h - 1 do
        local base = j * stride + 1
        for i = 0, cb.w - 1 do
            local idx = base + i * 2
            local hi = cb.data:byte(idx)
            local lo = cb.data:byte(idx + 1)
            if hi and lo then
                local color = (hi << 8) | lo
                if color ~= bg then
                    local px = cx + i
                    local py = cy + j
                    if px >= 0 and px < self._canvas_w
                            and py >= 0 and py < self._canvas_h then
                        self._canvas:fill_rect(px, py, 1, 1, color)
                    end
                end
            end
        end
    end
    self._view_dirty = true
    self._dirty      = true
end

function Paint:_paste_at_cursor()
    self:_paste_at(self._state.cursor_x, self._state.cursor_y)
end

-- "Move" is a two-step gesture: cut the selection into the clipboard,
-- then paste it at the cursor position. The user moves the cursor
-- between steps. Implemented as Cut + immediate hint to "press P or
-- Alt+M -> Paste at cursor".
function Paint:_begin_move()
    if not self._selection then return end
    self:_cut()
    self._selection = nil
end

-- ---------------------------------------------------------------------------
-- Pan / zoom
-- ---------------------------------------------------------------------------

function Paint:_clamp_view()
    local cv = self._canvas_node
    local zoom = self._state.zoom
    local vw = (cv and cv._viewport_w) or VIEWPORT_W
    local vh = (cv and cv._viewport_h) or VIEWPORT_H_MAX
    local visible_cw = math.floor(vw / zoom)
    local visible_ch = math.floor(vh / zoom)
    local max_x = math.max(0, self._canvas_w - visible_cw)
    local max_y = math.max(0, self._canvas_h - visible_ch)
    if self._state.view_x < 0 then self._state.view_x = 0 end
    if self._state.view_y < 0 then self._state.view_y = 0 end
    if self._state.view_x > max_x then self._state.view_x = max_x end
    if self._state.view_y > max_y then self._state.view_y = max_y end
end

function Paint:_pan(dx, dy)
    self._state.view_x = self._state.view_x + dx
    self._state.view_y = self._state.view_y + dy
    self:_clamp_view()
    self._view_dirty = true
end

function Paint:_set_zoom(z)
    if z < 1 then z = 1 end
    if z > 8 then z = 8 end
    if z == self._state.zoom then return end
    -- Keep the view roughly centred on the previous viewport when
    -- zooming so the user doesn't "fall off the edge" of the canvas.
    local cv = self._canvas_node
    local vw = (cv and cv._viewport_w) or VIEWPORT_W
    local vh = (cv and cv._viewport_h) or VIEWPORT_H_MAX
    local prev_zoom = self._state.zoom
    local cx_centre = self._state.view_x + math.floor(vw / (2 * prev_zoom))
    local cy_centre = self._state.view_y + math.floor(vh / (2 * prev_zoom))
    self._state.zoom = z
    self._state.view_x = cx_centre - math.floor(vw / (2 * z))
    self._state.view_y = cy_centre - math.floor(vh / (2 * z))
    self:_clamp_view()
    self._view_dirty = true
end

-- ---------------------------------------------------------------------------
-- Touch
-- ---------------------------------------------------------------------------

function Paint:_install_touch_handlers()
    local me = self
    local last_cx, last_cy = nil, nil
    local _ti_mod = require("ezui.touch_input")

    -- Resolve the screen-space "click point" for a touch event. In
    -- direct mode that's the finger position carried in the event;
    -- in mouse mode the finger drives a relative cursor that the
    -- ezui.touch_input module already updated on touch/move BEFORE
    -- our subscriber ran (its handler is attached at boot, ours
    -- when the screen opens), so reading cursor_x/y here gives the
    -- post-move position.
    local function click_point(data)
        if _ti_mod.mouse_mode then
            return _ti_mod.cursor_x, _ti_mod.cursor_y
        end
        return data.x, data.y
    end

    local function paint_touch(data, is_down)
        if type(data) ~= "table" then return end
        local sx, sy = click_point(data)
        local cx, cy = me:_screen_to_canvas(sx, sy)
        if not cx then
            last_cx, last_cy = nil, nil
            return
        end
        me._state.cursor_x = cx
        me._state.cursor_y = cy

        local tool = me._state.tool
        if tool == "select" then
            if is_down then
                me._drag_sel = { x0 = cx, y0 = cy, x1 = cx, y1 = cy }
            elseif me._drag_sel then
                me._drag_sel.x1 = cx
                me._drag_sel.y1 = cy
            end
        else
            -- One snapshot per stroke: capture the canvas state at
            -- touch/down so undo rolls back the whole drag, not just
            -- the most recent line segment.
            if is_down then me:_begin_action() end
            if is_down or not last_cx then
                me:_paint_at(cx, cy)
            else
                me:_paint_line(last_cx, last_cy, cx, cy)
            end
            last_cx, last_cy = cx, cy
        end
        me:set_state({})
    end

    -- Each cell stored on the header node by paint_header.draw is a
    -- screen-space {x, y, w, h} rect. This helper checks one of those
    -- against the touch point. Returns true if the touch landed on
    -- the cell.
    local function cell_hit(cell, x, y)
        return cell
            and x >= cell.x and x < cell.x + cell.w
            and y >= cell.y and y < cell.y + cell.h
    end

    local function header_touch(data)
        -- Tap on the toolbar / palette / brush selector. The header
        -- isn't focusable so the global touch_input bridge can't
        -- route taps -- we hit-test each cell list the header's
        -- draw pass recorded. Coordinates come from click_point so
        -- mouse mode hits the cell under the cursor rather than
        -- under the finger.
        if type(data) ~= "table" then return end
        if me._state.header_hidden then return end
        local hdr = me._header_node
        if not hdr then return end
        local hx, hy = click_point(data)

        -- Tool buttons: tap to set the active tool. A select-tool
        -- tap also clears any in-progress drag rectangle so a fresh
        -- selection starts cleanly.
        if hdr._tool_cells then
            for _, cell in ipairs(hdr._tool_cells) do
                if cell_hit(cell, hx, hy) then
                    me._state.tool = cell.tool
                    if cell.tool ~= "select" then me._drag_sel = nil end
                    me:set_state({})
                    return
                end
            end
        end

        -- Zoom buttons (+/-).
        if hdr._zoom_cells then
            for _, cell in ipairs(hdr._zoom_cells) do
                if cell_hit(cell, hx, hy) then
                    me:_set_zoom(me._state.zoom + cell.dir)
                    me:set_state({})
                    return
                end
            end
        end

        -- Undo button.
        if hdr._undo_cell and cell_hit(hdr._undo_cell, hx, hy) then
            if hdr._undo_cell.enabled then
                me:_undo_step()
                me:set_state({})
            end
            return
        end

        -- Brush-size cells.
        if hdr._brush_cells then
            for i, cell in ipairs(hdr._brush_cells) do
                if cell_hit(cell, hx, hy) then
                    me._state.brush_idx = i
                    me:set_state({})
                    return
                end
            end
        end

        -- Palette swatches.
        if hdr._palette_cells then
            for _, cell in ipairs(hdr._palette_cells) do
                if cell_hit(cell, hx, hy) then
                    me._state.color_idx = cell.idx
                    if me._state.tool ~= "select" then
                        me._state.tool = "pencil"
                    end
                    me:set_state({})
                    return
                end
            end
        end
    end

    local function end_stroke()
        last_cx, last_cy = nil, nil
        me:_end_action()
        if me._drag_sel then
            me:_finalise_selection()
            me:set_state({})
        end
    end

    table.insert(self._touch_subs, ez.bus.subscribe("touch/down",
        function(_, data)
            end_stroke()
            header_touch(data)
            paint_touch(data, true)
        end))
    table.insert(self._touch_subs, ez.bus.subscribe("touch/move",
        function(_, data) paint_touch(data, false) end))
    table.insert(self._touch_subs, ez.bus.subscribe("touch/up",
        function(_, _) end_stroke() end))
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

function Paint:build(state)
    if not self._canvas_node then
        self._canvas_node = { type = "paint_canvas" }
    end
    -- Pass-through reference so the canvas node can reach the screen
    -- without a global. Set every build because set_state may have
    -- spawned a fresh build pass.
    self._canvas_node.paint = self

    -- Title bar gets a contextual right-side hint. When the menu
    -- (palette + hint strip) is hidden, surface the H toggle there
    -- so the user can find their way back; when visible, advertise
    -- Alt+M for the action menu.
    local title_props = { back = true }
    if state.header_hidden then
        title_props.right = "H show menu"
    else
        title_props.right = "H hide  Alt+M"
    end
    local items = { ui.title_bar("Paint", title_props) }
    if not state.header_hidden then
        -- Persist the header node so the touch handler can hit-test
        -- the brush-size cells recorded by its draw pass across
        -- rebuilds. A fresh node per build would orphan the cells.
        if not self._header_node then
            self._header_node = { type = "paint_header" }
        end
        local hdr = self._header_node
        hdr.tool        = state.tool
        hdr.color_idx   = state.color_idx
        hdr.brush_idx   = state.brush_idx
        hdr.brush_size  = BRUSH_SIZES[state.brush_idx]
        hdr.brush_sizes = BRUSH_SIZES
        hdr.zoom        = state.zoom
        hdr.canvas_w    = self._canvas_w
        hdr.canvas_h    = self._canvas_h
        hdr.palette     = self._palette
        hdr.undo_depth  = self._undo and #self._undo or 0
        items[#items + 1] = hdr
    end
    items[#items + 1] = self._canvas_node

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

-- ---------------------------------------------------------------------------
-- Action menu (Alt+M)
-- ---------------------------------------------------------------------------

function Paint:menu()
    local items = {}
    local me = self

    if self._undo and #self._undo > 0 then
        items[#items + 1] = {
            title    = "Undo",
            subtitle = string.format("%d step%s available",
                #self._undo, (#self._undo == 1) and "" or "s"),
            on_press = function() me:_undo_step(); me:set_state({}) end,
        }
    end

    if self._selection then
        items[#items + 1] = { title = "Copy",   on_press = function() me:_copy(); me:set_state({}) end }
        items[#items + 1] = { title = "Cut",    on_press = function() me:_cut(); me:set_state({}) end }
        items[#items + 1] = { title = "Move",   subtitle = "Cut, then paste at the cursor",
            on_press = function() me:_begin_move(); me:set_state({}) end }
        items[#items + 1] = { title = "Delete", on_press = function() me:_delete_selection(); me:set_state({}) end }
        items[#items + 1] = { title = "Clear selection",
            on_press = function() me._selection = nil; me:set_state({}) end }
    end
    if self._clipboard then
        items[#items + 1] = { title = "Paste at cursor",
            subtitle = string.format("%dx%d clipboard, white = transparent",
                self._clipboard.w, self._clipboard.h),
            on_press = function() me:_paste_at_cursor(); me:set_state({}) end }
    end

    items[#items + 1] = { title = "Save...",
        subtitle = self._state.last_save_path
            and ("Last: " .. self._state.last_save_path)
            or "Choose .png / .jpg / .bmp by extension",
        on_press = function() me:_show_save_prompt() end }

    items[#items + 1] = { title = "Canvas size...",
        subtitle = string.format("Currently %dx%d", self._canvas_w, self._canvas_h),
        on_press = function() me:_show_size_picker() end }

    items[#items + 1] = { title = "Pick custom colour...",
        subtitle = "Replaces the active palette slot",
        on_press = function() me:_show_color_picker() end }

    items[#items + 1] = {
        title = self._state.header_hidden and "Show menu bar" or "Hide menu bar",
        on_press = function()
            me._state.header_hidden = not me._state.header_hidden
            me:set_state({})
        end,
    }
    return items
end

function Paint:_show_size_picker()
    local items = {}
    local me = self
    for idx, p in ipairs(SIZE_PRESETS) do
        items[#items + 1] = {
            title    = p.label,
            subtitle = (idx == self._state.size_idx) and "Current size" or "Resizing clears the canvas",
            on_press = function()
                if idx == me._state.size_idx then return end
                me._state.size_idx = idx
                me._state.cursor_x = p.w // 2
                me._state.cursor_y = p.h // 2
                me:_alloc_canvas()
                me:set_state({})
            end,
        }
    end
    local MenuDef = require("screens.dialog.menu")
    screen_mod.push(screen_mod.create(MenuDef,
        MenuDef.initial_state(items, "Canvas size")))
end

-- ---------------------------------------------------------------------------
-- Save to image (PNG / JPEG / BMP)
--
-- BMP is the original encoder, written in pure Lua. PNG and JPEG go
-- through the C++ ez.image bindings (sprite:encode_png /
-- encode_jpeg). The user picks the format by typing an extension in
-- the save prompt; PNG is the default since the canvas is pixel art
-- and JPEG's chroma subsampling damages 1-pixel features.
-- ---------------------------------------------------------------------------

-- Pack a 32-bit little-endian integer into 4 bytes.
local function u32le(v)
    return string.char(
        v & 0xFF,
        (v >> 8) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 24) & 0xFF)
end

-- Pack a 16-bit little-endian integer into 2 bytes.
local function u16le(v)
    return string.char(v & 0xFF, (v >> 8) & 0xFF)
end

-- Encode the canvas as a 24-bit BMP. We could pick a smaller format
-- (BI_BITFIELDS RGB565 sets the on-disk size at 2 bpp instead of 3)
-- but viewers / image-editing tools all handle 24-bit BGR cleanly,
-- and the per-pixel conversion in Lua is cheap enough -- ~0.5 s on
-- the largest 640x480 canvas. The expansion replicates each RGB565
-- channel's high bits into the low bits (the standard lossless
-- 5/6/5 -> 8/8/8 expansion) so the BMP is byte-identical to what
-- the panel actually displays.
function Paint:_encode_bmp()
    if not self._canvas then return nil, "no canvas" end
    local raw = self._canvas:get_raw()
    if not raw then return nil, "get_raw failed" end
    local w, h = self._canvas_w, self._canvas_h

    -- Each BMP row is BGR888 padded out to a multiple of 4 bytes.
    local row_size = w * 3
    local padding = (4 - (row_size % 4)) % 4
    local padded_row = row_size + padding
    local pad_str = string.rep("\0", padding)

    -- File + DIB headers.
    local data_offset = 14 + 40
    local image_size  = padded_row * h
    local file_size   = data_offset + image_size

    local file_hdr = "BM"
        .. u32le(file_size)
        .. u16le(0) .. u16le(0)            -- reserved
        .. u32le(data_offset)
    local dib_hdr  = u32le(40)             -- header size
        .. u32le(w) .. u32le(h)            -- positive height = bottom-up
        .. u16le(1)                        -- planes
        .. u16le(24)                       -- bits per pixel
        .. u32le(0)                        -- BI_RGB compression
        .. u32le(image_size)
        .. u32le(2835) .. u32le(2835)      -- ~72 dpi, x then y
        .. u32le(0) .. u32le(0)            -- colours used / important

    -- Pixel data, row by row from bottom to top (BMP convention).
    -- Each scanline is one big concatenation; rows go into a top-
    -- level table that we concat once at the end so we don't suffer
    -- O(n^2) Lua string copies.
    local rows  = {}
    local stride = w * 2
    for y = h - 1, 0, -1 do
        local base = y * stride + 1   -- 1-indexed Lua string
        local row = {}
        for x = 0, w - 1 do
            local i  = base + x * 2
            local hi = raw:byte(i)
            local lo = raw:byte(i + 1)
            -- RGB565 -> BGR888 (BMP wants BGR per pixel).
            local r5 = (hi >> 3) & 0x1F
            local g6 = ((hi & 0x07) << 3) | (lo >> 5)
            local b5 = lo & 0x1F
            local r8 = (r5 << 3) | (r5 >> 2)
            local g8 = (g6 << 2) | (g6 >> 4)
            local b8 = (b5 << 3) | (b5 >> 2)
            row[#row + 1] = string.char(b8, g8, r8)
        end
        row[#row + 1] = pad_str
        rows[#rows + 1] = table.concat(row)
    end

    return file_hdr .. dib_hdr .. table.concat(rows)
end

-- Map a file path to (format_name, encode_fn). Unknown extensions
-- default to PNG -- silently coercing seems friendlier than yelling
-- at someone who typed "painting" without thinking about it.
function Paint:_pick_format(path)
    local ext = path:lower():match("%.([%w]+)$") or ""
    if ext == "jpg" or ext == "jpeg" then
        return "JPEG", function(me) return me:_encode_jpeg() end
    elseif ext == "bmp" then
        return "BMP", function(me) return me:_encode_bmp() end
    end
    return "PNG", function(me) return me:_encode_png() end
end

-- Encode via the C++ binding. Both encoders allocate sizable PSRAM
-- buffers (canvas-w * canvas-h * 4 worst case for PNG) and run on
-- the main task -- worst-case ~2 s on a 640x480 canvas, which is
-- acceptable for a one-shot save action.
function Paint:_encode_png()
    if not self._canvas then return nil, "no canvas" end
    return self._canvas:encode_png(6)
end

function Paint:_encode_jpeg()
    if not self._canvas then return nil, "no canvas" end
    -- Quality 1 = HIGH, 4:4:4 chroma. The pixel-art content in a
    -- paint canvas is dominated by sharp single-pixel edges; the
    -- HIGH preset keeps those crisp where MED/LOW would blur them.
    return self._canvas:encode_jpeg(1)
end

function Paint:_save_image(path)
    local fmt, encode = self:_pick_format(path)
    local bytes, err = encode(self)
    local dialog = require("ezui.dialog")
    if not bytes then
        dialog.confirm({
            title = "Save failed",
            message = "Couldn't encode canvas: " .. (err or "unknown"),
            ok_label = "OK", cancel_label = "OK",
        })
        return
    end
    -- Make sure the directory exists. SD cards may have /sd/paint/
    -- on first run; mkdir is idempotent so it's fine to call always.
    local parent = path:match("^(.*)/")
    if parent then
        ez.storage.mkdir(parent)
    end
    local ok = ez.storage.write_file(path, bytes)
    if ok then
        self._state.last_save_path = path
        dialog.confirm({
            title    = "Saved",
            message  = string.format("%dx%d %s -> %s (%d bytes)",
                self._canvas_w, self._canvas_h, fmt, path, #bytes),
            ok_label = "OK", cancel_label = "OK",
        })
    else
        dialog.confirm({
            title    = "Save failed",
            message  = "Couldn't write " .. path
                .. ".  Check the SD card is mounted and the path is writable.",
            ok_label = "OK", cancel_label = "OK",
        })
    end
end

function Paint:_show_save_prompt()
    local default_path = self._state.last_save_path
        or "/sd/paint/painting.png"
    local me = self
    local dialog = require("ezui.dialog")
    dialog.prompt({
        title       = "Save canvas",
        message     = "Path (.png / .jpg / .bmp)",
        value       = default_path,
        placeholder = "/sd/paint/painting.png",
    }, function(path)
        if path and path ~= "" then me:_save_image(path) end
    end)
end

function Paint:_show_color_picker()
    local idx  = self._state.color_idx
    local cur  = self._palette[idx] or { 0, 0, 0 }
    local Picker = require("screens.pickers.color")
    local me = self
    screen_mod.push(screen_mod.create(Picker, Picker.initial_state({
        r = cur[1], g = cur[2], b = cur[3],
        on_pick = function(r, g, b)
            me._palette[idx] = { r, g, b }
            me:set_state({})
        end,
    })))
end

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

function Paint:handle_key(key)
    local s, c, st = key.special, key.character, self._state

    -- Movement (cursor or pan).
    local step = key.alt and 8 or 1
    if key.shift then
        if s == "LEFT"  then self:_pan(-PAN_STEP_PX, 0); self:set_state({}); return "handled" end
        if s == "RIGHT" then self:_pan( PAN_STEP_PX, 0); self:set_state({}); return "handled" end
        if s == "UP"    then self:_pan(0, -PAN_STEP_PX); self:set_state({}); return "handled" end
        if s == "DOWN"  then self:_pan(0,  PAN_STEP_PX); self:set_state({}); return "handled" end
    end
    if s == "LEFT"  then st.cursor_x = math.max(0, st.cursor_x - step) end
    if s == "RIGHT" then st.cursor_x = math.min(self._canvas_w - 1, st.cursor_x + step) end
    if s == "UP"    then st.cursor_y = math.max(0, st.cursor_y - step) end
    if s == "DOWN"  then st.cursor_y = math.min(self._canvas_h - 1, st.cursor_y + step) end
    if s == "LEFT" or s == "RIGHT" or s == "UP" or s == "DOWN" then
        -- A move ends the current "stroke" -- the next SPACE press
        -- starts a fresh undo step. Without this, SPACE -> arrow
        -- -> SPACE -> arrow -> SPACE would be one giant undo entry
        -- because keyboard repeat keeps _action_in_progress true
        -- (no key-release event gives us a natural boundary).
        self:_end_action()
        -- Auto-pan to keep the cursor visible when zoomed in.
        local cv = self._canvas_node
        local vw = (cv and cv._viewport_w) or VIEWPORT_W
        local vh = (cv and cv._viewport_h) or VIEWPORT_H_MAX
        local visible_cw = math.floor(vw / st.zoom)
        local visible_ch = math.floor(vh / st.zoom)
        if st.cursor_x < st.view_x then st.view_x = st.cursor_x end
        if st.cursor_x >= st.view_x + visible_cw then st.view_x = st.cursor_x - visible_cw + 1 end
        if st.cursor_y < st.view_y then st.view_y = st.cursor_y end
        if st.cursor_y >= st.view_y + visible_ch then st.view_y = st.cursor_y - visible_ch + 1 end
        self:_clamp_view()
        self._view_dirty = true
        self:set_state({})
        return "handled"
    end

    if c == " " then
        if st.tool == "select" then
            -- SPACE on the select tool starts a 1-px-anchored
            -- selection at the cursor. A second SPACE finalises it
            -- at the new cursor position.
            if not self._drag_sel then
                self._drag_sel = { x0 = st.cursor_x, y0 = st.cursor_y,
                                   x1 = st.cursor_x, y1 = st.cursor_y }
            else
                self._drag_sel.x1 = st.cursor_x
                self._drag_sel.y1 = st.cursor_y
                self:_finalise_selection()
            end
        else
            -- One snapshot per SPACE press. The keyboard's repeat
            -- behaviour means a held SPACE fires this branch many
            -- times; the de-dupe lives in _begin_action -- the second
            -- and later presses while still held are a no-op. The
            -- end_action flag is cleared by the cursor-move handler
            -- (LEFT/RIGHT/UP/DOWN) so a fresh stroke after moving
            -- gets its own snapshot.
            self:_begin_action()
            self:_paint_at(st.cursor_x, st.cursor_y)
        end
        self:set_state({})
        return "handled"
    end

    if c then
        local n = tonumber(c)
        if n and n >= 1 and n <= #self._palette then
            st.color_idx = n
            if st.tool ~= "select" then st.tool = "pencil" end
            self:set_state({})
            return "handled"
        end
        if c == "b" or c == "B" then
            st.brush_idx = (st.brush_idx % #BRUSH_SIZES) + 1
            self:set_state({})
            return "handled"
        end
        if c == "e" or c == "E" then
            st.tool = (st.tool == "eraser") and "pencil" or "eraser"
            self:set_state({})
            return "handled"
        end
        if c == "y" or c == "Y" then
            st.tool = (st.tool == "spray") and "pencil" or "spray"
            self:set_state({})
            return "handled"
        end
        if c == "r" or c == "R" then
            st.tool = (st.tool == "select") and "pencil" or "select"
            self._drag_sel = nil
            self:set_state({})
            return "handled"
        end
        if c == "f" or c == "F" then
            self:_flood_fill(st.cursor_x, st.cursor_y)
            self:set_state({})
            return "handled"
        end
        if c == "c" or c == "C" then
            self:_clear()
            self:set_state({})
            return "handled"
        end
        if c == "h" or c == "H" then
            st.header_hidden = not st.header_hidden
            self:set_state({})
            return "handled"
        end
        if (c == "m" or c == "M") and not key.alt then
            -- Toggle relative-cursor mode without leaving paint. The
            -- canvas cursor follows the mouse cursor on each drag,
            -- and toolbar buttons hit-test against the cursor too --
            -- see _install_touch_handlers.click_point. The `not
            -- key.alt` gate is critical: Alt+M is the global action
            -- menu shortcut and must fall through to screen.lua so
            -- this screen's Paint:menu() can populate it.
            require("ezui.touch_input").toggle_mouse_mode()
            self:set_state({})
            return "handled"
        end
        if c == "u" or c == "U" then
            self:_undo_step()
            self:set_state({})
            return "handled"
        end
        if c == "z" or c == "Z" then
            self:_set_zoom(st.zoom + 1)
            self:set_state({})
            return "handled"
        end
        if c == "x" or c == "X" then
            self:_set_zoom(st.zoom - 1)
            self:set_state({})
            return "handled"
        end
        if c == "p" or c == "P" then
            -- P is unused above; map it to paste-at-cursor as a
            -- convenience next to Move so a user can move + paste
            -- without round-tripping through Alt+M.
            if self._clipboard then
                self:_paste_at_cursor()
                self:set_state({})
                return "handled"
            end
        end
    end

    if s == "BACKSPACE" then
        -- Exit confirmation: only prompt if the canvas has actually
        -- been modified. A clean canvas (no strokes since open) pops
        -- straight back so the user doesn't fight an extra dialog
        -- when they just opened the wrong app.
        if self._dirty then
            local me = self
            local dialog = require("ezui.dialog")
            dialog.confirm({
                title    = "Leave Paint?",
                message  = "Your drawing will be lost. Exit anyway?",
                ok_label = "Discard",
                cancel_label = "Keep editing",
            }, function()
                -- Reset the dirty flag so the next BACKSPACE pops
                -- without another prompt; pop the paint screen
                -- explicitly because we've already consumed the key.
                me._dirty = false
                require("ezui.screen").pop()
            end)
            return "handled"
        end
        return "pop"
    end
    return nil
end

return Paint
