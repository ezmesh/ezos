-- Classic Tetris.
--
-- Standard 10×20 playfield, seven tetrominoes (I, O, T, S, Z, J, L),
-- rotation + hold-to-soft-drop, line clears with level speed-up. Top-5
-- high scores persisted to NVS via ez.storage.set_pref so they survive
-- reboots.
--
-- Scoring matches the classic NES-ish rules:
--   1 line → 40 × (level+1)
--   2 lines → 100 × (level+1)
--   3 lines → 300 × (level+1)
--   4 lines (tetris) → 1200 × (level+1)
-- Plus a small bonus for a hard drop (2 pts per cell travelled).
--
-- Level bumps every 10 lines, each level shaves ~10% off the tick
-- interval, capped at 16 frames for maximum speed (~0.5 s/cell at 30
-- Hz). Play field fits in a 160-wide band left of the HUD.

local ui         = require("ezui")
local node_mod   = require("ezui.node")
local theme      = require("ezui.theme")
local screen_mod = require("ezui.screen")
local highscores = require("engine.highscores")

-- Forward-declare the difficulty so the hs_key() closure below can
-- capture it as an upvalue. Without this declaration, `difficulty`
-- inside hs_key() resolves to the global _ENV.difficulty (always
-- nil), `HS_KEYS[nil]` is nil, the `or` falls through, and every
-- run goes to the Hard leaderboard regardless of which button was
-- pressed. The actual assignment lives at the bottom of the file
-- where the difficulty profiles are defined; this is a forward
-- decl so the closure picks up the same local.
local difficulty

-- Per-difficulty leaderboards. Mixing easy/hard scores on a single
-- list would let easy runs (slower drop, drop preview) push hard
-- scores off — separating them keeps each board honest.
local HS_KEYS = { easy = "tetris_easy", hard = "tetris_hard" }
local function hs_key()
    return HS_KEYS[difficulty] or HS_KEYS.hard
end

local Game = { title = "Tetris", fullscreen = true }

local floor = math.floor
local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

local SW, SH = 320, 240
local COLS, ROWS = 10, 20
local CELL = 11                      -- cell size in pixels (10×20 board = 110×220)
local BOARD_W = COLS * CELL
local BOARD_H = ROWS * CELL
-- Play board centred on the screen. HUD is tucked into the empty
-- column on the right; there's symmetric margin on the left of the
-- board so the focal point of the screen is the playfield itself.
local BOARD_X = floor((SW - BOARD_W) / 2)
local BOARD_Y = 12
local HUD_GAP = 10
local HUD_X   = BOARD_X + BOARD_W + HUD_GAP

---------------------------------------------------------------------------
-- Pieces. Each tetromino is listed as 4 rotations of 4 cells. Cells are
-- {dx, dy} offsets from the piece origin. Using explicit rotations (vs
-- computing on the fly) makes wall-kick / rotation edge cases trivial.
---------------------------------------------------------------------------

local PIECE_COLORS = {
    I = rgb( 90, 200, 230),
    O = rgb(230, 220,  80),
    T = rgb(180, 100, 220),
    S = rgb( 90, 210, 110),
    Z = rgb(230,  90, 110),
    J = rgb( 90, 130, 230),
    L = rgb(230, 160,  70),
}

local PIECE_EDGE = {
    I = rgb(170, 230, 250),
    O = rgb(255, 240, 160),
    T = rgb(230, 170, 250),
    S = rgb(160, 250, 180),
    Z = rgb(255, 160, 180),
    J = rgb(160, 190, 250),
    L = rgb(255, 200, 140),
}

