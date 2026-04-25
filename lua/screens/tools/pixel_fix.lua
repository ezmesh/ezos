-- Pixel Exerciser: Cycles display patterns to clear image persistence
-- Rapidly alternates colors and patterns to exercise all subpixels.
-- Press Q or ESCAPE to exit.

local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")

local PixelFix = { title = "Pixel Fix", fullscreen = true }

local floor = math.floor
local random = math.random

local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

local SW, SH = 320, 240
local frame = 0
local pattern = 0
local FRAMES_PER_PATTERN = 60  -- ~2 seconds per pattern at 30fps

-- Total number of pattern types
local NUM_PATTERNS = 9

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

local function draw_solid(d, color)
    d.fill_rect(0, 0, SW, SH, color)
end

local function draw_noise(d)
    -- Random 4x4 colored blocks for performance
    for y = 0, SH - 1, 4 do
        for x = 0, SW - 1, 4 do
            local r = random(0, 255)
            local g = random(0, 255)
            local b = random(0, 255)
            d.fill_rect(x, y, 4, 4, rgb(r, g, b))
        end
    end
end

local function draw_checkerboard(d, cell_size)
    local c1 = WHITE
    local c2 = BLACK
    -- Alternate between normal and inverted each cycle
    if floor(frame / 15) % 2 == 1 then c1, c2 = c2, c1 end

    d.fill_rect(0, 0, SW, SH, c2)
    for y = 0, SH - 1, cell_size do
        for x = 0, SW - 1, cell_size do
            local cx = floor(x / cell_size)
            local cy = floor(y / cell_size)
            if (cx + cy) % 2 == 0 then
                d.fill_rect(x, y, cell_size, cell_size, c1)
            end
        end
    end
end

local function draw_color_bars(d)
    local colors = { RED, GREEN, BLUE, CYAN, MAGENTA, YELLOW, WHITE, BLACK }
    local bar_w = floor(SW / #colors)
    for i, c in ipairs(colors) do
        d.fill_rect((i - 1) * bar_w, 0, bar_w, SH, c)
    end
end

local function draw_horizontal_sweep(d)
    -- A bright white line sweeps across the screen
    d.fill_rect(0, 0, SW, SH, BLACK)
    local line_y = frame % SH
    d.fill_rect(0, line_y, SW, 3, WHITE)
    -- Also fill with color above/below for subpixel exercise
    if line_y > 3 then
        d.fill_rect(0, line_y - 3, SW, 3, rgb(80, 80, 80))
    end
end

local function draw_vertical_sweep(d)
    d.fill_rect(0, 0, SW, SH, BLACK)
    local line_x = frame % SW
    d.fill_rect(line_x, 0, 3, SH, WHITE)
    if line_x > 3 then
        d.fill_rect(line_x - 3, 0, 3, SH, rgb(80, 80, 80))
    end
end

local function draw_pattern(d, idx)
    if idx == 0 then draw_solid(d, RED)
    elseif idx == 1 then draw_solid(d, GREEN)
    elseif idx == 2 then draw_solid(d, BLUE)
    elseif idx == 3 then draw_solid(d, WHITE)
    elseif idx == 4 then draw_solid(d, BLACK)
    elseif idx == 5 then draw_noise(d)
    elseif idx == 6 then draw_checkerboard(d, 8)
    elseif idx == 7 then draw_color_bars(d)
    elseif idx == 8 then draw_horizontal_sweep(d)
    end
end

local pattern_names = {
    "Red", "Green", "Blue", "White", "Black",
    "Noise", "Checkerboard", "Color Bars", "Sweep",
}

-- Register custom node for full-screen rendering
if not node_mod.handler("pixel_fix_view") then
    node_mod.register("pixel_fix_view", {
        measure = function(n, mw, mh) return 320, 240 end,

        draw = function(n, d, x, y, w, h)
            draw_pattern(d, pattern)

            -- Overlay pattern name and progress (except on solid patterns where
            -- the text might blend in - always draw with contrasting outline)
            theme.set_font("tiny_aa")
            local name = pattern_names[pattern + 1] or ""
            local progress = floor((frame % FRAMES_PER_PATTERN) / FRAMES_PER_PATTERN * 100)
            local info = name .. "  " .. progress .. "%  [Q:exit]"

            -- Draw text with dark outline for readability on any background
            local tw = theme.text_width(info)
            local tx = floor((SW - tw) / 2)
            local ty = SH - 14
            d.fill_rect(tx - 2, ty - 1, tw + 4, 12, rgb(0, 0, 0))
            d.draw_text(tx, ty, info, rgb(200, 200, 200))
        end,
    })
end

function PixelFix:build(state)
    return { type = "pixel_fix_view" }
end

function PixelFix:on_enter()
    math.randomseed(ez.system.millis())
    init_colors()
    frame = 0
    pattern = 0
end

function PixelFix:update()
    frame = frame + 1
    if frame % FRAMES_PER_PATTERN == 0 then
        pattern = (pattern + 1) % NUM_PATTERNS
    end
    screen_mod.invalidate()
end

function PixelFix:handle_key(key)
    if key.character == "q" or key.special == "ESCAPE" then
        return "pop"
    end
    -- Manual pattern advance
    if key.special == "RIGHT" or key.character == " " then
        pattern = (pattern + 1) % NUM_PATTERNS
        frame = 0
        return "handled"
    end
    if key.special == "LEFT" then
        pattern = (pattern - 1) % NUM_PATTERNS
        frame = 0
        return "handled"
    end
    return "handled"
end

return PixelFix
