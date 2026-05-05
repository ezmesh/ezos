-- HSV spectrum colour picker, RGB565-limited.
--
-- Layout:
--   Title bar
--   Preview swatch + hex readout (the RGB565 native + the round-tripped
--   RGB888 the device actually renders)
--   2D spectrum: x = hue 0..360, y = saturation 1..0 (top row is fully
--                saturated, bottom row is white). Value is fixed at
--                255 in the spectrum sprite; it's applied at sample
--                time so the strip itself doesn't have to redraw on
--                every brightness change.
--   Value (brightness) slider
--   "Use colour" button -- invokes on_pick(r, g, b) and pops.
--
-- The display panel is RGB565 (5 bits R, 6 bits G, 5 bits B = 65k
-- colours), so the picker quantises the chosen HSV through RGB565
-- on the way out -- the bytes the host sees are the bytes the screen
-- can actually show. The 8-bit r/g/b passed to on_pick are the
-- expanded RGB565 values (channels replicated into the unused low
-- bits, the standard lossless expansion), so round-tripping through
-- ez.display.rgb is a fixed point.
--
-- Spectrum sprite is built once on first draw -- ~70 ms one-shot.
-- Each subsequent frame just pushes the cached sprite + a crosshair.
--
-- Usage (matching the previous slider picker):
--   local picker = require("screens.pickers.color")
--   screen_mod.push(screen_mod.create(picker, picker.initial_state({
--       r = 128, g = 64, b = 200,
--       on_pick = function(r, g, b) ... end,
--   })))

local ui         = require("ezui")
local node       = require("ezui.node")
local theme      = require("ezui.theme")
local screen_mod = require("ezui.screen")

local M = { title = "Pick colour" }

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local SPEC_W = 320
local SPEC_H = 96
-- Cell size for the brightness-tinted re-render. The spectrum is
-- painted as cell_w x cell_h tiles; smaller tiles look smoother but
-- cost more time per draw. 4x4 is a good compromise -- ~1920
-- fill_rect calls (~10 ms in Lua) so a brightness drag stays
-- responsive while the strip still reads as a continuous gradient.
local SPEC_CELL_W = 4
local SPEC_CELL_H = 4

-- ---------------------------------------------------------------------------
-- Colour math
-- ---------------------------------------------------------------------------

-- HSV -> 8-bit RGB. h in 0..360, s and v in 0..1.
local function hsv_to_rgb(h, s, v)
    if s <= 0 then
        local c = math.floor(v * 255 + 0.5)
        return c, c, c
    end
    if h < 0   then h = h + 360 end
    if h >= 360 then h = h - 360 end
    local hh = h / 60
    local i  = math.floor(hh)
    local f  = hh - i
    local p = v * (1 - s)
    local q = v * (1 - s * f)
    local t = v * (1 - s * (1 - f))
    local r, g, b
    if     i == 0 then r, g, b = v, t, p
    elseif i == 1 then r, g, b = q, v, p
    elseif i == 2 then r, g, b = p, v, t
    elseif i == 3 then r, g, b = p, q, v
    elseif i == 4 then r, g, b = t, p, v
    else                r, g, b = v, p, q
    end
    return math.floor(r * 255 + 0.5),
           math.floor(g * 255 + 0.5),
           math.floor(b * 255 + 0.5)
end

local function rgb_to_hsv(r, g, b)
    local rf, gf, bf = r / 255, g / 255, b / 255
    local mx = math.max(rf, gf, bf)
    local mn = math.min(rf, gf, bf)
    local v  = mx
    local d  = mx - mn
    local s  = (mx > 0) and (d / mx) or 0
    local h  = 0
    if d > 0 then
        if mx == rf then h = ((gf - bf) / d) % 6
        elseif mx == gf then h = ((bf - rf) / d) + 2
        else                 h = ((rf - gf) / d) + 4
        end
        h = h * 60
        if h < 0 then h = h + 360 end
    end
    return h, s, v
end

-- 8-bit r/g/b -> RGB565 -> 8-bit r/g/b after the round-trip the panel
-- forces. Used for the preview and on_pick output so callers can
-- assume what they get back is exactly what the screen will show.
local function quantize_565(r, g, b)
    local r5 = (r >> 3) & 0x1F
    local g6 = (g >> 2) & 0x3F
    local b5 = (b >> 3) & 0x1F
    local rgb565 = (r5 << 11) | (g6 << 5) | b5
    -- Expand back into 8-bit form using bit replication (standard
    -- lossless expansion: copy the top bits down to fill the low
    -- bits, so 0x1F -> 0xFF, 0x00 -> 0x00).
    local r8 = (r5 << 3) | (r5 >> 2)
    local g8 = (g6 << 2) | (g6 >> 4)
    local b8 = (b5 << 3) | (b5 >> 2)
    return r8, g8, b8, rgb565
end

-- ---------------------------------------------------------------------------
-- Spectrum sprite (built lazily on first draw)
-- ---------------------------------------------------------------------------

