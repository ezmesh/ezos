-- Paint -- a minimalist mspaint-style bitmap editor.
--
-- Drawing surface is a 320×200 RGB565 sprite created on entry and
-- destroyed on exit. The rest of the panel is a 40 px header strip
-- showing the active colour, brush, tool, and a small palette.
-- A floating cursor moves with arrows / trackball; SPACE paints at
-- the cursor. Held-down character keys keep firing on the T-Deck so
-- you can hold SPACE to drag a stroke across the canvas.
--
-- Keys:
--   Arrows / trackball   move cursor (1 px; hold Alt for 8 px steps)
--   SPACE                paint at cursor
--   1..8                 pick palette colour
--   B                    cycle brush size (1, 2, 4, 6 px)
--   E                    toggle eraser (paints background colour)
--   F                    flood-fill cursor's region (cheap 4-way scan)
--   C                    clear canvas
--   Back                 leave (BACKSPACE; T-Deck has no Esc key)
--
-- Finger painting: touch + drag anywhere on the canvas to paint with
-- the current colour and brush. The cursor reticle follows the most
-- recent finger position so a quick stroke of SPACE after lifting can
-- continue from where the finger was. Header taps on a palette swatch
-- pick that colour; a tap on the brush text cycles brush size.

local ui     = require("ezui")
local node   = require("ezui.node")
local theme  = require("ezui.theme")

local Paint = { title = "Paint" }

local CANVAS_W, CANVAS_H = 320, 200
local HEADER_H           = 40
local PALETTE = {
    { 250, 250, 250 },   -- 1: white
    {  10,  10,  10 },   -- 2: black
    { 230,  60,  60 },   -- 3: red
    { 250, 170,  60 },   -- 4: orange
    { 250, 220,  60 },   -- 5: yellow
    {  60, 200,  90 },   -- 6: green
    {  60, 140, 240 },   -- 7: blue
    { 200, 100, 220 },   -- 8: purple
}
local BRUSH_SIZES = { 1, 2, 4, 6 }

-- ---------------------------------------------------------------------------
-- Canvas node: pushes the persistent sprite onto the screen each frame
-- and overlays the cursor reticle. Sprite ownership lives on the
-- screen instance so a rebuild doesn't blow away the user's work.
-- ---------------------------------------------------------------------------

