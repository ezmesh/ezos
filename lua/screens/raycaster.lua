-- FPS Raycaster: Doom-style first-person shooter
-- Explore a dungeon, shoot enemies, collect pickups.
-- W/S: forward/back, A/D: strafe, trackball L/R: turn, Space: shoot, R: restart, Q: quit

local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")

local FPS = { title = "Raycaster" }

-- Math shortcuts for performance
local floor = math.floor
local cos = math.cos
local sin = math.sin
local abs = math.abs
local sqrt = math.sqrt
local random = math.random
local pi = math.pi
local atan2 = math.atan

local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

-- Screen and viewport constants
local SW, SH = 320, 240
local VIEW_TOP = 18           -- viewport Y offset (below HUD)
local VIEW_H = SH - VIEW_TOP  -- 222 pixels of 3D view
local NUM_RAYS = 160           -- one ray per 2 horizontal pixels
local FOV = pi / 3            -- 60 degree field of view
local HALF_FOV = FOV / 2

-- Map: 16x16. Four corner rooms (NW spawn, NE armory, SW, SE) connected by
-- a central atrium with two steel pillars. Each room has one doorway.
-- Wall types: 0=empty, 1=gray stone (outer), 2=red brick (rooms), 3=blue steel
local MAP_S = 16
local MAP = {
    {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1},  -- y=1
    {1,0,0,0,0,2,0,0,0,0,2,0,0,0,0,1},  -- y=2  NW room | | NE room
    {1,0,0,0,0,2,0,0,0,0,2,0,0,0,0,1},  -- y=3
    {1,0,0,0,0,2,0,0,0,0,2,0,0,0,0,1},  -- y=4
    {1,2,2,2,0,2,0,0,0,0,2,0,2,2,2,1},  -- y=5  room south walls, doors at x=4, x=12
    {1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1},  -- y=6  atrium
    {1,0,0,3,3,0,0,0,0,0,0,3,3,0,0,1},  -- y=7  steel pillars
    {1,0,0,3,3,0,0,0,0,0,0,3,3,0,0,1},  -- y=8
    {1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1},  -- y=9
    {1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1},  -- y=10
    {1,2,2,2,0,2,0,0,0,0,2,0,2,2,2,1},  -- y=11 room north walls, doors at x=4, x=12
    {1,0,0,0,0,2,0,0,0,0,2,0,0,0,0,1},  -- y=12 SW room | | SE room
    {1,0,0,0,0,2,0,0,0,0,2,0,0,0,0,1},  -- y=13
    {1,0,0,0,0,2,0,0,0,0,2,0,0,0,0,1},  -- y=14
    {1,0,0,0,0,2,0,0,0,0,2,0,0,0,0,1},  -- y=15
    {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1},  -- y=16
}

-- Player state
local px, py, pa           -- position and angle
local health, ammo, score
local game_alive, game_won

-- Movement constants
local MOVE_SPD = 0.45      -- forward/back step per key press (keyboard repeat)
local STRAFE_SPD = 0.35
local TURN_SPD = pi / 20   -- 9 degrees per trackball tick

-- Weapon state
local shoot_timer = 0

-- Saved input settings to restore on exit
local saved_repeat_enabled, saved_repeat_delay, saved_repeat_rate, saved_tb_sens

-- Z-buffer: perpendicular wall distance for each ray column
local zbuf = {}

-- Ray result arrays (reused each frame to avoid GC pressure)
local ray_top   = {}
local ray_bot   = {}
local ray_wtype = {}
local ray_side  = {}
local ray_dist  = {}

-- Pre-computed wall colors: [wall_type][side+1], side 0=E/W bright, 1=N/S darker
local wall_colors = {}
local ceil_col, floor_col

-- Enemies and pickups
local enemies = {}
local pickups = {}