local _spectrum_sprite = nil
-- Cached brightness the sprite was last rendered for. When the
-- picker's value slider drags to a new brightness, we repaint the
-- sprite at that level so the strip itself reflects how the chosen
-- colour will actually look.
local _spectrum_v = -1

-- Re-render the spectrum sprite at value v (0..1). Always runs at
-- coarse SPEC_CELL_W x SPEC_CELL_H granularity so a live brightness
-- drag doesn't stall the UI; the visual blockiness of 4x4 cells is
-- acceptable for a colour picker (and matches how Photoshop's hue
-- strip looks at low brightness).
local function render_spectrum(s, v)
    if not s then return end
    local nx = math.floor(SPEC_W / SPEC_CELL_W)
    local ny = math.floor(SPEC_H / SPEC_CELL_H)
    for cx = 0, nx - 1 do
        local hue = (cx / (nx - 1)) * 360
        for cy = 0, ny - 1 do
            local sat = 1 - (cy / (ny - 1))
            local r, g, b = hsv_to_rgb(hue, sat, v)
            s:fill_rect(cx * SPEC_CELL_W, cy * SPEC_CELL_H,
                SPEC_CELL_W, SPEC_CELL_H,
                ez.display.rgb(r, g, b))
        end
    end
end

local function ensure_spectrum_sprite(v)
    if not _spectrum_sprite then
        _spectrum_sprite = ez.display.create_sprite(SPEC_W, SPEC_H)
    end
    if _spectrum_sprite and _spectrum_v ~= v then
        render_spectrum(_spectrum_sprite, v)
        _spectrum_v = v
    end
    return _spectrum_sprite
end

-- ---------------------------------------------------------------------------
-- Spectrum node
-- ---------------------------------------------------------------------------

