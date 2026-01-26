-- Breakout Game for T-Deck OS

local Breakout = {
    title = "Breakout",
}

local BRICK_ROWS = 5
local BRICK_COLS = 10
local BRICK_W = 28
local BRICK_H = 10
local BRICK_GAP = 2

local PADDLE_W = 50
local PADDLE_H = 8
local BALL_SIZE = 6

local COLORS = {0xF800, 0xFD20, 0xFFE0, 0x07E0, 0x07FF}  -- Red, Orange, Yellow, Green, Cyan

function Breakout:new()
    local o = {
        paddle_x = 0,
        paddle_vx = 0,  -- Paddle velocity for momentum
        ball_x = 0,
        ball_y = 0,
        ball_dx = 0,
        ball_dy = 0,
        bricks = {},
        score = 0,
        lives = 3,
        game_over = false,
        won = false,
        ball_stuck = true,  -- Ball stuck to paddle at start
        last_update = 0,
    }
    setmetatable(o, {__index = Breakout})
    return o
end

function Breakout:on_enter()
    -- Enter game mode (disables GC, slows mesh, hides status bar)
    if _G.MainLoop then _G.MainLoop.enter_game_mode() end
    self:reset_level()
end

function Breakout:on_exit()
    -- Exit game mode
    if _G.MainLoop then _G.MainLoop.exit_game_mode() end
end

