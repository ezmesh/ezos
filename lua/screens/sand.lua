-- Falling Sand: Particle simulation toy
-- Drop sand, water, stone, and fire particles that interact with gravity and each other.
-- Arrow keys move cursor, 1-4 select particle type, Enter/Space drops particles.

local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")

local Sand = { title = "Sand" }

-- Simulation grid: half resolution for performance (each cell = 2x2 display pixels)
local W, H = 160, 110
local GRID_OX, GRID_OY = 0, 20  -- display offset (top 20px reserved for HUD)

-- Particle type constants
local EMPTY = 0
local SAND  = 1
local WATER = 2
local STONE = 3
local FIRE  = 4

local TYPE_NAMES = { "Sand", "Water", "Stone", "Fire" }

-- Flat arrays for the simulation grid (1-indexed, row-major)
local grid = {}
local fire_life = {}

local cursor_x, cursor_y = 80, 55
local particle_type = SAND
local frame = 0
local particle_count = 0  -- cached count, updated during simulation

local floor = math.floor
local random = math.random

local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

-- Convert grid coordinates to a flat array index
local function idx(x, y) return (y - 1) * W + x end

-- Read a cell, returning -1 for out-of-bounds (treated as solid wall)
local function get(x, y)
    if x < 1 or x > W or y < 1 or y > H then return -1 end
    return grid[idx(x, y)]
end

-- Write a cell (bounds-checked)
local function set(x, y, val)
    if x >= 1 and x <= W and y >= 1 and y <= H then
        grid[idx(x, y)] = val
    end
end

-- Swap two cells by grid coordinates
local function swap(x1, y1, x2, y2)
    local i1, i2 = idx(x1, y1), idx(x2, y2)
    grid[i1], grid[i2] = grid[i2], grid[i1]
    fire_life[i1], fire_life[i2] = fire_life[i2], fire_life[i1]
end

-- Clear the entire grid
local function clear_grid()
    for i = 1, W * H do
        grid[i] = EMPTY
        fire_life[i] = 0
    end
end

-- Deterministic color variation based on position to avoid per-frame random calls
local function variation(x, y)
    return (x * 7 + y * 13) % 3
end

-- Pre-computed particle colors (base colors with slight variation baked in)
local colors_sand = {}
local colors_water = {}
local colors_stone = {}
local colors_fire = {}

local function init_colors()
    -- Sand: warm yellow/tan with subtle variation
    colors_sand[0] = rgb(210, 180, 100)
    colors_sand[1] = rgb(220, 190, 110)
    colors_sand[2] = rgb(200, 170, 90)
    -- Water: blue with depth variation
    colors_water[0] = rgb(30, 90, 200)
    colors_water[1] = rgb(40, 100, 220)
    colors_water[2] = rgb(20, 80, 190)
    -- Stone: gray with texture variation
    colors_stone[0] = rgb(128, 128, 128)
    colors_stone[1] = rgb(140, 140, 140)
    colors_stone[2] = rgb(116, 116, 116)
    -- Fire: red/orange with flicker variation
    colors_fire[0] = rgb(240, 80, 20)
    colors_fire[1] = rgb(255, 160, 30)
    colors_fire[2] = rgb(220, 40, 10)
end

-- Get the display color for a particle at a given grid position
local function particle_color(ptype, x, y)
    local v = variation(x, y)
    if ptype == SAND then return colors_sand[v]
    elseif ptype == WATER then return colors_water[v]
    elseif ptype == STONE then return colors_stone[v]
    elseif ptype == FIRE then return colors_fire[v]
    end
    return 0
end

-- Drop several particles around the cursor with slight spread
local function drop_particles()
    for i = 1, 5 do
        local dx = random(-2, 2)
        local dy = random(-2, 2)
        local px = cursor_x + dx
        local py = cursor_y + dy
        if px >= 1 and px <= W and py >= 1 and py <= H then
            if get(px, py) == EMPTY then
                set(px, py, particle_type)
                if particle_type == FIRE then
                    fire_life[idx(px, py)] = 40 + random(0, 20)
                end
            end
        end
    end
end

-- Neighbor offset arrays (pre-allocated to avoid creating tables every frame)
local NEIGHBOR_DX = { 0, 0, -1, 1 }
local NEIGHBOR_DY = { -1, 1, 0, 0 }

