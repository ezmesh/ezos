-- Pong Game for T-Deck OS

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local Pong = {
    title = "Pong",
}

-- Game constants
local PADDLE_HEIGHT = 40
local PADDLE_WIDTH = 8
local BALL_SIZE = 8
local PADDLE_SPEED = 6
local BALL_SPEED_X = 4
local BALL_SPEED_Y = 3
local WINNING_SCORE = 5

function Pong:new()
    local o = {
        player_y = 0,
        ai_y = 0,
        ball_x = 0,
        ball_y = 0,
        ball_dx = 0,
        ball_dy = 0,
        player_score = 0,
        ai_score = 0,
        game_over = false,
        player_won = false,
        paused = true,
        last_update = 0,
    }
    setmetatable(o, {__index = Pong})
    return o
end

function Pong:on_enter()
    if _G.MainLoop then _G.MainLoop.enter_game_mode() end
    self:reset_game()
end

function Pong:on_exit()
    if _G.MainLoop then _G.MainLoop.exit_game_mode() end
end

function Pong:reset_game()
    local h = ez.display.height

    self.player_y = h / 2 - PADDLE_HEIGHT / 2
    self.ai_y = h / 2 - PADDLE_HEIGHT / 2
    self:reset_ball()
    self.last_update = ez.system.millis()
end

function Pong:reset_ball()
    local w = ez.display.width
    local h = ez.display.height

    self.ball_x = w / 2 - BALL_SIZE / 2
    self.ball_y = h / 2 - BALL_SIZE / 2
    self.ball_dx = (math.random() > 0.5) and BALL_SPEED_X or -BALL_SPEED_X
    self.ball_dy = (math.random() > 0.5) and BALL_SPEED_Y or -BALL_SPEED_Y
    self.paused = true
end

function Pong:update_ai()
    local h = ez.display.height
    local ai_center = self.ai_y + PADDLE_HEIGHT / 2
    local ball_center = self.ball_y + BALL_SIZE / 2

    -- AI follows ball with some delay
    local diff = ball_center - ai_center
    local speed = PADDLE_SPEED * 0.7  -- Slightly slower than player

    if math.abs(diff) > 5 then
        if diff > 0 then
            self.ai_y = math.min(h - PADDLE_HEIGHT - 20, self.ai_y + speed)
        else
            self.ai_y = math.max(20, self.ai_y - speed)
        end
    end
end

function Pong:update_ball()
    local w = ez.display.width
    local h = ez.display.height

    -- Move ball
    self.ball_x = self.ball_x + self.ball_dx
    self.ball_y = self.ball_y + self.ball_dy

    -- Top/bottom wall collision
    if self.ball_y <= 20 then
        self.ball_y = 20
        self.ball_dy = -self.ball_dy
    elseif self.ball_y >= h - BALL_SIZE - 20 then
        self.ball_y = h - BALL_SIZE - 20
        self.ball_dy = -self.ball_dy
    end

    -- Player paddle collision (left side)
    local player_x = 20
    if self.ball_dx < 0 and
       self.ball_x <= player_x + PADDLE_WIDTH and
       self.ball_x + BALL_SIZE >= player_x and
       self.ball_y + BALL_SIZE >= self.player_y and
       self.ball_y <= self.player_y + PADDLE_HEIGHT then

        self.ball_x = player_x + PADDLE_WIDTH
        self.ball_dx = -self.ball_dx

        -- Angle based on where ball hits paddle
        local hit_pos = (self.ball_y + BALL_SIZE / 2 - self.player_y) / PADDLE_HEIGHT
        self.ball_dy = (hit_pos - 0.5) * BALL_SPEED_Y * 2
    end

    -- AI paddle collision (right side)
    local ai_x = w - 20 - PADDLE_WIDTH
    if self.ball_dx > 0 and
       self.ball_x + BALL_SIZE >= ai_x and
       self.ball_x <= ai_x + PADDLE_WIDTH and
       self.ball_y + BALL_SIZE >= self.ai_y and
       self.ball_y <= self.ai_y + PADDLE_HEIGHT then

        self.ball_x = ai_x - BALL_SIZE
        self.ball_dx = -self.ball_dx

        local hit_pos = (self.ball_y + BALL_SIZE / 2 - self.ai_y) / PADDLE_HEIGHT
        self.ball_dy = (hit_pos - 0.5) * BALL_SPEED_Y * 2
    end

    -- Scoring
    if self.ball_x < 0 then
        -- AI scores
        self.ai_score = self.ai_score + 1
        if self.ai_score >= WINNING_SCORE then
            self.game_over = true
            self.player_won = false
        else
            self:reset_ball()
        end
    elseif self.ball_x > w then
        -- Player scores
        self.player_score = self.player_score + 1
        if self.player_score >= WINNING_SCORE then
            self.game_over = true
            self.player_won = true
        else
            self:reset_ball()
        end
    end
