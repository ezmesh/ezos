-- 2048 Game for T-Deck OS
-- Slide tiles to combine matching numbers

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local Game2048 = {
    title = "2048",
    GRID_SIZE = 4,
    CELL_SIZE = 40,
    CELL_GAP = 3,
}

-- Tile colors (RGB565)
local TILE_COLORS = {
    [0]    = 0xCE59,  -- Empty
    [2]    = 0xEF5D,  -- Light
    [4]    = 0xEF1C,
    [8]    = 0xFD20,  -- Orange
    [16]   = 0xFC00,
    [32]   = 0xFB00,  -- Red-orange
    [64]   = 0xF800,  -- Red
    [128]  = 0xEF00,  -- Yellow
    [256]  = 0xEF20,
    [512]  = 0xEF40,
    [1024] = 0xEF60,
    [2048] = 0xEFC0,  -- Gold
}

local TILE_TEXT_COLORS = {
    [0]    = 0x0000,
    [2]    = 0x6B4D,  -- Dark
    [4]    = 0x6B4D,
    [8]    = 0xFFFF,  -- White for dark tiles
    [16]   = 0xFFFF,
    [32]   = 0xFFFF,
    [64]   = 0xFFFF,
    [128]  = 0xFFFF,
    [256]  = 0xFFFF,
    [512]  = 0xFFFF,
    [1024] = 0xFFFF,
    [2048] = 0xFFFF,
}

function Game2048:new()
    local o = {
        grid = {},
        score = 0,
        best_score = 0,
        game_over = false,
        won = false,
        continue_playing = false,
        GRID_X = 0,
        GRID_Y = 0,
    }
    setmetatable(o, {__index = Game2048})
    return o
end

function Game2048:on_enter()
    if _G.MainLoop then _G.MainLoop.enter_game_mode() end

    -- Center grid
    local grid_pixels = self.GRID_SIZE * self.CELL_SIZE + (self.GRID_SIZE + 1) * self.CELL_GAP
    self.GRID_X = math.floor((320 - grid_pixels) / 2)
    self.GRID_Y = 28

    -- Load best score
    if ez.storage and ez.storage.get_pref then
        self.best_score = ez.storage.get_pref("2048_best", 0)
    end

    self:reset_game()
end

function Game2048:on_exit()
    if _G.MainLoop then _G.MainLoop.exit_game_mode() end
    -- Save best score
    if ez.storage and ez.storage.set_pref and self.score > self.best_score then
        ez.storage.set_pref("2048_best", self.score)
    end
end

function Game2048:reset_game()
    self.grid = {}
    for y = 1, self.GRID_SIZE do
        self.grid[y] = {}
        for x = 1, self.GRID_SIZE do
            self.grid[y][x] = 0
        end
    end
    self.score = 0
    self.game_over = false
    self.won = false
    self.continue_playing = false

    -- Add two starting tiles
    self:add_random_tile()
    self:add_random_tile()
end