-- Run one simulation step. Process bottom-to-top and right-to-left so that
-- falling particles don't get processed twice in the same frame.
-- Also recomputes the particle_count cache.
local function simulate()
    local count = 0

    for y = H, 1, -1 do
        for x = W, 1, -1 do
            local i = idx(x, y)
            local p = grid[i]

            if p == SAND then
                count = count + 1
                local below = get(x, y + 1)
                if below == EMPTY then
                    swap(x, y, x, y + 1)
                elseif below == WATER then
                    -- Sand sinks through water
                    swap(x, y, x, y + 1)
                else
                    -- Try diagonal: pick a random order to avoid bias
                    local dx1, dx2
                    if random(1, 2) == 1 then dx1, dx2 = -1, 1
                    else dx1, dx2 = 1, -1 end
                    local dl = get(x + dx1, y + 1)
                    local dr = get(x + dx2, y + 1)
                    if dl == EMPTY or dl == WATER then
                        swap(x, y, x + dx1, y + 1)
                    elseif dr == EMPTY or dr == WATER then
                        swap(x, y, x + dx2, y + 1)
                    end
                end

            elseif p == WATER then
                count = count + 1
                local below = get(x, y + 1)
                if below == EMPTY then
                    swap(x, y, x, y + 1)
                else
                    -- Try diagonal down
                    local dx1, dx2
                    if random(1, 2) == 1 then dx1, dx2 = -1, 1
                    else dx1, dx2 = 1, -1 end
                    local dl = get(x + dx1, y + 1)
                    local dr = get(x + dx2, y + 1)
                    if dl == EMPTY then
                        swap(x, y, x + dx1, y + 1)
                    elseif dr == EMPTY then
                        swap(x, y, x + dx2, y + 1)
                    else
                        -- Flow sideways: try left or right (random order)
                        local sl = get(x + dx1, y)
                        local sr = get(x + dx2, y)
                        if sl == EMPTY then
                            swap(x, y, x + dx1, y)
                        elseif sr == EMPTY then
                            swap(x, y, x + dx2, y)
                        end
                    end
                end

            elseif p == STONE then
                count = count + 1

            elseif p == FIRE then
                count = count + 1
                local fi = i
                fire_life[fi] = fire_life[fi] - 1
                if fire_life[fi] <= 0 then
                    grid[fi] = EMPTY
                    fire_life[fi] = 0
                    count = count - 1
                else
                    -- Check all four neighbors for interactions
                    local extinguished = false
                    for n = 1, 4 do
                        local nx = x + NEIGHBOR_DX[n]
                        local ny = y + NEIGHBOR_DY[n]
                        local neighbor = get(nx, ny)
                        if neighbor == SAND then
                            -- Fire consumes adjacent sand
                            set(nx, ny, EMPTY)
                            count = count - 1
                        elseif neighbor == WATER then
                            -- Water extinguishes fire (both removed)
                            set(nx, ny, EMPTY)
                            grid[fi] = EMPTY
                            fire_life[fi] = 0
                            count = count - 2
                            extinguished = true
                            break
                        end
                    end
                    -- Rise upward with random horizontal drift
                    if not extinguished then
                        local above = get(x, y - 1)
                        if above == EMPTY then
                            swap(x, y, x, y - 1)
                        else
                            local drift = random(-1, 1)
                            if drift ~= 0 and get(x + drift, y - 1) == EMPTY then
                                swap(x, y, x + drift, y - 1)
                            elseif drift ~= 0 and get(x + drift, y) == EMPTY then
                                swap(x, y, x + drift, y)
                            end
                        end
                    end
                end
            end
        end
    end

    particle_count = count
end

-- Register the custom drawing node as focusable so it receives all key input
-- (including arrow keys and Enter) before the focus system's default navigation.
if not node_mod.handler("sand_view") then
    node_mod.register("sand_view", {
        measure = function(n, max_w, max_h) return 320, 240 end,

        draw = function(n, d, x, y, w, h)
            -- Background
            d.fill_rect(x, y, 320, 240, rgb(20, 20, 30))

            -- Draw all non-empty particles as 2x2 pixel blocks
            for gy = 1, H do
                local row_base = (gy - 1) * W
                local py = y + GRID_OY + (gy - 1) * 2
                for gx = 1, W do
                    local p = grid[row_base + gx]
                    if p ~= EMPTY then
                        local px = x + GRID_OX + (gx - 1) * 2
                        d.fill_rect(px, py, 2, 2, particle_color(p, gx, gy))
                    end
                end
            end

            -- Draw cursor crosshair (5x5 in simulation space = 10x10 display pixels)
            local cx = x + GRID_OX + (cursor_x - 1) * 2
            local cy = y + GRID_OY + (cursor_y - 1) * 2
            local cc = rgb(255, 255, 255)
            -- Horizontal line of crosshair
            d.draw_hline(cx - 4, cy + 1, 10, cc)
            -- Vertical line of crosshair
            d.fill_rect(cx + 1, cy - 4, 1, 10, cc)

            -- HUD bar at the top
            d.fill_rect(x, y, 320, GRID_OY, rgb(10, 10, 20))

            theme.set_font("tiny")
            -- Current particle type indicator with colored square
            local type_name = TYPE_NAMES[particle_type]
            local type_color = particle_color(particle_type, 5, 5)
            d.fill_rect(x + 4, y + 5, 10, 10, type_color)
            d.draw_text(x + 18, y + 4, type_name, rgb(220, 220, 220))

            -- Particle count (cached from simulation step)
            local info = particle_count .. " particles"
            d.draw_text(x + 160 - floor(theme.text_width(info) / 2), y + 4,
                        info, rgb(160, 160, 160))

            -- Controls hint
            d.draw_text(x + 260, y + 4, "1-4 C Q", rgb(100, 100, 120))
        end,
    })
end

function Sand:build(state)
    return { type = "sand_view" }
end

function Sand:on_enter()
    math.randomseed(ez.system.millis())
    init_colors()
    clear_grid()
    cursor_x = floor(W / 2)
    cursor_y = floor(H / 2)
    particle_type = SAND
    frame = 0
end

function Sand:update()
    frame = frame + 1
    -- Simulate every other frame to reduce CPU load
    if frame % 2 == 0 then
        simulate()
    end
    screen_mod.invalidate()
end

function Sand:handle_key(key)
    if key.character == "q" or key.special == "ESCAPE" then
        return "pop"
    end

    -- Cursor movement
    if key.special == "UP" then cursor_y = math.max(1, cursor_y - 2)
    elseif key.special == "DOWN" then cursor_y = math.min(H, cursor_y + 2)
    elseif key.special == "LEFT" then cursor_x = math.max(1, cursor_x - 2)
    elseif key.special == "RIGHT" then cursor_x = math.min(W, cursor_x + 2)
    elseif key.special == "ENTER" or key.character == " " then
        drop_particles()
    -- Particle type selection
    elseif key.character == "1" then particle_type = SAND
    elseif key.character == "2" then particle_type = WATER
    elseif key.character == "3" then particle_type = STONE
    elseif key.character == "4" then particle_type = FIRE
    elseif key.character == "c" then clear_grid()
    end

    return "handled"
end

return Sand
