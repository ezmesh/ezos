-- Sudoku for T-Deck OS
-- Classic number puzzle game

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local Sudoku = {
    title = "Sudoku",
    CELL_SIZE = 22,
    GRID_X = 35,
    GRID_Y = 25,
}

function Sudoku:new()
    local o = {
        grid = {},           -- Current state
        solution = {},       -- Solution
        fixed = {},          -- Original given cells
        cursor_x = 1,
        cursor_y = 1,
        selected_num = 1,
        mistakes = 0,
        won = false,
        difficulty = "medium",
    }
    setmetatable(o, {__index = Sudoku})
    return o
end

function Sudoku:on_enter()
    if _G.MainLoop then _G.MainLoop.enter_game_mode() end
    self:new_game()
end

function Sudoku:on_exit()
    if _G.MainLoop then _G.MainLoop.exit_game_mode() end
end

-- Generate a valid sudoku solution
function Sudoku:generate_solution()
    -- Start with empty grid
    local grid = {}
    for y = 1, 9 do
        grid[y] = {}
        for x = 1, 9 do
            grid[y][x] = 0
        end
    end

    -- Fill using backtracking
    local function is_valid(g, row, col, num)
        -- Check row
        for x = 1, 9 do
            if g[row][x] == num then return false end
        end
        -- Check column
        for y = 1, 9 do
            if g[y][col] == num then return false end
        end
        -- Check 3x3 box
        local box_y = math.floor((row - 1) / 3) * 3 + 1
        local box_x = math.floor((col - 1) / 3) * 3 + 1
        for dy = 0, 2 do
            for dx = 0, 2 do
                if g[box_y + dy][box_x + dx] == num then return false end
            end
        end
        return true
    end

    local function fill(g, pos)
        if pos > 81 then return true end

        local row = math.floor((pos - 1) / 9) + 1
        local col = ((pos - 1) % 9) + 1

        -- Shuffle numbers 1-9
        local nums = {1, 2, 3, 4, 5, 6, 7, 8, 9}
        for i = 9, 2, -1 do
            local j = math.random(i)
            nums[i], nums[j] = nums[j], nums[i]
        end

        for _, num in ipairs(nums) do
            if is_valid(g, row, col, num) then
                g[row][col] = num
                if fill(g, pos + 1) then
                    return true
                end
                g[row][col] = 0
            end
        end

        return false
    end

    fill(grid, 1)
    return grid
end

function Sudoku:new_game()
    -- Generate solution
    self.solution = self:generate_solution()

    -- Copy solution to grid
    self.grid = {}
    self.fixed = {}
    for y = 1, 9 do
        self.grid[y] = {}
        self.fixed[y] = {}
        for x = 1, 9 do
            self.grid[y][x] = self.solution[y][x]
            self.fixed[y][x] = false
        end
    end

    -- Remove cells based on difficulty
    local cells_to_remove = 45  -- medium
    if self.difficulty == "easy" then
        cells_to_remove = 35
    elseif self.difficulty == "hard" then
        cells_to_remove = 55
    end

    -- Create list of all positions and shuffle
    local positions = {}
    for y = 1, 9 do
        for x = 1, 9 do
            table.insert(positions, {x = x, y = y})
        end
    end
    for i = #positions, 2, -1 do
        local j = math.random(i)
        positions[i], positions[j] = positions[j], positions[i]
    end

    -- Remove cells
    for i = 1, cells_to_remove do
        local pos = positions[i]
        self.grid[pos.y][pos.x] = 0
    end

    -- Mark remaining cells as fixed
    for y = 1, 9 do
        for x = 1, 9 do
            self.fixed[y][x] = (self.grid[y][x] ~= 0)
        end
    end

    self.cursor_x = 1
    self.cursor_y = 1
    self.mistakes = 0
    self.won = false
end

function Sudoku:check_win()
    for y = 1, 9 do
        for x = 1, 9 do
            if self.grid[y][x] ~= self.solution[y][x] then
                return false
            end
        end
    end
    return true
end

function Sudoku:place_number(num)
    if self.won then return end
    if self.fixed[self.cursor_y][self.cursor_x] then return end

    if num == 0 then
        -- Clear cell
        self.grid[self.cursor_y][self.cursor_x] = 0
    else
        self.grid[self.cursor_y][self.cursor_x] = num
        -- Check if correct
        if num ~= self.solution[self.cursor_y][self.cursor_x] then
            self.mistakes = self.mistakes + 1
        end
    end

    if self:check_win() then
        self.won = true
    end
end

