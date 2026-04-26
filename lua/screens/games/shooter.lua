-- Top-down space arcade shooter.
--
-- Player(s) at the bottom, enemies spawn from the top and flow down
-- with various movement patterns, bullets travel up. Dropped items
-- change guns / heal / grant shield / multiply score. Solo or 2P
-- over WiFi (host-authoritative same as pong/bubble).
--
-- Enemy archetypes: scout (straight down, low hp), zigzag (L/R
-- sinusoidal descent), bomber (slow, shoots downward bombs), heavy
-- (boss, big + lots of hp). Drops vary by enemy tier.
--
-- Guns: blaster (default), spread, rapid, missile. Gun-change pickups
-- cycle through them; your gun resets to blaster on death.

local ui         = require("ezui")
local node_mod   = require("ezui.node")
local theme      = require("ezui.theme")
local screen_mod = require("ezui.screen")
local audio      = require("engine.audio_engine")
local sfx        = audio.sounds
local highscores = require("engine.highscores")

local HS_KEY = "starshot"

local Game = { title = "Starshot", fullscreen = true }

local floor, sin, cos, sqrt, abs, rand =
    math.floor, math.sin, math.cos, math.sqrt, math.abs, math.random

local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

local SW, SH       = 320, 240
local HUD_H        = 20
local FIELD_TOP    = HUD_H
local FIELD_BOTTOM = SH
local FIELD_W      = SW

local DT = 1 / 30

---------------------------------------------------------------------------
-- Weapons
---------------------------------------------------------------------------

local GUN_BLASTER = 1
local GUN_SPREAD  = 2
local GUN_RAPID   = 3
local GUN_MISSILE = 4

local GUN_NAMES = { "Blaster", "Spread", "Rapid", "Missile" }

-- Per-gun: cooldown in frames, bullet damage, spawn pattern.
-- Kept table-driven so adding a gun is purely data.
-- Each gun links to a sound in sfx. Sound plays in apply_input when
-- the cooldown check passes, so the "pew" tracks actual firing — not
-- just the key press, which would spam when the gun's on cooldown.
local GUNS = {
    [GUN_BLASTER] = { cooldown = 7,  damage = 2, sound = sfx.blaster,
                      spawn = function(px, py, bullets)
                          bullets[#bullets + 1] = {
                              x = px, y = py - 10, vx = 0, vy = -6,
                              dmg = 2, color = rgb(240, 230, 100), kind = "blaster" }
                      end },
    [GUN_SPREAD]  = { cooldown = 12, damage = 2, sound = sfx.spread,
                      spawn = function(px, py, bullets)
                          for _, a in ipairs({-0.28, 0, 0.28}) do
                              bullets[#bullets + 1] = {
                                  x = px, y = py - 10,
                                  vx = sin(a) * 6, vy = -cos(a) * 6,
                                  dmg = 2, color = rgb(160, 240, 140), kind = "spread" }
                          end
                      end },
    [GUN_RAPID]   = { cooldown = 3,  damage = 1, sound = sfx.rapid,
                      spawn = function(px, py, bullets)
                          bullets[#bullets + 1] = {
                              x = px, y = py - 10, vx = 0, vy = -8,
                              dmg = 1, color = rgb(90, 200, 240), kind = "rapid" }
                      end },
    -- Missile is slower but homing + high damage.
    [GUN_MISSILE] = { cooldown = 18, damage = 5, sound = sfx.missile,
                      spawn = function(px, py, bullets)
                          bullets[#bullets + 1] = {
                              x = px, y = py - 10, vx = 0, vy = -3,
                              dmg = 5, color = rgb(240, 120, 60), kind = "missile",
                              home = true,
                              ttl = 120 }
                      end },
}

---------------------------------------------------------------------------
-- Enemies
---------------------------------------------------------------------------

local E_SCOUT  = 1
local E_ZIGZAG = 2
local E_BOMBER = 3
local E_HEAVY  = 4

local ENEMY_DEFS = {
    [E_SCOUT]  = { hp = 2,  speed = 1.6, size = 8,  points = 10,
                   color = rgb(220, 80, 100),
                   color2 = rgb(255, 150, 160) },
    [E_ZIGZAG] = { hp = 3,  speed = 1.4, size = 9,  points = 25,
                   color = rgb(140, 90, 220),
                   color2 = rgb(200, 160, 255) },
    [E_BOMBER] = { hp = 6,  speed = 0.8, size = 12, points = 50,
                   color = rgb(220, 170, 50),
                   color2 = rgb(255, 220, 120),
                   drops_bombs = true },
    [E_HEAVY]  = { hp = 20, speed = 0.6, size = 18, points = 200,
                   color = rgb(80, 200, 140),
                   color2 = rgb(160, 240, 200),
                   drops_bombs = true },
}

---------------------------------------------------------------------------
-- Items (pickups)
---------------------------------------------------------------------------

local I_HEAL   = 1
local I_SHIELD = 2
local I_GUN    = 3     -- cycles weapon
local I_MULTI  = 4     -- 2x score for N seconds

local ITEM_DEFS = {
    [I_HEAL]   = { color = rgb(230, 80, 80),  label = "+" },
    [I_SHIELD] = { color = rgb(100, 180, 240), label = "O" },
    [I_GUN]    = { color = rgb(240, 220, 80), label = "G" },
    [I_MULTI]  = { color = rgb(180, 240, 120), label = "2" },
}

---------------------------------------------------------------------------
-- Runtime state (host-authoritative)
---------------------------------------------------------------------------

