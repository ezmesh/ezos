-- Breakout: paddle-and-ball brick breaker with multiple levels and a
-- persistent high score. Arrow keys slide the paddle; Space / Enter
-- launches the ball (and dismisses the level-clear / game-over
-- banners). Q or Escape returns to the menu.

local theme      = require("ezui.theme")
local node_mod   = require("ezui.node")
local screen_mod = require("ezui.screen")

local Breakout = { title = "Breakout", fullscreen = true }

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

local SCREEN_W   = 320
local SCREEN_H   = 240
local HUD_H      = 20

local PLAYFIELD_TOP    = HUD_H
local PLAYFIELD_BOTTOM = SCREEN_H
local PLAYFIELD_H      = PLAYFIELD_BOTTOM - PLAYFIELD_TOP

local PADDLE_W   = 44
local PADDLE_H   = 4
local PADDLE_Y   = SCREEN_H - 15
local PADDLE_SPEED = 5

local BALL_SIZE  = 4
local BALL_BASE_SPEED = 2.2  -- magnitude; components derived from angle

local BRICK_COLS = 10
local BRICK_W    = 30
local BRICK_H    = 10
local BRICK_GAP  = 2
local BRICK_AREA_X = (SCREEN_W - (BRICK_COLS * BRICK_W + (BRICK_COLS - 1) * BRICK_GAP)) // 2
local BRICK_AREA_Y = PLAYFIELD_TOP + 6

local STARTING_LIVES = 3

-- ---------------------------------------------------------------------------
-- Brick palette — one colour per hit count (1..3). Hit counts above 3 just
-- reuse the 3-hit colour, which is fine because levels use 1..3 only.
-- ---------------------------------------------------------------------------

local rgb = function(r, g, b) return ez.display.rgb(r, g, b) end

local BRICK_COLORS -- populated in init_colors (display driver not ready at
                    -- load time); indexed by remaining hit count.
local BRICK_EDGE
local PADDLE_COLOR
local BALL_COLOR
local BG_COLOR
local HUD_BG
local HUD_TEXT
local HUD_DIM
local BANNER_BG
local BANNER_FG

local function init_colors()
    BRICK_COLORS = {
        [1] = rgb(220,  70,  70),   -- red
        [2] = rgb(240, 150,  40),   -- orange
        [3] = rgb(230, 210,  40),   -- yellow
    }
    BRICK_EDGE   = rgb(30, 30, 30)
    PADDLE_COLOR = rgb(230, 230, 240)
    BALL_COLOR   = rgb(255, 255, 255)
    BG_COLOR     = rgb(10, 12, 22)
    HUD_BG       = rgb(0, 0, 0)
    HUD_TEXT     = rgb(230, 230, 230)
    HUD_DIM      = rgb(130, 130, 140)
    BANNER_BG    = rgb(0, 0, 0)
    BANNER_FG    = rgb(240, 240, 255)
end

-- ---------------------------------------------------------------------------
-- Levels — each entry is BRICK_COLS chars wide. '.' = empty, '1'..'3' = hit
-- count. Tall levels scroll off the top of the playfield so kept to 7 rows.
-- ---------------------------------------------------------------------------

local LEVELS = {
    -- Level 1: classic four-row warm-up.
    {
        "1111111111",
        "1111111111",
        "1111111111",
        "1111111111",
    },
    -- Level 2: gaps and a tougher second row.
    {
        "1.1.1.1.1.",
        "2222222222",
        "1.1.1.1.1.",
        "1111111111",
        ".1.1.1.1.1",
    },
    -- Level 3: pyramid of mixed toughness.
    {
        "....33....",
        "...2222...",
        "..211112..",
        ".21111112.",
        "2111111112",
    },
    -- Level 4: fortress with a strong core.
    {
        "1111111111",
        "1222222221",
        "1233333321",
        "1233333321",
        "1222222221",
        "1111111111",
    },
    -- Level 5: checkerboard hell — mostly 2-hit bricks.
    {
        "2.2.2.2.2.",
        ".2.2.2.2.2",
        "2.2.2.2.2.",
        ".2.2.2.2.2",
        "2.2.2.2.2.",
        ".2.2.2.2.2",
    },
}