---------------------------------------------------------------------------
-- Initialization helpers
---------------------------------------------------------------------------
local function init_colors()
    wall_colors[1] = { rgb(155, 155, 165), rgb(105, 105, 115) }  -- gray stone
    wall_colors[2] = { rgb(165, 65, 50),   rgb(115, 45, 30)  }   -- red brick
    wall_colors[3] = { rgb(50, 85, 165),    rgb(30, 60, 115)  }   -- blue steel
    ceil_col  = rgb(25, 25, 45)
    floor_col = rgb(50, 42, 32)
end

-- Darken an RGB565 color by factor 0..1
local function shade(color, f)
    if f >= 1 then return color end
    if f <= 0 then return 0 end
    local r = floor(floor(color / 2048) % 32 * f)
    local g = floor(floor(color / 32) % 64 * f)
    local b = floor(color % 32 * f)
    return r * 2048 + g * 32 + b
end

local function is_wall(x, y)
    local mx, my = floor(x), floor(y)
    if mx < 1 or mx > MAP_S or my < 1 or my > MAP_S then return true end
    return MAP[my][mx] > 0
end

-- Collision check: test 4 corners of a small bounding box
local function can_move(nx, ny)
    local r = 0.2
    return not is_wall(nx - r, ny - r)
       and not is_wall(nx + r, ny - r)
       and not is_wall(nx - r, ny + r)
       and not is_wall(nx + r, ny + r)
end

local function reset_game()
    -- Spawn in NW room centered, facing south toward the door.
    px, py = 3.5, 3.5
    pa = pi / 2
    health = 100
    ammo = 30
    score = 0
    game_alive = true
    game_won = false
    shoot_timer = 0

    -- Zombies distributed across the other three rooms and the atrium.
    -- NW room is left empty so the player gets a safe starting breath.
    enemies = {
        -- NE room (armory): two guarding the ammo
        { x = 12.5, y = 2.5,  hp = 3, alive = true, cooldown = 0 },
        { x = 13.5, y = 3.5,  hp = 3, alive = true, cooldown = 0 },

        -- Atrium: flanking each pillar, visible as soon as you exit NW
        { x = 7.5,  y = 6.5,  hp = 3, alive = true, cooldown = 0 },
        { x = 9.5,  y = 9.5,  hp = 3, alive = true, cooldown = 0 },

        -- SW room
        { x = 3.5,  y = 13.5, hp = 3, alive = true, cooldown = 0 },
        { x = 2.5,  y = 14.5, hp = 3, alive = true, cooldown = 0 },

        -- SE room
        { x = 12.5, y = 13.5, hp = 3, alive = true, cooldown = 0 },
        { x = 13.5, y = 14.5, hp = 3, alive = true, cooldown = 0 },
    }

    pickups = {
        -- NW room (safe start)
        { x = 2.5,  y = 2.5,  kind = "hp",   active = true },

        -- NE room (armory — extra ammo reward)
        { x = 11.5, y = 3.5,  kind = "ammo", active = true },

        -- Atrium
        { x = 8.5,  y = 8.5,  kind = "hp",   active = true },
        { x = 5.5,  y = 9.5,  kind = "ammo", active = true },

        -- SW room
        { x = 4.5,  y = 14.5, kind = "ammo", active = true },

        -- SE room
        { x = 13.5, y = 12.5, kind = "hp",   active = true },
    }

    for i = 1, NUM_RAYS do zbuf[i] = 100 end
end

