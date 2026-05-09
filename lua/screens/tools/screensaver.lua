-- Screensaver: animated pixel-exercising patterns
-- Cycles through patterns that drive every subpixel through its full range,
-- preventing and clearing LCD image persistence (stuck/ghosted pixels).
-- Launched automatically after idle timeout, or manually from the menu.
-- Any keypress exits.

local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")

local Screensaver = { title = "Screensaver", fullscreen = true }

local floor = math.floor
local random = math.random
local sin = math.sin
local abs = math.abs

local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

local SW, SH = 320, 240
local frame = 0
local pattern = 0
local FRAMES_PER_PATTERN = 300  -- ~10 seconds per pattern at 30fps
local NUM_PATTERNS = 5

-- Pre-computed colors
local RED, GREEN, BLUE, WHITE, BLACK
local CYAN, MAGENTA, YELLOW

local function init_colors()
    RED     = rgb(255, 0, 0)
    GREEN   = rgb(0, 255, 0)
    BLUE    = rgb(0, 0, 255)
    WHITE   = rgb(255, 255, 255)
    BLACK   = rgb(0, 0, 0)
    CYAN    = rgb(0, 255, 255)
    MAGENTA = rgb(255, 0, 255)
    YELLOW  = rgb(255, 255, 0)
end

-- Pattern 0: Color flood
-- Cycles through solid primary/secondary colors. Simple but effective at
-- unsticking pixels by driving each subpixel hard between 0 and max.
local FLOOD_COLORS
local function draw_color_flood(d)
    if not FLOOD_COLORS then
        FLOOD_COLORS = { RED, GREEN, BLUE, CYAN, MAGENTA, YELLOW, WHITE, BLACK }
    end
    local idx = floor(frame / 20) % #FLOOD_COLORS + 1
    d.fill_rect(0, 0, SW, SH, FLOOD_COLORS[idx])
end

-- Pattern 1: Plasma
-- Animated sine-wave color field. Every pixel gets a unique, continuously
-- shifting hue so no subpixel sits idle.
local function draw_plasma(d)
    local t = frame * 0.08
    -- Draw in 4x4 blocks for performance (4800 rects vs 76800 pixels)
    for by = 0, SH - 1, 4 do
        for bx = 0, SW - 1, 4 do
            local x, y = bx * 0.04, by * 0.04
            local v = sin(x + t) + sin(y + t * 0.7)
                    + sin((x + y) * 0.5 + t * 1.3)
            -- v is in [-3, 3], map to [0, 1]
            v = (v + 3) / 6
            -- Map to RGB via three offset sine curves
            local r = floor(abs(sin(v * 3.14159 * 2)) * 255)
            local g = floor(abs(sin(v * 3.14159 * 2 + 2.094)) * 255)
            local b = floor(abs(sin(v * 3.14159 * 2 + 4.189)) * 255)
            d.fill_rect(bx, by, 4, 4, rgb(r, g, b))
        end
    end
end

-- Pattern 2: Rain
-- Colored vertical streaks falling at different speeds. Each column
-- cycles through colors independently, sweeping every pixel vertically.
local rain_cols  -- { [col_index] = { y, speed, color_idx } }
local RAIN_W = 4
local RAIN_COLORS

