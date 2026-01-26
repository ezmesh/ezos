-- Snake Game for T-Deck OS
-- Classic snake game with square playfield and polished graphics

local Snake = {
    title = "Snake",
    -- Game constants (set in on_enter based on display)
    CELL_SIZE = 10,
    GRID_SIZE = 0,  -- Square grid, calculated in on_enter
    GRID_X = 0,
    GRID_Y = 0,
}

function Snake:new()
    local o = {
        snake = {},
        food = {x = 0, y = 0},
        direction = "RIGHT",
        next_direction = "RIGHT",
        game_over = false,
        paused = false,
        score = 0,
        speed = 150,  -- ms between moves
        speed_min = 50,
        speed_decrease = 5,
        last_move = 0,
        -- Grid dimensions (set in on_enter)
        CELL_SIZE = 10,
        GRID_SIZE = 0,
        GRID_X = 0,
        GRID_Y = 0,
    }
    setmetatable(o, {__index = Snake})
    return o
end

function Snake:on_enter()
    -- Enter game mode (disables GC, slows mesh, hides status bar)
    if _G.MainLoop then _G.MainLoop.enter_game_mode() end

    -- Calculate square playfield based on display size
    local h = tdeck.display.height
    local w = tdeck.display.width

    -- Use height as the constraint for square grid, leave room for score
    local available_h = h - 40  -- Reserve space for score and help text
    self.GRID_SIZE = math.floor(available_h / self.CELL_SIZE)
    if self.GRID_SIZE > 20 then self.GRID_SIZE = 20 end  -- Max 20x20
    if self.GRID_SIZE < 10 then self.GRID_SIZE = 10 end  -- Min 10x10

    -- Center the grid horizontally
    local grid_pixels = self.GRID_SIZE * self.CELL_SIZE
    self.GRID_X = math.floor((w - grid_pixels) / 2)
    self.GRID_Y = 25  -- Below score

    self:reset_game()
end

function Snake:on_exit()
    -- Exit game mode
    if _G.MainLoop then _G.MainLoop.exit_game_mode() end
end

function Snake:reset_game()
    self.snake = {}

    -- Start snake in the middle, length 3
    local start_x = math.floor(self.GRID_SIZE / 2)
    local start_y = math.floor(self.GRID_SIZE / 2)
    table.insert(self.snake, {x = start_x, y = start_y})
    table.insert(self.snake, {x = start_x - 1, y = start_y})
    table.insert(self.snake, {x = start_x - 2, y = start_y})

    self.direction = "RIGHT"
    self.next_direction = "RIGHT"
    self.game_over = false
    self.paused = false
    self.score = 0
    self.speed = 150
    self.last_move = tdeck.system.millis()

    self:spawn_food()
end

function Snake:spawn_food()
    local max_attempts = 100
    while max_attempts > 0 do
        self.food.x = math.random(0, self.GRID_SIZE - 1)
        self.food.y = math.random(0, self.GRID_SIZE - 1)

        -- Check if position is free
        local occupied = false
        for _, seg in ipairs(self.snake) do
            if seg.x == self.food.x and seg.y == self.food.y then
                occupied = true
                break
            end
        end

        if not occupied then
            return
        end

        max_attempts = max_attempts - 1
    end
end

function Snake:check_collision(pos)
    -- Self collision (skip head)
    for i = 2, #self.snake do
        if self.snake[i].x == pos.x and self.snake[i].y == pos.y then
            return true
        end
    end
    return false
end

function Snake:move_snake()
    -- Apply buffered direction change
    self.direction = self.next_direction

    -- Calculate new head position
    local new_head = {x = self.snake[1].x, y = self.snake[1].y}

    if self.direction == "UP" then
        new_head.y = new_head.y - 1
    elseif self.direction == "DOWN" then
        new_head.y = new_head.y + 1
    elseif self.direction == "LEFT" then
        new_head.x = new_head.x - 1
    elseif self.direction == "RIGHT" then
        new_head.x = new_head.x + 1
    end

    -- Wrap around walls
    if new_head.x < 0 then new_head.x = self.GRID_SIZE - 1 end
    if new_head.x >= self.GRID_SIZE then new_head.x = 0 end
    if new_head.y < 0 then new_head.y = self.GRID_SIZE - 1 end
    if new_head.y >= self.GRID_SIZE then new_head.y = 0 end

    -- Check for self collision
    if self:check_collision(new_head) then
        self.game_over = true
        return
    end

    -- Add new head
    table.insert(self.snake, 1, new_head)

    -- Check if eating food
    if new_head.x == self.food.x and new_head.y == self.food.y then
        self.score = self.score + 10
        -- Speed up
        if self.speed > self.speed_min + self.speed_decrease then
            self.speed = self.speed - self.speed_decrease
        else
            self.speed = self.speed_min
        end
        self:spawn_food()
        -- Don't remove tail - snake grows
    else
        -- Remove tail
        table.remove(self.snake)
    end
end

function Snake:update()
    if self.game_over or self.paused then
        return
    end

    local now = tdeck.system.millis()
    if now - self.last_move >= self.speed then
        self.last_move = now
        self:move_snake()
        ScreenManager.invalidate()
    end