function Game2048:add_random_tile()
    local empty = {}
    for y = 1, self.GRID_SIZE do
        for x = 1, self.GRID_SIZE do
            if self.grid[y][x] == 0 then
                table.insert(empty, {x = x, y = y})
            end
        end
    end

    if #empty > 0 then
        local cell = empty[math.random(#empty)]
        self.grid[cell.y][cell.x] = math.random() < 0.9 and 2 or 4
    end
end

function Game2048:slide_row(row)
    -- Remove zeros
    local tiles = {}
    for _, v in ipairs(row) do
        if v ~= 0 then table.insert(tiles, v) end
    end

    -- Merge
    local merged = {}
    local i = 1
    while i <= #tiles do
        if tiles[i + 1] and tiles[i] == tiles[i + 1] then
            local new_val = tiles[i] * 2
            table.insert(merged, new_val)
            self.score = self.score + new_val
            if new_val == 2048 and not self.continue_playing then
                self.won = true
            end
            i = i + 2
        else
            table.insert(merged, tiles[i])
            i = i + 1
        end
    end

    -- Pad with zeros
    while #merged < self.GRID_SIZE do
        table.insert(merged, 0)
    end

    return merged
end

function Game2048:move(direction)
    if self.game_over then return false end

    local old_grid = {}
    for y = 1, self.GRID_SIZE do
        old_grid[y] = {}
        for x = 1, self.GRID_SIZE do
            old_grid[y][x] = self.grid[y][x]
        end
    end

    if direction == "LEFT" then
        for y = 1, self.GRID_SIZE do
            self.grid[y] = self:slide_row(self.grid[y])
        end
    elseif direction == "RIGHT" then
        for y = 1, self.GRID_SIZE do
            local row = {}
            for x = self.GRID_SIZE, 1, -1 do
                table.insert(row, self.grid[y][x])
            end
            row = self:slide_row(row)
            for x = 1, self.GRID_SIZE do
                self.grid[y][x] = row[self.GRID_SIZE - x + 1]
            end
        end
    elseif direction == "UP" then
        for x = 1, self.GRID_SIZE do
            local col = {}
            for y = 1, self.GRID_SIZE do
                table.insert(col, self.grid[y][x])
            end
            col = self:slide_row(col)
            for y = 1, self.GRID_SIZE do
                self.grid[y][x] = col[y]
            end
        end
    elseif direction == "DOWN" then
        for x = 1, self.GRID_SIZE do
            local col = {}
            for y = self.GRID_SIZE, 1, -1 do
                table.insert(col, self.grid[y][x])
            end
            col = self:slide_row(col)
            for y = 1, self.GRID_SIZE do
                self.grid[y][x] = col[self.GRID_SIZE - y + 1]
            end
        end
    end

    -- Check if grid changed
    local changed = false
    for y = 1, self.GRID_SIZE do
        for x = 1, self.GRID_SIZE do
            if old_grid[y][x] ~= self.grid[y][x] then
                changed = true
                break
            end
        end
        if changed then break end
    end

    if changed then
        self:add_random_tile()
        self:check_game_over()
        if self.score > self.best_score then
            self.best_score = self.score
        end
    end

    return changed
end

function Game2048:check_game_over()
    -- Check for empty cells
    for y = 1, self.GRID_SIZE do
        for x = 1, self.GRID_SIZE do
            if self.grid[y][x] == 0 then return end
        end
    end

    -- Check for possible merges
    for y = 1, self.GRID_SIZE do
        for x = 1, self.GRID_SIZE do
            local val = self.grid[y][x]
            if x < self.GRID_SIZE and self.grid[y][x + 1] == val then return end
            if y < self.GRID_SIZE and self.grid[y + 1][x] == val then return end
        end
    end

    self.game_over = true
end

function Game2048:render(display)
    local colors = ListMixin.get_colors(display)

    display.fill_rect(0, 0, 320, 240, colors.BLACK)

    -- Header
    display.set_font_size("small")
    display.draw_text(10, 5, "2048", colors.ACCENT)
    display.draw_text(70, 5, string.format("Score: %d", self.score), colors.WHITE)
    display.draw_text(180, 5, string.format("Best: %d", self.best_score), colors.TEXT_SECONDARY)

    -- Draw grid background
    local grid_pixels = self.GRID_SIZE * self.CELL_SIZE + (self.GRID_SIZE + 1) * self.CELL_GAP
    display.fill_round_rect(self.GRID_X - 2, self.GRID_Y - 2, grid_pixels + 4, grid_pixels + 4, 6, 0x9CD3)

    -- Draw tiles
    for y = 1, self.GRID_SIZE do
        for x = 1, self.GRID_SIZE do
            local val = self.grid[y][x]
            local px = self.GRID_X + self.CELL_GAP + (x - 1) * (self.CELL_SIZE + self.CELL_GAP)
            local py = self.GRID_Y + self.CELL_GAP + (y - 1) * (self.CELL_SIZE + self.CELL_GAP)

            local bg = TILE_COLORS[val] or TILE_COLORS[2048]
            display.fill_round_rect(px, py, self.CELL_SIZE, self.CELL_SIZE, 4, bg)

            if val > 0 then
                local text = tostring(val)
                local tc = TILE_TEXT_COLORS[val] or 0xFFFF
                local text_w = #text * 7
                local tx = math.floor(px + (self.CELL_SIZE - text_w) / 2)
                local ty = math.floor(py + (self.CELL_SIZE - 14) / 2)
                if val >= 1000 then
                    display.set_font_size("small")
                    text_w = #text * 6
                    tx = math.floor(px + (self.CELL_SIZE - text_w) / 2)
                    ty = math.floor(py + (self.CELL_SIZE - 10) / 2)
                else
                    display.set_font_size("medium")
                end
                display.draw_text(tx, ty, text, tc)
            end
        end
    end

    display.set_font_size("small")

    -- Game over / win message
    if self.won and not self.continue_playing then
        display.fill_rect(40, 90, 240, 60, 0x0000)
        display.draw_text_centered(100, "You Win!", colors.SUCCESS)
        display.draw_text_centered(120, "[C] Continue [R] Restart", colors.TEXT_SECONDARY)
    elseif self.game_over then
        display.fill_rect(40, 90, 240, 60, 0x0000)
        display.draw_text_centered(100, "Game Over!", colors.ERROR)
        display.draw_text_centered(120, "[R] Restart [Q] Quit", colors.TEXT_SECONDARY)
    else
        display.draw_text(10, 225, "[Arrows] Move [R]estart [Q]uit", colors.TEXT_SECONDARY)
    end
end

function Game2048:handle_key(key)
    if self.won and not self.continue_playing then
        if key.character == "c" then
            self.continue_playing = true
            ScreenManager.invalidate()
            return "continue"
        elseif key.character == "r" then
            self:reset_game()
            ScreenManager.invalidate()
            return "continue"
        end
    end

    if key.special == "UP" or key.character == "w" then
        self:move("UP")
        ScreenManager.invalidate()
    elseif key.special == "DOWN" or key.character == "s" then
        self:move("DOWN")
        ScreenManager.invalidate()
    elseif key.special == "LEFT" or key.character == "a" then
        self:move("LEFT")
        ScreenManager.invalidate()
    elseif key.special == "RIGHT" or key.character == "d" then
        self:move("RIGHT")
        ScreenManager.invalidate()
    elseif key.character == "r" then
        self:reset_game()
        ScreenManager.invalidate()
    elseif key.special == "ESCAPE" or key.character == "q" then
        self:on_exit()
        return "pop"
    end

    return "continue"
end

return Game2048