local players          -- { id, x, y, hp, lives, score, gun, cooldown, shield_end_ms, multi_end_ms, alive, color }
local enemies          -- list
local bullets          -- list { x, y, vx, vy, dmg, color, kind, home?, ttl? }
local items            -- list { x, y, vy, kind }
local stars            -- background dots; {x, y, vy, color}
local spawn_timer
local wave
local frame_no         -- counter for deterministic patterns
local game_state = "menu"   -- "menu" | "playing" | "over"
local status_text = ""

---------------------------------------------------------------------------
-- Mode / net state
---------------------------------------------------------------------------

local mode = "menu"
local NET_SSID = "tdeck-ss"
local NET_PASS = "starship"
local NET_PORT = 4248
local STATE_HZ = 15
local INPUT_HZ = 20

local net_udp, net_peer_ip, net_peer_port
local remote_snapshot = nil

---------------------------------------------------------------------------
-- Setup helpers
---------------------------------------------------------------------------

local function make_player(id, x, color)
    return {
        id = id,
        x = x, y = SH - 20,
        -- Horizontal velocity. Replaces the constant per-event step
        -- model so a sustained LEFT/RIGHT (or a fast trackball spin
        -- whose pulses arrive within HOLD_MS of each other) builds
        -- real acceleration up to MAX_VX. Vertical motion stays the
        -- constant-step model — the field is short and accel there
        -- reads as mushy.
        vx = 0,
        hp = 5, lives = 3, score = 0,
        gun = GUN_BLASTER, cooldown = 0,
        shield_end_ms = 0, multi_end_ms = 0,
        alive = true, color = color,
    }
end

local function new_starfield()
    stars = {}
    for i = 1, 40 do
        local z = rand(1, 3)           -- parallax depth
        stars[i] = {
            x = rand(0, SW),
            y = rand(FIELD_TOP, SH),
            vy = z,
            color = z == 3 and rgb(220, 220, 230)
                  or z == 2 and rgb(140, 140, 160)
                  or rgb(80, 80, 100),
        }
    end
end

local function reset_world(n_players)
    players = {
        make_player(1, SW / 2 - (n_players > 1 and 40 or 0),
                       rgb(120, 220, 120)),
    }
    if n_players > 1 then
        players[2] = make_player(2, SW / 2 + 40, rgb(120, 180, 240))
    end
    enemies = {}
    bullets = {}
    items   = {}
    wave = 1
    spawn_timer = 0
    frame_no = 0
    new_starfield()
    status_text = "Wave 1"
end

---------------------------------------------------------------------------
-- Spawning
---------------------------------------------------------------------------

local function spawn_enemy(kind, x)
    local def = ENEMY_DEFS[kind]
    enemies[#enemies + 1] = {
        kind = kind,
        x = x or rand(def.size + 2, SW - def.size - 2),
        y = FIELD_TOP - def.size,
        hp = def.hp,
        t = 0,              -- per-enemy time counter for patterns
        phase = rand() * math.pi * 2,
    }
end

local function update_spawner()
    spawn_timer = spawn_timer - 1
    if spawn_timer > 0 then return end
    -- Base cadence ~1.2s, tightens every wave.
    spawn_timer = math.max(10, 36 - wave * 2)

    -- Weighted pick, scaled by wave (later waves lean tougher).
    local roll = rand()
    local kind
    if     roll < 0.55 - wave * 0.03 then kind = E_SCOUT
    elseif roll < 0.80 - wave * 0.02 then kind = E_ZIGZAG
    elseif roll < 0.95               then kind = E_BOMBER
    else                                   kind = E_HEAVY
    end
    spawn_enemy(kind)

    -- Wave up every 15 s of real time — tracked by frame_no at 30 Hz.
    if frame_no % (15 * 30) == 0 and frame_no > 0 then
        wave = wave + 1
        status_text = "Wave " .. wave
        audio.play(sfx.wave_up, 75)
    end
end

local function drop_item(x, y, enemy_kind)
    local roll = rand()
    local thresh = (enemy_kind == E_HEAVY) and 0.9
               or (enemy_kind == E_BOMBER) and 0.4
               or 0.18
    if roll > thresh then return end

    -- Pick a type weighted by usefulness — heals + guns more common.
    local r = rand()
    local kind
    if     r < 0.35 then kind = I_HEAL
    elseif r < 0.7  then kind = I_GUN
    elseif r < 0.9  then kind = I_SHIELD
    else                 kind = I_MULTI end
    items[#items + 1] = {
        x = x, y = y, vy = 0.8, kind = kind,
    }
end

---------------------------------------------------------------------------
-- Physics / step
---------------------------------------------------------------------------

local function step_enemy(e)
    e.t = e.t + 1
    local def = ENEMY_DEFS[e.kind]
    if e.kind == E_SCOUT then
        e.y = e.y + def.speed
    elseif e.kind == E_ZIGZAG then
        e.y = e.y + def.speed
        e.x = e.x + sin((e.t + e.phase) * 0.1) * 1.6
    elseif e.kind == E_BOMBER then
        e.y = e.y + def.speed
        -- Periodic bomb drop (modeled as a downward bullet on the
        -- same list so the same vs-player logic handles it).
        if e.t % 60 == 30 then
            bullets[#bullets + 1] = {
                x = e.x, y = e.y + def.size,
                vx = 0, vy = 3.0,
                dmg = 1, color = rgb(240, 120, 40), kind = "bomb",
                hostile = true,
            }
        end
    elseif e.kind == E_HEAVY then
        e.y = e.y + def.speed
        e.x = e.x + sin((e.t + e.phase) * 0.05) * 0.8
        if e.t % 40 == 0 then
            -- Three-bullet burst aimed roughly downward.
            for _, a in ipairs({-0.3, 0, 0.3}) do
                bullets[#bullets + 1] = {
                    x = e.x, y = e.y + def.size,
                    vx = sin(a) * 3, vy = cos(a) * 3,
                    dmg = 1, color = rgb(240, 80, 80), kind = "bomb",
                    hostile = true,
                }
            end
        end
    end
    -- Keep bouncing off the horizontal walls so zigzag/heavy don't
    -- leave the field.
    if e.x < def.size then e.x = def.size end
    if e.x > SW - def.size then e.x = SW - def.size end
