-- Classic Snake.
--
-- Grid-based snake on a 32x18 cell field (12 px per cell). Trackball
-- arrows or W/A/S/D set heading; the snake keeps moving every tick.
-- Eat food (one apple at a time) to grow + score; running into a wall
-- or yourself ends the game. Press Enter on game over to restart.

local ui         = require("ezui")
local screen_mod = require("ezui.screen")
local theme      = require("ezui.theme")
local node       = require("ezui.node")

local CELL       = 12
local GRID_W     = 26              -- 26 * 12 = 312, centred in 320 with a 4 px margin
local GRID_H     = 17              -- 17 * 12 = 204, leaves room for status bar + HUD
local FIELD_W    = GRID_W * CELL
local FIELD_H    = GRID_H * CELL
local HUD_H      = 16              -- score / hint strip below the title bar

local TICK_MS    = 110             -- snake step interval -- slow enough for tap navigation

local DIR_UP     = { dx =  0, dy = -1 }
local DIR_DOWN   = { dx =  0, dy =  1 }
local DIR_LEFT   = { dx = -1, dy =  0 }
local DIR_RIGHT  = { dx =  1, dy =  0 }

local floor = math.floor
local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

local function dir_opposite(a, b)
    return a.dx == -b.dx and a.dy == -b.dy
end

-- Mutable game state lives outside the screen instance so the field
-- node can read it on every draw without a tree rebuild. The screen
-- only set_state's when something HUD-visible (score, game_over)
-- changes, so on-tick movement is essentially free.
local game = nil

local function spawn_food()
    -- Pick a random empty cell. With a 26x17 grid (442 cells) and a
    -- snake well under that length, this rarely loops more than once.
    while true do
        local fx = math.random(0, GRID_W - 1)
        local fy = math.random(0, GRID_H - 1)
        local clash = false
        for _, seg in ipairs(game.snake) do
            if seg.x == fx and seg.y == fy then clash = true; break end
        end
        if not clash then
            game.food = { x = fx, y = fy }
            return
        end
    end
end

local function new_game()
    math.randomseed(ez.system.millis())
    -- Start with a 4-segment snake near the centre, heading right.
    local cx, cy = floor(GRID_W / 2), floor(GRID_H / 2)
    game = {
        snake     = {
            { x = cx,     y = cy }, -- head first
            { x = cx - 1, y = cy },
            { x = cx - 2, y = cy },
            { x = cx - 3, y = cy },
        },
        dir       = DIR_RIGHT,
        next_dir  = DIR_RIGHT,        -- queued so two quick taps don't reverse-into-self
        food      = nil,
        score     = 0,
        game_over = false,
    }
    spawn_food()
end

-- Step once. Returns true if the HUD changed (score / game-over),
-- so the caller can decide whether to set_state or just invalidate.
local function step()
    if game.game_over then return false end

    game.dir = game.next_dir
    local head = game.snake[1]
    local nx = head.x + game.dir.dx
    local ny = head.y + game.dir.dy

    -- Wall collision.
    if nx < 0 or nx >= GRID_W or ny < 0 or ny >= GRID_H then
        game.game_over = true
        return true
    end

    -- Self collision. Skip the tail because it's about to move out of
    -- the way -- unless we just ate, in which case the tail stays.
    local will_eat = (game.food and nx == game.food.x and ny == game.food.y)
    local n = #game.snake
    for i = 1, will_eat and n or (n - 1) do
        local seg = game.snake[i]
        if seg.x == nx and seg.y == ny then
            game.game_over = true
            return true
        end
    end

    -- Move: prepend new head, drop tail unless we ate.
    table.insert(game.snake, 1, { x = nx, y = ny })
    if will_eat then
        game.score = game.score + 1
        spawn_food()
        return true
    else
        table.remove(game.snake)
        return false
    end
end

