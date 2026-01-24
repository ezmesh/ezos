-- Snake Game for T-Deck OS
-- Classic snake game implementation

local Snake = {
    title = "Snake",
    -- Game area dimensions (in character cells)
    game_x = 1,
    game_y = 2,
    game_width = 38,
    game_height = 10,
    -- Game state
    snake = {},
    food = {x = 0, y = 0},
    direction = "RIGHT",
    next_direction = "RIGHT",
    game_over = false,
    paused = false,
    score = 0,
    speed = 200,  -- ms between moves
    speed_min = 50,
    speed_decrease = 5,
    last_move = 0
}

function Snake:new()
    local o = {
        title = self.title,
        game_x = self.game_x,
        game_y = self.game_y,
        game_width = self.game_width,
        game_height = self.game_height,
        snake = {},
        food = {x = 0, y = 0},
        direction = "RIGHT",
        next_direction = "RIGHT",
        game_over = false,
        paused = false,
        score = 0,
        speed = 200,
        last_move = 0
    }
    setmetatable(o, {__index = Snake})
    return o
end

function Snake:on_enter()
    self:reset_game()
end

function Snake:reset_game()
    self.snake = {}

    -- Start snake in the middle, length 3
    local start_x = math.floor(self.game_width / 2)
    local start_y = math.floor(self.game_height / 2)
    table.insert(self.snake, {x = start_x, y = start_y})
    table.insert(self.snake, {x = start_x - 1, y = start_y})
    table.insert(self.snake, {x = start_x - 2, y = start_y})

    self.direction = "RIGHT"
    self.next_direction = "RIGHT"
    self.game_over = false
    self.paused = false
    self.score = 0
    self.speed = 200
    self.last_move = tdeck.system.millis()

    self:spawn_food()
end

function Snake:spawn_food()
    local max_attempts = 100
    while max_attempts > 0 do
        self.food.x = math.random(0, self.game_width - 1)
        self.food.y = math.random(0, self.game_height - 1)

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
    if new_head.x < 0 then new_head.x = self.game_width - 1 end
    if new_head.x >= self.game_width then new_head.x = 0 end
    if new_head.y < 0 then new_head.y = self.game_height - 1 end
    if new_head.y >= self.game_height then new_head.y = 0 end

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
        tdeck.screen.invalidate()
    end
end

function Snake:draw_cell(display, x, y, color)
    local px = (self.game_x + x) * display.font_width
    local py = (self.game_y + y) * display.font_height
    display.fill_rect(px, py, display.font_width, display.font_height, color)
end

function Snake:render(display)
    local colors = display.colors

    -- Update game state
    self:update()

    -- Draw border
    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    -- Draw score
    local score_text = string.format("Score: %d", self.score)
    display.draw_text((display.cols - 12) * display.font_width, display.font_height,
                     score_text, colors.TEXT_DIM)

    -- Draw game area background (subtle checkerboard)
    for y = 0, self.game_height - 1 do
        for x = 0, self.game_width - 1 do
            if (x + y) % 2 == 0 then
                self:draw_cell(display, x, y, 0x0841)  -- Very dark green
            end
        end
    end

    -- Draw food
    self:draw_cell(display, self.food.x, self.food.y, colors.RED)

    -- Draw snake
    for i, seg in ipairs(self.snake) do
        local color = (i == 1) and colors.CYAN or colors.TEXT
        self:draw_cell(display, seg.x, seg.y, color)
    end

    -- Draw game over or pause message
    if self.game_over then
        display.draw_text_centered(7 * display.font_height, "GAME OVER!", colors.RED)
        display.draw_text_centered(9 * display.font_height, "[Enter] Restart  [Q] Quit", colors.TEXT_DIM)
    elseif self.paused then
        display.draw_text_centered(7 * display.font_height, "PAUSED", colors.CYAN)
        display.draw_text_centered(9 * display.font_height, "[P] Resume  [Q] Quit", colors.TEXT_DIM)
    else
        -- Help bar
        display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                        "[Arrows/WASD] Move [P]ause [Q]uit", colors.TEXT_DIM)
    end

    -- Request continuous redraws for animation
    if not self.game_over and not self.paused then
        tdeck.screen.invalidate()
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
            self:reset_game()
            tdeck.screen.invalidate()
        end
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "p" then
        self.paused = not self.paused
        tdeck.screen.invalidate()
    end

    return "continue"
end

return Snake
