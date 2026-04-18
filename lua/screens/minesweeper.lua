-- Minesweeper: Classic minesweeper game
-- Arrow keys to move, Enter to reveal, F to flag, R to restart, Q to quit.

local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")

local Minesweeper = { title = "Minesweeper" }

-- Game constants
local COLS, ROWS = 16, 10
local MINES = 25
local CELL = 18
local grid = {}      -- grid[r][c] = { mine=bool, revealed=bool, flagged=bool, count=int }
local cursor_r, cursor_c = 1, 1
local game_over = false
local game_won = false
local first_reveal = true  -- mines placed on first reveal to avoid instant death

local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

-- Initialize empty grid (no mines yet)
local function init_grid()
    grid = {}
    for r = 1, ROWS do
        grid[r] = {}
        for c = 1, COLS do
            grid[r][c] = { mine = false, revealed = false, flagged = false, count = 0 }
        end
    end
    cursor_r, cursor_c = 1, 1
    game_over = false
    game_won = false
    first_reveal = true
end

-- Place mines randomly, keeping a safe zone around (safe_r, safe_c)
local function place_mines(safe_r, safe_c)
    local placed = 0
    math.randomseed(ez.system.millis())
    while placed < MINES do
        local r = math.random(1, ROWS)
        local c = math.random(1, COLS)
        if not grid[r][c].mine and (math.abs(r - safe_r) > 1 or math.abs(c - safe_c) > 1) then
            grid[r][c].mine = true
            placed = placed + 1
        end
    end
    -- Compute neighbor mine counts for every cell
    for r = 1, ROWS do
        for c = 1, COLS do
            local count = 0
            for dr = -1, 1 do
                for dc = -1, 1 do
                    local nr, nc = r + dr, c + dc
                    if nr >= 1 and nr <= ROWS and nc >= 1 and nc <= COLS and grid[nr][nc].mine then
                        count = count + 1
                    end
                end
            end
            grid[r][c].count = count
        end
    end
end

-- Flood-fill reveal: recursively reveals zero-count neighbors
local function reveal(r, c)
    if r < 1 or r > ROWS or c < 1 or c > COLS then return end
    local cell = grid[r][c]
    if cell.revealed or cell.flagged then return end
    cell.revealed = true
    if cell.mine then
        game_over = true
        return
    end
    if cell.count == 0 then
        for dr = -1, 1 do
            for dc = -1, 1 do
                if dr ~= 0 or dc ~= 0 then
                    reveal(r + dr, c + dc)
                end
            end
        end
    end
end

-- Win when all non-mine cells are revealed
local function check_win()
    for r = 1, ROWS do
        for c = 1, COLS do
            local cell = grid[r][c]
            if not cell.mine and not cell.revealed then return end
        end
    end
    game_won = true
    game_over = true
end

