-- 2048: slide-and-merge tile puzzle.
--
-- 4x4 grid. Arrows / WASD slide all tiles in that direction; matching
-- pairs combine into the next power of two. After each move a new
-- 2 (90%) or 4 (10%) appears in a random empty cell. Reach 2048 to
-- win; lose when no move is possible.
--
-- Module name is `g2048` because Lua identifiers can't start with a
-- digit and `screens.games.2048` would never resolve.

local ui    = require("ezui")
local theme = require("ezui.theme")
local node  = require("ezui.node")

local floor = math.floor
local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

-- Board geometry. 4 cells of 40 px + 5 gaps of 6 px = 190 px square,
-- centred horizontally at x = (320 - 190) / 2 = 65. Vertically the
-- board sits below a 16 px HUD + 4 px gap inside a 220 px content
-- area, so HUD(16) + gap(4) + board(190) = 210 px fits with margin.
local CELL    = 40
local GAP     = 6
local COLS    = 4
local ROWS    = 4
local BOARD_W = COLS * CELL + (COLS + 1) * GAP   -- 206
local BOARD_H = ROWS * CELL + (ROWS + 1) * GAP   -- 206
local HUD_H   = 16

-- Tile colour ramp. Inspired by the classic Gabriele Cirulli palette
-- but darker so it sits well on a dark theme.
local TILE_COLORS = {
    [0]    = { bg = rgb( 30,  30,  35), fg = rgb(120, 120, 130) },
    [2]    = { bg = rgb(190, 175, 160), fg = rgb( 30,  30,  30) },
    [4]    = { bg = rgb(220, 195, 140), fg = rgb( 30,  30,  30) },
    [8]    = { bg = rgb(230, 150,  90), fg = rgb(255, 255, 255) },
    [16]   = { bg = rgb(240, 120,  80), fg = rgb(255, 255, 255) },
    [32]   = { bg = rgb(245,  90,  70), fg = rgb(255, 255, 255) },
    [64]   = { bg = rgb(245,  60,  40), fg = rgb(255, 255, 255) },
    [128]  = { bg = rgb(230, 200,  90), fg = rgb(255, 255, 255) },
    [256]  = { bg = rgb(230, 195,  70), fg = rgb(255, 255, 255) },
    [512]  = { bg = rgb(230, 190,  50), fg = rgb(255, 255, 255) },
    [1024] = { bg = rgb(230, 180,  20), fg = rgb(255, 255, 255) },
    [2048] = { bg = rgb(240, 170,   0), fg = rgb(255, 255, 255) },
}
local FALLBACK_COLOR = { bg = rgb(60, 60, 60), fg = rgb(255, 255, 255) }

local function tile_color(v)
    return TILE_COLORS[v] or FALLBACK_COLOR
end

-- Module-level state, mutated in place across moves.
local board     -- 4x4 array of integers (0 = empty)
local score
local game_over
local won
local won_acknowledged   -- once true, "you won" overlay is gone, play continues