function Breakout:reset_level()
    local w = tdeck.display.width

    -- Initialize bricks
    self.bricks = {}
    local start_x = (w - (BRICK_COLS * (BRICK_W + BRICK_GAP))) / 2
    local start_y = 30

    for row = 1, BRICK_ROWS do
        for col = 1, BRICK_COLS do
            local brick = {
                x = start_x + (col - 1) * (BRICK_W + BRICK_GAP),
                y = start_y + (row - 1) * (BRICK_H + BRICK_GAP),
                color = COLORS[row],
                alive = true,
                points = (BRICK_ROWS - row + 1) * 10,
            }
            self.bricks[#self.bricks + 1] = brick
        end
    end

    self:reset_ball()
end

function Breakout:reset_ball()
    local w = tdeck.display.width
    local h = tdeck.display.height

    self.paddle_x = (w - PADDLE_W) / 2
    self.ball_stuck = true
    self.ball_x = self.paddle_x + PADDLE_W / 2 - BALL_SIZE / 2
    self.ball_y = h - 40 - BALL_SIZE
    self.ball_dx = 3
    self.ball_dy = -3
    self.last_update = tdeck.system.millis()
end

function Breakout:launch_ball()
    if self.ball_stuck then
        self.ball_stuck = false
        -- Random angle
        self.ball_dx = (math.random() > 0.5) and 3 or -3
        self.ball_dy = -3
    end
end

function Breakout:count_bricks()
    local count = 0
    for _, brick in ipairs(self.bricks) do
        if brick.alive then count = count + 1 end
    end
    return count
end

function Breakout:update_physics()
    if self.game_over or self.won then return end

    local w = tdeck.display.width
    local h = tdeck.display.height

    -- Update paddle with momentum
    self.paddle_x = self.paddle_x + self.paddle_vx
    self.paddle_vx = self.paddle_vx * 0.85  -- Friction

    -- Clamp paddle to screen
    if self.paddle_x < 0 then
        self.paddle_x = 0
        self.paddle_vx = 0
    elseif self.paddle_x > w - PADDLE_W then
        self.paddle_x = w - PADDLE_W
        self.paddle_vx = 0
    end

    -- Move ball with paddle if stuck
    if self.ball_stuck then
        self.ball_x = self.paddle_x + PADDLE_W / 2 - BALL_SIZE / 2
        return
    end

    -- Move ball
    self.ball_x = self.ball_x + self.ball_dx
    self.ball_y = self.ball_y + self.ball_dy

    -- Wall collisions
    if self.ball_x <= 0 then
        self.ball_x = 0
        self.ball_dx = -self.ball_dx
    elseif self.ball_x >= w - BALL_SIZE then
        self.ball_x = w - BALL_SIZE
        self.ball_dx = -self.ball_dx
    end

    if self.ball_y <= 0 then
        self.ball_y = 0
        self.ball_dy = -self.ball_dy
    end

    -- Bottom - lose life
    if self.ball_y >= h - 20 then
        self.lives = self.lives - 1
        if self.lives <= 0 then
            self.game_over = true
        else
            self:reset_ball()
        end
        return
    end

    -- Paddle collision
    local paddle_y = h - 30
    if self.ball_dy > 0 and
       self.ball_y + BALL_SIZE >= paddle_y and
       self.ball_y < paddle_y + PADDLE_H and
       self.ball_x + BALL_SIZE >= self.paddle_x and
       self.ball_x <= self.paddle_x + PADDLE_W then

        self.ball_y = paddle_y - BALL_SIZE
        self.ball_dy = -self.ball_dy

        -- Angle based on where ball hits paddle
        local hit_pos = (self.ball_x + BALL_SIZE / 2 - self.paddle_x) / PADDLE_W
        self.ball_dx = (hit_pos - 0.5) * 6

        -- Ensure minimum horizontal speed
        if self.ball_dx > -1 and self.ball_dx < 1 then
            self.ball_dx = (self.ball_dx >= 0) and 1 or -1
        end
    end

    -- Brick collisions
    for _, brick in ipairs(self.bricks) do
        if brick.alive then
            if self.ball_x + BALL_SIZE >= brick.x and
               self.ball_x <= brick.x + BRICK_W and
               self.ball_y + BALL_SIZE >= brick.y and
               self.ball_y <= brick.y + BRICK_H then

                brick.alive = false
                self.score = self.score + brick.points

                -- Determine collision side
                local ball_cx = self.ball_x + BALL_SIZE / 2
                local ball_cy = self.ball_y + BALL_SIZE / 2
                local brick_cx = brick.x + BRICK_W / 2
                local brick_cy = brick.y + BRICK_H / 2

                local dx = ball_cx - brick_cx
                local dy = ball_cy - brick_cy

                if math.abs(dx / BRICK_W) > math.abs(dy / BRICK_H) then
                    self.ball_dx = -self.ball_dx
                else
                    self.ball_dy = -self.ball_dy
                end

                -- Check win
                if self:count_bricks() == 0 then
                    self.won = true
                end

                break
            end
        end
    end
end

function Breakout:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, w, h, colors.BLACK)
    end

    -- Draw bricks
    for _, brick in ipairs(self.bricks) do
        if brick.alive then
            display.fill_rect(brick.x, brick.y, BRICK_W, BRICK_H, brick.color)
        end
    end

    -- Draw paddle
    local paddle_y = h - 30
    display.fill_rect(self.paddle_x, paddle_y, PADDLE_W, PADDLE_H, colors.WHITE)

    -- Draw ball
    display.fill_rect(self.ball_x, self.ball_y, BALL_SIZE, BALL_SIZE, colors.WHITE)

    -- Score and lives
    display.draw_text(5, 5, "Score: " .. self.score, colors.WHITE)
    display.draw_text(w - 70, 5, "Lives: " .. self.lives, colors.WHITE)

    if self.ball_stuck then
        display.draw_text_centered(h / 2, "[Space] to launch", colors.TEXT_DIM)
    end

    if self.game_over then
        display.draw_text_centered(h / 2 - 10, "GAME OVER", colors.RED)
        display.draw_text_centered(h / 2 + 10, "[Enter] Restart", colors.TEXT_DIM)
    elseif self.won then
        display.draw_text_centered(h / 2 - 10, "YOU WIN!", colors.GREEN)
        display.draw_text_centered(h / 2 + 10, "[Enter] Play Again", colors.TEXT_DIM)
    end

    local help_y = h - 10
    display.draw_text(5, help_y, "[</>] Move  [Q] Quit", colors.TEXT_DIM)
end

function Breakout:handle_key(key)
    local w = tdeck.display.width

    if self.game_over or self.won then
        if key.special == "ENTER" then
            -- Clean up before restart
            collectgarbage("collect")
            self.score = 0
            self.lives = 3
            self.game_over = false
            self.won = false
            self:reset_level()
        elseif key.special == "ESCAPE" or key.character == "q" then
            self:on_exit()
            return "pop"
        end
        ScreenManager.invalidate()
        return "continue"
    end

    if key.special == "LEFT" then
        self.paddle_vx = math.max(self.paddle_vx - 3, -8)  -- Add leftward velocity, cap at -8
    elseif key.special == "RIGHT" then
        self.paddle_vx = math.min(self.paddle_vx + 3, 8)  -- Add rightward velocity, cap at 8
    elseif key.character == " " then
        self:launch_ball()
    elseif key.special == "ESCAPE" or key.character == "q" then
        self:on_exit()
        return "pop"
    end

    ScreenManager.invalidate()
    return "continue"
end

function Breakout:update()
    if self.game_over or self.won then return end

    local now = tdeck.system.millis()
    if now - self.last_update >= 30 then  -- ~33 FPS
        self:update_physics()
        self.last_update = now
        ScreenManager.invalidate()
    end
end

return Breakout