end

function Pong:update()
    if self.game_over or self.paused then return end

    local now = ez.system.millis()
    if now - self.last_update >= 30 then  -- ~33 FPS
        self:update_ai()
        self:update_ball()
        self.last_update = now
        ScreenManager.invalidate()
    end
end

function Pong:render(display)
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height

    -- Background
    ListMixin.draw_background(display)

    -- Center line (dashed)
    local center_x = w / 2 - 1
    for y = 25, h - 25, 15 do
        display.fill_rect(center_x, y, 2, 8, colors.TEXT_MUTED)
    end

    -- Player paddle (left)
    display.fill_rect(20, self.player_y, PADDLE_WIDTH, PADDLE_HEIGHT, colors.WHITE)

    -- AI paddle (right)
    display.fill_rect(w - 20 - PADDLE_WIDTH, self.ai_y, PADDLE_WIDTH, PADDLE_HEIGHT, colors.WHITE)

    -- Ball
    display.fill_rect(math.floor(self.ball_x), math.floor(self.ball_y), BALL_SIZE, BALL_SIZE, colors.WHITE)

    -- Scores
    display.set_font_size("large")
    display.draw_text(w / 4, 5, tostring(self.player_score), colors.WHITE)
    display.draw_text(w * 3 / 4 - 10, 5, tostring(self.ai_score), colors.WHITE)
    display.set_font_size("medium")

    -- Instructions
    if self.paused and not self.game_over then
        display.draw_text_centered(h / 2, "[Space] to start", colors.TEXT_SECONDARY)
    end

    if self.game_over then
        local msg = self.player_won and "YOU WIN!" or "YOU LOSE"
        local msg_color = self.player_won and colors.SUCCESS or colors.ERROR
        display.draw_text_centered(h / 2 - 10, msg, msg_color)
        display.draw_text_centered(h / 2 + 10, "[Enter] Play Again", colors.TEXT_SECONDARY)
    end

    local help_y = h - 10
    display.draw_text(5, help_y, "[Up/Down] Move  [Q] Quit", colors.TEXT_SECONDARY)
end

function Pong:handle_key(key)
    local h = ez.display.height

    if self.game_over then
        if key.special == "ENTER" then
            run_gc("collect", "pong-restart")
            self.player_score = 0
            self.ai_score = 0
            self.game_over = false
            self:reset_game()
        elseif key.special == "ESCAPE" or key.character == "q" then
            self:on_exit()
            return "pop"
        end
        ScreenManager.invalidate()
        return "continue"
    end

    if key.character == " " then
        self.paused = false
    elseif key.special == "UP" then
        self.player_y = math.max(20, self.player_y - PADDLE_SPEED)
    elseif key.special == "DOWN" then
        self.player_y = math.min(h - PADDLE_HEIGHT - 20, self.player_y + PADDLE_SPEED)
    elseif key.special == "ESCAPE" or key.character == "q" then
        self:on_exit()
        return "pop"
    end

    ScreenManager.invalidate()
    return "continue"
end

return Pong