local function empty_cells()
    local cells = {}
    for r = 1, ROWS do
        for c = 1, COLS do
            if board[r][c] == 0 then cells[#cells + 1] = { r, c } end
        end
    end
    return cells
end

local function spawn_tile()
    local empties = empty_cells()
    if #empties == 0 then return end
    local cell = empties[math.random(#empties)]
    board[cell[1]][cell[2]] = (math.random() < 0.9) and 2 or 4
end

local function new_game()
    math.randomseed(ez.system.millis())
    board = {}
    for r = 1, ROWS do
        board[r] = { 0, 0, 0, 0 }
    end
    score             = 0
    game_over         = false
    won               = false
    won_acknowledged  = false
    spawn_tile()
    spawn_tile()
end

-- Slide+merge a single row leftward. Returns the new row plus the
-- score delta. The four directions all reduce to this primitive by
-- transposing / reversing the board first; it keeps the merge rule
-- (one merge per tile per move) in one place.
local function slide_row_left(row)
    -- Compact non-zero values toward index 1 first.
    local packed = {}
    for i = 1, #row do
        if row[i] ~= 0 then packed[#packed + 1] = row[i] end
    end
    -- Walk packed left-to-right, merging adjacent equal pairs once.
    local out = {}
    local gained = 0
    local i = 1
    while i <= #packed do
        if i < #packed and packed[i] == packed[i + 1] then
            local merged = packed[i] * 2
            out[#out + 1] = merged
            gained = gained + merged
            if merged >= 2048 then won = true end
            i = i + 2
        else
            out[#out + 1] = packed[i]
            i = i + 1
        end
    end
    -- Pad back out to the original width with zeros.
    while #out < #row do out[#out + 1] = 0 end
    return out, gained
end

local function rows_equal(a, b)
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- Apply a directional slide. Returns true if the board actually
-- changed (i.e. the move was legal). reverse / transpose normalise
-- non-left moves into left moves so we only have one merge function.
local function move(dir)
    local moved = false
    local gained = 0

    local function process_row(get, set)
        local before = { get(1), get(2), get(3), get(4) }
        local after, g = slide_row_left(before)
        gained = gained + g
        if not rows_equal(before, after) then
            moved = true
            for i = 1, #after do set(i, after[i]) end
        end
    end

    if dir == "left" then
        for r = 1, ROWS do
            process_row(
                function(c) return board[r][c] end,
                function(c, v) board[r][c] = v end)
        end
    elseif dir == "right" then
        for r = 1, ROWS do
            process_row(
                function(c) return board[r][COLS + 1 - c] end,
                function(c, v) board[r][COLS + 1 - c] = v end)
        end
    elseif dir == "up" then
        for c = 1, COLS do
            process_row(
                function(r) return board[r][c] end,
                function(r, v) board[r][c] = v end)
        end
    elseif dir == "down" then
        for c = 1, COLS do
            process_row(
                function(r) return board[ROWS + 1 - r][c] end,
                function(r, v) board[ROWS + 1 - r][c] = v end)
        end
    end

    if moved then
        score = score + gained
        spawn_tile()
        -- Game-over check: any move possible?
        if #empty_cells() == 0 then
            local stuck = true
            for r = 1, ROWS do
                for c = 1, COLS do
                    if c < COLS and board[r][c] == board[r][c + 1] then
                        stuck = false
                    end
                    if r < ROWS and board[r][c] == board[r + 1][c] then
                        stuck = false
                    end
                end
            end
            if stuck then game_over = true end
        end
    end
    return moved
end

-- Field renderer.
node.register("g2048_field", {
    measure = function(n, max_w, max_h)
        return max_w, BOARD_H + HUD_H + 4
    end,
    draw = function(n, d, x, y, w, h)
        if not board then return end

        -- HUD strip.
        theme.set_font("tiny_aa")
        d.fill_rect(x, y, w, HUD_H, theme.color("SURFACE"))
        d.draw_text(x + 6, y + 3, "Score: " .. score, theme.color("TEXT"))
        local hint
        if game_over then
            hint = "Enter to restart"
        elseif won and not won_acknowledged then
            hint = "Enter to keep playing"
        else
            hint = "Arrows to slide"
        end
        local hw = theme.text_width(hint)
        d.draw_text(x + w - hw - 6, y + 3, hint, theme.color("TEXT_MUTED"))

        -- Board panel.
        local bx = x + floor((w - BOARD_W) / 2)
        local by = y + HUD_H + 4
        d.fill_rect(bx, by, BOARD_W, BOARD_H, rgb(70, 60, 55))

        theme.set_font("medium_aa", "bold")
        for r = 1, ROWS do
            for c = 1, COLS do
                local v = board[r][c]
                local cx = bx + GAP + (c - 1) * (CELL + GAP)
                local cy = by + GAP + (r - 1) * (CELL + GAP)
                local tc = tile_color(v)
                d.fill_rect(cx, cy, CELL, CELL, tc.bg)
                if v ~= 0 then
                    local s = tostring(v)
                    local tw = theme.text_width(s)
                    local th = theme.font_height()
                    d.draw_text(cx + floor((CELL - tw) / 2),
                                cy + floor((CELL - th) / 2),
                                s, tc.fg)
                end
            end
        end

        -- Win / lose overlays. Win is a one-shot popup the player can
        -- dismiss with Enter to keep stacking past 2048.
        local overlay
        if game_over then overlay = "Game Over"
        elseif won and not won_acknowledged then overlay = "You Win!" end
        if overlay then
            theme.set_font("large_aa", "bold")
            local mw = theme.text_width(overlay)
            local mh = theme.font_height()
            local pad = 10
            local px = bx + floor((BOARD_W - mw) / 2) - pad
            local py = by + floor((BOARD_H - mh) / 2) - pad
            d.fill_rect(px, py, mw + pad * 2, mh + pad * 2, theme.color("BG"))
            d.draw_rect(px, py, mw + pad * 2, mh + pad * 2, theme.color("ACCENT"))
            d.draw_text(px + pad, py + pad, overlay, theme.color("ACCENT"))
        end
    end,
})

local G2048 = { title = "2048" }

function G2048.initial_state()
    return { tick = 0 }
end

function G2048:on_enter()
    new_game()
    self:set_state({ tick = 0 })
end

function G2048:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("2048", { back = true }),
        { type = "g2048_field" },
    })
end

function G2048:handle_key(key)
    -- If an unacknowledged win popup is up, Enter dismisses it and
    -- play continues. Backspace exits as usual.
    if won and not won_acknowledged then
        if key.special == "ENTER" then
            won_acknowledged = true
            self:set_state({ tick = (self._state.tick or 0) + 1 })
            return "handled"
        elseif key.special == "BACKSPACE" or key.special == "ESCAPE" then
            return "pop"
        end
    end

    if game_over then
        if key.special == "ENTER" then
            new_game()
            self:set_state({ tick = (self._state.tick or 0) + 1 })
            return "handled"
        elseif key.special == "BACKSPACE" or key.special == "ESCAPE" then
            return "pop"
        end
        return nil
    end

    local d = nil
    if     key.special == "UP"    or key.character == "w" then d = "up"
    elseif key.special == "DOWN"  or key.character == "s" then d = "down"
    elseif key.special == "LEFT"  or key.character == "a" then d = "left"
    elseif key.special == "RIGHT" or key.character == "d" then d = "right"
    end
    if d then
        if move(d) then
            self:set_state({ tick = (self._state.tick or 0) + 1 })
        end
        return "handled"
    end

    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return G2048