-- ---------------------------------------------------------------------------
-- Game state (module-locals so draw/update/key handlers share a view)
-- ---------------------------------------------------------------------------

local bricks         -- list of { x, y, w, h, hp }
local paddle_x       -- left edge of paddle (float — smoothed by key repeat)
local ball_x, ball_y -- centre of ball (floats)
local ball_vx, ball_vy
local mode           -- "ready" | "playing" | "level_clear" | "game_over"
local mode_timer     -- frames remaining before auto-advance (0 = wait for key)
local score
local lives
local level_index
local hiscore
local hiscore_beaten -- becomes true once the current run passes the saved
                     -- hiscore so the HUD can mark the moment.

-- ---------------------------------------------------------------------------
-- Level / ball setup
-- ---------------------------------------------------------------------------

local function load_level(level_idx)
    bricks = {}
    local layout = LEVELS[level_idx]
    for row_i, row in ipairs(layout) do
        for col_i = 1, BRICK_COLS do
            local ch = row:sub(col_i, col_i)
            local hp = tonumber(ch)
            if hp and hp > 0 then
                bricks[#bricks + 1] = {
                    x = BRICK_AREA_X + (col_i - 1) * (BRICK_W + BRICK_GAP),
                    y = BRICK_AREA_Y + (row_i - 1) * (BRICK_H + BRICK_GAP),
                    w = BRICK_W,
                    h = BRICK_H,
                    hp = hp,
                }
            end
        end
    end
end

local function reset_ball_on_paddle()
    ball_x = paddle_x + PADDLE_W / 2
    ball_y = PADDLE_Y - BALL_SIZE
    ball_vx = 0
    ball_vy = 0
end

local function launch_ball()
    -- Small horizontal tilt so the first trajectory isn't perfectly
    -- vertical (which would oscillate forever between paddle and ceiling).
    local tilt = (math.random(0, 1) == 0) and -1 or 1
    local speed = BALL_BASE_SPEED + (level_index - 1) * 0.2
    ball_vx = tilt * speed * 0.5
    ball_vy = -speed
end

local function start_level(idx)
    level_index = idx
    load_level(idx)
    paddle_x = (SCREEN_W - PADDLE_W) / 2
    reset_ball_on_paddle()
    mode = "ready"
    mode_timer = 0
end

local function reset_game()
    score          = 0
    lives          = STARTING_LIVES
    hiscore_beaten = false
    start_level(1)
end

-- ---------------------------------------------------------------------------
-- Collision helpers
-- ---------------------------------------------------------------------------

-- Axis-aligned rectangle vs. ball (treated as a BALL_SIZE×BALL_SIZE square
-- centred on ball_x/ball_y). Returns the axis the ball should reflect on
-- ("x", "y", or nil if no collision), and whether the collision happened.
local function rect_collide(rx, ry, rw, rh)
    local half = BALL_SIZE / 2
    local bx0, by0 = ball_x - half, ball_y - half
    local bx1, by1 = ball_x + half, ball_y + half
    if bx1 <= rx or bx0 >= rx + rw or by1 <= ry or by0 >= ry + rh then
        return nil
    end
    -- Determine which axis to reflect on by comparing penetration depth.
    local pen_x = math.min(bx1 - rx, rx + rw - bx0)
    local pen_y = math.min(by1 - ry, ry + rh - by0)
    if pen_x < pen_y then
        return "x"
    else
        return "y"
    end
end

local function score_hit(points)
    score = score + points
    if not hiscore_beaten and score > hiscore then
        hiscore_beaten = true
        hiscore = score
        ez.storage.set_pref("breakout_hiscore", hiscore)
    elseif hiscore_beaten then
        hiscore = score
        ez.storage.set_pref("breakout_hiscore", hiscore)
    end
end

-- ---------------------------------------------------------------------------
-- Per-frame simulation
-- ---------------------------------------------------------------------------