local function init_rain()
    RAIN_COLORS = { RED, GREEN, BLUE, CYAN, MAGENTA, YELLOW, WHITE }
    local ncols = floor(SW / RAIN_W)
    rain_cols = {}
    for i = 1, ncols do
        rain_cols[i] = {
            y = random(0, SH - 1),
            speed = random(2, 6),
            cidx = random(1, #RAIN_COLORS),
        }
    end
end

local function draw_rain(d)
    d.fill_rect(0, 0, SW, SH, BLACK)
    if not rain_cols then init_rain() end
    for i, col in ipairs(rain_cols) do
        local x = (i - 1) * RAIN_W
        -- Draw a fading trail
        local trail_len = 40
        for t = 0, trail_len - 1, 4 do
            local ty = col.y - t
            if ty < 0 then ty = ty + SH end
            local brightness = floor((1 - t / trail_len) * 255)
            -- Tint the trail with the column's color
            local base = RAIN_COLORS[col.cidx]
            -- Extract approximate r/g/b from the base color and scale
            local r = floor(((base >> 11) & 0x1F) / 31 * brightness)
            local g = floor(((base >> 5) & 0x3F) / 63 * brightness)
            local b = floor((base & 0x1F) / 31 * brightness)
            d.fill_rect(x, ty, RAIN_W, 4, rgb(r, g, b))
        end
        -- Advance
        col.y = (col.y + col.speed) % SH
        -- Occasionally change color
        if random(1, 200) == 1 then
            col.cidx = random(1, #RAIN_COLORS)
        end
    end
end

-- Pattern 3: Pixel march
-- Horizontal colored bands that scroll vertically. Each band is a different
-- color, ensuring every row of pixels cycles through the full spectrum.
local function draw_pixel_march(d)
    local band_h = 8
    local colors = { RED, GREEN, BLUE, CYAN, MAGENTA, YELLOW, WHITE }
    local offset = floor(frame * 2) % (band_h * #colors)
    for y = -band_h, SH - 1, band_h do
        local actual_y = y + offset
        local band_idx = floor((y + offset) / band_h) % #colors + 1
        local dy = actual_y % (band_h * #colors)
        if dy < 0 then dy = dy + band_h * #colors end
        local ci = floor(dy / band_h) % #colors + 1
        d.fill_rect(0, y + offset, SW, band_h, colors[ci])
    end
end

-- Pattern 4: Sparkle
-- Random bright pixels appear on a dark background, cycling through
-- colors. Every pixel position gets hit over time. Effective at
-- exercising individual subpixels in isolation.
local sparkle_grid  -- persistent dim buffer, tracks "cooldown" per cell

local function draw_sparkle(d)
    d.fill_rect(0, 0, SW, SH, BLACK)
    local cell = 4
    local cols = floor(SW / cell)
    local rows = floor(SH / cell)

    -- Spawn new sparkles each frame
    local spawns = 60
    for _ = 1, spawns do
        local cx = random(0, cols - 1)
        local cy = random(0, rows - 1)
        local r = random(128, 255)
        local g = random(128, 255)
        local b = random(128, 255)
        d.fill_rect(cx * cell, cy * cell, cell, cell, rgb(r, g, b))
    end

    -- Also draw some larger bright rectangles to cover area faster
    if frame % 3 == 0 then
        local bx = random(0, SW - 32)
        local by = random(0, SH - 32)
        local r = random(64, 255)
        local g = random(64, 255)
        local b = random(64, 255)
        d.fill_rect(bx, by, 32, 32, rgb(r, g, b))
    end
end

-- Dispatch
local function draw_pattern(d, idx)
    if idx == 0 then draw_color_flood(d)
    elseif idx == 1 then draw_plasma(d)
    elseif idx == 2 then draw_rain(d)
    elseif idx == 3 then draw_pixel_march(d)
    elseif idx == 4 then draw_sparkle(d)
    end
end

-- Register custom node
if not node_mod.handler("screensaver_view") then
    node_mod.register("screensaver_view", {
        measure = function(n, mw, mh) return 320, 240 end,

        draw = function(n, d, x, y, w, h)
            draw_pattern(d, pattern)
        end,
    })
end

function Screensaver:build(state)
    return { type = "screensaver_view" }
end

function Screensaver:on_enter()
    math.randomseed(ez.system.millis())
    init_colors()
    frame = 0
    pattern = 0
    rain_cols = nil
    sparkle_grid = nil

    -- Dim keyboard backlight during screensaver
    self._saved_kb_bl = tonumber(ez.storage.get_pref("kb_backlight", 0)) or 0
    ez.keyboard.set_backlight(0)
end

function Screensaver:on_exit()
    -- Restore keyboard backlight
    if self._saved_kb_bl then
        ez.keyboard.set_backlight(self._saved_kb_bl)
    end
end

function Screensaver:update()
    frame = frame + 1
    if frame % FRAMES_PER_PATTERN == 0 then
        pattern = (pattern + 1) % NUM_PATTERNS
        rain_cols = nil  -- re-init rain on next draw
    end
    screen_mod.invalidate()
end

function Screensaver:handle_key(key)
    -- Any key exits
    return "pop"
end

return Screensaver