-- Field renderer. Reads the module-level `game` table directly so we
-- can invalidate without rebuilding the node tree every tick.
node.register("snake_field", {
    measure = function(n, max_w, max_h)
        return max_w, FIELD_H + HUD_H
    end,
    draw = function(n, d, x, y, w, h)
        if not game then return end

        -- HUD strip: score on the left, hint on the right.
        theme.set_font("tiny_aa")
        local hud_y = y
        d.fill_rect(x, hud_y, w, HUD_H, theme.color("SURFACE"))
        d.draw_text(x + 6, hud_y + 3, "Score: " .. game.score,
            theme.color("TEXT"))
        local hint = game.game_over and "Enter to restart" or "Arrows to steer"
        local hw = theme.text_width(hint)
        d.draw_text(x + w - hw - 6, hud_y + 3, hint,
            theme.color("TEXT_MUTED"))

        -- Field background + border. Centred horizontally inside the
        -- content area so 4 px of bg shows on the left/right edges.
        local fx = x + floor((w - FIELD_W) / 2)
        local fy = y + HUD_H
        d.fill_rect(fx, fy, FIELD_W, FIELD_H, rgb(8, 18, 8))
        d.draw_rect(fx - 1, fy - 1, FIELD_W + 2, FIELD_H + 2,
            theme.color("BORDER"))

        -- Food. Drawn first so the snake's head can overlap it on the
        -- frame it's eaten (purely cosmetic; collision already handled).
        if game.food then
            d.fill_rect(fx + game.food.x * CELL + 2,
                        fy + game.food.y * CELL + 2,
                        CELL - 4, CELL - 4, rgb(220, 60, 60))
        end

        -- Snake. Brighter head, dimmer body so direction is readable
        -- even on a frozen screenshot.
        local snake_head = rgb(120, 230, 120)
        local snake_body = rgb(70,  170, 70)
        for i, seg in ipairs(game.snake) do
            local color = (i == 1) and snake_head or snake_body
            d.fill_rect(fx + seg.x * CELL + 1,
                        fy + seg.y * CELL + 1,
                        CELL - 2, CELL - 2, color)
        end

        -- Game-over overlay. A translucent panel + centred text reads
        -- well on the small screen and doesn't hide the final state of
        -- the snake, which players want to see.
        if game.game_over then
            theme.set_font("medium_aa", "bold")
            local msg = "Game Over"
            local mw = theme.text_width(msg)
            local mh = theme.font_height()
            local pad = 8
            local panel_x = fx + floor((FIELD_W - mw) / 2) - pad
            local panel_y = fy + floor((FIELD_H - mh) / 2) - pad
            d.fill_rect(panel_x, panel_y, mw + pad * 2, mh + pad * 2,
                theme.color("BG"))
            d.draw_rect(panel_x, panel_y, mw + pad * 2, mh + pad * 2,
                theme.color("ACCENT"))
            d.draw_text(panel_x + pad, panel_y + pad, msg,
                theme.color("ACCENT"))
        end
    end,
})

local Snake = { title = "Snake" }

function Snake.initial_state()
    return { tick = 0 }
end

function Snake:on_enter()
    new_game()
    self:set_state({ tick = 0 })
    self._timer = ez.system.set_interval(TICK_MS, function()
        local hud_changed = step()
        if hud_changed then
            -- Bump tick to force a rebuild + redraw so the HUD score
            -- and game-over panel pick up. Cheap because the tree is
            -- tiny (one custom node).
            self:set_state({ tick = (self._state.tick or 0) + 1 })
        else
            -- Mid-game tick where only snake position moved. Skipping
            -- set_state avoids ~9 tree rebuilds per second.
            screen_mod.invalidate()
        end
    end)
end

function Snake:on_exit()
    if self._timer then
        ez.system.cancel_timer(self._timer)
        self._timer = nil
    end
end

function Snake:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Snake", { back = true }),
        { type = "snake_field" },
    })
end

local function try_turn(new_dir)
    if not game or game.game_over then return end
    -- Reject reversing onto self. Compare against the current direction
    -- (the one we'll move with this tick) rather than next_dir, so two
    -- quick taps in opposite directions queue correctly: tap RIGHT then
    -- DOWN at >TICK_MS rate ends up moving down, not right.
    if dir_opposite(new_dir, game.dir) then return end
    game.next_dir = new_dir
end

function Snake:handle_key(key)
    if key.special == "UP"    or key.character == "w" then
        try_turn(DIR_UP);    return "handled"
    elseif key.special == "DOWN"  or key.character == "s" then
        try_turn(DIR_DOWN);  return "handled"
    elseif key.special == "LEFT"  or key.character == "a" then
        try_turn(DIR_LEFT);  return "handled"
    elseif key.special == "RIGHT" or key.character == "d" then
        try_turn(DIR_RIGHT); return "handled"
    elseif key.special == "ENTER" then
        if game and game.game_over then
            new_game()
            self:set_state({ tick = (self._state.tick or 0) + 1 })
        end
        return "handled"
    elseif key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Snake