local function step_simulation()
    if mode ~= "playing" then return end

    -- Move in two half-steps to reduce the chance of tunnelling through a
    -- brick at high speed. With BALL_BASE_SPEED ~2.2 even two substeps keep
    -- per-step motion under the brick height, so simple AABB tests are safe.
    for _ = 1, 2 do
        ball_x = ball_x + ball_vx * 0.5
        ball_y = ball_y + ball_vy * 0.5

        -- Walls
        local half = BALL_SIZE / 2
        if ball_x - half < 0 then
            ball_x = half
            ball_vx = -ball_vx
        elseif ball_x + half > SCREEN_W then
            ball_x = SCREEN_W - half
            ball_vx = -ball_vx
        end
        if ball_y - half < PLAYFIELD_TOP then
            ball_y = PLAYFIELD_TOP + half
            ball_vy = -ball_vy
        end

        -- Floor: lose a life.
        if ball_y - half > PLAYFIELD_BOTTOM then
            lives = lives - 1
            if lives <= 0 then
                mode = "game_over"
                mode_timer = 0
            else
                reset_ball_on_paddle()
                mode = "ready"
            end
            return
        end

        -- Paddle. Treat as a rectangle; on hit, set vx based on where the
        -- ball struck so the player can aim.
        local axis = rect_collide(paddle_x, PADDLE_Y, PADDLE_W, PADDLE_H)
        if axis then
            local offset = (ball_x - (paddle_x + PADDLE_W / 2)) / (PADDLE_W / 2)
            offset = math.max(-1, math.min(1, offset))
            local speed = math.sqrt(ball_vx * ball_vx + ball_vy * ball_vy)
            local angle = offset * (math.pi * 0.35)  -- up to ~63° off vertical
            ball_vx = math.sin(angle) * speed
            ball_vy = -math.abs(math.cos(angle) * speed)
            ball_y  = PADDLE_Y - BALL_SIZE / 2 - 0.1
        end

        -- Bricks (iterate in reverse so we can remove while iterating).
        for i = #bricks, 1, -1 do
            local b = bricks[i]
            local a = rect_collide(b.x, b.y, b.w, b.h)
            if a then
                if a == "x" then ball_vx = -ball_vx else ball_vy = -ball_vy end
                b.hp = b.hp - 1
                score_hit(10)
                if b.hp <= 0 then
                    table.remove(bricks, i)
                end
                break  -- one collision per substep keeps physics stable
            end
        end

        if #bricks == 0 then
            score_hit(100 * level_index)  -- level clear bonus
            mode = "level_clear"
            mode_timer = 60  -- ~2s pause before advance
            ball_vx, ball_vy = 0, 0
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function draw_brick(d, b)
    local col = BRICK_COLORS[b.hp] or BRICK_COLORS[3]
    d.fill_rect(b.x, b.y, b.w, b.h, col)
    -- 1px darker border so adjacent bricks read separately on the panel.
    d.draw_rect(b.x, b.y, b.w, b.h, BRICK_EDGE)
end