---------------------------------------------------------------------------
-- Raycasting: DDA algorithm (one ray per 2-pixel screen column)
---------------------------------------------------------------------------
local function cast_rays()
    for col = 0, NUM_RAYS - 1 do
        local offset = -HALF_FOV + (col + 0.5) * FOV / NUM_RAYS
        local angle = pa + offset
        local rdx = cos(angle)
        local rdy = sin(angle)
        if abs(rdx) < 1e-8 then rdx = 1e-8 end
        if abs(rdy) < 1e-8 then rdy = 1e-8 end

        local mx, my = floor(px), floor(py)
        local ddx = abs(1 / rdx)
        local ddy = abs(1 / rdy)

        local sx, sdx
        if rdx < 0 then sx = -1; sdx = (px - mx) * ddx
        else             sx = 1;  sdx = (mx + 1 - px) * ddx end

        local sy, sdy
        if rdy < 0 then sy = -1; sdy = (py - my) * ddy
        else             sy = 1;  sdy = (my + 1 - py) * ddy end

        local side = 0
        local wt = 1
        for _ = 1, 40 do
            if sdx < sdy then
                sdx = sdx + ddx; mx = mx + sx; side = 0
            else
                sdy = sdy + ddy; my = my + sy; side = 1
            end
            if mx < 1 or mx > MAP_S or my < 1 or my > MAP_S then
                wt = 1; break
            end
            if MAP[my][mx] > 0 then
                wt = MAP[my][mx]; break
            end
        end

        -- DDA with a unit ray direction gives Euclidean distance along the
        -- ray. To avoid fisheye, project onto the camera forward axis by
        -- multiplying by cos(offset). Without this, walls perpendicular to
        -- the camera bulge outward at screen edges.
        local along = (side == 0) and (sdx - ddx) or (sdy - ddy)
        local pd = along * cos(offset)
        if pd < 0.1 then pd = 0.1 end

        local wh = VIEW_H / pd
        if wh > VIEW_H * 2 then wh = VIEW_H * 2 end

        local c = col + 1
        ray_top[c]   = floor(VIEW_TOP + (VIEW_H - wh) / 2)
        ray_bot[c]   = floor(VIEW_TOP + (VIEW_H + wh) / 2)
        ray_wtype[c] = wt
        ray_side[c]  = side
        ray_dist[c]  = pd
        zbuf[c]      = pd
    end
end

---------------------------------------------------------------------------
-- Drawing: walls, sprites, weapon, HUD
---------------------------------------------------------------------------
local function draw_walls(d)
    for c = 1, NUM_RAYS do
        local sx = (c - 1) * 2
        local t = ray_top[c]
        local b = ray_bot[c]
        local dist = ray_dist[c]

        -- Distance fog: objects fade to black at distance
        local f = 1.0 / (1.0 + dist * 0.12)

        -- Ceiling strip
        if t > VIEW_TOP then
            d.fill_rect(sx, VIEW_TOP, 2, t - VIEW_TOP, shade(ceil_col, f * 0.5 + 0.5))
        end

        -- Wall strip with side shading (E/W faces brighter than N/S)
        local base = wall_colors[ray_wtype[c]] or wall_colors[1]
        d.fill_rect(sx, t, 2, b - t, shade(base[ray_side[c] + 1], f))

        -- Floor strip
        if b < SH then
            d.fill_rect(sx, b, 2, SH - b, shade(floor_col, f * 0.5 + 0.5))
        end
    end
end