function Sudoku:render(display)
    local colors = ListMixin.get_colors(display)

    display.fill_rect(0, 0, 320, 240, colors.BLACK)

    -- Title and info
    display.set_font_size("small")
    display.draw_text(5, 5, "SUDOKU", colors.ACCENT)
    display.draw_text(100, 5, string.format("Mistakes: %d", self.mistakes),
        self.mistakes >= 3 and colors.ERROR or colors.WHITE)

    local grid_size = 9 * self.CELL_SIZE

    -- Draw grid background
    display.fill_rect(self.GRID_X, self.GRID_Y, grid_size, grid_size, 0xFFFF)

    -- Draw cells
    for y = 1, 9 do
        for x = 1, 9 do
            local px = self.GRID_X + (x - 1) * self.CELL_SIZE
            local py = self.GRID_Y + (y - 1) * self.CELL_SIZE

            local is_cursor = (x == self.cursor_x and y == self.cursor_y)
            local is_fixed = self.fixed[y][x]
            local value = self.grid[y][x]
            local is_wrong = (value ~= 0 and value ~= self.solution[y][x])

            -- Cell background
            local bg = 0xFFFF
            if is_cursor then
                bg = colors.ACCENT
            elseif is_wrong then
                bg = 0xFDD0  -- Light red
            end
            display.fill_rect(px + 1, py + 1, self.CELL_SIZE - 2, self.CELL_SIZE - 2, bg)

            -- Number
            if value > 0 then
                local text_color = 0x0000
                if is_fixed then
                    text_color = 0x0000  -- Black for fixed
                elseif is_wrong then
                    text_color = colors.ERROR
                else
                    text_color = colors.ACCENT  -- User placed
                end
                if is_cursor then
                    text_color = 0xFFFF
                end

                local num_str = tostring(value)
                display.draw_text(px + 7, py + 4, num_str, text_color)
            end
        end
    end

    -- Draw grid lines
    for i = 0, 9 do
        local thickness = (i % 3 == 0) and 2 or 1
        local color = (i % 3 == 0) and 0x0000 or 0x8410

        -- Vertical
        local vx = self.GRID_X + i * self.CELL_SIZE
        for t = 0, thickness - 1 do
            display.draw_line(vx + t, self.GRID_Y, vx + t, self.GRID_Y + grid_size, color)
        end

        -- Horizontal
        local hy = self.GRID_Y + i * self.CELL_SIZE
        for t = 0, thickness - 1 do
            display.draw_line(self.GRID_X, hy + t, self.GRID_X + grid_size, hy + t, color)
        end
    end

    -- Number selector on right side
    local sel_x = self.GRID_X + grid_size + 15
    display.draw_text(sel_x, self.GRID_Y, "Num:", colors.TEXT_SECONDARY)
    for n = 1, 9 do
        local ny = self.GRID_Y + 15 + (n - 1) * 18
        local is_sel = (n == self.selected_num)
        if is_sel then
            display.fill_rect(sel_x - 2, ny - 2, 20, 16, colors.ACCENT)
            display.draw_text(sel_x + 4, ny, tostring(n), 0xFFFF)
        else
            display.draw_text(sel_x + 4, ny, tostring(n), colors.WHITE)
        end
    end

    -- Win message
    if self.won then
        display.fill_rect(60, 90, 200, 50, 0x0000)
        display.draw_text_centered(100, "You Win!", colors.SUCCESS)
        display.draw_text_centered(120, "[R] New Game [Q] Quit", colors.TEXT_SECONDARY)
    else
        display.draw_text(5, 227, "[Arrows]Move [1-9]Place [0/Del]Clear [R]eset", colors.TEXT_SECONDARY)
    end
end

function Sudoku:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        self:on_exit()
        return "pop"
    end

    if key.character == "r" then
        self:new_game()
        ScreenManager.invalidate()
        return "continue"
    end

    if self.won then return "continue" end

    if key.special == "UP" then
        self.cursor_y = self.cursor_y > 1 and self.cursor_y - 1 or 9
    elseif key.special == "DOWN" then
        self.cursor_y = self.cursor_y < 9 and self.cursor_y + 1 or 1
    elseif key.special == "LEFT" then
        self.cursor_x = self.cursor_x > 1 and self.cursor_x - 1 or 9
    elseif key.special == "RIGHT" then
        self.cursor_x = self.cursor_x < 9 and self.cursor_x + 1 or 1
    elseif key.character and key.character >= "1" and key.character <= "9" then
        local num = tonumber(key.character)
        self.selected_num = num
        self:place_number(num)
    elseif key.character == "0" or key.special == "BACKSPACE" then
        self:place_number(0)
    elseif key.special == "ENTER" then
        self:place_number(self.selected_num)
    end

    ScreenManager.invalidate()
    return "continue"
end

return Sudoku
