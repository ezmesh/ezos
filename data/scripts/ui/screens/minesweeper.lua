-- Minesweeper for T-Deck OS
-- Classic mine-finding puzzle game

local Minesweeper = {
    title = "Minesweeper",
    CELL_SIZE = 16,
}

-- Number colors
local NUM_COLORS = {
    [1] = 0x001F,  -- Blue
    [2] = 0x07E0,  -- Green
    [3] = 0xF800,  -- Red
    [4] = 0x000F,  -- Dark blue
    [5] = 0x8000,  -- Maroon
    [6] = 0x07FF,  -- Cyan
    [7] = 0x0000,  -- Black
    [8] = 0x8410,  -- Gray
}

function Minesweeper:new()
    local o = {
        grid = {},
        revealed = {},
        flagged = {},
        cursor_x = 1,
        cursor_y = 1,
        width = 16,
        height = 12,
        mines = 30,
        game_over = false,
        won = false,
        first_click = true,
        time_start = 0,
        time_elapsed = 0,
        GRID_X = 0,
        GRID_Y = 0,
    }
    setmetatable(o, {__index = Minesweeper})
    return o
end

function Minesweeper:on_enter()
    if _G.MainLoop then _G.MainLoop.enter_game_mode() end

    -- Center grid
    local grid_w = self.width * self.CELL_SIZE
    local grid_h = self.height * self.CELL_SIZE
    self.GRID_X = math.floor((320 - grid_w) / 2)
    self.GRID_Y = 30

    self:reset_game()
end

function Minesweeper:on_exit()
    if _G.MainLoop then _G.MainLoop.exit_game_mode() end
end

function Minesweeper:reset_game()
    self.grid = {}
    self.revealed = {}
    self.flagged = {}

    for y = 1, self.height do
        self.grid[y] = {}
        self.revealed[y] = {}
        self.flagged[y] = {}
        for x = 1, self.width do
            self.grid[y][x] = 0
            self.revealed[y][x] = false
            self.flagged[y][x] = false
        end
    end

    self.game_over = false
    self.won = false
    self.first_click = true
    self.time_start = 0
    self.time_elapsed = 0
    self.cursor_x = math.floor(self.width / 2)
    self.cursor_y = math.floor(self.height / 2)
end

function Minesweeper:place_mines(safe_x, safe_y)
    local placed = 0
    while placed < self.mines do
        local x = math.random(1, self.width)
        local y = math.random(1, self.height)

        -- Don't place mine on or adjacent to first click
        local safe = math.abs(x - safe_x) > 1 or math.abs(y - safe_y) > 1

        if safe and self.grid[y][x] ~= -1 then
            self.grid[y][x] = -1
            placed = placed + 1
        end
    end

    -- Calculate numbers
    for y = 1, self.height do
        for x = 1, self.width do
            if self.grid[y][x] ~= -1 then
                local count = 0
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        local nx, ny = x + dx, y + dy
                        if nx >= 1 and nx <= self.width and ny >= 1 and ny <= self.height then
                            if self.grid[ny][nx] == -1 then
                                count = count + 1
                            end
                        end
                    end
                end
                self.grid[y][x] = count
            end
        end
    end
end

function Minesweeper:reveal(x, y)
    if x < 1 or x > self.width or y < 1 or y > self.height then return end
    if self.revealed[y][x] or self.flagged[y][x] then return end

    self.revealed[y][x] = true

    if self.grid[y][x] == -1 then
        self.game_over = true
        -- Reveal all mines
        for ry = 1, self.height do
            for rx = 1, self.width do
                if self.grid[ry][rx] == -1 then
                    self.revealed[ry][rx] = true
                end
            end
        end
        return
    end

    -- Flood fill for empty cells
    if self.grid[y][x] == 0 then
        for dy = -1, 1 do
            for dx = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    self:reveal(x + dx, y + dy)
                end
            end
        end
    end

    self:check_win()
end

function Minesweeper:check_win()
    for y = 1, self.height do
        for x = 1, self.width do
            if self.grid[y][x] ~= -1 and not self.revealed[y][x] then
                return
            end
        end
    end
    self.won = true
    self.game_over = true
end

function Minesweeper:count_flags()
    local count = 0
    for y = 1, self.height do
        for x = 1, self.width do
            if self.flagged[y][x] then
                count = count + 1
            end
        end
    end
    return count
end

