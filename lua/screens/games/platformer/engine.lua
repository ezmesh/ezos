-- Platformer physics + collision + rendering.
--
-- Single tick of the simulation:
--   1. read input -> set desired horizontal accel + jump request
--   2. apply gravity, clamp to terminal velocity
--   3. integrate X, resolve against solid tiles (axis-separated sweep)
--   4. integrate Y, resolve against solid + one-way tiles, set on_ground
--   5. trigger checks: spike, goal, enemy contact
--   6. enemies: walk + edge/wall flip
--
-- Collisions are resolved one axis at a time to keep corner cases sane:
-- if the player is jumping into the underside of a corner block, the X
-- pass blocks the horizontal motion before the Y pass tries to.

local levels_mod = require("screens.games.platformer.levels")

local E = {}

-- ---------------------------------------------------------------------------
-- Geometry & physics constants
-- ---------------------------------------------------------------------------

E.SCREEN_W = 320
E.SCREEN_H = 240
E.HUD_H    = 16
E.TILE     = 16
E.ROWS     = 14    -- playfield rows below the HUD
E.PLAY_H   = E.SCREEN_H - E.HUD_H

E.PLAYER_W = 10
E.PLAYER_H = 14
E.ENEMY_W  = 12
E.ENEMY_H  = 12

E.GRAVITY            = 0.5
E.MAX_FALL           = 7.0
E.WALK_TARGET_SPEED  = 2.4
E.WALK_ACCEL_GROUND  = 0.55
E.WALK_ACCEL_AIR     = 0.22
E.FRICTION_NORMAL    = 0.35
E.FRICTION_ICE       = 0.04
E.JUMP_VY            = -7.0
E.COYOTE_FRAMES      = 4
E.JUMP_BUFFER_FRAMES = 4    -- jump pressed up to N frames before landing still fires
E.STOMP_BOUNCE_VY    = -4.5

E.ENEMY_SPEED        = 1.0

-- ---------------------------------------------------------------------------
-- Color cache. Resolved at level load (display driver may not be ready
-- at module load time). Keyed by env name -> resolved RGB565 table.
-- ---------------------------------------------------------------------------

local _color_cache = {}

local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

local function resolve_palette(env_name)
    if _color_cache[env_name] then return _color_cache[env_name] end
    local pal = levels_mod.PALETTES[env_name] or levels_mod.PALETTES.forest
    local out = {}
    for k, triple in pairs(pal) do
        out[k] = rgb(triple[1], triple[2], triple[3])
    end
    _color_cache[env_name] = out
    return out
end

-- Some palette keys are referenced from the HUD outside the active level
-- (e.g. a generic dim text). Provide a default fallback.
function E.colors(env_name)
    return resolve_palette(env_name or "forest")
end

-- ---------------------------------------------------------------------------
-- Level loading
-- ---------------------------------------------------------------------------