-- Generic sprite renderer: sorts a list by distance and draws each with draw_fn
local function draw_sprites(d, list, alive_key, draw_fn)
    local vis = {}
    for _, s in ipairs(list) do
        if s[alive_key] then
            local dx = s.x - px
            local dy = s.y - py
            local dist = sqrt(dx * dx + dy * dy)
            if dist > 0.3 then
                local ang = atan2(dy, dx) - pa
                if ang > pi then ang = ang - 2 * pi
                elseif ang < -pi then ang = ang + 2 * pi end
                if abs(ang) < HALF_FOV + 0.1 then
                    vis[#vis + 1] = { s = s, dist = dist, ang = ang }
                end
            end
        end
    end

    -- Painter's algorithm: draw far sprites first
    table.sort(vis, function(a, b) return a.dist > b.dist end)

    for _, v in ipairs(vis) do
        -- Screen X from angle offset within FOV
        local sx = floor((v.ang / FOV + 0.5) * SW)

        -- Match the wall projection: convert Euclidean distance to the
        -- camera-forward perpendicular so sprite scale and z-buffer
        -- comparison stay consistent with corrected wall distances.
        local perp = v.dist * cos(v.ang)
        if perp < 0.1 then perp = 0.1 end

        local sp_h = floor(VIEW_H * 0.7 / perp)
        if sp_h < 3 then sp_h = 3 end
        if sp_h > VIEW_H then sp_h = VIEW_H end

        -- Only draw if in front of the wall at the sprite's center column
        local zi = floor(sx / 2) + 1
        if zi < 1 then zi = 1 end
        if zi > NUM_RAYS then zi = NUM_RAYS end
        if perp < zbuf[zi] then
            draw_fn(d, v.s, sx, sp_h)
        end
    end
end

local function draw_enemy(d, e, sx, sp_h)
    local sp_w = floor(sp_h * 0.5)
    if sp_w < 2 then sp_w = 2 end
    local top = floor(VIEW_TOP + (VIEW_H - sp_h) / 2)
    local left = sx - floor(sp_w / 2)

    -- Body (red)
    local body_top = top + floor(sp_h * 0.25)
    d.fill_rect(left, body_top, sp_w, sp_h - floor(sp_h * 0.25), rgb(175, 30, 30))

    -- Head (skin color)
    local hw = floor(sp_w * 0.55)
    if hw < 2 then hw = 2 end
    local hh = floor(sp_h * 0.28)
    if hh < 2 then hh = 2 end
    d.fill_rect(sx - floor(hw / 2), top, hw, hh, rgb(195, 145, 105))

    -- Glowing red eyes when close enough to see detail
    if sp_h > 24 then
        local ey = top + floor(hh * 0.45)
        local sep = floor(hw * 0.25)
        d.fill_rect(sx - sep - 1, ey, 2, 2, rgb(255, 40, 40))
        d.fill_rect(sx + sep, ey, 2, 2, rgb(255, 40, 40))
    end
end

local function draw_pickup(d, p, sx, sp_h)
    local sp_w = floor(sp_h * 0.7)
    if sp_w < 3 then sp_w = 3 end
    -- Pickups sit on the ground (lower portion of viewport)
    local top = floor(VIEW_TOP + VIEW_H * 0.5 + sp_h * 0.15)
    local left = sx - floor(sp_w / 2)

    if p.kind == "hp" then
        -- Green box with white cross
        d.fill_rect(left, top, sp_w, sp_h, rgb(0, 160, 0))
        if sp_w > 6 then
            local cw = floor(sp_w * 0.3)
            local ch = floor(sp_h * 0.3)
            d.fill_rect(sx - floor(cw / 2), top + 1, cw, sp_h - 2, rgb(240, 240, 240))
            d.fill_rect(left + 1, top + floor(sp_h / 2) - floor(ch / 2), sp_w - 2, ch, rgb(240, 240, 240))
        end
    else
        -- Yellow ammo box
        d.fill_rect(left, top, sp_w, sp_h, rgb(200, 175, 25))
        d.draw_rect(left, top, sp_w, sp_h, rgb(100, 85, 10))
    end
end

local function draw_weapon(d)
    local cx = 160

    -- Muzzle flash when shooting
    if shoot_timer > 0 then
        d.fill_triangle(cx, SH - 90, cx - 16, SH - 58, cx + 16, SH - 58,
                         rgb(255, 255, 100))
        d.fill_triangle(cx, SH - 96, cx - 8, SH - 65, cx + 8, SH - 65,
                         rgb(255, 255, 210))
    end

    -- Barrel
    d.fill_rect(cx - 4, SH - 72, 8, 30, rgb(140, 140, 155))
    -- Slide
    d.fill_rect(cx - 6, SH - 72, 12, 9, rgb(120, 120, 135))
    -- Receiver
    d.fill_rect(cx - 12, SH - 44, 24, 16, rgb(130, 130, 145))
    -- Grip
    d.fill_rect(cx - 8, SH - 30, 16, 24, rgb(120, 85, 45))
    -- Trigger guard
    d.fill_rect(cx + 6, SH - 40, 8, 2, rgb(110, 110, 125))
end

local function draw_crosshair(d)
    local cx, cy = 160, floor(VIEW_TOP + VIEW_H / 2)
    local cc = rgb(0, 255, 0)
    -- Larger crosshair gap for better visibility
    d.fill_rect(cx - 8, cy, 6, 1, cc)
    d.fill_rect(cx + 3, cy, 6, 1, cc)
    d.fill_rect(cx, cy - 8, 1, 6, cc)
    d.fill_rect(cx, cy + 3, 1, 6, cc)
    -- Center dot
    d.fill_rect(cx, cy, 1, 1, cc)
end

local function draw_hud(d)
    d.fill_rect(0, 0, SW, VIEW_TOP, rgb(20, 20, 35))
    d.draw_hline(0, VIEW_TOP - 1, SW, rgb(60, 60, 90))

    theme.set_font("small")

    -- Health bar with color indicating severity
    local hb_w = 60
    local hb_fill = floor(hb_w * health / 100)
    local hc
    if health > 50 then hc = rgb(0, 210, 0)
    elseif health > 25 then hc = rgb(230, 210, 0)
    else hc = rgb(230, 0, 0) end
    d.fill_rect(4, 3, hb_fill, 12, hc)
    d.draw_rect(4, 3, hb_w, 12, rgb(200, 200, 200))
    d.draw_text(hb_w + 8, 2, tostring(health), rgb(255, 255, 255))

    -- Ammo count
    local at = "Ammo:" .. ammo
    d.draw_text(SW - theme.text_width(at) - 4, 2, at, rgb(255, 255, 255))

    -- Score
    local st = tostring(score)
    d.draw_text(floor(SW / 2 - theme.text_width(st) / 2), 2, st, rgb(200, 200, 200))
end

local function draw_minimap(d)
    local cs = 3  -- pixels per map cell
    local ox = SW - MAP_S * cs - 4
    local oy = SH - MAP_S * cs - 4

    -- Dark background with visible border
    d.fill_rect(ox - 2, oy - 2, MAP_S * cs + 4, MAP_S * cs + 4, rgb(0, 0, 0))
    d.draw_rect(ox - 2, oy - 2, MAP_S * cs + 4, MAP_S * cs + 4, rgb(60, 60, 80))

    for my = 1, MAP_S do
        for mx = 1, MAP_S do
            if MAP[my][mx] > 0 then
                d.fill_rect(ox + (mx - 1) * cs, oy + (my - 1) * cs, cs, cs, rgb(75, 75, 75))
            end
        end
    end

    -- Player position and facing direction
    local pdx = floor((px - 1) * cs)
    local pdy = floor((py - 1) * cs)
    d.fill_rect(ox + pdx, oy + pdy, 2, 2, rgb(0, 255, 0))

    -- Direction indicator (small line)
    local dir_len = 4
    local dx2 = floor(cos(pa) * dir_len)
    local dy2 = floor(sin(pa) * dir_len)
    d.fill_rect(ox + pdx + dx2, oy + pdy + dy2, 1, 1, rgb(0, 200, 0))

    -- Enemy positions
    for _, e in ipairs(enemies) do
        if e.alive then
            d.fill_rect(ox + floor((e.x - 1) * cs), oy + floor((e.y - 1) * cs),
                         2, 2, rgb(255, 0, 0))
        end
    end
end

local function draw_end_screen(d)
    d.fill_rect(0, 0, SW, SH, rgb(0, 0, 0))

    theme.set_font("large")
    local title = game_won and "YOU WIN!" or "GAME OVER"
    local tc = game_won and rgb(0, 215, 0) or rgb(215, 0, 0)
    d.draw_text(floor((SW - theme.text_width(title)) / 2), 50, title, tc)

    theme.set_font("medium")
    local sc = "Score: " .. score
    d.draw_text(floor((SW - theme.text_width(sc)) / 2), 100, sc, rgb(195, 195, 195))

    theme.set_font("small")
    local hint = "R:restart  Q:quit"
    d.draw_text(floor((SW - theme.text_width(hint)) / 2), 150, hint, rgb(130, 130, 130))
end

---------------------------------------------------------------------------
-- Custom node: full-screen rendering surface
---------------------------------------------------------------------------
if not node_mod.handler("fps_view") then
    node_mod.register("fps_view", {
        measure = function(n, mw, mh) return 320, 240 end,

        draw = function(n, d, x, y, w, h)
            if not game_alive or game_won then
                draw_end_screen(d)
                return
            end

            cast_rays()
            draw_walls(d)
            draw_sprites(d, pickups, "active", draw_pickup)
            draw_sprites(d, enemies, "alive",  draw_enemy)
            draw_weapon(d)
            draw_crosshair(d)
            draw_hud(d)
            draw_minimap(d)
        end,
    })
end

---------------------------------------------------------------------------
-- Game logic
---------------------------------------------------------------------------
local function do_shoot()
    if ammo <= 0 or shoot_timer > 0 then return end
    ammo = ammo - 1
    shoot_timer = 4

    -- Hitscan: find the nearest enemy within the crosshair cone
    local best_dist = 999
    local best_enemy = nil

    for _, e in ipairs(enemies) do
        if e.alive then
            local dx = e.x - px
            local dy = e.y - py
            local dist = sqrt(dx * dx + dy * dy)
            local ang = atan2(dy, dx) - pa
            if ang > pi then ang = ang - 2 * pi
            elseif ang < -pi then ang = ang + 2 * pi end

            -- Hit cone widens at close range for easier targeting
            local half_cone = 0.35 / dist
            if half_cone < 0.08 then half_cone = 0.08 end
            if half_cone > 0.4 then half_cone = 0.4 end

            if abs(ang) < half_cone and dist < best_dist then
                -- Verify no wall between player and enemy
                local scol = floor((ang / FOV + 0.5) * NUM_RAYS) + 1
                if scol < 1 then scol = 1 end
                if scol > NUM_RAYS then scol = NUM_RAYS end
                if dist < zbuf[scol] then
                    best_dist = dist
                    best_enemy = e
                end
            end
        end
    end

    if best_enemy then
        best_enemy.hp = best_enemy.hp - 1
        if best_enemy.hp <= 0 then
            best_enemy.alive = false
            score = score + 100
        else
            score = score + 10
        end
    end
end

local function update_enemies()
    for _, e in ipairs(enemies) do
        if e.alive then
            if e.cooldown > 0 then e.cooldown = e.cooldown - 1 end

            local dx = px - e.x
            local dy = py - e.y
            local dist = sqrt(dx * dx + dy * dy)

            -- Chase player when within detection range
            if dist < 7 and dist > 0.01 then
                local spd = 0.018
                local nx = e.x + dx / dist * spd
                local ny = e.y + dy / dist * spd
                if not is_wall(nx, ny) then
                    e.x = nx
                    e.y = ny
                end
            end

            -- Melee attack when adjacent
            if dist < 0.8 and e.cooldown <= 0 then
                health = health - 5
                e.cooldown = 45  -- ~1.5 seconds between attacks
                if health <= 0 then
                    health = 0
                    game_alive = false
                end
            end
        end
    end
end

local function check_pickups()
    for _, p in ipairs(pickups) do
        if p.active then
            local dx = px - p.x
            local dy = py - p.y
            if dx * dx + dy * dy < 0.4 then
                p.active = false
                if p.kind == "hp" then
                    health = math.min(100, health + 25)
                else
                    ammo = ammo + 10
                end
            end
        end
    end
end

local function check_win()
    for _, e in ipairs(enemies) do
        if e.alive then return end
    end
    game_won = true
    score = score + 500
end

---------------------------------------------------------------------------
-- Screen lifecycle
---------------------------------------------------------------------------
function FPS:build(state)
    return { type = "fps_view" }
end

function FPS:on_enter()
    math.randomseed(ez.system.millis())
    init_colors()
    reset_game()

    -- Key repeat stays off — W/S hold is driven by matrix polling, not repeat.
    -- But we still save/restore in case a user has enabled it globally.
    saved_repeat_enabled = ez.keyboard.get_repeat_enabled()
    saved_repeat_delay   = ez.keyboard.get_repeat_delay()
    saved_repeat_rate    = ez.keyboard.get_repeat_rate()
    ez.keyboard.set_repeat_enabled(false)

    -- Lower threshold = fewer accumulated steps needed per trackball tick
    saved_tb_sens = ez.keyboard.get_trackball_sensitivity()
    ez.keyboard.set_trackball_sensitivity(1)
end

function FPS:on_exit()
    if saved_repeat_enabled ~= nil then ez.keyboard.set_repeat_enabled(saved_repeat_enabled) end
    if saved_repeat_delay then ez.keyboard.set_repeat_delay(saved_repeat_delay) end
    if saved_repeat_rate  then ez.keyboard.set_repeat_rate(saved_repeat_rate)   end
    if saved_tb_sens      then ez.keyboard.set_trackball_sensitivity(saved_tb_sens) end
end

local function move_forward()
    local nx = px + cos(pa) * MOVE_SPD
    local ny = py + sin(pa) * MOVE_SPD
    if can_move(nx, ny) then px = nx; py = ny
    elseif can_move(nx, py) then px = nx
    elseif can_move(px, ny) then py = ny end
end

local function move_backward()
    local nx = px - cos(pa) * MOVE_SPD
    local ny = py - sin(pa) * MOVE_SPD
    if can_move(nx, ny) then px = nx; py = ny
    elseif can_move(nx, py) then px = nx
    elseif can_move(px, ny) then py = ny end
end

local function strafe_left()
    local nx = px + cos(pa - pi / 2) * STRAFE_SPD
    local ny = py + sin(pa - pi / 2) * STRAFE_SPD
    if can_move(nx, ny) then px = nx; py = ny
    elseif can_move(nx, py) then px = nx
    elseif can_move(px, ny) then py = ny end
end

local function strafe_right()
    local nx = px + cos(pa + pi / 2) * STRAFE_SPD
    local ny = py + sin(pa + pi / 2) * STRAFE_SPD
    if can_move(nx, ny) then px = nx; py = ny
    elseif can_move(nx, py) then px = nx
    elseif can_move(px, ny) then py = ny end
end

function FPS:update()
    if game_alive and not game_won then
        -- Hold-to-move. First tap moves via handle_key (which also teaches
        -- the C++ layer the key's matrix position); subsequent frames poll
        -- is_held() directly. Cached internally so cost is ~40ms per query.
        if ez.keyboard.is_held("w") then move_forward() end
        if ez.keyboard.is_held("s") then move_backward() end
        if ez.keyboard.is_held("a") then strafe_left() end
        if ez.keyboard.is_held("d") then strafe_right() end

        update_enemies()
        check_pickups()
        check_win()
        if shoot_timer > 0 then shoot_timer = shoot_timer - 1 end
    end
    screen_mod.invalidate()
end

function FPS:handle_key(key)
    if key.character == "q" or key.special == "ESCAPE" then
        return "pop"
    end

    if key.character == "r" then
        reset_game()
        return "handled"
    end

    if not game_alive or game_won then return "handled" end

    -- Forward/backward via keyboard only, with wall sliding. The C++ layer
    -- learns the matrix position on first press so update() can poll is_held().
    if key.character == "w" then
        move_forward()

    elseif key.character == "s" then
        move_backward()

    elseif key.special == "LEFT" then
        pa = pa - TURN_SPD

    elseif key.special == "RIGHT" then
        pa = pa + TURN_SPD

    elseif key.character == "a" then
        strafe_left()

    elseif key.character == "d" then
        strafe_right()

    elseif key.character == " " or key.special == "ENTER" then
        do_shoot()
    end

    return "handled"
end

return FPS
