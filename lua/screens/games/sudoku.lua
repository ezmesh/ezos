-- Sudoku: Classic 9x9 number puzzle
-- Arrow keys to move, 1-9 to place, 0/Delete to clear, R to restart, Q to quit.

local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")

local Sudoku = { title = "Sudoku", fullscreen = true }

local CELL = 22
local GRID_X = 61  -- (320 - 9*22) / 2
local GRID_Y = 28

local board = {}    -- board[r][c] = number (0 = empty)
local given = {}    -- given[r][c] = true if pre-filled
local cursor_r, cursor_c = 1, 1
local solved = false
local conflict = {}  -- conflict[r][c] = true if cell has conflict

local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

-- Check if placing val at (r,c) is valid (no duplicate in row, column, or 3x3 box)
local function is_valid(b, r, c, val)
    for i = 1, 9 do
        if i ~= c and b[r][i] == val then return false end
        if i ~= r and b[i][c] == val then return false end
    end
    local br = math.floor((r - 1) / 3) * 3
    local bc = math.floor((c - 1) / 3) * 3
    for dr = 1, 3 do
        for dc = 1, 3 do
            local nr, nc = br + dr, bc + dc
            if (nr ~= r or nc ~= c) and b[nr][nc] == val then return false end
        end
    end
    return true
end

-- Solve board with backtracking, trying values in random order for puzzle generation.
-- Returns true if a complete valid solution was found.
local function solve(b, iters)
    iters[1] = iters[1] + 1
    if iters[1] > 5000 then return false end
    for r = 1, 9 do
        for c = 1, 9 do
            if b[r][c] == 0 then
                local order = {1, 2, 3, 4, 5, 6, 7, 8, 9}
                for i = 9, 2, -1 do
                    local j = math.random(1, i)
                    order[i], order[j] = order[j], order[i]
                end
                for _, val in ipairs(order) do
                    if is_valid(b, r, c, val) then
                        b[r][c] = val
                        if solve(b, iters) then return true end
                        b[r][c] = 0
                    end
                end
                return false
            end
        end
    end
    return true  -- all cells filled
end