-- Register custom drawing handler for the minesweeper board
if not node_mod.handler("minesweeper_view") then
    node_mod.register("minesweeper_view", {
        measure = function(n, max_w, max_h) return 320, 240 end,
        draw = function(n, d, x, y, w, h)
            local floor = math.floor
            d.fill_rect(x, y, 320, 240, rgb(40, 40, 50))

            -- Title bar text changes based on game state
            theme.set_font("small")
            local title = game_won and "YOU WIN!" or (game_over and "GAME OVER" or "Minesweeper")
            local title_c = game_won and rgb(50, 220, 50) or (game_over and rgb(220, 50, 50) or rgb(220, 220, 220))
            d.draw_text(x + floor((320 - theme.text_width(title)) / 2), y + 4, title, title_c)

            -- Remaining mines counter (mines minus flags placed)
            theme.set_font("tiny")
            local flags = 0
            for r = 1, ROWS do
                for c = 1, COLS do
                    if grid[r][c].flagged then flags = flags + 1 end
                end
            end
            d.draw_text(x + 4, y + 6, (MINES - flags) .. " mines", rgb(180, 180, 180))
            d.draw_text(x + 260, y + 6, "R:new Q:quit", rgb(120, 120, 120))

            -- Grid origin, centered horizontally below the title bar
            local gx = x + floor((320 - COLS * CELL) / 2)
            local gy = y + 24

            -- Colors for neighbor count digits 1-8
            local num_colors = {
                rgb(60, 60, 220),   -- 1: blue
                rgb(0, 130, 0),     -- 2: green
                rgb(220, 50, 50),   -- 3: red
                rgb(0, 0, 150),     -- 4: dark blue
                rgb(150, 0, 0),     -- 5: dark red
                rgb(0, 130, 130),   -- 6: teal
                rgb(50, 50, 50),    -- 7: black
                rgb(130, 130, 130), -- 8: gray
            }

            for r = 1, ROWS do
                for c = 1, COLS do
                    local cx = gx + (c - 1) * CELL
                    local cy = gy + (r - 1) * CELL
                    local cell = grid[r][c]

                    if cell.revealed then
                        if cell.mine then
                            -- Exploded mine: red background with mine icon
                            d.fill_rect(cx + 1, cy + 1, CELL - 2, CELL - 2, rgb(200, 50, 50))
                            d.fill_circle(cx + CELL / 2, cy + CELL / 2, 6, rgb(30, 30, 30))
                            d.fill_rect(cx + CELL / 2 - 1, cy + 3, 2, CELL - 6, rgb(30, 30, 30))
                            d.fill_rect(cx + 3, cy + CELL / 2 - 1, CELL - 6, 2, rgb(30, 30, 30))
                        else
                            -- Revealed safe cell: flat background with optional count
                            d.fill_rect(cx + 1, cy + 1, CELL - 2, CELL - 2, rgb(180, 180, 190))
                            if cell.count > 0 then
                                theme.set_font("small")
                                local txt = tostring(cell.count)
                                local tw = theme.text_width(txt)
                                d.draw_text(cx + floor((CELL - tw) / 2), cy + 5, txt, num_colors[cell.count] or rgb(0, 0, 0))
                            end
                        end
                    else
                        -- Unrevealed cell: 3D raised button appearance
                        d.fill_rect(cx + 1, cy + 1, CELL - 2, CELL - 2, rgb(120, 120, 140))
                        d.draw_hline(cx + 1, cy + 1, CELL - 2, rgb(160, 160, 180))
                        d.fill_rect(cx + 1, cy + 1, 1, CELL - 2, rgb(160, 160, 180))
                        d.draw_hline(cx + 1, cy + CELL - 2, CELL - 2, rgb(80, 80, 100))
                        d.fill_rect(cx + CELL - 2, cy + 1, 1, CELL - 2, rgb(80, 80, 100))

                        if cell.flagged then
                            -- Flag marker: red triangle with pole
                            d.fill_triangle(cx + 8, cy + 4, cx + 8, cy + 14, cx + 17, cy + 9, rgb(220, 40, 40))
                            d.fill_rect(cx + 8, cy + 14, 1, 4, rgb(50, 50, 50))
                        end

                        -- On game over, reveal unflagged mine positions
                        if game_over and cell.mine and not cell.flagged then
                            d.fill_circle(cx + CELL / 2, cy + CELL / 2, 5, rgb(60, 60, 60))
                        end
                    end

                    -- Cell border
                    d.draw_rect(cx, cy, CELL, CELL, rgb(60, 60, 70))
                end
            end

            -- Cursor highlight (yellow double border)
            if not game_over then
                local cx = gx + (cursor_c - 1) * CELL
                local cy = gy + (cursor_r - 1) * CELL
                d.draw_rect(cx, cy, CELL, CELL, rgb(255, 220, 50))
                d.draw_rect(cx + 1, cy + 1, CELL - 2, CELL - 2, rgb(255, 220, 50))
            end

            -- Bottom hint text
            theme.set_font("tiny")
            if not game_over then
                local hint = "Space:reveal  F:flag"
                d.draw_text(x + floor((320 - theme.text_width(hint)) / 2), y + 228, hint, rgb(100, 100, 110))
            else
                local hint = "R to restart"
                d.draw_text(x + floor((320 - theme.text_width(hint)) / 2), y + 228, hint, rgb(150, 150, 150))
            end
        end,
    })
end

function Minesweeper:build(state)
    return { type = "minesweeper_view" }
end

function Minesweeper:on_enter()
    init_grid()
end

function Minesweeper:update()
    screen_mod.invalidate()
end

function Minesweeper:handle_key(key)
    if key.character == "q" or key.special == "ESCAPE" then return "pop" end
    if key.character == "r" then
        init_grid()
        return "handled"
    end
    if game_over then return "handled" end

    if key.special == "UP" then cursor_r = math.max(1, cursor_r - 1)
    elseif key.special == "DOWN" then cursor_r = math.min(ROWS, cursor_r + 1)
    elseif key.special == "LEFT" then cursor_c = math.max(1, cursor_c - 1)
    elseif key.special == "RIGHT" then cursor_c = math.min(COLS, cursor_c + 1)
    elseif key.special == "ENTER" or key.character == " " then
        if not grid[cursor_r][cursor_c].flagged then
            if first_reveal then
                place_mines(cursor_r, cursor_c)
                first_reveal = false
            end
            reveal(cursor_r, cursor_c)
            if not game_over then check_win() end
        end
    elseif key.character == "f" then
        local cell = grid[cursor_r][cursor_c]
        if not cell.revealed then
            cell.flagged = not cell.flagged
        end
    end
    return "handled"
end

return Minesweeper