-- Build a level instance from a definition table. Returns:
--   { width, height, env, palette, rows (array), tile(c, r) }
-- where tile(col, row) returns the character at that cell or '#' for
-- out-of-bounds (so the player can't fly off the world horizontally).
function E.load_level(idx)
    local def = levels_mod.LEVELS[idx]
    if not def then return nil, "no level " .. tostring(idx) end

    local rows = def.rows
    local h = #rows
    local w = #(rows[1] or "")
    -- Sanity: every row must be the same width. Misaligned data is a
    -- pain to debug at runtime — bail at load with a clear message.
    for ri, r in ipairs(rows) do
        if #r ~= w then
            return nil, string.format("level %d row %d width %d, expected %d",
                idx, ri, #r, w)
        end
    end

    local L = {
        idx     = idx,
        env     = def.env,
        palette = resolve_palette(def.env),
        rows    = rows,
        width   = w,
        height  = h,
    }

    -- Spawn points. P1 at 's', P2 at 'S' (falls back to P1).
    L.p1_spawn_x, L.p1_spawn_y = 0, 0
    L.p2_spawn_x, L.p2_spawn_y = nil, nil
    -- Goal AABB inferred from the first 'G' tile. Levels with multiple
    -- 'G' chars (e.g. a 'G' column) treat the bbox as the column; we
    -- track first/last to compute it.
    L.goal = nil
    L.enemies_seed = {}

    local goal_min_c, goal_max_c, goal_min_r, goal_max_r
    for r = 1, h do
        local row = rows[r]
        for c = 1, w do
            local ch = row:sub(c, c)
            if ch == "s" then
                L.p1_spawn_x = (c - 1) * E.TILE + (E.TILE - E.PLAYER_W) / 2
                L.p1_spawn_y = (r - 1) * E.TILE + (E.TILE - E.PLAYER_H)
            elseif ch == "S" then
                L.p2_spawn_x = (c - 1) * E.TILE + (E.TILE - E.PLAYER_W) / 2
                L.p2_spawn_y = (r - 1) * E.TILE + (E.TILE - E.PLAYER_H)
            elseif ch == "G" then
                goal_min_c = math.min(goal_min_c or c, c)
                goal_max_c = math.max(goal_max_c or c, c)
                goal_min_r = math.min(goal_min_r or r, r)
                goal_max_r = math.max(goal_max_r or r, r)
            elseif ch == "e" then
                L.enemies_seed[#L.enemies_seed + 1] = {
                    x = (c - 1) * E.TILE + (E.TILE - E.ENEMY_W) / 2,
                    y = (r - 1) * E.TILE + (E.TILE - E.ENEMY_H),
                }
            end
        end
    end

    if goal_min_c then
        L.goal = {
            x = (goal_min_c - 1) * E.TILE,
            y = (goal_min_r - 1) * E.TILE,
            w = (goal_max_c - goal_min_c + 1) * E.TILE,
            h = (goal_max_r - goal_min_r + 1) * E.TILE,
        }
    end

    -- Tile lookup with out-of-bounds = solid wall (left/right) and
    -- empty above. Below-floor is killing pit (handled in step()).
    function L:tile(c, r)
        if c < 1 or c > self.width then return "#" end
        if r < 1 then return " " end
        if r > self.height then return " " end
        return self.rows[r]:sub(c, c)
    end

    -- Tile's vertical kind: solid (full block), oneway (collide top
    -- only), spike (kill), goal (clear), enemy seed (cosmetic), or
    -- empty. Used by the physics resolver and the renderer.
    function L:kind(ch)
        if ch == "#" then return "solid"
        elseif ch == "=" then return "oneway"
        elseif ch == "^" then return "spike"
        elseif ch == "G" then return "goal"
        else return "empty" end
    end

    return L
end

-- ---------------------------------------------------------------------------
-- Tile-vs-AABB sweep helpers.
-- ---------------------------------------------------------------------------

-- Iterate every tile cell that an AABB at (x, y) with size (w, h)
-- overlaps. Yields (col, row, char) for each. The grid is 1-indexed.
local function for_each_overlap(L, x, y, w, h, fn)
    local c0 = math.max(1, math.floor(x / E.TILE) + 1)
    local c1 = math.min(L.width, math.floor((x + w - 1) / E.TILE) + 1)
    local r0 = math.max(1, math.floor(y / E.TILE) + 1)
    local r1 = math.min(L.height, math.floor((y + h - 1) / E.TILE) + 1)
    for r = r0, r1 do
        for c = c0, c1 do
            local ch = L.rows[r]:sub(c, c)
            if fn(c, r, ch) == "stop" then return end
        end
    end
end

-- Check whether (x, y, w, h) overlaps any solid tile. Used for grounded
-- detection and trigger checks — pure read, no resolve.
local function overlaps_solid(L, x, y, w, h)
    local hit = false
    for_each_overlap(L, x, y, w, h, function(c, r, ch)
        if ch == "#" then hit = true; return "stop" end
    end)
    return hit
end

-- Resolve a horizontal move. Move (entity.x) by dx, then push back out
-- of any solid tile along the X axis. Returns true if the move was
-- blocked (entity.x shifted to stop at the wall).
local function resolve_x(L, ent, dx)
    ent.x = ent.x + dx
    local blocked = false
    for_each_overlap(L, ent.x, ent.y, ent.w, ent.h, function(c, r, ch)
        if ch == "#" then
            local left  = (c - 1) * E.TILE
            local right = c * E.TILE
            if dx > 0 then
                ent.x = left - ent.w
            elseif dx < 0 then
                ent.x = right
            end
            blocked = true
            return "stop"
        end
    end)
    return blocked
end

-- Resolve a vertical move with one-way support. Returns:
--   landed      true if vy was positive and we hit a floor
--   bumped_head true if vy was negative and we hit a ceiling
local function resolve_y(L, ent, dy)
    local prev_bottom = ent.y + ent.h
    ent.y = ent.y + dy
    local landed, bumped = false, false

    for_each_overlap(L, ent.x, ent.y, ent.w, ent.h, function(c, r, ch)
        if ch == "#" then
            local top    = (r - 1) * E.TILE
            local bottom = r * E.TILE
            if dy > 0 then
                ent.y = top - ent.h
                landed = true
            elseif dy < 0 then
                ent.y = bottom
                bumped = true
            end
            return "stop"
        elseif ch == "=" then
            -- One-way: only collide if we were above the platform's top
            -- in the previous frame and we're moving down now. Avoids
            -- the player catching on the underside while jumping up.
            if dy > 0 then
                local top = (r - 1) * E.TILE
                if prev_bottom <= top + 1 then
                    ent.y = top - ent.h
                    landed = true
                    return "stop"
                end
            end
        end
    end)

    return landed, bumped
end

-- Trigger checks. Run after the resolved move so the entity is at its
-- final position. Returns "spike", "goal", or nil.
local function trigger_check(L, ent)
    local result
    for_each_overlap(L, ent.x, ent.y, ent.w, ent.h, function(c, r, ch)
        if ch == "^" then result = "spike"; return "stop" end
        if ch == "G" then result = "goal";  return "stop" end
    end)
    return result
end

-- ---------------------------------------------------------------------------
-- World creation + state
-- ---------------------------------------------------------------------------

-- Build a fresh world for a level + player count. Returns a world table
-- with players[], enemies[], camera_x, won, dead.
function E.new_world(level, num_players)
    num_players = num_players or 1
    local players = {}
    for i = 1, num_players do
        local sx, sy
        if i == 1 then
            sx, sy = level.p1_spawn_x, level.p1_spawn_y
        else
            sx = level.p2_spawn_x or level.p1_spawn_x
            sy = level.p2_spawn_y or level.p1_spawn_y
        end
        players[i] = {
            x = sx, y = sy, vx = 0, vy = 0,
            w = E.PLAYER_W, h = E.PLAYER_H,
            on_ground = false,
            facing = 1,             -- 1 right, -1 left
            coyote = 0,
            jump_buffer = 0,
            alive = true,
            reached_goal = false,
            id = i,
        }
    end

    local enemies = {}
    for _, seed in ipairs(level.enemies_seed) do
        enemies[#enemies + 1] = {
            x = seed.x, y = seed.y, vx = -E.ENEMY_SPEED, vy = 0,
            w = E.ENEMY_W, h = E.ENEMY_H,
            alive = true,
        }
    end

    return {
        level     = level,
        players   = players,
        enemies   = enemies,
        camera_x  = 0,
        won       = false,        -- all live players reached the goal
        any_dead  = false,        -- at least one player died this tick (transient)
        tick      = 0,
    }
end

-- ---------------------------------------------------------------------------
-- Per-tick simulation
-- ---------------------------------------------------------------------------

-- Advance an entity (player or enemy) by one frame using its current
-- vx/vy. Calls back into the level for collision. Mutates ent in place.
local function step_entity(L, ent, env)
    -- Gravity + terminal velocity.
    ent.vy = ent.vy + E.GRAVITY
    if ent.vy > E.MAX_FALL then ent.vy = E.MAX_FALL end

    -- Resolve X first.
    if ent.vx ~= 0 then
        if resolve_x(L, ent, ent.vx) then ent.vx = 0 end
    end

    -- Resolve Y, capture grounded.
    local landed, bumped = resolve_y(L, ent, ent.vy)
    if landed then
        ent.vy = 0
        ent.on_ground = true
    elseif bumped then
        ent.vy = 0
        ent.on_ground = false
    else
        ent.on_ground = false
    end
end

-- Friction model. Ice levels skid for a long time so the user has to
-- manage momentum; everything else slows quickly when input is zero.
local function apply_friction(ent, env, has_input)
    if not ent.on_ground or has_input then return end
    local f = (env == "ice") and E.FRICTION_ICE or E.FRICTION_NORMAL
    if math.abs(ent.vx) < f then
        ent.vx = 0
    elseif ent.vx > 0 then
        ent.vx = ent.vx - f
    else
        ent.vx = ent.vx + f
    end
end

-- Apply player input for one frame. `input` shape:
--   { left, right, jump }  -- booleans
local function apply_player_input(player, input, env)
    local accel = player.on_ground and E.WALK_ACCEL_GROUND or E.WALK_ACCEL_AIR
    local has_input = false

    if input.left then
        player.vx = player.vx - accel
        if player.vx < -E.WALK_TARGET_SPEED then
            player.vx = -E.WALK_TARGET_SPEED
        end
        player.facing = -1
        has_input = true
    end
    if input.right then
        player.vx = player.vx + accel
        if player.vx > E.WALK_TARGET_SPEED then
            player.vx = E.WALK_TARGET_SPEED
        end
        player.facing = 1
        has_input = true
    end

    -- Jump with coyote time + buffer. The buffer lets a slightly-early
    -- press still fire the jump on landing, which is the difference
    -- between "tight" and "infuriating" jump feel.
    if input.jump then
        player.jump_buffer = E.JUMP_BUFFER_FRAMES
    end

    if player.jump_buffer > 0 and player.coyote > 0 then
        player.vy = E.JUMP_VY
        player.on_ground = false
        player.coyote = 0
        player.jump_buffer = 0
    end

    apply_friction(player, env, has_input)
end

-- Enemy AI: walk toward `vx` direction. Flip direction if blocked by a
-- wall OR if the next step would walk off a ledge (no floor under the
-- forward foot). Keeps enemies on their platform without per-tile
-- waypoints.
local function step_enemy(L, en)
    if not en.alive then return end

    -- Probe the next position one tile ahead in walk direction.
    local probe_x = en.x + (en.vx > 0 and en.w or -1)
    local probe_foot_y = en.y + en.h + 1  -- one pixel below feet
    local probe_col = math.floor(probe_x / E.TILE) + 1
    local probe_row = math.floor(probe_foot_y / E.TILE) + 1

    local floor_ch = L:tile(probe_col, probe_row)
    local wall_ch  = L:tile(math.floor(probe_x / E.TILE) + 1,
                            math.floor((en.y + en.h - 1) / E.TILE) + 1)
    if wall_ch == "#" then
        en.vx = -en.vx
    elseif floor_ch ~= "#" and floor_ch ~= "=" then
        en.vx = -en.vx
    end

    step_entity(L, en, L.env)
end

-- Stomp check: was the player descending and is its bottom near the
-- enemy's top? Liberal margin (4 px) so the player doesn't have to land
-- pixel-perfect to score the kill.
local function stomped(player, enemy)
    if not player.alive or not enemy.alive then return false end
    if player.vy <= 0 then return false end
    local p_bottom = player.y + player.h
    local e_top    = enemy.y
    if math.abs(p_bottom - e_top) > 5 then return false end
    -- Horizontal overlap.
    if player.x + player.w <= enemy.x then return false end
    if enemy.x + enemy.w   <= player.x then return false end
    return true
end

local function aabb_overlap(a, b)
    if a.x + a.w <= b.x or b.x + b.w <= a.x then return false end
    if a.y + a.h <= b.y or b.y + b.h <= a.y then return false end
    return true
end

-- Single tick. `inputs` is an array indexed by player number, each entry
-- shaped like the apply_player_input() input table. Mutates `world`.
function E.step(world, inputs)
    world.tick = world.tick + 1
    local L = world.level
    world.any_dead = false

    for i, p in ipairs(world.players) do
        if p.alive and not p.reached_goal then
            local input = inputs[i] or { left = false, right = false, jump = false }
            apply_player_input(p, input, L.env)
            step_entity(L, p, L.env)

            -- Coyote: after leaving the ground, give the player a few
            -- forgiving frames to still trigger a jump. Reset on land.
            if p.on_ground then
                p.coyote = E.COYOTE_FRAMES
            elseif p.coyote > 0 then
                p.coyote = p.coyote - 1
            end
            if p.jump_buffer > 0 then
                p.jump_buffer = p.jump_buffer - 1
            end

            -- Trigger checks.
            local trig = trigger_check(L, p)
            if trig == "spike" then
                p.alive = false
                world.any_dead = true
            elseif trig == "goal" then
                p.reached_goal = true
            end

            -- Pit fall: anyone whose AABB top crosses the bottom of the
            -- playfield dies, regardless of biome.
            if p.y > L.height * E.TILE then
                p.alive = false
                world.any_dead = true
            end

            -- Player-vs-enemy.
            for _, en in ipairs(world.enemies) do
                if en.alive and aabb_overlap(p, en) then
                    if stomped(p, en) then
                        en.alive = false
                        p.vy = E.STOMP_BOUNCE_VY
                    else
                        p.alive = false
                        world.any_dead = true
                    end
                end
            end
        end
    end

    -- Enemies move after players so a stomp-kill registers before the
    -- enemy steps out from under the player's feet.
    for _, en in ipairs(world.enemies) do
        step_enemy(L, en)
    end

    -- Win condition: every player that's alive has reached the goal AND
    -- at least one player is alive. If ALL players are dead, the
    -- caller handles respawn — that's not a "won" state.
    local alive_count, goal_count = 0, 0
    for _, p in ipairs(world.players) do
        if p.alive then
            alive_count = alive_count + 1
            if p.reached_goal then goal_count = goal_count + 1 end
        end
    end
    if alive_count > 0 and goal_count == alive_count then
        world.won = true
    end

    -- Camera: follow the average of all live players, clamp to level.
    local cam_target = 0
    if alive_count > 0 then
        local sum = 0
        for _, p in ipairs(world.players) do
            if p.alive then sum = sum + p.x + p.w / 2 end
        end
        cam_target = sum / alive_count - E.SCREEN_W / 2
    end
    local max_cam = math.max(0, L.width * E.TILE - E.SCREEN_W)
    if cam_target < 0 then cam_target = 0 end
    if cam_target > max_cam then cam_target = max_cam end
    -- Smooth follow so the camera doesn't snap on the first frame.
    world.camera_x = world.camera_x + (cam_target - world.camera_x) * 0.25
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- Compute the world-space rect for a tile cell.
local function tile_rect(c, r)
    return (c - 1) * E.TILE, (r - 1) * E.TILE + E.HUD_H, E.TILE, E.TILE
end

-- Draw a single tile. Splits by character so the renderer can decorate
-- each kind (e.g. spikes are triangles, not rects).
local function draw_tile(d, ch, sx, sy, pal)
    if ch == "#" then
        d.fill_rect(sx, sy, E.TILE, E.TILE, pal.block)
        d.draw_rect(sx, sy, E.TILE, E.TILE, pal.block_edge)
    elseif ch == "=" then
        -- One-way platform: thin top slab + edge below for shadow.
        d.fill_rect(sx, sy, E.TILE, 4, pal.block)
        d.draw_hline(sx, sy + 4, E.TILE, pal.block_edge)
    elseif ch == "^" then
        -- Spike: two triangles per tile so the spike pattern reads.
        local mid_y = sy + E.TILE
        local h    = 8
        d.fill_triangle(sx,            mid_y,
                        sx + 4,        mid_y - h,
                        sx + 8,        mid_y, pal.spike)
        d.fill_triangle(sx + 8,        mid_y,
                        sx + 12,       mid_y - h,
                        sx + 16,       mid_y, pal.spike)
    elseif ch == "G" then
        -- Goal: a flag pole. Pole on the left, triangular flag pointing right.
        d.fill_rect(sx + 2, sy, 2, E.TILE, pal.goal)
        d.fill_triangle(sx + 4,  sy + 2,
                        sx + 4,  sy + 10,
                        sx + 14, sy + 6, pal.goal)
    end
end

-- Draw a player. Filled rect plus a 2x2 eye dot in the facing direction.
local function draw_player(d, p, sx, sy, pal)
    if not p.alive then return end
    d.fill_rect(sx, sy, p.w, p.h, pal.p1)
    -- Player 2 gets the alt color.
    if p.id == 2 then d.fill_rect(sx, sy, p.w, p.h, pal.p2) end
    local eye_x = sx + (p.facing > 0 and p.w - 4 or 2)
    d.fill_rect(eye_x, sy + 3, 2, 2, pal.eye)
end

local function draw_enemy(d, en, sx, sy, pal)
    if not en.alive then return end
    d.fill_rect(sx, sy, en.w, en.h, pal.enemy)
    -- Two eye dots so it reads as alive vs a stationary block.
    d.fill_rect(sx + 2, sy + 3, 2, 2, pal.eye)
    d.fill_rect(sx + en.w - 4, sy + 3, 2, 2, pal.eye)
end

-- Render one frame. `world` is from new_world / step. `hud` is a table
-- of strings the caller wants on top: { left = "L1  Lives 3", right = "..." }.
function E.render(d, world, hud)
    local L = world.level
    local pal = L.palette

    -- Background fill.
    d.fill_rect(0, 0, E.SCREEN_W, E.SCREEN_H, pal.bg)

    -- Tiles. Compute first/last col from camera so we don't iterate
    -- the whole level every frame on long stages.
    local cam_x = math.floor(world.camera_x)
    local first_c = math.max(1, math.floor(cam_x / E.TILE) + 1)
    local last_c  = math.min(L.width, math.floor((cam_x + E.SCREEN_W) / E.TILE) + 1)
    for r = 1, L.height do
        local row = L.rows[r]
        for c = first_c, last_c do
            local ch = row:sub(c, c)
            if ch ~= " " and ch ~= "." and ch ~= "s" and ch ~= "S" and ch ~= "e" then
                local wx, wy = tile_rect(c, r)
                draw_tile(d, ch, wx - cam_x, wy, pal)
            end
        end
    end

    -- Enemies + players. Skip when fully off-screen so very long levels
    -- don't pay for invisible work.
    for _, en in ipairs(world.enemies) do
        local sx = math.floor(en.x - cam_x)
        if sx + en.w >= 0 and sx <= E.SCREEN_W then
            draw_enemy(d, en, sx, math.floor(en.y) + E.HUD_H, pal)
        end
    end
    for _, p in ipairs(world.players) do
        local sx = math.floor(p.x - cam_x)
        if sx + p.w >= 0 and sx <= E.SCREEN_W then
            draw_player(d, p, sx, math.floor(p.y) + E.HUD_H, pal)
        end
    end

    -- HUD overlay.
    local theme = require("ezui.theme")
    d.fill_rect(0, 0, E.SCREEN_W, E.HUD_H, pal.hud_bg)
    d.draw_hline(0, E.HUD_H - 1, E.SCREEN_W, pal.block_edge)
    theme.set_font("small_aa")
    local fh = theme.font_height()
    local ty = (E.HUD_H - fh) // 2
    if hud and hud.left then
        d.draw_text(4, ty, hud.left, pal.hud_fg)
    end
    if hud and hud.right then
        local tw = theme.text_width(hud.right)
        d.draw_text(E.SCREEN_W - tw - 4, ty, hud.right, pal.hud_dim)
    end
end

-- Big centered banner overlay. Used for level-clear / game-over /
-- "press space" prompts. Drawn on top of the world.
function E.draw_banner(d, world, title, subtitle)
    local pal = world.level.palette
    local theme = require("ezui.theme")
    local band_h = 60
    local band_y = E.HUD_H + (E.PLAY_H - band_h) // 2
    d.fill_rect(0, band_y, E.SCREEN_W, band_h, pal.hud_bg)
    d.draw_hline(0, band_y, E.SCREEN_W, pal.block_edge)
    d.draw_hline(0, band_y + band_h - 1, E.SCREEN_W, pal.block_edge)

    theme.set_font("medium_aa")
    local tfh = theme.font_height()
    local tw = theme.text_width(title)
    d.draw_text((E.SCREEN_W - tw) // 2, band_y + 14, title, pal.hud_fg)

    if subtitle then
        theme.set_font("small_aa")
        local sw = theme.text_width(subtitle)
        d.draw_text((E.SCREEN_W - sw) // 2,
                    band_y + 14 + tfh + 6,
                    subtitle, pal.hud_dim)
    end
end

return E