end

-- Return the closest alive enemy to (x, y) within `radius` — used by
-- homing missiles so they curve toward their target rather than
-- flying straight.
local function nearest_enemy(x, y, radius)
    local best_d, best = radius * radius, nil
    for _, e in ipairs(enemies) do
        local dx = e.x - x
        local dy = e.y - y
        local d = dx * dx + dy * dy
        if d < best_d then best_d = d; best = e end
    end
    return best
end

local function step_bullet(b)
    if b.home and b.kind == "missile" then
        local target = nearest_enemy(b.x, b.y, 200)
        if target then
            local tx, ty = target.x - b.x, target.y - b.y
            local len = sqrt(tx * tx + ty * ty)
            if len > 0 then
                -- Blend current velocity toward target direction.
                local steer = 0.4
                b.vx = b.vx * (1 - steer) + (tx / len * 5) * steer
                b.vy = b.vy * (1 - steer) + (ty / len * 5) * steer
            end
        end
    end
    b.x = b.x + b.vx
    b.y = b.y + b.vy
    if b.ttl then b.ttl = b.ttl - 1 end
end

local function step_items()
    for i = #items, 1, -1 do
        local it = items[i]
        it.y = it.y + it.vy
        if it.y > SH + 8 then table.remove(items, i) end
    end
end

local function step_stars()
    for _, s in ipairs(stars) do
        s.y = s.y + s.vy
        if s.y > SH then
            s.y = FIELD_TOP; s.x = rand(0, SW)
        end
    end
end

---------------------------------------------------------------------------
-- Collision / damage
---------------------------------------------------------------------------

local PLAYER_HW = 6

local function circle_aabb(cx, cy, r, ax, ay, aw, ah)
    local nx = cx < ax and ax or (cx > ax + aw and ax + aw or cx)
    local ny = cy < ay and ay or (cy > ay + ah and ay + ah or cy)
    local dx = cx - nx
    local dy = cy - ny
    return dx * dx + dy * dy <= r * r
end