if not node.handler("paint_canvas") then
    node.register("paint_canvas", {
        focusable = false,
        measure = function(n, max_w, max_h)
            return max_w, CANVAS_H
        end,
        draw = function(n, d, x, y, w, h)
            -- Stash the canvas's screen origin so the screen-level
            -- touch handler can convert raw panel coords back into
            -- canvas-internal pixels. We can't store it on the
            -- screen instance directly because the canvas node is
            -- created lazily and doesn't have a back-pointer.
            n._screen_x = x
            n._screen_y = y
            if n.sprite then
                n.sprite:push(x, y)
            end
            -- Cursor reticle: a small crosshair so it's visible over
            -- any colour. Draws over the just-pushed sprite.
            local cx, cy = x + (n.cursor_x or 0), y + (n.cursor_y or 0)
            d.draw_line(cx - 4, cy, cx + 4, cy, theme.color("ACCENT"))
            d.draw_line(cx, cy - 4, cx, cy + 4, theme.color("ACCENT"))
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Header node: tool indicator + palette swatches.
-- ---------------------------------------------------------------------------

if not node.handler("paint_header") then
    node.register("paint_header", {
        focusable = false,
        measure = function(n, max_w, max_h)
            return max_w, HEADER_H
        end,
        draw = function(n, d, x, y, w, h)
            d.fill_rect(x, y, w, h, theme.color("SURFACE"))
            d.fill_rect(x, y + h - 1, w, 1, theme.color("BORDER"))

            -- Status: tool, brush, current colour preview.
            theme.set_font("small_aa")
            local fh = theme.font_height()
            local txt = string.format("%s  brush %d  hint: 1-8 colour, B brush, E eraser, F fill, C clear",
                n.tool == "eraser" and "Eraser" or "Pencil",
                n.brush_size or 1)
            d.draw_text(x + 6, y + 4, txt, theme.color("TEXT"))

            -- Palette row across the bottom of the header.
            local sw = 18
            local sh = 14
            local sy = y + 4 + fh + 2
            for i, p in ipairs(PALETTE) do
                local sx = x + 6 + (i - 1) * (sw + 2)
                d.fill_rect(sx, sy, sw, sh,
                    ez.display.rgb(p[1], p[2], p[3]))
                if i == n.color_idx then
                    d.draw_rect(sx - 1, sy - 1, sw + 2, sh + 2,
                        theme.color("ACCENT"))
                end
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

function Paint.initial_state()
    return {
        cursor_x  = CANVAS_W // 2,
        cursor_y  = CANVAS_H // 2,
        brush_idx = 1,
        color_idx = 2,        -- black
        tool      = "pencil",
    }
end

function Paint:on_enter()
    if not self._sprite then
        -- Allocate the canvas. PSRAM-backed sprites are fine here;
        -- the canvas only needs ~125 KiB and we have plenty of
        -- headroom.
        self._sprite = ez.display.create_sprite(CANVAS_W, CANVAS_H)
        if self._sprite then
            self._sprite:clear(ez.display.rgb(250, 250, 250))   -- white
        end
    end

    -- Subscribe to touch events. We hold a list of subscription IDs
    -- so on_exit can clean them up; otherwise re-entering Paint after
    -- a screen pop would stack a fresh subscriber on every visit.
    self._touch_subs = self._touch_subs or {}
    if #self._touch_subs == 0 then
        local me = self
        local function paint_touch(data, is_down)
            if type(data) ~= "table" then return end
            local cv = me._canvas_node
            if not cv or not cv._screen_x then return end
            -- Translate the screen-space touch into canvas-local
            -- pixels. Drop the event if the finger is over the
            -- header / palette strip rather than the canvas.
            local cx = data.x - cv._screen_x
            local cy = data.y - cv._screen_y
            if cx < 0 or cx >= CANVAS_W or cy < 0 or cy >= CANVAS_H then
                return
            end
            -- Header palette tap (only on the initial down event so a
            -- drag that crosses up onto the palette doesn't keep
            -- changing colour).
            me._state.cursor_x = cx
            me._state.cursor_y = cy
            me:_paint_at(cx, cy)
            me:set_state({})
        end
        local function header_touch(data)
            -- Tap a palette swatch in the header to pick a colour.
            -- The header sits above the canvas; we only get this if
            -- the touch landed there.
            if type(data) ~= "table" then return end
            local cv = me._canvas_node
            if not cv or not cv._screen_y then return end
            -- The header occupies the strip above the canvas.
            local header_top = cv._screen_y - HEADER_H
            local y_in_header = data.y - header_top
            if y_in_header < 0 or y_in_header >= HEADER_H then return end
            -- Swatch geometry mirrors the header draw: each swatch is
            -- 18+2 px wide starting at x=6, two rows of text above.
            theme.set_font("small_aa")
            local fh = theme.font_height()
            local sy = 4 + fh + 2
            if y_in_header < sy or y_in_header >= sy + 14 then return end
            local sw = 18 + 2
            local sx_start = 6
            local idx = math.floor((data.x - sx_start) / sw) + 1
            if idx >= 1 and idx <= #PALETTE then
                me._state.color_idx = idx
                me._state.tool = "pencil"
                me:set_state({})
            end
        end
        table.insert(self._touch_subs, ez.bus.subscribe("touch/down",
            function(_, data)
                header_touch(data)
                paint_touch(data, true)
            end))
        table.insert(self._touch_subs, ez.bus.subscribe("touch/move",
            function(_, data) paint_touch(data, false) end))
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
    if self._sprite and self._sprite.destroy then
        self._sprite:destroy()
    end
    self._sprite = nil
end

local function rgb565(p) return ez.display.rgb(p[1], p[2], p[3]) end

function Paint:_paint_at(x, y)
    if not self._sprite then return end
    local s   = self._state
    local col = (s.tool == "eraser")
        and rgb565(PALETTE[1])
        or  rgb565(PALETTE[s.color_idx])
    local r = BRUSH_SIZES[s.brush_idx] or 1
    if r <= 1 then
        self._sprite:fill_rect(x, y, 1, 1, col)
    else
        self._sprite:fill_circle(x, y, r, col)
    end
end

function Paint:_clear()
    if self._sprite then
        self._sprite:clear(rgb565(PALETTE[1]))
    end
end

-- Cheap flood fill: walk a queue of pixels reading via get_raw and
-- writing via fill_rect. We avoid an actual stack-recursion pattern
-- to keep frame time bounded; the queue is capped at a couple
-- thousand cells per fill which is more than enough for a 320×200
-- canvas filled in regions.
function Paint:_flood_fill(sx, sy)
    if not self._sprite or not self._sprite.get_raw then return end
    local raw = self._sprite:get_raw()
    if not raw or #raw < CANVAS_W * CANVAS_H * 2 then return end
    local stride = CANVAS_W * 2
    local function px_at(x, y)
        local i = y * stride + x * 2 + 1
        local hi = raw:byte(i)
        local lo = raw:byte(i + 1)
        return (hi << 8) | lo
    end
    local target = px_at(sx, sy)
    local fill   = (self._state.tool == "eraser")
        and rgb565(PALETTE[1])
        or  rgb565(PALETTE[self._state.color_idx])
    if target == fill then return end

    -- Cap the queue length so a runaway fill on a borderless canvas
    -- can't lock the UI.
    local queue = { { sx, sy } }
    local seen  = {}
    local function key(x, y) return y * CANVAS_W + x end
    seen[key(sx, sy)] = true
    local n = 1
    local MAX = 8000
    while n > 0 and n < MAX do
        local p = table.remove(queue)
        n = n - 1
        local x, y = p[1], p[2]
        if px_at(x, y) == target then
            self._sprite:fill_rect(x, y, 1, 1, fill)
            local function push(nx, ny)
                if nx >= 0 and nx < CANVAS_W and ny >= 0 and ny < CANVAS_H
                        and not seen[key(nx, ny)] then
                    seen[key(nx, ny)] = true
                    queue[#queue + 1] = { nx, ny }
                    n = n + 1
                end
            end
            push(x + 1, y); push(x - 1, y)
            push(x, y + 1); push(x, y - 1)
            -- Re-fetch raw once per chunk so we see the writes -- but
            -- only every ~256 cells to keep cost low. fill_rect bypasses
            -- raw, so we need an explicit refresh.
            if (n % 256) == 0 then
                raw = self._sprite:get_raw()
            end
        end
    end
end

function Paint:build(state)
    -- Canvas node persists across rebuilds so the touch handler can
    -- read the canvas's drawn screen position (set during draw) even
    -- when set_state() spawns a fresh node tree. Sprite and cursor
    -- position get refreshed each rebuild.
    if not self._canvas_node then
        self._canvas_node = { type = "paint_canvas" }
    end
    self._canvas_node.sprite   = self._sprite
    self._canvas_node.cursor_x = state.cursor_x
    self._canvas_node.cursor_y = state.cursor_y

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Paint", { back = true }),
        {
            type      = "paint_header",
            tool      = state.tool,
            color_idx = state.color_idx,
            brush_size = BRUSH_SIZES[state.brush_idx],
        },
        self._canvas_node,
    })
end

function Paint:handle_key(key)
    local s = key.special
    local c = key.character
    local st = self._state

    -- Movement (1 px default, 8 px with Alt).
    local step = key.alt and 8 or 1
    if s == "LEFT"  then st.cursor_x = math.max(0, st.cursor_x - step) end
    if s == "RIGHT" then st.cursor_x = math.min(CANVAS_W - 1, st.cursor_x + step) end
    if s == "UP"    then st.cursor_y = math.max(0, st.cursor_y - step) end
    if s == "DOWN"  then st.cursor_y = math.min(CANVAS_H - 1, st.cursor_y + step) end
    if s == "LEFT" or s == "RIGHT" or s == "UP" or s == "DOWN" then
        self:set_state({})
        return "handled"
    end

    if c == " " then
        self:_paint_at(st.cursor_x, st.cursor_y)
        self:set_state({})
        return "handled"
    end

    if c then
        local n = tonumber(c)
        if n and n >= 1 and n <= #PALETTE then
            st.color_idx = n
            st.tool      = "pencil"
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
    end

    if s == "BACKSPACE" then return "pop" end
    return nil
end

return Paint