if not node.handler("color_spectrum") then
    -- Trackball / arrow-key step sizes. Coarse (default) sweeps
    -- ~6 hue degrees and ~4% saturation per click so a few rolls of
    -- the ball land on a recognisable colour; fine (with Alt held)
    -- moves a single pixel for precise tweaking once the user is
    -- close. The constants are chosen so a full hue sweep takes
    -- about 60 coarse steps -- enough to feel responsive but not so
    -- fast that it skips colours.
    local STEP_COARSE = 6   -- pixels of crosshair travel per click
    local STEP_FINE   = 1

    node.register("color_spectrum", {
        -- Marked focusable so the global touch_input bridge will
        -- route touch/down events here; on_touch_down/drag below let
        -- the picker pick up screen-space taps and translate them
        -- into hue/saturation. Without focusable=true the bridge
        -- would only consider the title bar / button as candidates.
        -- Same focusable flag means LEFT/RIGHT/UP/DOWN are routed to
        -- on_key below for trackball / arrow-key navigation.
        focusable = true,
        measure = function(n, max_w, max_h)
            return max_w, SPEC_H
        end,
        on_key = function(n, key)
            if not n.on_step then return nil end
            local step = key.alt and STEP_FINE or STEP_COARSE
            local s = key.special
            -- LEFT / RIGHT always consumed (hue is cyclic-ish; the
            -- on_step clamps at the strip edges). UP / DOWN are
            -- consumed only when there's room to move; once the
            -- crosshair reaches the top (sat=1) or bottom (sat=0)
            -- we let the focus chain take the key so the user can
            -- step through to the brightness slider / Use button
            -- without lifting their thumb off the trackball.
            local h = (n._h or SPEC_H)
            local cur_py = (1 - (n.s or 0)) * (h - 1)
            if s == "LEFT"  then n.on_step(n, -step,  0); return "handled" end
            if s == "RIGHT" then n.on_step(n,  step,  0); return "handled" end
            if s == "UP" then
                if cur_py <= 0 then return nil end
                n.on_step(n, 0, -step); return "handled"
            end
            if s == "DOWN" then
                if cur_py >= h - 1 then return nil end
                n.on_step(n, 0, step); return "handled"
            end
            return nil
        end,
        draw = function(n, d, x, y, w, h)
            n._screen_x = x
            n._screen_y = y
            n._w = w
            n._h = h

            local sprite = ensure_spectrum_sprite(n.v or 1.0)
            if sprite then
                sprite:push(x, y)
            else
                d.fill_rect(x, y, w, h, theme.color("SURFACE"))
            end

            -- Crosshair at the current (h, s) sample point.
            local cx = x + math.floor((n.h or 0) / 360 * (w - 1))
            local cy = y + math.floor((1 - (n.s or 0)) * (h - 1))
            -- Two-tone halo so the indicator reads on any colour
            -- underneath.
            d.draw_circle(cx, cy, 6, theme.color("BG"))
            d.draw_circle(cx, cy, 5, theme.color("TEXT"))
            d.draw_circle(cx, cy, 4, theme.color("BG"))
        end,
        on_touch_down = function(n, sx, sy)
            if n.on_sample then n.on_sample(n, sx, sy) end
        end,
        on_touch_drag = function(n, sx, sy, dx, dy)
            if n.on_sample then n.on_sample(n, sx, sy) end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Preview swatch node (preview + hex)
-- ---------------------------------------------------------------------------

if not node.handler("color_preview") then
    node.register("color_preview", {
        focusable = false,
        measure = function(n, max_w, max_h) return max_w, 30 end,
        draw = function(n, d, x, y, w, h)
            d.fill_rect(x, y, w, h, theme.color("BG"))
            local sw = 56
            local sx = x + 8
            local sy = y + 2
            d.fill_rect(sx, sy, sw, h - 4,
                ez.display.rgb(n.r or 0, n.g or 0, n.b or 0))
            d.draw_rect(sx, sy, sw, h - 4, theme.color("BORDER"))

            theme.set_font("medium_aa")
            local fh = theme.font_height()
            local label = string.format("#%02X%02X%02X  RGB565 %04X",
                n.r or 0, n.g or 0, n.b or 0, n.rgb565 or 0)
            d.draw_text(sx + sw + 12,
                sy + math.floor(((h - 4) - fh) / 2),
                label, theme.color("TEXT"))
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

function M.initial_state(opts)
    opts = opts or {}
    local h, s, v = rgb_to_hsv(opts.r or 128, opts.g or 128, opts.b or 128)
    return {
        h        = h,
        s        = s,
        v        = math.floor(v * 255 + 0.5),
        on_pick  = opts.on_pick,
    }
end

local function current_rgb(state)
    local r, g, b = hsv_to_rgb(state.h, state.s, (state.v or 0) / 255)
    local r8, g8, b8, rgb565 = quantize_565(r, g, b)
    return r8, g8, b8, rgb565
end

function M:build(state)
    local r, g, b, rgb565 = current_rgb(state)

    -- Persist the spectrum node so its drawn rect stays addressable
    -- across rebuilds (the touch hook reads _screen_x/_y/_w/_h).
    if not self._spec_node then
        self._spec_node = { type = "color_spectrum" }
    end
    self._spec_node.h = state.h
    self._spec_node.s = state.s
    self._spec_node.v = (state.v or 0) / 255

    -- Trackball / arrow-key step handler. Receives pixel deltas
    -- (dx, dy) and translates them into hue / saturation deltas
    -- using the same x->hue, y->saturation mapping as the touch
    -- handler. Works in screen pixels so the coarse / fine step
    -- sizes feel consistent with the touch hit-test.
    self._spec_node.on_step = function(n, dx, dy)
        local w = (n._w or SPEC_W)
        local h = (n._h or SPEC_H)
        if w <= 1 or h <= 1 then return end
        -- Convert current state back into pixel coordinates so the
        -- round-trip through HSV doesn't drift on each step.
        local px = (state.h / 360) * (w - 1) + dx
        local py = (1 - state.s) * (h - 1) + dy
        if px < 0 then px = 0 end
        if px > w - 1 then px = w - 1 end
        if py < 0 then py = 0 end
        if py > h - 1 then py = h - 1 end
        state.h = (px / (w - 1)) * 360
        state.s = 1 - (py / (h - 1))
        self:set_state({})
    end
    -- on_sample called from on_touch_down/drag with (node, screen_x,
    -- screen_y). Map screen → (hue, saturation) and update state.
    self._spec_node.on_sample = function(n, sx, sy)
        local rel_x = sx - (n._screen_x or 0)
        local rel_y = sy - (n._screen_y or 0)
        local w = (n._w or SPEC_W)
        local h = (n._h or SPEC_H)
        if w <= 1 or h <= 1 then return end
        if rel_x < 0 then rel_x = 0 end
        if rel_x > w - 1 then rel_x = w - 1 end
        if rel_y < 0 then rel_y = 0 end
        if rel_y > h - 1 then rel_y = h - 1 end
        state.h = (rel_x / (w - 1)) * 360
        state.s = 1 - (rel_y / (h - 1))
        self:set_state({})
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Pick colour", { back = true }),
        ui.padding({ 4, 8, 2, 8 },
            { type = "color_preview", r = r, g = g, b = b, rgb565 = rgb565 }),
        ui.padding({ 2, 8, 2, 8 }, self._spec_node),
        ui.padding({ 4, 12, 4, 12 },
            ui.slider({
                label = "Brightness",
                value = state.v,
                min = 0, max = 255,
                on_change = function(v)
                    state.v = v
                    self:set_state({})
                end,
            })),
        ui.padding({ 4, 12, 4, 12 },
            ui.button("Use colour", {
                on_press = function()
                    if state.on_pick then
                        local r2, g2, b2 = current_rgb(state)
                        state.on_pick(r2, g2, b2)
                    end
                    screen_mod.pop()
                end,
            })),
    })
end

function M:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return M