local PIECES = {
    I = {
        { {0,1},{1,1},{2,1},{3,1} },
        { {2,0},{2,1},{2,2},{2,3} },
        { {0,2},{1,2},{2,2},{3,2} },
        { {1,0},{1,1},{1,2},{1,3} },
    },
    O = {
        { {1,0},{2,0},{1,1},{2,1} },
        { {1,0},{2,0},{1,1},{2,1} },
        { {1,0},{2,0},{1,1},{2,1} },
        { {1,0},{2,0},{1,1},{2,1} },
    },
    T = {
        { {1,0},{0,1},{1,1},{2,1} },
        { {1,0},{1,1},{2,1},{1,2} },
        { {0,1},{1,1},{2,1},{1,2} },
        { {1,0},{0,1},{1,1},{1,2} },
    },
    S = {
        { {1,0},{2,0},{0,1},{1,1} },
        { {1,0},{1,1},{2,1},{2,2} },
        { {1,1},{2,1},{0,2},{1,2} },
        { {0,0},{0,1},{1,1},{1,2} },
    },
    Z = {
        { {0,0},{1,0},{1,1},{2,1} },
        { {2,0},{1,1},{2,1},{1,2} },
        { {0,1},{1,1},{1,2},{2,2} },
        { {1,0},{0,1},{1,1},{0,2} },
    },
    J = {
        { {0,0},{0,1},{1,1},{2,1} },
        { {1,0},{2,0},{1,1},{1,2} },
        { {0,1},{1,1},{2,1},{2,2} },
        { {1,0},{1,1},{0,2},{1,2} },
    },
    L = {
        { {2,0},{0,1},{1,1},{2,1} },
        { {1,0},{1,1},{1,2},{2,2} },
        { {0,1},{1,1},{2,1},{0,2} },
        { {0,0},{1,0},{1,1},{1,2} },
    },
}

local PIECE_KEYS = { "I", "O", "T", "S", "Z", "J", "L" }

---------------------------------------------------------------------------
-- Runtime state
---------------------------------------------------------------------------

local board                    -- board[r][c] = piece_key or nil
local piece, rot, px, py      -- current falling piece
local next_piece
local score, level, lines
-- start_lines is the level-progression offset for difficulties that
-- begin past level 0. `lines` is the literal count of lines the
-- player has cleared this run (for HUD + leaderboard); the level-up
-- check in award_clear works against `lines + start_lines` so the
-- math still bumps the level after every 10 *additional* cleared
-- lines. Without this split, a Hard start at level 4 would show
-- "LINES 30" in the HUD and submit 30 phantom lines to the
-- leaderboard.
local start_lines = 0
local drop_timer               -- remaining frames until auto-drop
-- Soft-drop is "sticky" — the T-Deck keyboard doesn't fire release
-- events, so a simple boolean would latch until the next spawn. We
-- instead track a deadline: each DOWN press bumps `soft_drop_until`
-- a short window into the future, and the tick/soft_drop check asks
-- whether we're still inside it. Key-repeat during a hold re-arms the
-- window; letting go stops it within SOFT_DROP_HOLD_MS.
local SOFT_DROP_HOLD_MS = 140
local soft_drop_until = 0
local function soft_drop_active()
    return ez.system.millis() < soft_drop_until
end
local game_state              -- "menu" | "playing" | "over"
local status_text

-- Picked from the menu. Easy mode draws a ghost-piece landing
-- preview plus a faint lane highlight so the player can see exactly
-- where the current piece will hit; it also runs the drop curve a
-- couple of levels behind hard mode so there's actual time to plan.
-- Hard mode drops the visual aids and starts a few levels in for
-- people who want the classic difficulty curve from the first piece.
-- Plain assignment, not `local` — this writes to the upvalue
-- declared at the top of the file so hs_key() and start_with()
-- both see the same value.
difficulty = "hard"

-- Per-difficulty tuning. base_drop_frames is the starting drop
-- interval at level 0 (subject to the 0.9^level decay in
-- drop_interval_for_level); drop_floor is the cap so a long run
-- can't reduce the interval below playable. start_level offsets the
-- initial level so hard players don't have to suffer through the
-- gentle early curve.
local DIFFICULTY_PROFILES = {
    easy = { base_drop_frames = 60, drop_floor = 22, start_level = 0,
             show_ghost = true },
    hard = { base_drop_frames = 40, drop_floor = 12, start_level = 3,
             show_ghost = false },
}

local function profile()
    return DIFFICULTY_PROFILES[difficulty] or DIFFICULTY_PROFILES.hard
end

-- High scores are persisted through the shared engine.highscores
-- module. We pass `lines` as the `extra` tag so the leaderboard can
-- display both score and lines-cleared per entry.

---------------------------------------------------------------------------
-- Board helpers
---------------------------------------------------------------------------