local function draw_hud(d)
    d.fill_rect(0, 0, SCREEN_W, HUD_H, HUD_BG)
    theme.set_font("small_aa")
    local fh = theme.font_height()
    local ty = (HUD_H - fh) // 2

    d.draw_text(4, ty, "L" .. level_index, HUD_DIM)

    local score_str = "Score " .. score
    d.draw_text(36, ty, score_str, HUD_TEXT)

    local hs_str = "Best " .. hiscore
    local hs_col = hiscore_beaten and BRICK_COLORS[3] or HUD_DIM
    local hs_w = theme.text_width(hs_str)
    d.draw_text(SCREEN_W - hs_w - 50, ty, hs_str, hs_col)

    -- Lives as small paddle icons stacked against the right edge.
    local icon_w, icon_h = 12, 3
    for i = 1, lives do
        local ix = SCREEN_W - 4 - i * (icon_w + 3)
        d.fill_rect(ix, ty + (fh - icon_h) // 2 + 1, icon_w, icon_h, PADDLE_COLOR)
    end
end

local function draw_banner(d, title, subtitle)
    -- Semi-transparent band spans the middle third of the playfield with a
    -- title + subtitle stack. Drawn as a solid fill rather than a dithered
    -- stipple because the bricks behind it are already busy.
    local band_h = 60
    local band_y = PLAYFIELD_TOP + (PLAYFIELD_H - band_h) // 2
    d.fill_rect(0, band_y, SCREEN_W, band_h, BANNER_BG)

    theme.set_font("medium_aa")
    local fh = theme.font_height()
    local tw = theme.text_width(title)
    d.draw_text((SCREEN_W - tw) // 2, band_y + 14, title, BANNER_FG)

    if subtitle then
        theme.set_font("small_aa")
        local sh = theme.font_height()
        local sw = theme.text_width(subtitle)
        d.draw_text((SCREEN_W - sw) // 2, band_y + 14 + fh + 6, subtitle, HUD_DIM)
    end
end

if not node_mod.handler("breakout_view") then
    node_mod.register("breakout_view", {
        measure = function(n, max_w, max_h) return SCREEN_W, SCREEN_H end,

        draw = function(n, d, x, y, w, h)
            d.fill_rect(0, 0, SCREEN_W, SCREEN_H, BG_COLOR)

            for i = 1, #bricks do
                draw_brick(d, bricks[i])
            end

            d.fill_rect(math.floor(paddle_x), PADDLE_Y, PADDLE_W, PADDLE_H, PADDLE_COLOR)

            d.fill_rect(
                math.floor(ball_x - BALL_SIZE / 2),
                math.floor(ball_y - BALL_SIZE / 2),
                BALL_SIZE, BALL_SIZE, BALL_COLOR)

            draw_hud(d)

            if mode == "ready" then
                draw_banner(d, "Level " .. level_index, "Space / Enter to launch")
            elseif mode == "level_clear" then
                local next_idx = level_index + 1
                if next_idx > #LEVELS then
                    draw_banner(d, "Loop cleared!",
                                "Speed bumped — space to restart the set")
                else
                    draw_banner(d, "Level " .. level_index .. " clear",
                                "Level " .. next_idx .. " incoming...")
                end
            elseif mode == "game_over" then
                draw_banner(d, "Game over",
                            "Score " .. score .. "  |  Best " .. hiscore
                            .. "  |  space restarts")
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Screen lifecycle
-- ---------------------------------------------------------------------------

function Breakout:build(state)
    return { type = "breakout_view" }
end

function Breakout:on_enter()
    math.randomseed(ez.system.millis())
    init_colors()
    hiscore = tonumber(ez.storage.get_pref("breakout_hiscore", 0)) or 0
    reset_game()
end

function Breakout:update()
    -- Advance the mode timer first — level_clear auto-transitions.
    if mode == "level_clear" and mode_timer > 0 then
        mode_timer = mode_timer - 1
        if mode_timer == 0 then
            if level_index >= #LEVELS then
                -- Loop the set: keep score and lives, but ratchet the
                -- starting ball speed a touch via BALL_BASE_SPEED scaling
                -- on launch. Easier than a separate "endless mode".
                start_level(1)
            else
                start_level(level_index + 1)
            end
        end
    end

    step_simulation()
    screen_mod.invalidate()
end

function Breakout:handle_key(key)
    if key.character == "q" or key.special == "ESCAPE" then
        return "pop"
    end

    if key.special == "LEFT" then
        paddle_x = math.max(0, paddle_x - PADDLE_SPEED)
        if mode == "ready" then reset_ball_on_paddle() end
        return "handled"
    elseif key.special == "RIGHT" then
        paddle_x = math.min(SCREEN_W - PADDLE_W, paddle_x + PADDLE_SPEED)
        if mode == "ready" then reset_ball_on_paddle() end
        return "handled"
    end

    if key.special == "ENTER" or key.character == " " then
        if mode == "ready" then
            launch_ball()
            mode = "playing"
        elseif mode == "game_over" then
            reset_game()
        elseif mode == "level_clear" then
            -- Skip the countdown if the player is impatient.
            mode_timer = 0
        end
        return "handled"
    end

    return "handled"
end

return Breakout