function Minesweeper:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local now = ez.system.millis()

    if not self.game_over and not self.first_click then
        self.time_elapsed = math.floor((now - self.time_start) / 1000)
    end

    display.fill_rect(0, 0, 320, 240, colors.BLACK)

    -- Header
    display.set_font_size("small")
    local flags_left = self.mines - self:count_flags()
    display.draw_text(10, 5, string.format("Mines: %d", flags_left), colors.ERROR)
    display.draw_text(130, 5, "MINESWEEPER", colors.WHITE)
    display.draw_text(260, 5, string.format("Time: %d", self.time_elapsed), colors.ACCENT)

    -- Draw grid
    for y = 1, self.height do
        for x = 1, self.width do
            local px = self.GRID_X + (x - 1) * self.CELL_SIZE
            local py = self.GRID_Y + (y - 1) * self.CELL_SIZE
            local is_cursor = (x == self.cursor_x and y == self.cursor_y)

            if self.revealed[y][x] then
                -- Revealed cell
                display.fill_rect(px, py, self.CELL_SIZE - 1, self.CELL_SIZE - 1, 0xC618)

                local val = self.grid[y][x]
                if val == -1 then
                    -- Mine
                    display.fill_circle(px + 7, py + 7, 5, 0x0000)
                    if is_cursor then
                        display.draw_rect(px, py, self.CELL_SIZE - 1, self.CELL_SIZE - 1, colors.ERROR)
                    end
                elseif val > 0 then
                    -- Number
                    local nc = NUM_COLORS[val] or colors.WHITE
                    display.draw_text(px + 4, py + 2, tostring(val), nc)
                end
            else
                -- Unrevealed cell
                display.fill_rect(px, py, self.CELL_SIZE - 1, self.CELL_SIZE - 1, 0x8410)
                display.draw_line(px, py, px + self.CELL_SIZE - 2, py, 0xC618)
                display.draw_line(px, py, px, py + self.CELL_SIZE - 2, 0xC618)

                if self.flagged[y][x] then
                    -- Flag
                    display.fill_triangle(px + 4, py + 3, px + 4, py + 10, px + 11, py + 6, colors.ERROR)
                    display.fill_rect(px + 3, py + 10, 2, 3, 0x0000)
                end
            end

            -- Cursor highlight
            if is_cursor then
                display.draw_rect(px - 1, py - 1, self.CELL_SIZE + 1, self.CELL_SIZE + 1, colors.ACCENT)
            end
        end
    end

    -- Game over message
    if self.game_over then
        display.fill_rect(60, 100, 200, 50, 0x0000)
        if self.won then
            display.draw_text_centered(110, "You Win!", colors.SUCCESS)
        else
            display.draw_text_centered(110, "Game Over!", colors.ERROR)
        end
        display.draw_text_centered(130, "[R] Restart [Q] Quit", colors.TEXT_SECONDARY)
    else
        display.draw_text(10, 225, "[Arrows]Move [Enter]Reveal [F]lag [R]eset", colors.TEXT_SECONDARY)
    end

    -- Keep updating for timer
    if not self.game_over and not self.first_click then
        ScreenManager.invalidate()
    end
end

function Minesweeper:handle_key(key)
    if key.special == "UP" or key.character == "w" then
        if self.cursor_y > 1 then self.cursor_y = self.cursor_y - 1 end
        ScreenManager.invalidate()
    elseif key.special == "DOWN" or key.character == "s" then
        if self.cursor_y < self.height then self.cursor_y = self.cursor_y + 1 end
        ScreenManager.invalidate()
    elseif key.special == "LEFT" or key.character == "a" then
        if self.cursor_x > 1 then self.cursor_x = self.cursor_x - 1 end
        ScreenManager.invalidate()
    elseif key.special == "RIGHT" or key.character == "d" then
        if self.cursor_x < self.width then self.cursor_x = self.cursor_x + 1 end
        ScreenManager.invalidate()
    elseif key.special == "ENTER" or key.character == " " then
        if not self.game_over then
            if self.first_click then
                self.first_click = false
                self.time_start = ez.system.millis()
                self:place_mines(self.cursor_x, self.cursor_y)
            end
            self:reveal(self.cursor_x, self.cursor_y)
            ScreenManager.invalidate()
        end
    elseif key.character == "f" then
        if not self.game_over and not self.revealed[self.cursor_y][self.cursor_x] then
            self.flagged[self.cursor_y][self.cursor_x] = not self.flagged[self.cursor_y][self.cursor_x]
            ScreenManager.invalidate()
        end
    elseif key.character == "r" then
        self:reset_game()
        ScreenManager.invalidate()
    elseif key.special == "ESCAPE" or key.character == "q" then
        self:on_exit()
        return "pop"
    end

    return "continue"
end

return Minesweeper