local function new_board()
    local b = {}
    for r = 1, ROWS do
        local row = {}
        for c = 1, COLS do row[c] = nil end
        b[r] = row
    end
    return b
end

local function piece_cells(key, rotation, cx, cy)
    -- Returns iterator of absolute (col, row) cells for the piece.
    local offsets = PIECES[key][((rotation - 1) % 4) + 1]
    local i = 0
    return function()
        i = i + 1
        if i > 4 then return nil end
        local o = offsets[i]
        return cx + o[1], cy + o[2]
    end
end

local function valid_position(key, rotation, cx, cy)
    for c, r in piece_cells(key, rotation, cx, cy) do
        if c < 0 or c >= COLS or r < 0 or r >= ROWS then return false end
        if board[r + 1] and board[r + 1][c + 1] then return false end
    end
    return true
end

local function lock_piece()
    for c, r in piece_cells(piece, rot, px, py) do
        if r >= 0 and r < ROWS and c >= 0 and c < COLS then
            board[r + 1][c + 1] = piece
        end
    end
end

local function clear_lines()
    local cleared = 0
    local r = ROWS
    while r >= 1 do
        local full = true
        for c = 1, COLS do
            if not board[r][c] then full = false; break end
        end
        if full then
            table.remove(board, r)
            local new_row = {}
            for c = 1, COLS do new_row[c] = nil end
            table.insert(board, 1, new_row)
            cleared = cleared + 1
            -- Don't decrement r — same index is now a new row.
        else
            r = r - 1
        end
    end
    return cleared
end

---------------------------------------------------------------------------
-- Game flow
---------------------------------------------------------------------------

