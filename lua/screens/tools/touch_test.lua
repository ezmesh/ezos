-- Touch diagnostics screen.
--
-- Renders a fullscreen canvas that shows every active GT911 contact
-- as a coloured ring (per track id) and prints a header with the
-- product id, firmware revision, and live point count + coordinates.
-- Subscribes to touch/down, touch/move and touch/up so we exercise
-- the bus path that real apps will consume; the underlying
-- ez.touch.read() snapshot is also probed for the legend.
--
-- Useful for verifying:
--   * I2C wiring and GT911 init  (id "911", non-zero firmware)
--   * Coordinate range (0..319 X, 0..239 Y) and panel rotation
--   * Multi-touch: each new finger gets its own colour
--   * Down -> move -> up sequencing on the bus

local ui    = require("ezui")
local node  = require("ezui.node")
local theme = require("ezui.theme")

local Touch = { title = "Touch test" }

local HEADER_H = 36
local TRAIL_MAX = 32   -- per finger, latest segments for visualisation

local PALETTE = {
    0xF800,  -- red       id 0
    0x07E0,  -- green     id 1
    0x001F,  -- blue      id 2
    0xFFE0,  -- yellow    id 3
    0xF81F,  -- magenta   id 4
    0x07FF,  -- cyan      id 5
    0xFD20,  -- orange    id 6
    0x8410,  -- gray      id 7
}

local function color_for(id)
    if not id or id < 0 then return PALETTE[1] end
    return PALETTE[(id % #PALETTE) + 1]
end

-- ---------------------------------------------------------------------------
-- Custom node: header strip + canvas. Drawing is direct (no widgets)
-- because every paint is just lines + filled circles, and we're polling
-- ez.touch.read() at 30 FPS.
-- ---------------------------------------------------------------------------

if not node.handler("touch_diag") then
    node.register("touch_diag", {
        focusable = false,

        measure = function(n, max_w, max_h)
            return max_w, max_h
        end,

        draw = function(n, d, x, y, w, h)
            -- Background.
            d.fill_rect(x, y, w, h, theme.color("BG"))

            -- Header strip.
            d.fill_rect(x, y, w, HEADER_H, theme.color("SURFACE"))
            d.fill_rect(x, y + HEADER_H - 1, w, 1, theme.color("BORDER"))

            theme.set_font("small_aa")
            local fh = theme.font_height()
            local pid = ez.touch.product_id() or ""
            local fwv = ez.touch.firmware_version() or 0
            local pts = n.snapshot or {}
            local hdr = string.format("GT911 id=\"%s\" fw=%04X  active=%d",
                pid, fwv, #pts)
            d.draw_text(x + 6, y + 4, hdr, theme.color("TEXT"))

            local hint = "Tap, drag, multi-touch -- BACK to exit"
            theme.set_font("tiny_aa")
            d.draw_text(x + 6, y + 4 + fh + 1, hint,
                theme.color("TEXT_MUTED"))

            -- Canvas region: everything below the header.
            local cy = y + HEADER_H

            -- Panel-pixel grid in the canvas region. Light dotted axes
            -- at 80-px multiples so coordinate readouts make intuitive
            -- sense as you drag a finger across.
            local grid_color = theme.color("BORDER")
            for gx = 0, w, 80 do
                d.fill_rect(x + gx, cy, 1, h - HEADER_H, grid_color)
            end
            for gy = 0, h - HEADER_H, 60 do
                d.fill_rect(x, cy + gy, w, 1, grid_color)
            end

            -- Trails: for each tracked finger, draw line segments
            -- between the recent samples so you can see the gesture
            -- path. The samples are stored in raw panel coordinates;
            -- the panel and the screen share an origin so we can plot
            -- them directly. Touches landing inside the header strip
            -- are clamped down so trails don't run over the header
            -- text.
            local function clamp_y(py)
                if py < cy then return cy end
                return py
            end
            for id, trail in pairs(n.trails or {}) do
                local col = color_for(id)
                if #trail >= 2 then
                    for i = 2, #trail do
                        local a, b = trail[i - 1], trail[i]
                        d.draw_line(a.x, clamp_y(a.y),
                                    b.x, clamp_y(b.y), col)
                    end
                end
            end

            -- Active points: filled disc + ring at the raw panel
            -- coordinate.
            for _, p in ipairs(pts) do
                local col = color_for(p.id)
                local py = clamp_y(p.y)
                d.fill_circle(p.x, py, 6, col)
                d.draw_circle(p.x, py, 14, col)
                local label = string.format("#%d (%d,%d) s=%d",
                    p.id, p.x, p.y, p.size)
                d.draw_text(p.x + 18, py - 6, label, col)
            end

            -- Coordinate readout, bottom-left, even when nothing is
            -- pressed (so an offline panel is still obvious).
            theme.set_font("tiny_aa")
            if not ez.touch.is_initialized() then
                d.draw_text(x + 6, y + h - 16,
                    "Touch hardware not initialised",
                    theme.color("ERROR"))
            elseif #pts == 0 then
                d.draw_text(x + 6, y + h - 16,
                    "No active contacts",
                    theme.color("TEXT_MUTED"))
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

function Touch.initial_state()
    return {}
end

function Touch:on_enter()
    self._diag = {
        type     = "touch_diag",
        snapshot = {},
        trails   = {},     -- [track_id] = array of {x, y}
    }
    self._subs = {}

    local me = self

    -- Subscribe to bus events. We use them to maintain the trail
    -- visualisation; the live-point overlay is driven by the snapshot
    -- read from ez.touch.read() so we never miss the *current* frame
    -- even between bus deliveries.
    -- Trails store raw panel coordinates. Drawing converts to screen
    -- coordinates by clamping y past the header.
    local function add_trail(id, px, py)
        local t = me._diag.trails[id]
        if not t then t = {}; me._diag.trails[id] = t end
        t[#t + 1] = { x = px, y = py }
        if #t > TRAIL_MAX then table.remove(t, 1) end
    end

    local function on_down(_, data)
        if type(data) ~= "table" then return end
        add_trail(data.id, data.x, data.y)
        require("ezui.screen").invalidate()
    end
    local function on_move(_, data)
        if type(data) ~= "table" then return end
        add_trail(data.id, data.x, data.y)
        require("ezui.screen").invalidate()
    end
    local function on_up(_, data)
        if type(data) ~= "table" then return end
        -- Keep the trail visible briefly after release. We just stop
        -- adding new samples; the trail fades the next time the same
        -- track id is reused for a new contact.
        require("ezui.screen").invalidate()
    end

    table.insert(self._subs, ez.bus.subscribe("touch/down", on_down))
    table.insert(self._subs, ez.bus.subscribe("touch/move", on_move))
    table.insert(self._subs, ez.bus.subscribe("touch/up",   on_up))

    -- Tick at ~30 FPS to repoll snapshot. The bus events drive the
    -- trail; the snapshot drives the live discs.
    self._tick = ez.system.set_interval(33, function()
        me._diag.snapshot = ez.touch.read() or {}
        require("ezui.screen").invalidate()
    end)
end

function Touch:on_exit()
    if self._subs then
        for _, id in ipairs(self._subs) do ez.bus.unsubscribe(id) end
        self._subs = nil
    end
    if self._tick then
        ez.system.clear_interval(self._tick)
        self._tick = nil
    end
    self._diag = nil
end

function Touch:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Touch test", { back = true }),
        self._diag,
    })
end

function Touch:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Touch