local function apply_item(p, kind)
    local now = ez.system.millis()
    -- Distinct audio per pickup so the player can tell them apart
    -- without looking at the HUD.
    if kind == I_HEAL then
        p.hp = math.min(5, p.hp + 2)
        if p.id == 1 then audio.play(sfx.pickup, 80) end
    elseif kind == I_SHIELD then
        p.shield_end_ms = now + 8000
        if p.id == 1 then audio.play(sfx.powerup, 80) end
    elseif kind == I_GUN then
        p.gun = (p.gun % #GUNS) + 1
        if p.id == 1 then audio.play(sfx.gun_up, 80) end
    elseif kind == I_MULTI then
        p.multi_end_ms = now + 10000
        if p.id == 1 then audio.play(sfx.powerup, 80) end
    end
end

local function damage_player(p, dmg)
    local now = ez.system.millis()
    if p.shield_end_ms > now then return end
    p.hp = p.hp - dmg
    if p.id == 1 then audio.play(sfx.hurt, 85) end
    if p.hp <= 0 then
        p.lives = p.lives - 1
        if p.lives <= 0 then
            p.alive = false
        else
            p.hp = 5
            p.gun = GUN_BLASTER
            p.shield_end_ms = now + 2000
        end
    end
end

---------------------------------------------------------------------------
-- Input + step (authoritative)
---------------------------------------------------------------------------

-- Horizontal motion tunables. Higher accel + max speed than the old
-- constant-3.5 step so a fast trackball flick or a held LEFT/RIGHT
-- builds real momentum, while friction keeps brief taps responsive.
-- The values reach max in ~7 frames (~0.23 s @ 30 Hz) and decay to
-- stop in ~6 frames after release.
local PLAYER_ACCEL    = 1.10
local PLAYER_MAX_VX   = 7.50
local PLAYER_FRICTION = 0.55
local PLAYER_VSPEED   = 3.50

local function apply_input(p, in_left, in_right, in_up, in_down, in_fire)
    if not p.alive or game_state ~= "playing" then return end

    -- Horizontal: accelerate toward held direction, decay otherwise.
    if in_left and not in_right then
        p.vx = p.vx - PLAYER_ACCEL
        if p.vx < -PLAYER_MAX_VX then p.vx = -PLAYER_MAX_VX end
    elseif in_right and not in_left then
        p.vx = p.vx + PLAYER_ACCEL
        if p.vx > PLAYER_MAX_VX then p.vx = PLAYER_MAX_VX end
    elseif math.abs(p.vx) <= PLAYER_FRICTION then
        p.vx = 0
    elseif p.vx > 0 then
        p.vx = p.vx - PLAYER_FRICTION
    else
        p.vx = p.vx + PLAYER_FRICTION
    end
    p.x = p.x + p.vx

    if in_up   then p.y = p.y - PLAYER_VSPEED end
    if in_down then p.y = p.y + PLAYER_VSPEED end
    -- Keep the player inside the bottom half of the field so they
    -- can't rush up into the spawn line and be invincible. Hitting
    -- a wall zeroes vx so the ship doesn't slide back the moment
    -- the user releases the held key.
    if p.x < PLAYER_HW then
        p.x = PLAYER_HW; if p.vx < 0 then p.vx = 0 end
    elseif p.x > SW - PLAYER_HW then
        p.x = SW - PLAYER_HW; if p.vx > 0 then p.vx = 0 end
    end
    p.y = math.max(SH / 2, math.min(SH - 8, p.y))

    if in_fire then
        if p.cooldown <= 0 then
            local g = GUNS[p.gun]
            g.spawn(p.x, p.y, bullets)
            p.cooldown = g.cooldown
            -- Only the local listening device plays sounds — player 1
            -- is always "us" both on host and join because the join
            -- side renders from a remote snapshot, not from local
            -- players state.
            if p.id == 1 and g.sound then audio.play(g.sound, 70) end
        end
    end
end

local function step_authoritative()
    if game_state ~= "playing" then return end
    frame_no = frame_no + 1

    update_spawner()

    for _, p in ipairs(players) do
        if p.cooldown > 0 then p.cooldown = p.cooldown - 1 end
    end

    -- Enemies.
    for i = #enemies, 1, -1 do
        local e = enemies[i]
        step_enemy(e)
        -- Off-screen bottom → they "pass by", player loses 1 HP for
        -- letting enemies through (only scouts to avoid hammering
        -- the HUD too hard).
        if e.y - ENEMY_DEFS[e.kind].size > SH then
            if e.kind == E_SCOUT then
                for _, p in ipairs(players) do
                    if p.alive then damage_player(p, 1) end
                end
            end
            table.remove(enemies, i)
        end
    end

    -- Bullets.
    for i = #bullets, 1, -1 do
        local b = bullets[i]
        step_bullet(b)
        if b.y < FIELD_TOP - 8 or b.y > SH + 8
                or b.x < -8 or b.x > SW + 8
                or (b.ttl and b.ttl <= 0) then
            table.remove(bullets, i)
        end
    end

    step_items()
    step_stars()

    -- Collisions: bullets vs enemies (player-fired) and bullets vs
    -- players (enemy-fired). The `hostile` flag separates the two.
    for bi = #bullets, 1, -1 do
        local b = bullets[bi]
        if b.hostile then
            for _, p in ipairs(players) do
                if p.alive and circle_aabb(b.x, b.y, 4,
                        p.x - PLAYER_HW, p.y - 8, PLAYER_HW * 2, 14) then
                    damage_player(p, b.dmg)
                    table.remove(bullets, bi)
                    goto next_bullet
                end
            end
        else
            for ei = #enemies, 1, -1 do
                local e = enemies[ei]
                local def = ENEMY_DEFS[e.kind]
                local dx = b.x - e.x
                local dy = b.y - e.y
                if dx * dx + dy * dy <= def.size * def.size then
                    e.hp = e.hp - b.dmg
                    table.remove(bullets, bi)
                    if e.hp <= 0 then
                        -- Credit score to player 1 for simplicity — a
                        -- real MP would track which bullet came from
                        -- which player by tagging on spawn.
                        local p = players[1]
                        local mult = (p.multi_end_ms > ez.system.millis())
                            and 2 or 1
                        p.score = p.score + def.points * mult
                        drop_item(e.x, e.y, e.kind)
                        -- Big enemies earn the longer "explosion"
                        -- cue, small fry get the quicker pop.
                        local snd = (e.kind == E_HEAVY
                                  or e.kind == E_BOMBER)
                                    and sfx.explosion or sfx.enemy_pop
                        audio.play(snd, 85)
                        table.remove(enemies, ei)
                    else
                        -- Non-lethal hit: short crunch for feedback.
                        audio.play(sfx.enemy_hit, 60)
                    end
                    goto next_bullet
                end
            end
        end
        ::next_bullet::
    end

    -- Player vs enemies (body slam).
    for ei = #enemies, 1, -1 do
        local e = enemies[ei]
        local def = ENEMY_DEFS[e.kind]
        for _, p in ipairs(players) do
            if p.alive and circle_aabb(e.x, e.y, def.size,
                    p.x - PLAYER_HW, p.y - 8, PLAYER_HW * 2, 14) then
                damage_player(p, 2)
                table.remove(enemies, ei)
                break
            end
        end
    end

    -- Player vs items.
    for ii = #items, 1, -1 do
        local it = items[ii]
        for _, p in ipairs(players) do
            if p.alive and circle_aabb(it.x, it.y, 6,
                    p.x - PLAYER_HW, p.y - 8, PLAYER_HW * 2, 14) then
                apply_item(p, it.kind)
                table.remove(items, ii)
                break
            end
        end
    end

    -- Game over: all players dead.
    local any_alive = false
    for _, p in ipairs(players) do if p.alive then any_alive = true; break end end
    if not any_alive then
        if game_state ~= "over" then
            audio.play(sfx.game_over, 90)
            -- Record high score once on transition. Solo runs get
            -- credited their own score; in MP the host records its
            -- own (player 1) score since there's no shared ranking.
            if mode == "solo" and players[1] then
                highscores.submit(HS_KEY, players[1].score, wave)
            end
        end
        game_state = "over"
        status_text = "Game over"
    end
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function draw_hud(d)
    d.fill_rect(0, 0, SW, HUD_H, rgb(0, 0, 0))
    theme.set_font("small_aa")
    local p1 = players and players[1]
    if p1 then
        local txt = string.format("P1 %s  HP:%d  L:%d  %d",
            GUN_NAMES[p1.gun], math.max(0, p1.hp), math.max(0, p1.lives),
            p1.score)
        d.draw_text(4, 4, txt, rgb(200, 230, 200))
    end
    if players and players[2] then
        local p2 = players[2]
        theme.set_font("tiny_aa")
        local txt = string.format("P2 %s HP:%d L:%d %d",
            GUN_NAMES[p2.gun], math.max(0, p2.hp), math.max(0, p2.lives),
            p2.score)
        local tw = theme.text_width(txt)
        d.draw_text(SW - tw - 4, 4, txt, rgb(180, 200, 240))
    end
    theme.set_font("tiny_aa")
    if status_text and status_text ~= "" then
        local tw = theme.text_width(status_text)
        d.draw_text(floor((SW - tw) / 2), 13, status_text,
            rgb(200, 200, 200))
    end
end

local function draw_player(d, p)
    if not p.alive then return end
    local now = ez.system.millis()
    local shielded = p.shield_end_ms > now
    -- Body as a small triangle — can't call fill_triangle on arbitrary
    -- coords since we don't know the display binding's flavour; using
    -- three filled boxes in a stack approximates a ship silhouette.
    local x = floor(p.x)
    local y = floor(p.y)
    d.fill_rect(x - 6, y - 2, 13, 6, p.color)   -- body
    d.fill_rect(x - 1, y - 8, 3, 8, p.color)    -- nose
    d.fill_rect(x - 8, y + 2, 3, 3, p.color)    -- left fin
    d.fill_rect(x + 5, y + 2, 3, 3, p.color)    -- right fin
    if shielded then
        d.draw_circle(x, y, 12, rgb(120, 200, 240))
    end
end

-- Per-archetype enemy sprites.
--
-- Each archetype gets a distinct silhouette so the player can read
-- the threat at a glance without matching colour to memory. The
-- collision model still uses (e.x, e.y, def.size) as a circular hit
-- bounds — only the visuals change, so tuning hit radius vs sprite
-- detail stays a one-line edit on def.size.
--
-- All shapes are centred on (x, y). `frame_no` is captured by the
-- caller so animations (zigzag rotor blink, heavy core pulse) tick
-- on the gameplay clock rather than wall time.

local function draw_scout(d, x, y, def, fno)
    -- Small downward-pointing fighter. Triangle hull + two short
    -- wing tips that flick to convey thrust direction.
    local s = def.size
    d.fill_triangle(x - s,     y - s + 2,
                    x + s,     y - s + 2,
                    x,         y + s,     def.color)
    -- Wing tips
    d.fill_rect(x - s - 2, y - s + 2, 3, 3, def.color2)
    d.fill_rect(x + s,     y - s + 2, 3, 3, def.color2)
    -- Cockpit glint
    local glint = (fno // 6) % 2 == 0
    d.fill_rect(x - 1, y - 2, 3, 3, glint and rgb(255, 255, 255) or def.color2)
end

local function draw_zigzag(d, x, y, def, fno)
    -- Spinning four-pointed rotor. The main body is a small diamond;
    -- four rotor arms flip orientation every couple of frames so the
    -- enemy reads as actively spinning.
    local s = def.size
    -- Diamond hull
    d.fill_triangle(x, y - s, x + s, y, x, y + s, def.color)
    d.fill_triangle(x, y - s, x - s, y, x, y + s, def.color)
    -- Rotor arms — alternate between "+" and "X" each ~5 frames.
    local arm_color = def.color2
    if (fno // 5) % 2 == 0 then
        d.fill_rect(x - s - 3, y - 1, 3, 3, arm_color)
        d.fill_rect(x + s,     y - 1, 3, 3, arm_color)
        d.fill_rect(x - 1, y - s - 3, 3, 3, arm_color)
        d.fill_rect(x - 1, y + s,     3, 3, arm_color)
    else
        d.fill_rect(x - s - 2, y - s - 2, 3, 3, arm_color)
        d.fill_rect(x + s - 1, y - s - 2, 3, 3, arm_color)
        d.fill_rect(x - s - 2, y + s - 1, 3, 3, arm_color)
        d.fill_rect(x + s - 1, y + s - 1, 3, 3, arm_color)
    end
    -- Bright core
    d.fill_rect(x - 2, y - 2, 5, 5, rgb(255, 255, 255))
end

local function draw_bomber(d, x, y, def, fno)
    -- Wide hull with two engine pods. The engines pulse to sell the
    -- "actively cruising" read; bomb-drop comes from elsewhere in
    -- the simulation, not from this draw call.
    local s = def.size
    -- Main hull: wide rectangle with bevelled corners (drawn as
    -- two stacked rects so we don't need a polygon primitive).
    d.fill_rect(x - s,     y - 4, s * 2, 8, def.color)
    d.fill_rect(x - s + 2, y - 6, s * 2 - 4, 4, def.color)
    d.fill_rect(x - s + 2, y + 4, s * 2 - 4, 3, def.color)
    -- Hull stripe
    d.fill_rect(x - s + 1, y - 1, s * 2 - 2, 2, def.color2)
    -- Two engine pods at the rear (top, since enemies face down).
    local engine_pulse = ((fno // 4) % 2 == 0) and rgb(255, 200, 80)
                                                or rgb(255, 130, 30)
    d.fill_circle(x - s + 3, y - 6, 3, engine_pulse)
    d.fill_circle(x + s - 3, y - 6, 3, engine_pulse)
    -- Cockpit canopy at the front
    d.fill_rect(x - 2, y + 3, 5, 4, rgb(40, 40, 60))
end

local function draw_heavy(d, x, y, def, fno)
    -- Boss — octagonal armoured ship with internal lights. Cycles a
    -- "scanning" beam across its lower edge to imply targeting.
    local s = def.size
    -- Octagon: stack of three rects of decreasing width.
    d.fill_rect(x - s + 4, y - s,      s * 2 - 8, 4,         def.color)
    d.fill_rect(x - s,     y - s + 4,  s * 2,     s * 2 - 8, def.color)
    d.fill_rect(x - s + 4, y + s - 4,  s * 2 - 8, 4,         def.color)
    -- Highlights along the leading edges
    d.draw_line(x - s + 4, y - s,     x - s,     y - s + 4, def.color2)
    d.draw_line(x + s - 4, y - s,     x + s,     y - s + 4, def.color2)
    d.draw_line(x - s,     y + s - 4, x - s + 4, y + s,     def.color2)
    d.draw_line(x + s,     y + s - 4, x + s - 4, y + s,     def.color2)
    -- Cross-shaped armour plating
    d.fill_rect(x - 2, y - s + 4, 5, s * 2 - 8, def.color2)
    d.fill_rect(x - s + 4, y - 2, s * 2 - 8, 5, def.color2)
    -- Two bright "windows" left and right of centre
    local window_lit = ((fno // 8) % 2 == 0)
    d.fill_rect(x - s + 6, y - 2, 3, 4,
        window_lit and rgb(255, 240, 160) or rgb(180, 140, 60))
    d.fill_rect(x + s - 9, y - 2, 3, 4,
        window_lit and rgb(255, 240, 160) or rgb(180, 140, 60))
    -- Scanning beam: a thin red line that sweeps across the lower
    -- edge over ~24 frames. Reads as "the boss has a sensor".
    local sweep = ((fno % 24) / 24)
    local sx = x - s + 4 + math.floor(sweep * (s * 2 - 8))
    d.fill_rect(sx, y + s - 5, 3, 2, rgb(240, 80, 80))
end

local function draw_enemy(d, e)
    local def = ENEMY_DEFS[e.kind]
    local x = floor(e.x); local y = floor(e.y)
    -- frame_no is set by step_authoritative; the client uses the
    -- host's last-snapshot tick instead but we don't currently mirror
    -- that, so on the join side animations freeze between snapshots.
    -- Acceptable since this is purely cosmetic.
    local fno = frame_no or 0
    if e.kind == E_SCOUT then
        draw_scout(d, x, y, def, fno)
    elseif e.kind == E_ZIGZAG then
        draw_zigzag(d, x, y, def, fno)
    elseif e.kind == E_BOMBER then
        draw_bomber(d, x, y, def, fno)
    elseif e.kind == E_HEAVY then
        draw_heavy(d, x, y, def, fno)
    end
end

local function draw_bullet(d, b)
    if b.hostile then
        d.fill_circle(floor(b.x), floor(b.y), 3, b.color)
    else
        local w = (b.kind == "missile") and 3 or 2
        local h = (b.kind == "missile") and 8 or 6
        d.fill_rect(floor(b.x) - math.floor(w/2),
                    floor(b.y) - math.floor(h/2),
                    w, h, b.color)
    end
end

local function draw_item(d, it)
    local def = ITEM_DEFS[it.kind]
    local x = floor(it.x); local y = floor(it.y)
    d.fill_rect(x - 5, y - 5, 11, 11, def.color)
    d.draw_rect(x - 5, y - 5, 11, 11, rgb(250, 250, 250))
    theme.set_font("tiny_aa")
    local lw = theme.text_width(def.label)
    d.draw_text(x - math.floor(lw / 2), y - 4, def.label,
        rgb(30, 30, 30))
end

local function draw_stars(d)
    for _, s in ipairs(stars or {}) do
        d.fill_rect(floor(s.x), floor(s.y), 1, 1, s.color)
    end
end

local function render(d)
    d.fill_rect(0, HUD_H, SW, SH - HUD_H, rgb(5, 5, 20))

    if mode == "join" and remote_snapshot then
        for _, s in ipairs(remote_snapshot.stars or {}) do
            d.fill_rect(floor(s.x), floor(s.y), 1, 1,
                rgb(120, 120, 150))
        end
        for _, e in ipairs(remote_snapshot.enemies or {}) do draw_enemy(d, e) end
        for _, b in ipairs(remote_snapshot.bullets or {}) do draw_bullet(d, b) end
        for _, it in ipairs(remote_snapshot.items  or {}) do draw_item(d, it) end
        for _, p in ipairs(remote_snapshot.players or {}) do draw_player(d, p) end
    else
        draw_stars(d)
        for _, e in ipairs(enemies or {}) do draw_enemy(d, e) end
        for _, b in ipairs(bullets or {}) do draw_bullet(d, b) end
        for _, it in ipairs(items   or {}) do draw_item(d, it) end
        for _, p in ipairs(players  or {}) do draw_player(d, p) end
    end

    draw_hud(d)

    if game_state == "over" then
        theme.set_font("medium_aa", "bold")
        local t = "GAME OVER"
        local tw = theme.text_width(t)
        d.draw_text(floor((SW - tw) / 2), 46, t, rgb(230, 120, 120))

        -- Top-5 board (solo only — MP has no shared leaderboard).
        if mode == "solo" then
            theme.set_font("tiny_aa")
            local y0 = 74
            local rows = highscores.format(HS_KEY, function(i, h)
                return string.format("%d.  %6d   wave %d",
                    i, h.score, h.extra)
            end)
            for i, line in ipairs(rows) do
                local lw = theme.text_width(line)
                d.draw_text(floor((SW - lw) / 2), y0 + (i - 1) * 12,
                    line, rgb(220, 220, 220))
            end
        end

        theme.set_font("small_aa")
        local h = "Press R to retry, Q for menu"
        local hw = theme.text_width(h)
        d.draw_text(floor((SW - hw) / 2), SH - 20, h, rgb(200, 200, 200))
    end
end

if not node_mod.handler("shooter_view") then
    node_mod.register("shooter_view", {
        measure = function(_, _, _) return SW, SH end,
        draw = function(_, d, _, _, _, _) render(d) end,
    })
end

---------------------------------------------------------------------------
-- Net (host-authoritative, compact packets)
---------------------------------------------------------------------------

-- Input packet C→H:  [0x01][left][right][up][down][fire]  (6 bytes)
-- Snapshot H→C: ad-hoc concat (see encode_snapshot).

local function encode_snapshot()
    local out = { string.char(0x02) }
    out[#out + 1] = string.pack("<B", game_state == "playing" and 0 or 1)
    for i = 1, 2 do
        local p = players and players[i]
        if p then
            out[#out + 1] = string.pack("<HHBBBBH",
                floor(p.x), floor(p.y),
                math.max(0, p.hp), math.max(0, p.lives),
                p.gun, p.alive and 1 or 0,
                p.score)
        else
            out[#out + 1] = string.pack("<HHBBBBH", 0,0,0,0,1,0,0)
        end
    end
    -- Enemies
    out[#out + 1] = string.char(math.min(#enemies, 40))
    for i = 1, math.min(#enemies, 40) do
        local e = enemies[i]
        out[#out + 1] = string.pack("<BHH", e.kind, floor(e.x), floor(e.y))
    end
    -- Bullets
    out[#out + 1] = string.char(math.min(#bullets, 40))
    for i = 1, math.min(#bullets, 40) do
        local b = bullets[i]
        local c = b.hostile and 1 or 0
        out[#out + 1] = string.pack("<BBHH", c,
            (b.kind == "missile") and 1 or 0,
            floor(b.x), floor(b.y))
    end
    -- Items
    out[#out + 1] = string.char(math.min(#items, 20))
    for i = 1, math.min(#items, 20) do
        local it = items[i]
        out[#out + 1] = string.pack("<BHH", it.kind, floor(it.x), floor(it.y))
    end
    return table.concat(out)
end

local function decode_snapshot(data)
    if #data < 2 or data:byte(1) ~= 0x02 then return nil end
    local snap = { players = {}, enemies = {}, bullets = {}, items = {} }
    local off = 2
    snap.state, off = string.unpack("<B", data, off)
    for i = 1, 2 do
        local x, y, hp, lives, gun, alive, score, next_off =
            string.unpack("<HHBBBBH", data, off)
        off = next_off
        snap.players[i] = {
            id = i, x = x, y = y, hp = hp, lives = lives,
            gun = gun, alive = alive == 1, score = score,
            color = (i == 1) and rgb(120, 220, 120) or rgb(120, 180, 240),
            shield_end_ms = 0,
        }
    end
    local n_e = data:byte(off); off = off + 1
    for _ = 1, n_e do
        local k, x, y, next_off = string.unpack("<BHH", data, off)
        off = next_off
        snap.enemies[#snap.enemies + 1] = { kind = k, x = x, y = y }
    end
    local n_b = data:byte(off); off = off + 1
    for _ = 1, n_b do
        local hostile, ismissile, x, y, next_off =
            string.unpack("<BBHH", data, off)
        off = next_off
        snap.bullets[#snap.bullets + 1] = {
            x = x, y = y,
            hostile = hostile == 1,
            color = hostile == 1 and rgb(240, 80, 80) or rgb(240, 230, 100),
            kind = ismissile == 1 and "missile" or "rapid",
        }
    end
    local n_i = data:byte(off); off = off + 1
    for _ = 1, n_i do
        local k, x, y, next_off = string.unpack("<BHH", data, off)
        off = next_off
        snap.items[#snap.items + 1] = { kind = k, x = x, y = y }
    end
    return snap
end

---------------------------------------------------------------------------
-- Input state
---------------------------------------------------------------------------

-- Trackball pulses arrive as short LEFT/RIGHT/UP/DOWN special-key
-- events. To turn the discrete pulses into a held-direction signal
-- we extend each event's "active" window by HOLD_MS so a continuous
-- spin reads as a continuous press. handle_key bumps the deadline;
-- input_flag() asks if we're still inside it.
local HOLD_MS = 120
local hold = { left = 0, right = 0, up = 0, down = 0, fire = 0 }
local function input_flag(name)
    -- Fire is special: it has both an event-based deadline (set on
    -- KEY_DOWN, like the directional keys) AND a real "is held"
    -- query for the spacebar. Either path firing keeps the gun
    -- chugging while the user holds space, which is the standard
    -- shoot-em-up expectation. Held check first is cheap when the
    -- key isn't down (returns false immediately).
    if name == "fire" then
        if ez.keyboard.is_held and ez.keyboard.is_held(" ") then
            return true
        end
    end
    return hold[name] > ez.system.millis()
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local function tear_down(self)
    for _, k in ipairs({"_tick","_rx","_tx","_itx"}) do
        if self[k] then ez.system.cancel_timer(self[k]); self[k] = nil end
    end
    if net_udp then ez.net.udp_close(net_udp); net_udp = nil end
    if mode == "host" then ez.wifi.stop_ap()
    elseif mode == "join" then ez.wifi.disconnect() end
    audio.stop()
    mode = "menu"; game_state = "menu"
    net_peer_ip, net_peer_port = nil, nil
    remote_snapshot = nil
end

function Game.initial_state() return {} end

function Game:build(_state)
    if mode == "menu" or game_state == "menu" then
        return ui.vbox({ gap = 0, bg = "BG" }, {
            ui.title_bar("Starshot", { back = true }),
            ui.padding({ 12, 20, 4, 20 },
                ui.text_widget("Top-down shooter. Blast enemies, grab "
                    .. "pickups, survive the waves.",
                    { font = "small_aa", color = "TEXT_SEC",
                      text_align = "center", wrap = true })
            ),
            ui.padding({ 4, 40, 4, 40 },
                ui.button("Solo", { on_press = function() self:_start("solo") end })),
            ui.padding({ 4, 40, 4, 40 },
                ui.button("Host (2P)", { on_press = function() self:_start("host") end })),
            ui.padding({ 4, 40, 4, 40 },
                ui.button("Join", { on_press = function() self:_start("join") end })),
            ui.padding({ 8, 20, 0, 20 },
                ui.text_widget(status_text or "", {
                    font = "tiny_aa", color = "TEXT_MUTED",
                    text_align = "center", wrap = true })),
        })
    end
    return { type = "shooter_view" }
end

function Game:on_enter()
    mode = "menu"; game_state = "menu"
    status_text = ""
end

function Game:on_exit() tear_down(self) end

function Game:_start(m)
    mode = m
    if m == "solo" then
        reset_world(1)
        game_state = "playing"
        self._tick = ez.system.set_interval(math.floor(DT * 1000), function()
            apply_input(players[1],
                input_flag("left"), input_flag("right"),
                input_flag("up"),   input_flag("down"),
                input_flag("fire"))
            step_authoritative()
            screen_mod.invalidate()
        end)
        self:set_state({})
    elseif m == "host" then
        status_text = "Starting AP..."
        self:set_state({})
        spawn(function()
            if not ez.wifi.start_ap(NET_SSID, NET_PASS, 1, false, 2) then
                status_text = "AP failed"; mode = "menu"
                self:set_state({}); return
            end
            net_udp = ez.net.udp_open(NET_PORT)
            if not net_udp then
                status_text = "UDP open failed"; mode = "menu"
                ez.wifi.stop_ap(); self:set_state({}); return
            end
            reset_world(2)
            game_state = "playing"
            status_text = "Hosting " .. NET_SSID
            self:set_state({})

            self._rx = ez.system.set_interval(20, function()
                while true do
                    local data, from_ip, from_port = ez.net.udp_recv(net_udp)
                    if not data then break end
                    if #data == 6 and data:byte(1) == 0x01 then
                        if not net_peer_ip then
                            net_peer_ip, net_peer_port = from_ip, from_port
                        end
                        apply_input(players[2],
                            data:byte(2) == 1,
                            data:byte(3) == 1,
                            data:byte(4) == 1,
                            data:byte(5) == 1,
                            data:byte(6) == 1)
                    end
                end
            end)
            self._tick = ez.system.set_interval(math.floor(DT * 1000), function()
                apply_input(players[1],
                    input_flag("left"), input_flag("right"),
                    input_flag("up"),   input_flag("down"),
                    input_flag("fire"))
                step_authoritative()
                screen_mod.invalidate()
            end)
            self._tx = ez.system.set_interval(math.floor(1000 / STATE_HZ),
                function()
                    if net_peer_ip then
                        ez.net.udp_send(net_udp, net_peer_ip, net_peer_port,
                            encode_snapshot())
                    end
                end)
        end)
    elseif m == "join" then
        status_text = "Joining..."
        self:set_state({})
        spawn(function()
            ez.wifi.connect(NET_SSID, NET_PASS)
            local up = false
            for _ = 1, 5 do
                up = ez.wifi.wait_connected(4)
                if up then break end
                ez.wifi.disconnect()
                local w = ez.system.millis() + 1500
                while ez.system.millis() < w do defer() end
            end
            if not up then
                status_text = "Could not join AP"; mode = "menu"
                self:set_state({}); return
            end
            net_udp = ez.net.udp_open(0)
            if not net_udp then
                status_text = "UDP open failed"; mode = "menu"
                self:set_state({}); return
            end
            net_peer_ip, net_peer_port = ez.wifi.get_gateway(), NET_PORT
            game_state = "playing"
            status_text = "Connected"
            self:set_state({})

            self._rx = ez.system.set_interval(20, function()
                while true do
                    local data = ez.net.udp_recv(net_udp)
                    if not data then break end
                    local snap = decode_snapshot(data)
                    if snap then
                        remote_snapshot = snap
                        game_state = snap.state == 0 and "playing" or "over"
                        screen_mod.invalidate()
                    end
                end
            end)
            self._itx = ez.system.set_interval(math.floor(1000 / INPUT_HZ),
                function()
                    ez.net.udp_send(net_udp, net_peer_ip, net_peer_port,
                        string.pack("<BBBBBB", 0x01,
                            input_flag("left")  and 1 or 0,
                            input_flag("right") and 1 or 0,
                            input_flag("up")    and 1 or 0,
                            input_flag("down")  and 1 or 0,
                            input_flag("fire")  and 1 or 0))
                end)
        end)
    end
end

function Game:handle_key(key)
    local s = key.special
    local c = key.character
    if c then c = c:lower() end

    if mode == "menu" or game_state == "menu" then return nil end

    if s == "BACKSPACE" or s == "ESCAPE" or c == "q" then
        tear_down(self); self:set_state({}); return "handled"
    end
    if c == "r" and game_state == "over" then
        if mode == "solo" then reset_world(1)
        elseif mode == "host" then reset_world(2) end
        game_state = "playing"; return "handled"
    end

    local now = ez.system.millis()
    if s == "LEFT"  or c == "a" then hold.left  = now + HOLD_MS; return "handled" end
    if s == "RIGHT" or c == "d" then hold.right = now + HOLD_MS; return "handled" end
    if s == "UP"    or c == "w" then hold.up    = now + HOLD_MS; return "handled" end
    if s == "DOWN"  or c == "s" then hold.down  = now + HOLD_MS; return "handled" end
    if c == " " or s == "ENTER" then hold.fire  = now + 80;      return "handled" end
    return nil
end

return Game