-- 7-bag randomizer. Standard fill for modern Tetris; gives each piece
-- a guaranteed 1-in-7 appearance per bag, which keeps droughts short.
local bag = {}
local function next_bag_piece()
    if #bag == 0 then
        for _, k in ipairs(PIECE_KEYS) do bag[#bag + 1] = k end
        -- Fisher-Yates shuffle.
        for i = #bag, 2, -1 do
            local j = math.random(i)
            bag[i], bag[j] = bag[j], bag[i]
        end
    end
    return table.remove(bag)
end

local function spawn_piece()
    piece = next_piece or next_bag_piece()
    next_piece = next_bag_piece()
    rot = 1
    -- Start in the middle-ish so 4-wide I-piece lands evenly.
    px = 3
    py = 0
    if not valid_position(piece, rot, px, py) then
        -- Can't even spawn — game over.
        game_state = "over"
        status_text = "Game over"
        local rank = highscores.submit(hs_key(), score, lines)
        if rank then
            status_text = "High score! #" .. rank
        end
    end
end

local function drop_interval_for_level(lvl)
    -- 30 FPS tick. base / floor are difficulty-dependent so easy mode
    -- gives noticeable thinking time and hard mode hits the speed cap
    -- a few levels earlier. Lua 5.4 removed math.pow — `^` is the
    -- idiomatic alternative.
    local p = profile()
    local f = p.base_drop_frames * (0.9 ^ lvl)
    if f < p.drop_floor then f = p.drop_floor end
    return floor(f)
end

local function award_clear(n_cleared)
    if n_cleared == 0 then return end
    local base = (n_cleared == 1) and 40
              or (n_cleared == 2) and 100
              or (n_cleared == 3) and 300
              or 1200
    score = score + base * (level + 1)
    lines = lines + n_cleared
    -- Add the difficulty's pre-credit so a Hard start at level 4
    -- still levels up after every 10 *additional* cleared lines.
    -- `lines` itself is left as the user-visible count.
    local new_level = floor((lines + start_lines) / 10)
    if new_level > level then
        level = new_level
        status_text = "Level " .. (level + 1)
    end
end

local function try_move(dx, dy, drot)
    local nrot = rot + drot
    local nx = px + dx
    local ny = py + dy
    if valid_position(piece, nrot, nx, ny) then
        px = nx; py = ny; rot = nrot
        return true
    end
    return false
end

local function lock_and_advance()
    lock_piece()
    local n = clear_lines()
    award_clear(n)
    spawn_piece()
    drop_timer = drop_interval_for_level(level)
end

local function tick()
    if game_state ~= "playing" then return end
    drop_timer = drop_timer - 1
    if drop_timer > 0 then return end
    if try_move(0, 1, 0) then
        if soft_drop_active() then score = score + 1 end
    else
        lock_and_advance()
        return
    end
    drop_timer = drop_interval_for_level(level)
                     // (soft_drop_active() and 6 or 1)
end

local function hard_drop()
    local dropped = 0
    while try_move(0, 1, 0) do dropped = dropped + 1 end
    score = score + dropped * 2
    lock_and_advance()
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local BG        = rgb(12, 14, 26)
local GRID      = rgb(40, 42, 60)
local FRAME     = rgb(120, 120, 150)
local TEXT_MAIN = rgb(230, 230, 240)
local TEXT_DIM  = rgb(160, 160, 180)
-- Easy-mode hint colours. LANE_BG is a subtle navy band to mark the
-- columns the current piece occupies — only a couple of shades above
-- BG so it doesn't compete with the locked blocks. The ghost outline
-- reuses each tetromino's own edge colour so the hint visually ties
-- back to the piece overhead.
local LANE_BG   = rgb(30, 40, 70)

local function draw_cell(d, col, row, key)
    local x = BOARD_X + col * CELL
    local y = BOARD_Y + row * CELL
    d.fill_rect(x, y, CELL, CELL, PIECE_COLORS[key])
    d.draw_rect(x, y, CELL, CELL, PIECE_EDGE[key])
end

-- Compute the lowest valid landing row for the current piece. Used
-- by the easy-mode ghost preview. Doesn't mutate state.
local function ghost_y()
    local gy = py
    while valid_position(piece, rot, px, gy + 1) do
        gy = gy + 1
    end
    return gy
end

local function draw_board(d)
    d.fill_rect(BOARD_X, BOARD_Y, BOARD_W, BOARD_H, BG)

    -- Easy-mode lane highlight. Tints the full-height columns that the
    -- piece currently spans so the player can see at a glance which
    -- lanes are about to be occupied. Drawn on top of BG but under the
    -- grid lines + locked blocks so it reads as a faint background
    -- band, not a foreground element.
    if profile().show_ghost and game_state == "playing" and piece then
        local minc, maxc = COLS, -1
        for c, _ in piece_cells(piece, rot, px, py) do
            if c < minc then minc = c end
            if c > maxc then maxc = c end
        end
        if minc <= maxc then
            for cc = minc, maxc do
                local x = BOARD_X + cc * CELL
                d.fill_rect(x, BOARD_Y, CELL, BOARD_H, LANE_BG)
            end
        end
    end

    -- Subtle column grid.
    for c = 1, COLS - 1 do
        local x = BOARD_X + c * CELL
        d.fill_rect(x, BOARD_Y, 1, BOARD_H, GRID)
    end
    d.draw_rect(BOARD_X - 1, BOARD_Y - 1, BOARD_W + 2, BOARD_H + 2, FRAME)
    for r = 1, ROWS do
        for c = 1, COLS do
            local k = board[r][c]
            if k then draw_cell(d, c - 1, r - 1, k) end
        end
    end
end

-- Easy mode only: outline the cells where the current piece will land
-- if hard-dropped. Outline-only (no fill) so the live piece overhead
-- always reads as the foreground element. Cells overlapping the
-- current piece position are skipped to avoid a doubled border on the
-- piece itself.
local function draw_ghost(d)
    if not profile().show_ghost then return end
    if game_state ~= "playing" or not piece then return end
    local gy = ghost_y()
    if gy == py then return end  -- piece is already at landing row
    -- Build a quick set of current-piece cells so we can skip them.
    local cur = {}
    for c, r in piece_cells(piece, rot, px, py) do
        cur[r * COLS + c] = true
    end
    local edge = PIECE_EDGE[piece]
    for c, r in piece_cells(piece, rot, px, gy) do
        if r >= 0 and not cur[r * COLS + c] then
            local x = BOARD_X + c * CELL
            local y = BOARD_Y + r * CELL
            d.draw_rect(x, y, CELL, CELL, edge)
        end
    end
end

local function draw_current_piece(d)
    if game_state ~= "playing" then return end
    for c, r in piece_cells(piece, rot, px, py) do
        if r >= 0 then draw_cell(d, c, r, piece) end
    end
end

local function draw_next_preview(d, x, y)
    -- 4-cell preview box with the upcoming piece.
    local box = 4 * CELL
    d.fill_rect(x, y, box, box, BG)
    d.draw_rect(x, y, box, box, FRAME)
    if not next_piece then return end
    -- Render the piece's first rotation in its own 4x4 space.
    for _, off in ipairs(PIECES[next_piece][1]) do
        local cx = x + off[1] * CELL
        local cy = y + off[2] * CELL
        d.fill_rect(cx, cy, CELL, CELL, PIECE_COLORS[next_piece])
        d.draw_rect(cx, cy, CELL, CELL, PIECE_EDGE[next_piece])
    end
end

local function draw_hud(d)
    theme.set_font("small_aa")
    d.draw_text(HUD_X, 10, "SCORE", TEXT_DIM)
    theme.set_font("medium_aa", "bold")
    d.draw_text(HUD_X, 22, tostring(score), TEXT_MAIN)

    theme.set_font("small_aa")
    d.draw_text(HUD_X, 46, "LEVEL", TEXT_DIM)
    theme.set_font("medium_aa", "bold")
    d.draw_text(HUD_X, 58, tostring(level + 1), TEXT_MAIN)

    theme.set_font("small_aa")
    d.draw_text(HUD_X, 82, "LINES", TEXT_DIM)
    theme.set_font("medium_aa", "bold")
    d.draw_text(HUD_X, 94, tostring(lines), TEXT_MAIN)

    theme.set_font("small_aa")
    d.draw_text(HUD_X, 118, "NEXT", TEXT_DIM)
    draw_next_preview(d, HUD_X, 130)

    if status_text and status_text ~= "" then
        theme.set_font("tiny_aa")
        d.draw_text(HUD_X, 182, status_text, TEXT_DIM)
    end
end

local function draw_over(d)
    -- Semi-transparent-ish overlay by simply drawing a solid panel.
    local panel_x, panel_y = 36, 44
    local panel_w, panel_h = SW - 72, SH - 80
    d.fill_rect(panel_x, panel_y, panel_w, panel_h, rgb(10, 10, 20))
    d.draw_rect(panel_x, panel_y, panel_w, panel_h, FRAME)

    theme.set_font("medium_aa", "bold")
    local title = "GAME OVER"
    local tw = theme.text_width(title)
    d.draw_text(floor((SW - tw) / 2), panel_y + 8, title, rgb(240, 120, 120))

    theme.set_font("small_aa")
    local sub = string.format("%d pts  ·  %d lines", score, lines)
    local sw = theme.text_width(sub)
    d.draw_text(floor((SW - sw) / 2), panel_y + 28, sub, TEXT_MAIN)

    theme.set_font("tiny_aa")
    local board_label = (difficulty == "easy")
        and "HIGH SCORES (EASY)" or "HIGH SCORES (HARD)"
    d.draw_text(panel_x + 12, panel_y + 50, board_label, TEXT_DIM)
    local rows = highscores.format(hs_key(), function(i, h)
        return string.format("%d.  %6d   %d lines", i, h.score, h.extra)
    end)
    for i, line in ipairs(rows) do
        d.draw_text(panel_x + 12, panel_y + 62 + (i - 1) * 12, line, TEXT_MAIN)
    end

    theme.set_font("tiny_aa")
    local hint = "R: retry · Q: menu"
    local hw = theme.text_width(hint)
    d.draw_text(floor((SW - hw) / 2), panel_y + panel_h - 14, hint, TEXT_DIM)
end

local function render(d)
    d.fill_rect(0, 0, SW, SH, rgb(0, 0, 0))
    draw_board(d)
    draw_ghost(d)
    draw_current_piece(d)
    draw_hud(d)
    if game_state == "over" then draw_over(d) end
end

if not node_mod.handler("tetris_view") then
    node_mod.register("tetris_view", {
        measure = function(_, _, _) return SW, SH end,
        draw = function(_, d, _, _, _, _) render(d) end,
    })
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function reset_world()
    board = new_board()
    score = 0
    -- `lines` is the literal cleared count this run (HUD + leaderboard);
    -- start_lines is the offset for the level-up math so a Hard run
    -- starting at level N still bumps level after every 10
    -- *additional* clears. Setting both here.
    local p = profile()
    level = p.start_level
    lines = 0
    start_lines = level * 10
    bag = {}
    next_piece = next_bag_piece()
    spawn_piece()
    drop_timer = drop_interval_for_level(level)
    soft_drop_until = 0
    status_text = (difficulty == "easy") and "Easy" or "Hard"
    game_state = "playing"
end

function Game.initial_state() return {} end

function Game:build(_state)
    if game_state == "menu" then
        -- Wraps reset_world + tick install so both menu buttons go
        -- through the same launch path. Picks the difficulty into the
        -- module-local `difficulty` first so reset_world sees the
        -- right profile.
        local function start_with(diff)
            difficulty = diff
            reset_world()
            self:set_state({})
            self._tick = ez.system.set_interval(math.floor(1000/30),
                function()
                    tick()
                    screen_mod.invalidate()
                end)
        end

        return ui.vbox({ gap = 0, bg = "BG" }, {
            ui.title_bar("Tetris", { back = true }),
            ui.padding({ 18, 20, 6, 20 },
                ui.text_widget("Classic tetris with top-5 high scores.",
                    { font = "small_aa", color = "TEXT_SEC",
                      text_align = "center", wrap = true })
            ),
            ui.padding({ 4, 40, 4, 40 },
                ui.button("Easy",
                    { on_press = function() start_with("easy") end })
            ),
            ui.padding({ 0, 20, 6, 20 },
                ui.text_widget(
                    "Drop preview + lane highlight. Slower start.",
                    { font = "tiny_aa", color = "TEXT_MUTED",
                      text_align = "center", wrap = true })
            ),
            ui.padding({ 4, 40, 4, 40 },
                ui.button("Hard",
                    { on_press = function() start_with("hard") end })
            ),
            ui.padding({ 0, 20, 6, 20 },
                ui.text_widget(
                    "No drop preview. Starts a few levels in.",
                    { font = "tiny_aa", color = "TEXT_MUTED",
                      text_align = "center", wrap = true })
            ),
            ui.padding({ 8, 20, 0, 20 },
                ui.text_widget(
                    "LEFT/RIGHT move | UP rotate | DOWN soft drop | SPACE hard drop | Q back",
                    { font = "tiny_aa", color = "TEXT_MUTED",
                      text_align = "center", wrap = true })
            ),
        })
    end
    return { type = "tetris_view" }
end

function Game:on_enter()
    -- engine.highscores caches per-key lists internally; no explicit
    -- load call needed here.
    game_state = "menu"
    status_text = ""
    math.randomseed(ez.system.millis())
end

function Game:on_exit()
    if self._tick then ez.system.cancel_timer(self._tick); self._tick = nil end
end

function Game:handle_key(key)
    local s = key.special
    local c = key.character
    if c then c = c:lower() end

    if game_state == "menu" then return nil end

    if s == "BACKSPACE" or s == "ESCAPE" or c == "q" then
        if self._tick then ez.system.cancel_timer(self._tick); self._tick = nil end
        game_state = "menu"
        self:set_state({})
        return "handled"
    end

    if game_state == "over" then
        if c == "r" then reset_world(); return "handled" end
        if c == "m" then
            if self._tick then ez.system.cancel_timer(self._tick); self._tick = nil end
            game_state = "menu"; self:set_state({}); return "handled"
        end
        return "handled"
    end

    -- Gameplay keys.
    if s == "LEFT"  or c == "a" then try_move(-1, 0, 0); return "handled" end
    if s == "RIGHT" or c == "d" then try_move( 1, 0, 0); return "handled" end
    if s == "UP"    or c == "w" then try_move( 0, 0, 1); return "handled" end
    if s == "DOWN"  or c == "s" then
        -- Each DOWN tap also nudges the piece down immediately so the
        -- first press isn't eaten by the soft-drop timer reduction.
        if try_move(0, 1, 0) then score = score + 1 end
        soft_drop_until = ez.system.millis() + SOFT_DROP_HOLD_MS
        return "handled"
    end
    if c == " " or s == "ENTER" then hard_drop(); return "handled" end
    return nil
end

return Game