end

function Snake:draw_cell(display, x, y, color, is_head)
    local px = self.GRID_X + x * self.CELL_SIZE
    local py = self.GRID_Y + y * self.CELL_SIZE
    local size = self.CELL_SIZE - 1

    if is_head then
        -- Draw head with rounded corners effect
        display.fill_rect(px, py, size, size, color)
        -- Inner highlight
        display.fill_rect(px + 2, py + 2, size - 4, size - 4, 0xFFFF)
    else
        -- Body segments with slight inner shadow
        display.fill_rect(px, py, size, size, color)
        display.fill_rect(px + 1, py + 1, size - 2, size - 2, 0x07E0)  -- Lighter green inside
    end
end

function Snake:draw_food(display, x, y)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local px = self.GRID_X + x * self.CELL_SIZE
    local py = self.GRID_Y + y * self.CELL_SIZE
    local size = self.CELL_SIZE - 1

    -- Draw apple with highlight
    display.fill_rect(px, py, size, size, colors.RED)
    -- Stem
    display.fill_rect(px + math.floor(size/2), py - 1, 2, 2, 0x0400)  -- Dark green stem
    -- Highlight
    display.fill_rect(px + 2, py + 2, 2, 2, 0xFD20)  -- Orange highlight
end

function Snake:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Update game state
    self:update()

    -- Black background (no wallpaper for games - faster)
    display.fill_rect(0, 0, display.width, display.height, colors.BLACK)

    -- Score at top
    local score_text = string.format("Score: %d", self.score)
    display.draw_text(10, 5, score_text, colors.WHITE)

    -- Speed indicator
    local speed_text = string.format("Speed: %d", 200 - self.speed)
    display.draw_text(display.width - 80, 5, speed_text, colors.TEXT_DIM)

    -- Draw grid border
    local grid_w = self.GRID_SIZE * self.CELL_SIZE
    display.draw_rect(self.GRID_X - 1, self.GRID_Y - 1, grid_w + 2, grid_w + 2, colors.DARK_GRAY)

    -- Draw subtle grid background
    for y = 0, self.GRID_SIZE - 1 do
        for x = 0, self.GRID_SIZE - 1 do
            if (x + y) % 2 == 0 then
                local px = self.GRID_X + x * self.CELL_SIZE
                local py = self.GRID_Y + y * self.CELL_SIZE
                display.fill_rect(px, py, self.CELL_SIZE - 1, self.CELL_SIZE - 1, 0x0841)
            end
        end
    end

    -- Draw food
    self:draw_food(display, self.food.x, self.food.y)

    -- Draw snake
    for i, seg in ipairs(self.snake) do
        local is_head = (i == 1)
        local color = is_head and colors.CYAN or 0x07C0  -- Cyan head, green body
        self:draw_cell(display, seg.x, seg.y, color, is_head)
    end

    -- Draw game over or pause message
    if self.game_over then
        -- Semi-transparent overlay
        local msg_y = display.height / 2 - 20
        display.fill_rect(0, msg_y - 10, display.width, 60, 0x0000)
        display.draw_text_centered(msg_y, "GAME OVER!", colors.RED)
        display.draw_text_centered(msg_y + 20, "[Enter] Restart  [Q] Quit", colors.TEXT_DIM)
    elseif self.paused then
        local msg_y = display.height / 2 - 10
        display.fill_rect(0, msg_y - 10, display.width, 40, 0x0000)
        display.draw_text_centered(msg_y, "PAUSED", colors.CYAN)
        display.draw_text_centered(msg_y + 20, "[P] Resume  [Q] Quit", colors.TEXT_DIM)
    else
        -- Help bar at bottom
        display.draw_text(10, display.height - 15,
                        "[Arrows/WASD] Move [P]ause [Q]uit", colors.TEXT_DIM)
    end

    -- Request continuous redraws for animation
    if not self.game_over and not self.paused then
        ScreenManager.invalidate()
    end
end

function Snake:handle_key(key)
    if key.special == "UP" or key.character == "w" then
        if self.direction ~= "DOWN" then
            self.next_direction = "UP"
        end
    elseif key.special == "DOWN" or key.character == "s" then
        if self.direction ~= "UP" then
            self.next_direction = "DOWN"
        end
    elseif key.special == "LEFT" or key.character == "a" then
        if self.direction ~= "RIGHT" then
            self.next_direction = "LEFT"
        end
    elseif key.special == "RIGHT" or key.character == "d" then
        if self.direction ~= "LEFT" then
            self.next_direction = "RIGHT"
        end
    elseif key.special == "ENTER" then
        if self.game_over then
            collectgarbage("collect")  -- Clean up before restart
            self:reset_game()
            ScreenManager.invalidate()
        end
    elseif key.special == "ESCAPE" or key.character == "q" then
        self:on_exit()
        return "pop"
    elseif key.character == "p" then
        self.paused = not self.paused
        ScreenManager.invalidate()
    end

    return "continue"
end

return Snake