-- Generate a new puzzle by building a complete solution and removing cells
local function generate()
    math.randomseed(ez.system.millis())
    board = {}
    given = {}
    conflict = {}
    for r = 1, 9 do
        board[r] = {}
        given[r] = {}
        conflict[r] = {}
        for c = 1, 9 do
            board[r][c] = 0
            given[r][c] = false
            conflict[r][c] = false
        end
    end

    -- Fill the three diagonal 3x3 boxes independently (they share no row/column constraints)
    for box = 0, 2 do
        local nums = {1, 2, 3, 4, 5, 6, 7, 8, 9}
        for i = 9, 2, -1 do
            local j = math.random(1, i)
            nums[i], nums[j] = nums[j], nums[i]
        end
        local idx = 1
        for r = 1, 3 do
            for c = 1, 3 do
                board[box * 3 + r][box * 3 + c] = nums[idx]
                idx = idx + 1
            end
        end
    end

    -- Fill remaining cells with backtracking
    local iters = {0}
    if not solve(board, iters) then
        return generate()
    end

    -- Remove 42 cells to create the puzzle (leaving ~39 clues)
    local cells = {}
    for r = 1, 9 do
        for c = 1, 9 do
            cells[#cells + 1] = {r, c}
            given[r][c] = true
        end
    end
    for i = #cells, 2, -1 do
        local j = math.random(1, i)
        cells[i], cells[j] = cells[j], cells[i]
    end
    local to_remove = 42
    for i = 1, to_remove do
        local r, c = cells[i][1], cells[i][2]
        board[r][c] = 0
        given[r][c] = false
    end

    cursor_r, cursor_c = 1, 1
    solved = false
end

-- Mark all cells that violate Sudoku constraints
local function update_conflicts()
    for r = 1, 9 do
        for c = 1, 9 do
            conflict[r][c] = false
        end
    end
    for r = 1, 9 do
        for c = 1, 9 do
            if board[r][c] ~= 0 and not is_valid(board, r, c, board[r][c]) then
                conflict[r][c] = true
            end
        end
    end
end

-- Check if every cell is filled with no conflicts remaining
local function check_solved()
    for r = 1, 9 do
        for c = 1, 9 do
            if board[r][c] == 0 or conflict[r][c] then return end
        end
    end
    solved = true
end

-- Register custom drawing handler for the Sudoku board
if not node_mod.handler("sudoku_view") then
    node_mod.register("sudoku_view", {
        measure = function(n, max_w, max_h) return 320, 240 end,
        draw = function(n, d, x, y, w, h)
            local floor = math.floor
            d.fill_rect(x, y, 320, 240, rgb(25, 25, 35))

            -- Title bar
            theme.set_font("small")
            local title = solved and "SOLVED!" or "Sudoku"
            local tc = solved and rgb(50, 220, 50) or rgb(220, 220, 220)
            d.draw_text(x + floor((320 - theme.text_width(title)) / 2), y + 4, title, tc)
            theme.set_font("tiny")
            d.draw_text(x + 4, y + 6, "R:new", rgb(120, 120, 120))
            d.draw_text(x + 280, y + 6, "Q:quit", rgb(120, 120, 120))

            local gx = x + GRID_X
            local gy = y + GRID_Y

            -- Draw cells
            for r = 1, 9 do
                for c = 1, 9 do
                    local cx = gx + (c - 1) * CELL
                    local cy = gy + (r - 1) * CELL

                    -- Cell background color depends on state
                    local bg
                    if conflict[r][c] then
                        bg = rgb(80, 30, 30)
                    elseif r == cursor_r and c == cursor_c and not solved then
                        bg = rgb(60, 60, 90)
                    elseif given[r][c] then
                        bg = rgb(45, 45, 55)
                    else
                        bg = rgb(35, 35, 45)
                    end
                    d.fill_rect(cx + 1, cy + 1, CELL - 2, CELL - 2, bg)

                    -- Draw the number if the cell is not empty
                    if board[r][c] ~= 0 then
                        theme.set_font("small")
                        local txt = tostring(board[r][c])
                        local tw = theme.text_width(txt)
                        local nc
                        if given[r][c] then
                            nc = rgb(200, 200, 210)
                        elseif conflict[r][c] then
                            nc = rgb(255, 80, 80)
                        else
                            nc = rgb(100, 160, 255)
                        end
                        d.draw_text(cx + floor((CELL - tw) / 2), cy + 4, txt, nc)
                    end
                end
            end

            -- Grid lines: thick borders for 3x3 box boundaries, thin for individual cells
            local thin = rgb(60, 60, 80)
            local thick = rgb(140, 140, 160)
            for i = 0, 9 do
                local lc = (i % 3 == 0) and thick or thin
                -- Horizontal lines
                d.draw_hline(gx, gy + i * CELL, 9 * CELL, lc)
                if i % 3 == 0 then
                    d.draw_hline(gx, gy + i * CELL + 1, 9 * CELL, lc)
                end
                -- Vertical lines
                d.fill_rect(gx + i * CELL, gy, 1, 9 * CELL, lc)
                if i % 3 == 0 then
                    d.fill_rect(gx + i * CELL + 1, gy, 1, 9 * CELL, lc)
                end
            end

            -- Cursor highlight (yellow double border around selected cell)
            if not solved then
                local cx = gx + (cursor_c - 1) * CELL
                local cy = gy + (cursor_r - 1) * CELL
                d.draw_rect(cx, cy, CELL, CELL, rgb(255, 220, 50))
                d.draw_rect(cx + 1, cy + 1, CELL - 2, CELL - 2, rgb(255, 220, 50))
            end

            -- Bottom hint text
            theme.set_font("tiny")
            local hint = solved and "R for new puzzle" or "1-9:place  0:clear"
            d.draw_text(x + floor((320 - theme.text_width(hint)) / 2), y + 228, hint, rgb(100, 100, 110))
        end,
    })
end

function Sudoku:build(state)
    return { type = "sudoku_view" }
end

function Sudoku:on_enter()
    generate()
end

function Sudoku:update()
    screen_mod.invalidate()
end

function Sudoku:handle_key(key)
    if key.character == "q" or key.special == "ESCAPE" then return "pop" end
    if key.character == "r" then
        generate()
        return "handled"
    end
    if solved then return "handled" end

    if key.special == "UP" then cursor_r = math.max(1, cursor_r - 1)
    elseif key.special == "DOWN" then cursor_r = math.min(9, cursor_r + 1)
    elseif key.special == "LEFT" then cursor_c = math.max(1, cursor_c - 1)
    elseif key.special == "RIGHT" then cursor_c = math.min(9, cursor_c + 1)
    elseif key.character and key.character >= "1" and key.character <= "9" then
        if not given[cursor_r][cursor_c] then
            board[cursor_r][cursor_c] = tonumber(key.character)
            update_conflicts()
            check_solved()
        end
    elseif key.character == "0" or key.special == "DELETE" or key.special == "BACKSPACE" then
        if not given[cursor_r][cursor_c] then
            board[cursor_r][cursor_c] = 0
            update_conflicts()
        end
    end
    return "handled"
end

return Sudoku
