-- Wasteland: rasterized outdoor zombie shooter.
--
-- Uses the Scene3D C-side renderer (ez.display.scene_*) to move the hot
-- path — transform, near-plane clip, back-face cull, painter's sort, and
-- fillTriangle — entirely into native code. Lua only submits world-space
-- triangles (once for static geometry at game reset, then per-frame for
-- billboard sprites) and issues a single scene_render call per frame.
--
-- Controls: W/S forward-back, A/D strafe, LEFT/RIGHT turn, SPACE shoot,
--           R restart, Q quit.

local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")
local highscores = require("engine.highscores")

local HS_KEY = "wasteland"

local Game = { title = "Wasteland", fullscreen = true }

local floor, sqrt, cos, sin, abs = math.floor, math.sqrt, math.cos, math.sin, math.abs
local random, pi, atan2 = math.random, math.pi, math.atan
local min3, max3 = math.min, math.max

local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

---------------------------------------------------------------------------
-- Display / projection constants
---------------------------------------------------------------------------
local SW, SH = 320, 240
-- HUD bar at the top of the screen. Sized to fit two rows of text
-- (small-font status line + tiny-font detail line) plus a stamina
-- strip without any of them overlapping. The 3D viewport starts
-- directly below this.
local VIEW_TOP = 24
local VIEW_H = SH - VIEW_TOP
local VIEW_CX = SW / 2
local VIEW_CY = VIEW_TOP + VIEW_H / 2
local FOCAL = 200
local NEAR = 0.3
-- Draw distance in world units. Enforced in C via scene_render's
-- optional `far` parameter. Anything whose vertices are all beyond this
-- ring of the player is skipped before transform, which is the primary
-- lever for FPS in the large world — fog at FOG_K already darkens
-- everything beyond ~25 units, so shorter draw distance is barely
-- noticeable except at the horizon.
local FAR = 28
local FOG_K = 0.07    -- slightly stronger fog so the FAR clip blends in


---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local px, py, pz
local p_yaw
local yaw_cos, yaw_sin

local health, ammo, score
local game_alive
local shoot_timer = 0
local anim_t = 0

-- Weapons. Each entry defines combat stats, cooldown, and a simple
-- drawing style. `cone_at_1m` is the half-angle of the hit cone at 1m
-- (scaled by 1/distance at shoot time). `pellets` lets shotguns pierce
-- through multiple targets in one trigger pull — for single-target
-- weapons it stays at 1 and the fire loop picks the nearest.
local WEAPONS = {
    {
        key = "pistol",
        name = "Pistol",
        damage = 1,
        ammo_cost = 1,
        cooldown = 4,
        cone_at_1m = 0.32,
        cone_min = 0.07,
        cone_max = 0.35,
        pellets = 1,
        barrel_w = 8,
        barrel_h = 30,
        color_barrel = rgb(140, 140, 155),
        color_grip   = rgb(120,  85,  45),
        owned = true,  -- always have the starter pistol
    },
    {
        key = "shotgun",
        name = "Shotgun",
        damage = 1,
        ammo_cost = 1,
        cooldown = 14,
        cone_at_1m = 0.70,
        cone_min = 0.15,
        cone_max = 0.80,
        pellets = 4,      -- hits up to N enemies inside the wider cone
        barrel_w = 14,
        barrel_h = 36,
        color_barrel = rgb(95, 95, 110),
        color_grip   = rgb(85, 55, 30),
        owned = false,
    },
    {
        key = "rifle",
        name = "Rifle",
        damage = 3,
        ammo_cost = 1,
        cooldown = 10,
        cone_at_1m = 0.14,
        cone_min = 0.03,
        cone_max = 0.16,
        pellets = 1,
        barrel_w = 6,
        barrel_h = 46,
        color_barrel = rgb(80, 90, 95),
        color_grip   = rgb(50, 35, 25),
        owned = false,
    },
    {
        -- SMG: fully automatic. Fires while the trigger key is held
        -- (see update() for the autofire hook). Low damage per round
        -- but high fire rate; ammo evaporates fast.
        key = "smg",
        name = "SMG",
        damage = 1,
        ammo_cost = 1,
        cooldown = 2,       -- ~15 rounds/sec
        cone_at_1m = 0.22,
        cone_min = 0.06,
        cone_max = 0.28,
        pellets = 1,
        barrel_w = 7,
        barrel_h = 26,
        color_barrel = rgb(70, 70, 80),
        color_grip   = rgb(40, 40, 45),
        auto = true,        -- held-fire flag; checked in update()
        owned = false,
    },
    {
        -- Assault Rifle: auto-fire like the SMG but harder-hitting
        -- and slower-firing, with a narrower cone to reward aiming.
        -- Sits between SMG (spam + weak) and Rifle (semi + strong).
        key = "assault",
        name = "Assault",
        damage = 2,
        ammo_cost = 1,
        cooldown = 4,       -- ~7-8 rounds/sec
        cone_at_1m = 0.16,
        cone_min = 0.04,
        cone_max = 0.20,
        pellets = 1,
        barrel_w = 7,
        barrel_h = 38,
        color_barrel = rgb(55, 60, 70),
        color_grip   = rgb(30, 25, 20),
        auto = true,
        owned = false,
    },
}
local current_weapon = 1  -- index into WEAPONS

-- Day/night cycle. time_of_day ∈ [0, 1) — 0 is midnight, 0.25 is sunrise,
-- 0.5 is noon, 0.75 is sunset, wrapping at 1. One full day lasts
-- DAY_LENGTH frames (~2.5 min at 30 FPS).
local DAY_LENGTH = 30 * 150
local time_of_day = 0.35

-- Wave / progression. A wave ends after KILLS_PER_WAVE confirmed kills;
-- the next wave respawns pickups and the zombie pool grows slightly
-- tougher.
local wave = 1
local kills = 0
local KILLS_PER_WAVE = 8

-- Sprint + stamina. Holding shift drains stamina while moving faster;
-- it regenerates when not sprinting.
local stamina = 100
local MAX_STAMINA = 100
local SPRINT_DRAIN = 1.2
local SPRINT_REGEN = 0.45
local SPRINT_MULT = 1.75
local sprint_locked = false  -- briefly blocks sprint after full drain

-- Shop interaction. `nearest_shop` is set each frame if the player is
-- inside a shop's interaction radius — drives the "Press E" prompt.
-- `ui.shop_open` gates the overlay menu and pauses enemy movement while
-- true so browsing isn't a death trap.
local nearest_shop = nil
-- All transient menu state lives in one table so the main chunk stays
-- under Lua's 200-locals-per-function limit. `open` is the boolean
-- visibility flag; `sel` (where applicable) is the highlighted row.
-- Keep field names matching the original locals so reads/writes remain
-- one-dot accesses throughout the file.
local ui = {
    shop_open = false,  shop_sel = 1,
    craft_open = false, craft_sel = 1,
    pause_open = false, pause_sel = 1,
    help_open = false,
    inv_open = false,   inv_sel = 1,
}
local max_health = 100    -- upgradeable via shop

-- Crafting / building. The player accumulates wood from zombie drops;
-- every WOOD_PER_CRATE chips auto-crafts into a placeable crate. `B`
-- places a crate from the inventory directly in front of you. Placed
-- crates are stored in `placed_crates` so their geometry is re-submitted
-- every frame (they aren't in the static scene prefix) and obstacles
-- is kept in sync so zombies path around them.
local wood = 0
local cloth = 0
local scrap = 0
local crates_held = 0
local MAX_PLACED_CRATES = 24
local placed_crates = {}

-- Material drop table. Each zombie kill rolls once against the full
-- chance sum; the first bucket whose cumulative threshold exceeds the
-- roll wins. Any roll beyond the sum yields nothing (cheap zombies
-- don't always drop something). Probabilities are tuned so wood is
-- the most common drop and scrap is the rarest.
local MAT_DROPS = {
    { kind = "wood",  chance = 0.35 },
    { kind = "cloth", chance = 0.25 },
    { kind = "scrap", chance = 0.15 },
}

-- Physical drops on the ground. Each entry: { x, z, kind, ttl }.
-- Materials aren't instantly added to inventory — a pickup spawns at
-- the zombie's position and despawns after DROP_TTL_FRAMES if ignored.
-- Walking within PICKUP_RADIUS of one collects it.
local drops = {}
local DROP_TTL_FRAMES = 30 * 20     -- ~20 s at 30 FPS
local DROP_PICKUP_RADIUS_SQ = 0.7 * 0.7

-- Per-kind colour and label (for the pickup billboards). Kept small
-- + distinctive so they read at a glance without being as visually
-- loud as the hp/ammo crates.
local MAT_STYLE = {
    wood  = { col_top = rgb(180, 130, 70),  col_bot = rgb(110, 70, 30)  },
    cloth = { col_top = rgb(230, 215, 180), col_bot = rgb(160, 140, 110) },
    scrap = { col_top = rgb(170, 175, 185), col_bot = rgb( 95, 100, 110) },
}

local function mat_count(name)
    if     name == "wood"  then return wood
    elseif name == "cloth" then return cloth
    elseif name == "scrap" then return scrap end
    return 0
end
local function mat_add(name, n)
    if     name == "wood"  then wood  = wood  + n
    elseif name == "cloth" then cloth = cloth + n
    elseif name == "scrap" then scrap = scrap + n end
end

-- Pause / help / inventory state lives in `ui` (declared above) so
-- the main chunk stays under Lua's local limit. No redeclaration
-- here.

-- Craft menu state + recipe list. `inputs` is a map of material name
-- → count. `apply` runs after the inputs are deducted. Extending is
-- just a matter of appending to this table; the menu, key-handler,
-- and HUD pick up new recipes with no code changes.
-- ui.craft_open / ui.craft_sel live on `ui` above.

local CRAFT_RECIPES = {
    {
        label  = "Crate",
        desc   = "Fortify with a wooden box",
        inputs = { wood = 3 },
        apply  = function() crates_held = crates_held + 1 end,
    },
    {
        label  = "Bandage",
        desc   = "Restore 25 HP",
        inputs = { cloth = 2 },
        apply  = function()
            health = math.min(max_health, health + 25)
        end,
    },
    {
        label  = "Medkit",
        desc   = "Restore 75 HP",
        inputs = { cloth = 3, scrap = 1 },
        apply  = function()
            health = math.min(max_health, health + 75)
        end,
    },
    {
        label  = "Ammo Pack",
        desc   = "+20 rounds",
        inputs = { scrap = 2 },
        apply  = function() ammo = ammo + 20 end,
    },
    {
        label  = "Armor Plate",
        desc   = "+15 max HP (permanent)",
        inputs = { scrap = 3, cloth = 2 },
        apply  = function()
            max_health = max_health + 15
            health = max_health
        end,
    },
}

-- How much raw material a destroyed placed-crate refunds. Strictly
-- smaller than the Crate recipe's wood cost so it can't be farmed.
local CRATE_DROP_WOOD = 1

local MOVE_SPD = 0.22
local STRAFE_SPD = 0.18
local TURN_SPD = pi / 22
local PLAYER_R = 0.45
local EYE_HEIGHT = 1.6

-- Scene3D handle (native buffer)
local scene
local static_mark = 0  -- triangle count after static geometry is loaded

-- Obstacles for player collision: {cx, cz, r}
local obstacles = {}

local zombies = {}
local pickups = {}
local trees   = {}
local spawn_points = {}
local campfires = {}  -- dynamic (flame animates each frame)
local lampposts = {}  -- post is static; the glow bulb animates with time-of-day

-- Cheat flags. Each is togglable via a keybinding; the HUD shows a small
-- badge while any are active so it's obvious the run is non-canonical.
local cheat_god = false
local cheat_freeze = false
local cheat_perf = false

-- FPS / triangle-count sampling. Updated from update() / render() so the
-- perf overlay can display recent averages rather than jittery per-frame
-- numbers.
local fps_last_ms = 0
local fps_frames = 0
local fps_display = 0
local tris_last = 0

local saved_repeat_enabled, saved_repeat_delay, saved_repeat_rate, saved_tb_sens

local ZOMBIE_COUNT = 10
local ZOMBIE_HP = 3
local ZOMBIE_STOP_DIST = 0.85
local ZOMBIE_HIT_DIST = 1.05
local ZOMBIE_RESPAWN_FRAMES = 180

---------------------------------------------------------------------------
-- Math helpers
---------------------------------------------------------------------------
local function shade(color, f)
    if f >= 1 then return color end
    if f <= 0 then return 0 end
    local r = floor(floor(color / 2048) % 32 * f)
    local g = floor(floor(color / 32) % 64 * f)
    local b = floor(color % 32 * f)
    return r * 2048 + g * 32 + b
end

local function set_yaw(y)
    p_yaw = y
    yaw_cos = cos(y)
    yaw_sin = sin(y)
end

-- Day/night-cycle helpers ------------------------------------------------
-- Everything here is a cheap closed-form function of `time_of_day` so
-- the sky, fog, and scene brightness all stay in lockstep with one
-- scalar advance per frame.

local function sun_height()
    -- sin((time - 0.25) * 2π) is −1 at midnight, 0 at sunrise (0.25) and
    -- sunset (0.75), +1 at noon (0.5). Matches the intuitive mapping.
    return sin((time_of_day - 0.25) * 2 * pi)
end

-- Scene brightness ∈ [0.22, 1.0]. Smooth but with a solid night floor so
-- nothing goes fully black (the z-buffer does no ambient emission — if
-- we multiplied by 0 we'd lose the scene entirely).
local function scene_light()
    local sh = sun_height()
    -- Remap sh∈[−1,1] → t∈[0,1] with emphasis on daylight hours.
    local t = (sh + 1) * 0.5
    t = t * t * (3 - 2 * t)  -- smoothstep
    return 0.22 + 0.78 * t
end

-- Blend three RGB tuples into an rgb565 colour. Each input is {r,g,b}.
local function mix3(a, b, t)
    if t <= 0 then return a end
    if t >= 1 then return b end
    return {
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
    }
end

local SKY_NIGHT_TOP     = { 8,  12, 32 }
local SKY_NIGHT_MID     = { 18, 22, 45 }
local SKY_NIGHT_HORIZON = { 32, 38, 70 }
local SKY_DUSK_TOP      = { 60, 50, 110 }
local SKY_DUSK_MID      = { 160, 90, 70 }
local SKY_DUSK_HORIZON  = { 225, 140, 80 }
local SKY_DAY_TOP       = { 90, 140, 210 }
local SKY_DAY_MID       = { 140, 180, 225 }
local SKY_DAY_HORIZON   = { 195, 215, 230 }

local function sky_palette()
    local sh = sun_height()
    local top, mid, horizon
    if sh >= 0.3 then
        top, mid, horizon = SKY_DAY_TOP, SKY_DAY_MID, SKY_DAY_HORIZON
    elseif sh >= 0 then
        local t = sh / 0.3
        top     = mix3(SKY_DUSK_TOP,     SKY_DAY_TOP,     t)
        mid     = mix3(SKY_DUSK_MID,     SKY_DAY_MID,     t)
        horizon = mix3(SKY_DUSK_HORIZON, SKY_DAY_HORIZON, t)
    elseif sh >= -0.3 then
        local t = (sh + 0.3) / 0.3
        top     = mix3(SKY_NIGHT_TOP,     SKY_DUSK_TOP,     t)
        mid     = mix3(SKY_NIGHT_MID,     SKY_DUSK_MID,     t)
        horizon = mix3(SKY_NIGHT_HORIZON, SKY_DUSK_HORIZON, t)
    else
        top, mid, horizon = SKY_NIGHT_TOP, SKY_NIGHT_MID, SKY_NIGHT_HORIZON
    end
    return rgb(floor(top[1]),     floor(top[2]),     floor(top[3])),
           rgb(floor(mid[1]),     floor(mid[2]),     floor(mid[3])),
           rgb(floor(horizon[1]), floor(horizon[2]), floor(horizon[3]))
end

---------------------------------------------------------------------------
-- Scene helpers (world-space triangle submission)
---------------------------------------------------------------------------
local scene_add = nil  -- bound to ez.display.scene_add_tri once scene exists

local function add_tri(x1,y1,z1, x2,y2,z2, x3,y3,z3, col)
    scene_add(scene, x1,y1,z1, x2,y2,z2, x3,y3,z3, col)
end

-- Quad with CCW winding when viewed from the visible side
local function add_quad(x1,y1,z1, x2,y2,z2, x3,y3,z3, x4,y4,z4, col)
    scene_add(scene, x1,y1,z1, x2,y2,z2, x3,y3,z3, col)
    scene_add(scene, x1,y1,z1, x3,y3,z3, x4,y4,z4, col)
end

---------------------------------------------------------------------------
-- Static scene: ground, path, buildings
---------------------------------------------------------------------------
-- World dimensions. GROUND_SIZE is the edge length of the terrain
-- square; GROUND_N is the per-axis tile count. We scale the world up
-- ~8x in area without keeping per-tile resolution proportionally high
-- — coarser tiles keep the visible triangle budget under control on
-- the ESP32-S3 while the hills still read as hills.
local GROUND_N = 20
local GROUND_SIZE = 108
local GROUND_HALF = GROUND_SIZE / 2

-- Distance threshold (squared) beyond which dynamic tree geometry is
-- skipped at submission time. Kept slightly larger than FAR so tall
-- canopy tips still show at the horizon even though their trunks may
-- be just beyond the far plane. Saves per-tri Lua→C crossing cost.
local TREE_CULL_SQ = 30 * 30

local function ground_height(gx, gz)
    return sin(gx * 0.35) * 0.25 + cos(gz * 0.28) * 0.25
           + sin(gx * 0.17 + gz * 0.13) * 0.2
end

local function build_ground()
    local step = GROUND_SIZE / GROUND_N
    for gi = 0, GROUND_N - 1 do
        for gj = 0, GROUND_N - 1 do
            local x1 = -GROUND_HALF + gi * step
            local z1 = -GROUND_HALF + gj * step
            local x2 = x1 + step
            local z2 = z1 + step
            local y11 = ground_height(x1, z1)
            local y21 = ground_height(x2, z1)
            local y22 = ground_height(x2, z2)
            local y12 = ground_height(x1, z2)
            local v = (sin(gi * 0.9) + cos(gj * 1.3)) * 0.5 + 0.5
            local gc = rgb(55 + floor(v * 20),
                           100 + floor(v * 45),
                           40 + floor(v * 25))
            add_tri(x1, y11, z1, x2, y21, z1, x2, y22, z2, gc)
            add_tri(x1, y11, z1, x2, y22, z2, x1, y12, z2, gc)
        end
    end
end

local function build_path()
    -- Subdivide the N-S and E-W paths into many short segments so each
    -- segment's avg-z maps cleanly to its real position. Each corner's
    -- Y is sampled from ground_height() + a small offset so the path
    -- drapes over the hills instead of cutting through them, which
    -- eliminates the z-fighting we'd otherwise get between the path and
    -- the grass tiles. The offset is larger than any likely mismatch
    -- between the path's linear interpolation and the ground grid's
    -- linear interpolation.
    local pc = rgb(180, 150, 95)
    local pc2 = rgb(150, 125, 75)
    local lift = 0.12
    local segs = 12
    local step = GROUND_SIZE / segs
    local hw = 1.2

    -- N-S path (running along +Z)
    for i = 0, segs - 1 do
        local z1 = -GROUND_HALF + i * step
        local z2 = z1 + step
        local y11 = ground_height(-hw, z1) + lift
        local y21 = ground_height( hw, z1) + lift
        local y22 = ground_height( hw, z2) + lift
        local y12 = ground_height(-hw, z2) + lift
        add_quad(-hw, y11, z1,  hw, y21, z1,
                  hw, y22, z2, -hw, y12, z2, pc)
    end

    -- E-W path (running along +X). A hair taller at the intersection so
    -- the cross-over draws cleanly over the N-S segment.
    local cross_lift = lift + 0.01
    for i = 0, segs - 1 do
        local x1 = -GROUND_HALF + i * step
        local x2 = x1 + step
        local y11 = ground_height(x1, -hw) + cross_lift
        local y21 = ground_height(x2, -hw) + cross_lift
        local y22 = ground_height(x2,  hw) + cross_lift
        local y12 = ground_height(x1,  hw) + cross_lift
        add_quad(x1, y11, -hw,  x2, y21, -hw,
                  x2, y22,  hw,  x1, y12,  hw, pc2)
    end
end

local function add_building(bx, bz, bw, bd, wall_h, roof_h, wall_col, roof_col)
    local x1, x2 = bx - bw / 2, bx + bw / 2
    local z1, z2 = bz - bd / 2, bz + bd / 2
    local ridge_y = wall_h + roof_h
    local rz = bz

    add_quad(x1, 0, z1, x2, 0, z1, x2, wall_h, z1, x1, wall_h, z1,
             shade(wall_col, 1.0))
    add_quad(x2, 0, z2, x1, 0, z2, x1, wall_h, z2, x2, wall_h, z2,
             shade(wall_col, 0.55))
    add_quad(x2, 0, z1, x2, 0, z2, x2, wall_h, z2, x2, wall_h, z1,
             shade(wall_col, 0.8))
    add_quad(x1, 0, z2, x1, 0, z1, x1, wall_h, z1, x1, wall_h, z2,
             shade(wall_col, 0.65))

    add_tri(x2, wall_h, z1, x2, wall_h, z2, x2, ridge_y, rz,
            shade(wall_col, 0.78))
    add_tri(x1, wall_h, z2, x1, wall_h, z1, x1, ridge_y, rz,
            shade(wall_col, 0.62))

    add_quad(x1, wall_h, z1, x2, wall_h, z1, x2, ridge_y, rz, x1, ridge_y, rz,
             shade(roof_col, 1.0))
    add_quad(x1, ridge_y, rz, x2, ridge_y, rz, x2, wall_h, z2, x1, wall_h, z2,
             shade(roof_col, 0.7))

    local cr = max3(bw, bd) * 0.55
    obstacles[#obstacles + 1] = { bx, bz, cr }
end

-- Generic axis-aligned box: 4 side faces with directional shading + a
-- top. No bottom face (never visible at eye height). Used for hedges,
-- crates, gravestones, fence posts, and similar single-volume props.
-- `y0` is the bottom Y in world space (defaults to 0, i.e. ground).
local function add_box(bx, bz, bw, bd, h, side_col, top_col, y0)
    y0 = y0 or 0
    local x1, x2 = bx - bw / 2, bx + bw / 2
    local z1, z2 = bz - bd / 2, bz + bd / 2
    local y1, y2 = y0, y0 + h

    add_quad(x1, y1, z1, x2, y1, z1, x2, y2, z1, x1, y2, z1, shade(side_col, 1.0))
    add_quad(x2, y1, z2, x1, y1, z2, x1, y2, z2, x2, y2, z2, shade(side_col, 0.55))
    add_quad(x2, y1, z1, x2, y1, z2, x2, y2, z2, x2, y2, z1, shade(side_col, 0.8))
    add_quad(x1, y1, z2, x1, y1, z1, x1, y2, z1, x1, y2, z2, shade(side_col, 0.65))
    add_quad(x1, y2, z1, x2, y2, z1, x2, y2, z2, x1, y2, z2, shade(top_col, 1.0))
end

-- Hedge: leafy green box.
local function add_hedge_box(bx, bz, bw, bd, h)
    add_box(bx, bz, bw, bd, h, rgb(55, 120, 55), rgb(70, 140, 65))
end

-- Hollow shop building. South-facing doorway gap (1.5m wide, full
-- wall-height) lets the player see the interior through the opening
-- without walking in — we render every wall from both sides and add a
-- wooden floor + dark ceiling so the interior reads as a real room.
-- Returns (door_x, door_z) so shop interaction code can know where the
-- entry is. The shop is registered as a single-circle obstacle (player
-- can approach the doorway but not pass through), and `shops` keeps a
-- record for proximity-based interaction.
local shops = {}
local function add_shop_building(bx, bz, bw, bd, wall_h, roof_h,
                                 wall_col, roof_col, floor_col, interior_col,
                                 label)
    local x1, x2 = bx - bw / 2, bx + bw / 2
    local z1, z2 = bz - bd / 2, bz + bd / 2
    local ridge_y = wall_h + roof_h
    local rz = bz

    -- Doorway geometry: centred on south wall.
    local door_hw = 0.75     -- half-width
    local door_h  = 2.0      -- height
    local door_lx = bx - door_hw
    local door_rx = bx + door_hw

    -- === OUTER walls (CCW viewed from outside) =============================
    -- South wall has the doorway: left segment + right segment + lintel above
    -- the door. North/east/west walls are full panels.
    if door_lx > x1 then
        add_quad(x1, 0, z1, door_lx, 0, z1, door_lx, wall_h, z1,
                 x1, wall_h, z1, shade(wall_col, 1.0))
    end
    if door_rx < x2 then
        add_quad(door_rx, 0, z1, x2, 0, z1, x2, wall_h, z1,
                 door_rx, wall_h, z1, shade(wall_col, 1.0))
    end
    -- Lintel above the door
    add_quad(door_lx, door_h, z1, door_rx, door_h, z1,
             door_rx, wall_h, z1, door_lx, wall_h, z1,
             shade(wall_col, 0.9))

    -- Remaining three walls — full panels.
    add_quad(x2, 0, z2, x1, 0, z2, x1, wall_h, z2, x2, wall_h, z2,
             shade(wall_col, 0.55))
    add_quad(x2, 0, z1, x2, 0, z2, x2, wall_h, z2, x2, wall_h, z1,
             shade(wall_col, 0.8))
    add_quad(x1, 0, z2, x1, 0, z1, x1, wall_h, z1, x1, wall_h, z2,
             shade(wall_col, 0.65))

    -- === INNER walls (CCW viewed from INSIDE — opposite winding) ===========
    -- Same wall geometry, reversed vertex order so back-face cull keeps
    -- them visible when the camera is inside the shop OR looking through
    -- the doorway.
    local inner = shade(interior_col, 0.9)
    if door_lx > x1 then
        add_quad(x1, wall_h, z1, door_lx, wall_h, z1,
                 door_lx, 0, z1, x1, 0, z1, inner)
    end
    if door_rx < x2 then
        add_quad(door_rx, wall_h, z1, x2, wall_h, z1,
                 x2, 0, z1, door_rx, 0, z1, inner)
    end
    add_quad(door_lx, wall_h, z1, door_rx, wall_h, z1,
             door_rx, door_h, z1, door_lx, door_h, z1,
             shade(interior_col, 0.8))
    add_quad(x2, wall_h, z2, x2, wall_h, z1, x2, 0, z1, x2, 0, z2,
             shade(interior_col, 0.7))
    add_quad(x1, wall_h, z1, x1, wall_h, z2, x1, 0, z2, x1, 0, z1,
             shade(interior_col, 0.85))
    -- North wall inner face — brightest, facing the doorway
    add_quad(x1, wall_h, z2, x1, 0, z2, x2, 0, z2, x2, wall_h, z2,
             shade(interior_col, 1.0))

    -- === Floor + ceiling for the interior =================================
    -- Floor quad slightly above the ground so the adjacent ground grass
    -- doesn't z-fight with it. CCW when viewed from above.
    add_quad(x1, 0.04, z2, x2, 0.04, z2, x2, 0.04, z1, x1, 0.04, z1,
             shade(floor_col, 1.0))
    -- Ceiling: visible from inside looking up; skip when viewed from above.
    add_quad(x1, wall_h, z1, x2, wall_h, z1, x2, wall_h, z2, x1, wall_h, z2,
             shade(interior_col, 0.6))

    -- === Gabled roof (same as add_building) ===============================
    add_tri(x2, wall_h, z1, x2, wall_h, z2, x2, ridge_y, rz,
            shade(wall_col, 0.78))
    add_tri(x1, wall_h, z2, x1, wall_h, z1, x1, ridge_y, rz,
            shade(wall_col, 0.62))
    add_quad(x1, wall_h, z1, x2, wall_h, z1, x2, ridge_y, rz, x1, ridge_y, rz,
             shade(roof_col, 1.0))
    add_quad(x1, ridge_y, rz, x2, ridge_y, rz, x2, wall_h, z2, x1, wall_h, z2,
             shade(roof_col, 0.7))

    -- Register a circular obstacle for collision. Using the building
    -- footprint minus the doorway would need AABB collision; a slightly
    -- shrunken circle is a reasonable compromise that still stops the
    -- player from clipping into the walls.
    local cr = max3(bw, bd) * 0.5
    obstacles[#obstacles + 1] = { bx, bz, cr }

    -- Record the shop so proximity/interaction code can find it.
    shops[#shops + 1] = {
        x = bx,
        z = bz,
        door_x = bx,           -- centre of doorway on south face
        door_z = z1,
        radius = max3(bw, bd) * 0.5 + 1.2,  -- interaction radius
        label = label or "SHOP",
    }
end

-- Walkable stone castle — four thick walls enclosing an open courtyard
-- with a gateway on the south face plus corner towers. Walls are real
-- 3D boxes (add_box) so they're visible and lit correctly from both
-- the outside and from inside the courtyard. Collision registers each
-- wall as an AABB obstacle so the player can walk through the gateway
-- but not through the walls or corners.
--
-- Geometry layout (looking down from above):
--
--    W wall      N wall      E wall
--     ┌───────────────────────┐
--     │         N             │
--     │     ╔════════╗        │
--     │     ║ COURT  ║        │
--     │     ║        ║        │
--     │     ╚══╗  ╔══╝        │
--     └────────┘  └───────────┘
--              SW gap SE         ← south wall with gateway
--
-- Parameters:
--   cx, cz   centre of the castle footprint
--   inner    inner courtyard side length (open playable area)
--   wall_h   wall height in world units
local function add_castle(cx, cz, inner, wall_h)
    inner = inner or 10
    wall_h = wall_h or 3.5
    local t = 0.8                -- wall thickness
    local outer = inner + 2 * t
    local x1_out = cx - outer / 2
    local x2_out = cx + outer / 2
    local z1_out = cz - outer / 2
    local z2_out = cz + outer / 2
    local x1_in = x1_out + t
    local x2_in = x2_out - t
    local z1_in = z1_out + t
    local z2_in = z2_out - t

    -- Gateway on south wall — centre on cx, 2.4m wide, full wall height.
    local gate_hw = 1.2
    local gate_lx = cx - gate_hw
    local gate_rx = cx + gate_hw

    local wall_col  = rgb(130, 125, 115)
    local wall_top  = rgb(155, 150, 140)
    local floor_col = rgb(110, 100, 90)
    local roof_col  = rgb(85, 50, 40)
    local tower_col = rgb(120, 115, 105)

    -- === Walls as thick boxes ============================================
    -- South wall, segmented into west and east halves flanking the gate.
    local sw_w = gate_lx - x1_out
    if sw_w > 0 then
        add_box(x1_out + sw_w / 2, z1_out + t / 2, sw_w, t, wall_h,
                wall_col, wall_top)
        obstacles[#obstacles + 1] = { aabb = true,
            x1 = x1_out, z1 = z1_out, x2 = gate_lx, z2 = z1_out + t }
    end
    local se_w = x2_out - gate_rx
    if se_w > 0 then
        add_box(gate_rx + se_w / 2, z1_out + t / 2, se_w, t, wall_h,
                wall_col, wall_top)
        obstacles[#obstacles + 1] = { aabb = true,
            x1 = gate_rx, z1 = z1_out, x2 = x2_out, z2 = z1_out + t }
    end

    -- North wall (full)
    add_box(cx, z2_out - t / 2, outer, t, wall_h, wall_col, wall_top)
    obstacles[#obstacles + 1] = { aabb = true,
        x1 = x1_out, z1 = z2_out - t, x2 = x2_out, z2 = z2_out }

    -- West and East walls span the corners inside the N/S slabs.
    add_box(x1_out + t / 2, cz, t, outer, wall_h, wall_col, wall_top)
    obstacles[#obstacles + 1] = { aabb = true,
        x1 = x1_out, z1 = z1_out, x2 = x1_out + t, z2 = z2_out }

    add_box(x2_out - t / 2, cz, t, outer, wall_h, wall_col, wall_top)
    obstacles[#obstacles + 1] = { aabb = true,
        x1 = x2_out - t, z1 = z1_out, x2 = x2_out, z2 = z2_out }

    -- Stone gateway lintel spanning the opening at the top. Matches the
    -- shop building's lintel trick so the top of the gate is a solid
    -- piece of wall.
    local lintel_h = 1.2
    local gate_open_h = wall_h - lintel_h
    add_box(cx, z1_out + t / 2, 2 * gate_hw, t, lintel_h,
            wall_col, wall_top, gate_open_h)

    -- === Courtyard floor =================================================
    -- Cobble-stone floor slightly above ground to avoid z-fighting.
    add_quad(x1_in, 0.05, z2_in, x2_in, 0.05, z2_in,
             x2_in, 0.05, z1_in, x1_in, 0.05, z1_in,
             shade(floor_col, 1.0))

    -- === Corner towers ===================================================
    -- Square towers at each corner, taller than the walls, with pyramid
    -- caps. Each tower re-uses add_tower but inlines here with tighter
    -- size so they anchor to the wall corners cleanly.
    local tower_size = 2.4
    local tower_h = wall_h + 1.6
    local function place_tower(tx, tz)
        add_box(tx, tz, tower_size, tower_size, tower_h,
                tower_col, wall_top)
        -- Pyramid cap: 4 triangles meeting at a tip.
        local ts = tower_size / 2
        local tx1, tx2 = tx - ts, tx + ts
        local tz1, tz2 = tz - ts, tz + ts
        local tip_h = tower_h + tower_size * 0.8
        add_tri(tx1, tower_h, tz1, tx2, tower_h, tz1, tx, tip_h, tz,
                shade(roof_col, 1.0))
        add_tri(tx2, tower_h, tz2, tx1, tower_h, tz2, tx, tip_h, tz,
                shade(roof_col, 0.55))
        add_tri(tx2, tower_h, tz1, tx2, tower_h, tz2, tx, tip_h, tz,
                shade(roof_col, 0.8))
        add_tri(tx1, tower_h, tz2, tx1, tower_h, tz1, tx, tip_h, tz,
                shade(roof_col, 0.65))
        -- Tower obstacle — box-shaped, though it sits within the wall
        -- AABBs so it's mostly redundant; kept anyway for certainty.
        obstacles[#obstacles + 1] = { aabb = true,
            x1 = tx - ts, z1 = tz - ts, x2 = tx + ts, z2 = tz + ts }
    end
    place_tower(x1_out, z1_out)
    place_tower(x2_out, z1_out)
    place_tower(x1_out, z2_out)
    place_tower(x2_out, z2_out)
end

-- Stone watchtower with a pyramid roof. Taller than regular buildings so
-- it silhouettes against the sky and gives the player a visual landmark.
local function add_tower(bx, bz, size, height, wall_col, cap_col)
    local s = size / 2
    local x1, x2 = bx - s, bx + s
    local z1, z2 = bz - s, bz + s
    add_quad(x1, 0, z1, x2, 0, z1, x2, height, z1, x1, height, z1, shade(wall_col, 1.0))
    add_quad(x2, 0, z2, x1, 0, z2, x1, height, z2, x2, height, z2, shade(wall_col, 0.55))
    add_quad(x2, 0, z1, x2, 0, z2, x2, height, z2, x2, height, z1, shade(wall_col, 0.8))
    add_quad(x1, 0, z2, x1, 0, z1, x1, height, z1, x1, height, z2, shade(wall_col, 0.65))
    -- Pyramid cap — four triangles meeting at a central tip. Shading
    -- follows the same compass convention as the walls.
    local tip_h = height + size * 0.9
    add_tri(x1, height, z1, x2, height, z1, bx, tip_h, bz, shade(cap_col, 1.0))
    add_tri(x2, height, z2, x1, height, z2, bx, tip_h, bz, shade(cap_col, 0.55))
    add_tri(x2, height, z1, x2, height, z2, bx, tip_h, bz, shade(cap_col, 0.8))
    add_tri(x1, height, z2, x1, height, z1, bx, tip_h, bz, shade(cap_col, 0.65))
    obstacles[#obstacles + 1] = { bx, bz, size * 0.6 }
end

-- Stone well: a square stone ring with water visible at the top.
-- Crosses the grid origin by default, serving as a landmark at the
-- central crossroads. Two concentric boxes (outer stone + inner water).
local function add_well(bx, bz)
    local outer = 1.2
    local inner = 0.7
    local rim_h = 0.8
    local stone = rgb(150, 140, 125)
    local stone_top = rgb(175, 165, 150)
    -- Outer stone ring: we model it as four narrow rectangular walls so
    -- the inside of the well is hollow (you see water, not stone).
    local s = outer / 2
    local is = inner / 2
    -- N wall
    add_box(bx, bz + (s + is) / 2, outer, s - is, rim_h, stone, stone_top)
    -- S wall
    add_box(bx, bz - (s + is) / 2, outer, s - is, rim_h, stone, stone_top)
    -- E wall
    add_box(bx + (s + is) / 2, bz, s - is, inner, rim_h, stone, stone_top)
    -- W wall
    add_box(bx - (s + is) / 2, bz, s - is, inner, rim_h, stone, stone_top)
    -- Water surface — a single dark-blue quad at rim height minus a hair.
    local wy = rim_h - 0.08
    add_quad(bx - is, wy, bz - is, bx + is, wy, bz - is,
             bx + is, wy, bz + is, bx - is, wy, bz + is,
             rgb(40, 70, 140))
    -- Wooden crossbeam above the well (decorative)
    add_box(bx, bz, outer * 1.05, 0.12, 0.15, rgb(110, 75, 40), rgb(130, 90, 50),
            rim_h + 1.3)
    -- Roof: two small posts + a gabled cap
    add_box(bx - outer * 0.45, bz, 0.1, 0.1, 1.3, rgb(100, 65, 35), rgb(120, 85, 45), rim_h)
    add_box(bx + outer * 0.45, bz, 0.1, 0.1, 1.3, rgb(100, 65, 35), rgb(120, 85, 45), rim_h)
    obstacles[#obstacles + 1] = { bx, bz, outer * 0.55 }
end

-- Lamppost: thin dark post + cross-arm + a bulb that glows at night.
-- Static parts added at scene build; the glow is a camera-facing
-- billboard added per frame so it can modulate with scene_light().
local function add_lamppost(bx, bz)
    local post_h = 2.8
    -- Post: tall thin column
    add_box(bx, bz, 0.15, 0.15, post_h,
            rgb(55, 55, 60), rgb(75, 75, 80))
    -- Cross-arm at the top extending slightly north so the lamp
    -- silhouette reads clearly against the sky.
    add_box(bx, bz + 0.3, 0.08, 0.6, 0.1,
            rgb(55, 55, 60), rgb(75, 75, 80), post_h - 0.2)
    -- Lamp housing (small box at the end of the arm)
    add_box(bx, bz + 0.5, 0.28, 0.28, 0.28,
            rgb(40, 40, 50), rgb(60, 60, 65), post_h - 0.45)
    obstacles[#obstacles + 1] = { bx, bz, 0.25 }
    lampposts[#lampposts + 1] = { x = bx, z = bz + 0.5, y = post_h - 0.3 }
end

-- Wooden crate: squat box with a lighter top.
local function add_crate(bx, bz, size)
    size = size or 0.7
    add_box(bx, bz, size, size, size,
            rgb(125, 85, 40), rgb(150, 105, 55))
    obstacles[#obstacles + 1] = { bx, bz, size * 0.55 }
end

-- Barrel — simple square approximation rather than a cylinder (cylinders
-- aren't worth the triangle budget). A bit taller than wide.
local function add_barrel(bx, bz)
    local w = 0.55
    local h = 0.85
    add_box(bx, bz, w, w, h, rgb(95, 60, 30), rgb(115, 75, 35))
    -- Lid rim — a thin darker band around the top edge.
    add_box(bx, bz, w * 1.02, w * 1.02, 0.06,
            rgb(60, 35, 20), rgb(70, 45, 25), h - 0.03)
    obstacles[#obstacles + 1] = { bx, bz, w * 0.55 }
end

-- Simple gravestone: narrow upright slab.
local function add_gravestone(bx, bz, rot_north)
    local w = rot_north and 0.1 or 0.4
    local d = rot_north and 0.4 or 0.1
    local h = 0.55 + random() * 0.15
    add_box(bx, bz, w, d, h, rgb(130, 130, 125), rgb(155, 155, 150))
    obstacles[#obstacles + 1] = { bx, bz, 0.3 }
end

-- Fence: a run of thin tall posts along an axis-aligned line.
-- segments controls how many posts to lay down (one at each step).
local function add_fence_line(x1, z1, x2, z2, segments)
    local dx = (x2 - x1) / segments
    local dz = (z2 - z1) / segments
    for i = 0, segments - 1 do
        local cx = x1 + dx * (i + 0.5)
        local cz = z1 + dz * (i + 0.5)
        add_box(cx, cz, 0.08, 0.08, 0.9,
                rgb(110, 80, 45), rgb(130, 95, 55))
    end
    -- Horizontal rails connecting the posts (two thin boxes)
    local mx = (x1 + x2) * 0.5
    local mz = (z1 + z2) * 0.5
    local len_x = abs(x2 - x1)
    local len_z = abs(z2 - z1)
    local rail_w = (len_x > len_z) and len_x or 0.06
    local rail_d = (len_x > len_z) and 0.06 or len_z
    add_box(mx, mz, rail_w, rail_d, 0.08,
            rgb(110, 80, 45), rgb(130, 95, 55), 0.55)
    add_box(mx, mz, rail_w, rail_d, 0.08,
            rgb(110, 80, 45), rgb(130, 95, 55), 0.15)
end

-- Campfire: a stack of two crossed logs plus a flame silhouette that
-- flickers with anim_t. Pure decoration — added to dynamic scene each
-- frame so the flame animation reads.
local function add_campfire_static(bx, bz)
    -- Two crossed logs at ground level. Fixed geometry (no animation).
    add_box(bx, bz, 0.6, 0.12, 0.12, rgb(85, 55, 25), rgb(105, 70, 30))
    add_box(bx, bz, 0.12, 0.6, 0.12, rgb(85, 55, 25), rgb(105, 70, 30), 0.12)
    obstacles[#obstacles + 1] = { bx, bz, 0.35 }
    -- Stone ring around the fire
    for _, p in ipairs({ {-1,0}, {1,0}, {0,-1}, {0,1} }) do
        add_box(bx + p[1] * 0.4, bz + p[2] * 0.4, 0.2, 0.2, 0.1,
                rgb(130, 120, 110), rgb(150, 140, 130))
    end
end

---------------------------------------------------------------------------
-- Billboard submission (per-frame sprite geometry)
---------------------------------------------------------------------------
-- Small forward nudge (in world units) applied to billboards so their
-- vertices sit slightly closer to the camera than the ground tile they
-- stand on. Without this, trunk/ground share an avg_z and the painter's
-- tie-break can leave patches of grass drawn over a tree.
local BILLBOARD_FWD = 0.08

-- Thin Lua shims over the C billboard primitives. Each helper is a
-- single Lua→C crossing now; corner math + forward nudge happen in
-- native code using the camera context set via scene_set_camera()
-- once per frame. Local aliases keep the hot-path call cheap.
local add_billboard, add_billboard_split

-- Camera-facing triangular tier used for layered pine canopy. Apex at
-- the top (always on the tree's centre line), base spread horizontally
-- along the camera-right vector so every angle shows a clean silhouette.
-- Same forward-nudge as billboards so the tier beats the ground tile
-- beneath the tree in the painter's depth sort.
local function add_pine_tier(cx, cz, apex_y, base_y, half_w, color)
    local rx = yaw_cos
    local rz = -yaw_sin
    local fdx = cx - px
    local fdz = cz - pz
    local flen = sqrt(fdx * fdx + fdz * fdz)
    if flen > 0.001 then
        fdx = fdx / flen * BILLBOARD_FWD
        fdz = fdz / flen * BILLBOARD_FWD
        cx = cx - fdx
        cz = cz - fdz
    end
    local lx = cx - rx * half_w
    local lz = cz - rz * half_w
    local r2x = cx + rx * half_w
    local r2z = cz + rz * half_w
    scene_add(scene, cx, apex_y, cz, lx, base_y, lz, r2x, base_y, r2z, color)
end

local function add_pine(t)
    local base_y = ground_height(t.x, t.z)
    local trunk_h = 0.45 * t.scale
    local canopy_h = 2.3 * t.scale
    local canopy_w = 1.0 * t.scale
    local cb = base_y + trunk_h

    -- Shadow first so it draws furthest back on ties (stable sort).
    add_billboard(t.x, cb - 0.02, t.z,
                  canopy_w * 0.7, 0.1, rgb(15, 40, 20))
    -- Trunk
    add_billboard(t.x, base_y + trunk_h * 0.5, t.z,
                  0.13 * t.scale, trunk_h, rgb(85, 55, 30))

    -- Three stacked tiers, widest at the base and narrower toward the
    -- tip. Colours progress from dark green at the base to bright green
    -- at the top — the classic Christmas-tree silhouette that a single
    -- flat triangle couldn't capture. Inserted bottom-first so the
    -- tip tier ends up drawn last (stable sort preserves this order).
    add_pine_tier(t.x, t.z,
                  cb + canopy_h * 0.45,
                  cb,
                  canopy_w,
                  rgb(25, 80, 40))

    add_pine_tier(t.x, t.z,
                  cb + canopy_h * 0.72,
                  cb + canopy_h * 0.3,
                  canopy_w * 0.68,
                  rgb(40, 110, 50))

    add_pine_tier(t.x, t.z,
                  cb + canopy_h,
                  cb + canopy_h * 0.55,
                  canopy_w * 0.36,
                  rgb(65, 145, 60))
end

local function add_oak(t)
    local base_y = ground_height(t.x, t.z)
    local trunk_h = 0.75 * t.scale
    local canopy_h = 1.7 * t.scale
    local canopy_w = 1.35 * t.scale
    local cb = base_y + trunk_h - 0.05

    -- Shadow first (submitted before other billboards so it sorts
    -- behind them on stable-sort ties).
    add_billboard(t.x, cb - 0.02, t.z,
                  canopy_w * 0.55, 0.1, rgb(15, 40, 20))

    -- Trunk
    add_billboard(t.x, base_y + trunk_h * 0.5, t.z,
                  0.17 * t.scale, trunk_h, rgb(95, 65, 35))

    -- Round bushy oak built from three overlapping billboard clusters:
    -- a wide brighter middle, a narrower dark base, and a small light
    -- crown. Submitted bottom-first so the crown tops out on ties.
    add_billboard(t.x, cb + canopy_h * 0.2, t.z,
                  canopy_w * 0.48, canopy_h * 0.45,
                  rgb(30, 75, 35))

    add_billboard_split(t.x, cb + canopy_h * 0.55, t.z,
                        canopy_w * 0.55, canopy_h * 0.65,
                        rgb(65, 140, 60), rgb(40, 95, 45))

    add_billboard(t.x, cb + canopy_h * 0.9, t.z,
                  canopy_w * 0.34, canopy_h * 0.35,
                  rgb(95, 170, 70))
end

-- Zombie type definitions. Each variant has a visual scale and a unique
-- colour palette so the player can identify threats at a glance. HP and
-- speed come from spawn_zombie; rendering only reads the visual fields.
local ZOMBIE_KIND = {
    normal = {
        body_w = 0.45, body_h = 1.0, leg_h = 0.55, head_h = 0.32,
        shirt = rgb(150, 30, 25), arm = rgb(115, 25, 20),
        leg = rgb(55, 30, 20), skin = rgb(165, 125, 90),
        hp = 3, speed = 0.022,
    },
    fast = {
        -- Slimmer, slightly shorter, vivid yellow-green shirt so it
        -- reads as "sprinter" at distance.
        body_w = 0.32, body_h = 0.9, leg_h = 0.6, head_h = 0.28,
        shirt = rgb(165, 185, 40), arm = rgb(125, 140, 30),
        leg = rgb(45, 45, 20), skin = rgb(150, 145, 90),
        hp = 2, speed = 0.036,
    },
    tank = {
        -- Beefier silhouette, dark green hulking body, slow but durable.
        body_w = 0.65, body_h = 1.25, leg_h = 0.55, head_h = 0.38,
        shirt = rgb(70, 115, 55), arm = rgb(50, 95, 40),
        leg = rgb(35, 40, 25), skin = rgb(130, 155, 110),
        hp = 6, speed = 0.014,
    },
}

local function add_zombie(e)
    local def = ZOMBIE_KIND[e.kind] or ZOMBIE_KIND.normal
    local base_y = ground_height(e.x, e.z)
    local body_h = def.body_h
    local body_w = def.body_w
    local leg_h = def.leg_h
    local head_h = def.head_h

    -- Walk cycle phase offset per zombie so they don't all animate in
    -- lockstep; tanks shuffle slower so divide anim_t by a larger step.
    local step = (e.kind == 'tank') and 14 or 10
    local phase = (floor(anim_t / step) + e.phase) % 2
    local lift_l = (phase == 0) and 0.08 or 0.0
    local lift_r = (phase == 0) and 0.0 or 0.08

    local rx = yaw_cos
    local rz = -yaw_sin
    local leg_cx_l = e.x - rx * body_w * 0.25
    local leg_cz_l = e.z - rz * body_w * 0.25
    local leg_cx_r = e.x + rx * body_w * 0.25
    local leg_cz_r = e.z + rz * body_w * 0.25

    add_billboard(leg_cx_l, base_y + leg_h * 0.5 + lift_l, leg_cz_l,
                  body_w * 0.24, leg_h - lift_l, def.leg)
    add_billboard(leg_cx_r, base_y + leg_h * 0.5 + lift_r, leg_cz_r,
                  body_w * 0.24, leg_h - lift_r, def.leg)

    add_billboard(e.x, base_y + leg_h + body_h * 0.5, e.z,
                  body_w * 0.5, body_h, def.shirt)
    -- Belt separating torso from legs — same dark band for every kind.
    add_billboard(e.x, base_y + leg_h + body_h * 0.08, e.z,
                  body_w * 0.5, body_h * 0.1, rgb(40, 25, 15))

    add_billboard(e.x - rx * body_w * 0.55, base_y + leg_h + body_h * 0.6,
                  e.z - rz * body_w * 0.55,
                  body_w * 0.13, body_h * 0.7, def.arm)
    add_billboard(e.x + rx * body_w * 0.55, base_y + leg_h + body_h * 0.6,
                  e.z + rz * body_w * 0.55,
                  body_w * 0.13, body_h * 0.7, def.arm)

    add_billboard(e.x, base_y + leg_h + body_h + head_h * 0.5, e.z,
                  body_w * 0.3, head_h, def.skin)
    -- Glowing eye strip — brighter on tanks / fasts so they read as
    -- more dangerous at distance.
    local eye_col = (e.kind == 'tank') and rgb(255, 180, 40)
                 or (e.kind == 'fast') and rgb(90, 255, 90)
                 or rgb(210, 50, 50)
    add_billboard(e.x, base_y + leg_h + body_h + head_h * 0.55, e.z,
                  body_w * 0.28, head_h * 0.18, eye_col)
end

-- Animated campfire flame: three stacked triangles facing the camera.
-- Flickers via a sin(anim_t)-modulated height offset.
local function add_campfire_flame(cf)
    local flicker = sin(anim_t * 0.4 + cf.x * 2 + cf.z) * 0.08
    local base_y = 0.25
    local flame_h = 0.7 + flicker
    local flame_w = 0.3
    local cx = cf.x
    local cz = cf.z
    -- Outer orange flame
    local rx = yaw_cos
    local rz = -yaw_sin
    local lx = cx - rx * flame_w * 0.5
    local lz = cz - rz * flame_w * 0.5
    local r2x = cx + rx * flame_w * 0.5
    local r2z = cz + rz * flame_w * 0.5
    scene_add(scene,
        cx, base_y + flame_h, cz,
        lx, base_y, lz,
        r2x, base_y, r2z,
        rgb(255, 110, 20))
    -- Inner yellow hot core
    local core_h = flame_h * 0.7
    local core_w = flame_w * 0.55
    lx = cx - rx * core_w * 0.5
    lz = cz - rz * core_w * 0.5
    r2x = cx + rx * core_w * 0.5
    r2z = cz + rz * core_w * 0.5
    scene_add(scene,
        cx, base_y + core_h, cz,
        lx, base_y + 0.05, lz,
        r2x, base_y + 0.05, r2z,
        rgb(255, 220, 80))
    -- Glowing embers at the bottom
    add_billboard(cx, base_y - 0.1, cz, 0.3, 0.1, rgb(200, 60, 15))
end

-- Lamp glow: only submitted at dusk/night when scene_light dims. Two
-- stacked translucent-looking billboards (just overlapping colors) give
-- a simple bloom effect. Size flickers subtly so the lamp reads as lit.
local function add_lamp_glow(lp)
    local sh = sun_height()
    if sh > 0.1 then return end  -- bright daylight, glow invisible
    local flick = sin(anim_t * 0.15 + lp.x + lp.z) * 0.05
    local outer = 0.55 + flick
    local inner = 0.28 + flick * 0.5
    local intensity = math.min(1.0, (0.1 - sh) / 0.25)
    local rb = floor(80 + 140 * intensity)
    local gb = floor(60 + 110 * intensity)
    add_billboard(lp.x, lp.y, lp.z, outer, outer * 1.1,
                  rgb(rb, gb, 30))
    add_billboard(lp.x, lp.y, lp.z, inner, inner * 1.1,
                  rgb(255, 230, 120))
end

-- Dropped material sprite. Small bobbing billboard coloured by kind.
-- When its TTL is nearly expired we flicker the visibility so the
-- player gets a visual "about to disappear" hint.
local function add_drop(drop)
    local base_y = ground_height(drop.x, drop.z)
    -- Flicker in the last ~2 seconds of the TTL
    if drop.ttl < 60 and (floor(anim_t / 4) % 2 == 0) then return end
    local bob = sin(anim_t * 0.1 + drop.x * 1.7 + drop.z * 1.1) * 0.08
    local style = MAT_STYLE[drop.kind] or MAT_STYLE.wood
    local h = 0.3
    local hw = 0.18
    add_billboard_split(drop.x, base_y + h * 0.5 + 0.15 + bob, drop.z,
                        hw, h, style.col_top, style.col_bot)
end

local function add_pickup(p)
    local base_y = ground_height(p.x, p.z)
    local bob = sin(anim_t * 0.08 + p.x * 1.3 + p.z * 0.7) * 0.1
    local w = 0.35
    local h = 0.35
    if p.kind == "hp" then
        add_billboard_split(p.x, base_y + h * 0.5 + 0.2 + bob, p.z,
                            w * 0.5, h,
                            rgb(60, 230, 60), rgb(10, 130, 10))
    else
        add_billboard_split(p.x, base_y + h * 0.5 + 0.2 + bob, p.z,
                            w * 0.5, h,
                            rgb(245, 220, 80), rgb(140, 115, 20))
    end
end

---------------------------------------------------------------------------
-- World build
---------------------------------------------------------------------------
local function build_world()
    ez.display.scene_clear(scene)
    obstacles = {}
    trees = {}
    spawn_points = {}
    campfires = {}
    shops = {}
    lampposts = {}

    build_ground()
    build_path()

    -- Three cottages at the compass corners plus a SHOP on the SE
    -- corner with a visible doorway on its south face. The shop is
    -- built with add_shop_building so walls render from both sides
    -- and the interior is a visible room through the doorway.
    add_building(-8, -8, 3.5, 3.0, 2.4, 1.2,
                 rgb(200, 180, 140), rgb(140, 60, 40))
    add_building( 8, -8, 3.0, 3.0, 2.6, 1.2,
                 rgb(175, 150, 115), rgb(90, 50, 35))
    add_building(-8,  8, 3.2, 3.2, 2.4, 1.4,
                 rgb(215, 195, 155), rgb(120, 55, 35))
    add_shop_building( 8,  8, 4.0, 3.0, 2.6, 1.3,
                 rgb(200, 180, 140), rgb(120, 55, 30),
                 rgb(120, 85, 45), rgb(180, 160, 130),
                 "GENERAL STORE")

    -- A few lampposts around the central crossroads. At night the
    -- glow billboards make the intersection feel lit; during the day
    -- they're just silhouettes against the sky.
    add_lamppost(-3, -3)
    add_lamppost( 3, -3)
    add_lamppost(-3,  3)
    add_lamppost( 3,  3)

    -- Large hall on the west side (replaces the simple east box).
    add_building(-13, 0, 3.0, 5.0, 2.6, 1.4,
                 rgb(195, 175, 135), rgb(100, 50, 40))

    -- Stone watchtower on the east side — taller than everything else
    -- so it anchors the skyline from anywhere on the map.
    add_tower(13, 0, 2.4, 4.5, rgb(155, 150, 135), rgb(90, 55, 45))

    -- Well at the central crossroads, where the paths meet.
    add_well(0, 0)

    -- Campfire between the SW cottage and the well — with a cluster of
    -- crates and barrels suggesting a survivor encampment.
    campfires[#campfires + 1] = { x = -4, z = -4 }
    add_campfire_static(-4, -4)
    add_crate(-5.2, -4)
    add_crate(-3.5, -5.1, 0.55)
    add_barrel(-4.8, -3.1)

    -- Graveyard cluster on the south edge.
    local gy_centre_x = 4
    local gy_centre_z = 13
    for row = 0, 2 do
        for col = 0, 2 do
            if (row + col) % 2 == 0 then
                add_gravestone(gy_centre_x + (col - 1) * 1.2,
                               gy_centre_z + (row - 1) * 1.2,
                               (row + col) % 2 == 0)
            end
        end
    end
    -- Small fence around the graveyard.
    add_fence_line(gy_centre_x - 2, gy_centre_z - 2, gy_centre_x + 2, gy_centre_z - 2, 5)
    add_fence_line(gy_centre_x - 2, gy_centre_z + 2, gy_centre_x + 2, gy_centre_z + 2, 5)
    add_fence_line(gy_centre_x - 2, gy_centre_z - 2, gy_centre_x - 2, gy_centre_z + 2, 5)

    -- A stray barrel/crate pile near the east tower (loot area).
    add_crate(11.5, 2.2)
    add_barrel(12, 3)
    add_crate(11.2, 3.8, 0.55)

    -- Hedges: short 3D boxes flanking the central crossroads. Axis is
    -- determined by which side of the path they sit on so they form
    -- visible corridors rather than single blocks.
    local hedge_spots = {
        {-3, -2.2, 'ew'}, {3, -2.2, 'ew'}, {-3, 2.2, 'ew'}, {3, 2.2, 'ew'},
        {-2.2, -3, 'ns'}, {-2.2, 3, 'ns'}, {2.2, -3, 'ns'}, {2.2, 3, 'ns'},
    }
    local HEDGE_H = 0.85
    for _, h in ipairs(hedge_spots) do
        local bw, bd = 1.6, 0.55
        if h[3] == 'ns' then bw, bd = 0.55, 1.6 end
        add_hedge_box(h[1], h[2], bw, bd, HEDGE_H)
        obstacles[#obstacles + 1] = { h[1], h[2], max3(bw, bd) * 0.55 }
    end

    -- Outlying landmarks scattered across the expanded map so there's
    -- something to walk toward no matter which direction you pick from
    -- the crossroads.
    add_tower(-40,  42, 2.2, 4.0, rgb(140, 135, 120), rgb(85, 50, 40))
    add_tower( 42, -38, 2.2, 4.2, rgb(150, 140, 125), rgb(95, 55, 45))

    -- Walkable stone castle with a south gateway. Placed far enough
    -- from the town that the player has to traverse some wilderness
    -- to get there, making it an explicit destination.
    add_castle(-22, -22, 10, 3.5)
    add_building(-42, -20, 3.4, 3.2, 2.4, 1.2,
                 rgb(205, 180, 140), rgb(130, 55, 35))
    add_building( 38,  36, 3.6, 3.0, 2.6, 1.3,
                 rgb(180, 160, 120), rgb(100, 50, 35))

    -- Second survivor camp on the north ridge.
    campfires[#campfires + 1] = { x = 6, z = -28 }
    add_campfire_static(6, -28)
    add_crate(4.6, -28)
    add_barrel(7.2, -27)

    -- A small second graveyard to the west.
    local g2x, g2z = -32, 28
    for row = 0, 1 do
        for col = 0, 2 do
            add_gravestone(g2x + (col - 1) * 1.2,
                           g2z + (row - 0.5) * 1.2, true)
        end
    end
    add_fence_line(g2x - 2.2, g2z - 1.4, g2x + 2.2, g2z - 1.4, 5)
    add_fence_line(g2x - 2.2, g2z + 1.4, g2x + 2.2, g2z + 1.4, 5)

    -- Broken perimeter fence stretched to the new world size, still with
    -- a gap at the centre so the path can continue north.
    add_fence_line(-GROUND_HALF + 3, -GROUND_HALF + 3, -4, -GROUND_HALF + 3, 14)
    add_fence_line( 4, -GROUND_HALF + 3,  GROUND_HALF - 3, -GROUND_HALF + 3, 14)

    -- Procedural forest: scatter trees on a jittered grid across the
    -- whole map, skipping the central town, paths, and graveyards.
    -- math.random is deterministic here because reset_game seeded it
    -- with the current time — each run gets a different forest layout
    -- but within one game it's stable.
    local cell = 5
    for gz = -GROUND_HALF + cell, GROUND_HALF - cell, cell do
        for gx = -GROUND_HALF + cell, GROUND_HALF - cell, cell do
            if random() < 0.42 then
                local tx = gx + (random() - 0.5) * cell * 0.8
                local tz = gz + (random() - 0.5) * cell * 0.8
                -- Clear zones: central town (~20 radius), paths, and
                -- the two graveyards. Skip if any landmark is near.
                local in_town = abs(tx) < 17 and abs(tz) < 17
                local on_path = abs(tx) < 2.2 or abs(tz) < 2.2
                local near_gy = (abs(tx - 4) < 3 and abs(tz - 13) < 3)
                              or (abs(tx - g2x) < 3 and abs(tz - g2z) < 3)
                local near_outpost = (abs(tx + 40) < 4 and abs(tz - 42) < 4)
                                  or (abs(tx - 42) < 4 and abs(tz + 38) < 4)
                                  or (abs(tx + 42) < 4 and abs(tz + 20) < 4)
                                  or (abs(tx - 38) < 4 and abs(tz - 36) < 4)
                -- Castle footprint (centre -22,-22, radius ~7 incl. towers)
                local near_castle = abs(tx + 22) < 8 and abs(tz + 22) < 8
                if not (in_town or on_path or near_gy or near_outpost
                        or near_castle) then
                    local kind = (random() < 0.5) and 'pine' or 'oak'
                    trees[#trees + 1] = { x = tx, z = tz, kind = kind,
                                          scale = 0.8 + random() * 0.5 }
                    obstacles[#obstacles + 1] = { tx, tz, 0.5 }
                end
            end
        end
    end

    -- Also keep a handful of hand-placed trees near the central town so
    -- the courtyard has consistent greenery every run.
    local town_trees = {
        {-5, -5, 'pine'}, {5, -5, 'oak'}, {-5, 5, 'oak'}, {5, 5, 'pine'},
        {-11, -2, 'pine'}, {11, -3, 'oak'},
        {-3, -11, 'pine'}, {3, -11, 'oak'}, {-3, 11, 'oak'}, {3, 11, 'pine'},
    }
    for _, t in ipairs(town_trees) do
        trees[#trees + 1] = { x = t[1], z = t[2], kind = t[3],
                              scale = 0.9 + random() * 0.4 }
        obstacles[#obstacles + 1] = { t[1], t[2], 0.5 }
    end

    -- Spawn points scattered around the map. pick_spawn_random picks
    -- one within [SPAWN_MIN, SPAWN_MAX] of the player, so distant
    -- points only engage when the player actually roams into their
    -- radius. Four concentric rings + some asymmetric points give a
    -- decent mix without needing a spatial query at spawn time.
    spawn_points = {}
    local function add_spawn(x, z) spawn_points[#spawn_points + 1] = { x, z } end
    -- Inner ring (close around town)
    for i = 0, 7 do
        local a = i * pi / 4
        add_spawn(cos(a) * 10, sin(a) * 10)
    end
    -- Middle ring
    for i = 0, 11 do
        local a = i * pi / 6 + pi / 12
        add_spawn(cos(a) * 18, sin(a) * 18)
    end
    -- Outer ring
    for i = 0, 15 do
        local a = i * pi / 8
        add_spawn(cos(a) * 30, sin(a) * 30)
    end
    -- A handful of jittered extras so spawn locations aren't perfectly
    -- on the rings.
    for _ = 1, 10 do
        add_spawn(
            (random() - 0.5) * (GROUND_SIZE - 10),
            (random() - 0.5) * (GROUND_SIZE - 10))
    end

    static_mark = ez.display.scene_mark_static(scene)
end

---------------------------------------------------------------------------
-- Collision
---------------------------------------------------------------------------
-- Obstacle representation. Two shapes live in the same `obstacles` list:
--   Circle: { cx, cz, r }                     (indexed)
--   AABB:   { aabb=true, x1, z1, x2, z2 }    (field-keyed)
-- We detect the AABB variant by the `.aabb` field being set; circles
-- remain plain arrays for back-compatibility with every other
-- place-an-obstacle call site.
local function blocked(nx, nz)
    for i = 1, #obstacles do
        local o = obstacles[i]
        if o.aabb then
            if nx > o.x1 - PLAYER_R and nx < o.x2 + PLAYER_R
               and nz > o.z1 - PLAYER_R and nz < o.z2 + PLAYER_R then
                return true
            end
        else
            local dx = nx - o[1]
            local dz = nz - o[2]
            local r = o[3] + PLAYER_R
            if dx * dx + dz * dz < r * r then return true end
        end
    end
    if nx < -GROUND_HALF + 1 or nx > GROUND_HALF - 1 then return true end
    if nz < -GROUND_HALF + 1 or nz > GROUND_HALF - 1 then return true end
    return false
end

local function try_move(nx, nz)
    if not blocked(nx, nz) then px, pz = nx, nz
    elseif not blocked(nx, pz) then px = nx
    elseif not blocked(px, nz) then pz = nz
    end
end

---------------------------------------------------------------------------
-- Zombies
---------------------------------------------------------------------------
-- Randomised spawn selection. Previously we always picked the single
-- farthest spawn point, which meant every zombie spawned at the same
-- spot (often behind one tower on the map edge) and funnelled into a
-- single lane. Now we:
--   1. Pick a random point whose distance from the player is inside
--      [MIN, MAX]. Too-close spawns feel unfair; too-far ones never
--      engage the player.
--   2. Reject points that would land inside an obstacle.
--   3. Fall back to the classic "farthest" behaviour after a retry cap.
local SPAWN_MIN_SQ = 9 * 9      -- zombies shouldn't appear within 9 units
local SPAWN_MAX_SQ = 28 * 28    -- or beyond the FAR plane area
local function pick_spawn_random()
    for _ = 1, 16 do
        local sp = spawn_points[random(1, #spawn_points)]
        local dx = sp[1] - px
        local dz = sp[2] - pz
        local d2 = dx * dx + dz * dz
        if d2 >= SPAWN_MIN_SQ and d2 <= SPAWN_MAX_SQ then
            -- Check the point isn't inside an obstacle.
            local blocked_here = false
            for i = 1, #obstacles do
                local o = obstacles[i]
                if o.aabb then
                    if sp[1] > o.x1 - 0.3 and sp[1] < o.x2 + 0.3
                       and sp[2] > o.z1 - 0.3 and sp[2] < o.z2 + 0.3 then
                        blocked_here = true
                        break
                    end
                else
                    local ox = sp[1] - o[1]
                    local oz = sp[2] - o[2]
                    if ox * ox + oz * oz < (o[3] + 0.3) * (o[3] + 0.3) then
                        blocked_here = true
                        break
                    end
                end
            end
            if not blocked_here then return sp end
        end
    end
    -- Fallback: any point that satisfies only the min-distance rule.
    for _ = 1, 8 do
        local sp = spawn_points[random(1, #spawn_points)]
        local dx = sp[1] - px
        local dz = sp[2] - pz
        if dx * dx + dz * dz >= SPAWN_MIN_SQ then return sp end
    end
    return spawn_points[1]
end

local function pick_spawn_far()
    local best, best_d = nil, 0
    for _, sp in ipairs(spawn_points) do
        local dx = sp[1] - px
        local dz = sp[2] - pz
        local d = dx * dx + dz * dz
        if d > best_d then best, best_d = sp, d end
    end
    return best
end

-- Weighted random kind: mostly normal zombies with occasional fast and
-- rare tank variants. Tuned so the mix stays varied without overwhelming
-- the player.
local function pick_kind()
    local r = random()
    if r < 0.15 then return 'tank' end
    if r < 0.45 then return 'fast' end
    return 'normal'
end

local function spawn_zombie(e)
    local sp = pick_spawn_random()
    e.x = sp[1]; e.z = sp[2]
    e.kind = pick_kind()
    local def = ZOMBIE_KIND[e.kind]
    e.hp = def.hp
    e.speed = def.speed
    e.alive = true
    e.cooldown = 0
    e.respawn = 0
    e.phase = random(0, 3)
end

-- Distance at which nearby zombies exert a separation force on each
-- other. Slightly larger than a zombie's body radius so they start
-- steering apart before actually overlapping.
local ZOMBIE_SEP_RADIUS = 1.1

local function update_zombies()
    for _, e in ipairs(zombies) do
        if e.alive then
            if e.cooldown > 0 then e.cooldown = e.cooldown - 1 end
            local dx = px - e.x
            local dz = pz - e.z
            local dist = sqrt(dx * dx + dz * dz)

            if not cheat_freeze and dist < 14 and dist > ZOMBIE_STOP_DIST then
                -- Base chase direction toward the player (unit vector).
                local chase_x = dx / dist
                local chase_z = dz / dist

                -- Separation: sum of outward-pointing unit vectors from
                -- other zombies within ZOMBIE_SEP_RADIUS, weighted by
                -- how close they are. Using a weighted sum of unit
                -- vectors gives smooth steering; pairs can't occupy the
                -- same column because their separation vectors oppose
                -- each other.
                local sep_x, sep_z = 0, 0
                for _, other in ipairs(zombies) do
                    if other ~= e and other.alive then
                        local odx = e.x - other.x
                        local odz = e.z - other.z
                        local od = sqrt(odx * odx + odz * odz)
                        if od > 0.001 and od < ZOMBIE_SEP_RADIUS then
                            local w = (ZOMBIE_SEP_RADIUS - od) / ZOMBIE_SEP_RADIUS
                            sep_x = sep_x + (odx / od) * w
                            sep_z = sep_z + (odz / od) * w
                        end
                    end
                end

                -- Blend chase + separation and renormalise.
                local dir_x = chase_x + sep_x * 0.9
                local dir_z = chase_z + sep_z * 0.9
                local dl = sqrt(dir_x * dir_x + dir_z * dir_z)
                if dl > 0.001 then
                    dir_x = dir_x / dl
                    dir_z = dir_z / dl
                end

                local spd = e.speed or 0.022
                local nx = e.x + dir_x * spd
                local nz = e.z + dir_z * spd

                -- Respect static obstacles (buildings, trees, hedges,
                -- castle walls). Handles both circle and AABB shapes.
                local can = true
                for i = 1, #obstacles do
                    local o = obstacles[i]
                    if o.aabb then
                        if nx > o.x1 - 0.25 and nx < o.x2 + 0.25
                           and nz > o.z1 - 0.25 and nz < o.z2 + 0.25 then
                            can = false; break
                        end
                    else
                        local odx = nx - o[1]
                        local odz = nz - o[2]
                        local or_ = o[3] + 0.25
                        if odx * odx + odz * odz < or_ * or_ then
                            can = false; break
                        end
                    end
                end
                if can then e.x = nx; e.z = nz end
            end

            if not cheat_freeze and dist < ZOMBIE_HIT_DIST and e.cooldown <= 0 then
                if not cheat_god then
                    health = health - 5
                    if health <= 0 then
                        health = 0
                        if game_alive then
                            -- `extra` logs the wave reached — a more
                            -- interesting secondary metric than kills
                            -- since wave scales difficulty.
                            highscores.submit(HS_KEY, score,
                                (rawget(_G, "wave") or 1))
                        end
                        game_alive = false
                    end
                end
                e.cooldown = 45
            end
        else
            e.respawn = e.respawn + 1
            if e.respawn >= ZOMBIE_RESPAWN_FRAMES then
                spawn_zombie(e)
            end
        end
    end
end

-- Per-frame bookkeeping for material drops: collect anything the
-- player has walked onto, and expire drops whose TTL has hit zero.
-- Iterates in reverse so table.remove calls don't shift indices we
-- still need to visit.
local function check_drops()
    for i = #drops, 1, -1 do
        local d = drops[i]
        local dx = px - d.x
        local dz = pz - d.z
        if dx * dx + dz * dz < DROP_PICKUP_RADIUS_SQ then
            mat_add(d.kind, 1)
            table.remove(drops, i)
        else
            d.ttl = d.ttl - 1
            if d.ttl <= 0 then table.remove(drops, i) end
        end
    end
end

local function check_pickups()
    for _, p in ipairs(pickups) do
        if p.active then
            local dx = px - p.x
            local dz = pz - p.z
            if dx * dx + dz * dz < 0.7 then
                p.active = false
                if p.kind == "hp" then
                    health = health + 25
                    if health > max_health then health = max_health end
                else
                    ammo = ammo + 10
                end
            end
        end
    end
end

-- Apply a hit to a zombie, honouring the current weapon's damage. On
-- kill, tick wave/kill counters and respawn consumable pickups every
-- KILLS_PER_WAVE kills. Split out of do_shoot so multi-pellet weapons
-- (shotguns) can call it once per target.
local function apply_hit(e, damage)
    e.hp = e.hp - damage
    if e.hp <= 0 then
        e.alive = false
        e.respawn = 0
        score = score + 100
        kills = kills + 1

        -- Material drop roll. On success, spawn a physical pickup at
        -- the zombie's last position — the player has to walk over it
        -- to collect. Missed pickups expire after DROP_TTL_FRAMES so
        -- the world doesn't accumulate an infinite scatter of unused
        -- loot.
        local r = random()
        local acc = 0
        for _, drop in ipairs(MAT_DROPS) do
            acc = acc + drop.chance
            if r < acc then
                drops[#drops + 1] = {
                    x = e.x, z = e.z, kind = drop.kind,
                    ttl = DROP_TTL_FRAMES,
                }
                break
            end
        end

        if kills % KILLS_PER_WAVE == 0 then
            wave = wave + 1
            for _, p in ipairs(pickups) do p.active = true end
        end
    else
        score = score + 10
    end
end

-- Place one crate from inventory at ~1.5m in front of the player.
-- Aborts if no crates held, if the target spot overlaps an obstacle,
-- or if we've already hit MAX_PLACED_CRATES. Registers a circular
-- obstacle so zombies path around the crate and the player can use it
-- for cover / choke-point funneling.
local CRATE_HP = 5

local function place_crate()
    if crates_held <= 0 then return false end
    if #placed_crates >= MAX_PLACED_CRATES then return false end
    local dx = sin(p_yaw) * 1.5
    local dz = cos(p_yaw) * 1.5
    local nx = px + dx
    local nz = pz + dz
    if blocked(nx, nz) then return false end
    local size = 0.7
    placed_crates[#placed_crates + 1] = {
        x = nx, z = nz, size = size, hp = CRATE_HP,
        obstacle_idx = #obstacles + 1,  -- for cleanup on destroy
    }
    obstacles[#obstacles + 1] = { nx, nz, size * 0.55 }
    crates_held = crates_held - 1
    return true
end

-- Deletes a placed crate by index, removes its obstacle entry, and
-- drops CRATE_DROP_WOOD. Careful: removing from the obstacles array
-- shifts indices, so any later-placed crate's `obstacle_idx` needs to
-- shift down to stay in sync.
local function destroy_crate(i)
    local c = placed_crates[i]
    if not c then return end
    -- Remove the obstacle entry (keep array dense).
    if c.obstacle_idx and obstacles[c.obstacle_idx] then
        table.remove(obstacles, c.obstacle_idx)
        -- Fix obstacle_idx on every later-placed crate that pointed
        -- past this one.
        for _, other in ipairs(placed_crates) do
            if other.obstacle_idx and other.obstacle_idx > c.obstacle_idx then
                other.obstacle_idx = other.obstacle_idx - 1
            end
        end
    end
    -- Partial wood refund — no auto-craft; stays as raw material
    -- until the player opens the craft menu.
    wood = wood + CRATE_DROP_WOOD
    table.remove(placed_crates, i)
end

-- Attempt to craft a recipe. Returns true on success, false if any
-- ingredient is short. Materials are deducted only on success.
local function try_craft(recipe)
    if not recipe then return false end
    for mat, n in pairs(recipe.inputs) do
        if mat_count(mat) < n then return false end
    end
    for mat, n in pairs(recipe.inputs) do
        mat_add(mat, -n)
    end
    recipe.apply()
    return true
end

local function do_shoot()
    local w = WEAPONS[current_weapon]
    if ammo < w.ammo_cost or shoot_timer > 0 then return end
    ammo = ammo - w.ammo_cost
    shoot_timer = w.cooldown

    -- Build a unified hit list over zombies AND placed crates. The
    -- cone-at-1m heuristic scales with target distance, so close-range
    -- crates get hit cleanly while far-away ones need aim.
    local hits = {}
    local function cone_check(tx, tz, target_kind, ref)
        local dx = tx - px
        local dz = tz - pz
        local dist = sqrt(dx * dx + dz * dz)
        local ang = atan2(dx, dz) - p_yaw
        if ang > pi then ang = ang - 2 * pi
        elseif ang < -pi then ang = ang + 2 * pi end
        local cone = w.cone_at_1m / dist
        if cone < w.cone_min then cone = w.cone_min end
        if cone > w.cone_max then cone = w.cone_max end
        if abs(ang) < cone then
            hits[#hits + 1] = { kind = target_kind, ref = ref, dist = dist }
        end
    end

    for _, e in ipairs(zombies) do
        if e.alive then cone_check(e.x, e.z, 'zombie', e) end
    end
    for i, c in ipairs(placed_crates) do
        cone_check(c.x, c.z, 'crate', i)
    end

    table.sort(hits, function(a, b) return a.dist < b.dist end)

    -- Each weapon pellet picks the nearest target and damages it. A
    -- shotgun's 4 pellets can split across multiple zombies/crates at
    -- different distances, but a single pellet that intersects both
    -- hits only the nearest.
    local destroyed_crate_indices = {}
    for i = 1, math.min(w.pellets, #hits) do
        local h = hits[i]
        if h.kind == 'zombie' then
            apply_hit(h.ref, w.damage)
        else
            local c = placed_crates[h.ref]
            if c then
                c.hp = c.hp - w.damage
                if c.hp <= 0 then
                    destroyed_crate_indices[#destroyed_crate_indices + 1] = h.ref
                end
            end
        end
    end

    -- Destroy crates in descending index order so earlier removals
    -- don't shift the later indices we still need to delete.
    table.sort(destroyed_crate_indices, function(a, b) return a > b end)
    for _, idx in ipairs(destroyed_crate_indices) do
        destroy_crate(idx)
    end
end

local function reset_game()
    math.randomseed(ez.system.millis())
    px, py, pz = 0, EYE_HEIGHT, -2
    set_yaw(0)
    health = 100
    -- Generous starting ammo: we want the player to immediately try
    -- every weapon without having to go shopping first.
    ammo = 90
    score = 0
    game_alive = true
    shoot_timer = 0
    anim_t = 0
    time_of_day = 0.35
    wave = 1
    kills = 0
    stamina = MAX_STAMINA
    sprint_locked = false
    max_health = 100
    ui.shop_open = false
    nearest_shop = nil
    -- Reset weapon inventory: every weapon unlocked from the jump so
    -- the player can try the whole arsenal immediately. Shop entries
    -- for weapons auto-hide via their `available()` checks once owned.
    for _, w in ipairs(WEAPONS) do w.owned = true end
    current_weapon = 1

    wood = 0
    cloth = 0
    scrap = 0
    crates_held = 0
    placed_crates = {}
    drops = {}
    ui.craft_open = false
    ui.craft_sel = 1
    ui.pause_open = false
    ui.pause_sel = 1
    ui.help_open = false
    ui.inv_open = false
    ui.inv_sel = 1

    if not scene then
        scene = ez.display.scene_new()
        scene_add = ez.display.scene_add_tri
        -- Bind billboard helpers. Each is a direct C function reference;
        -- we close over `scene` so callers can keep the old signature.
        local bb = ez.display.scene_add_billboard
        local bbs = ez.display.scene_add_billboard_split
        add_billboard = function(wx, wy, wz, hw, h, col)
            bb(scene, wx, wy, wz, hw, h, col)
        end
        add_billboard_split = function(wx, wy, wz, hw, h, ct, cb)
            bbs(scene, wx, wy, wz, hw, h, ct, cb)
        end
    end
    build_world()

    zombies = {}
    for i = 1, ZOMBIE_COUNT do
        local z = {}
        spawn_zombie(z)
        zombies[i] = z
    end

    pickups = {
        -- Central town
        { x = -8, z = -8, kind = "hp",   active = true },
        { x =  8, z = -8, kind = "ammo", active = true },
        { x = -8, z =  8, kind = "ammo", active = true },
        { x =  8, z =  8, kind = "hp",   active = true },
        { x = 13, z =  0, kind = "ammo", active = true },
        { x =  0, z = 12, kind = "hp",   active = true },
        { x = -13, z = 0, kind = "ammo", active = true },
        -- Reward pickups at the outlying landmarks
        { x = -40, z =  42, kind = "ammo", active = true },
        { x =  42, z = -38, kind = "hp",   active = true },
        { x = -42, z = -20, kind = "hp",   active = true },
        { x =  38, z =  36, kind = "ammo", active = true },
        { x =   6, z = -28, kind = "ammo", active = true },
        { x = -32, z =  28, kind = "hp",   active = true },
    }
end

---------------------------------------------------------------------------
-- Sky + HUD overlays (drawn around the rasterizer pass)
---------------------------------------------------------------------------
local function draw_sky(d)
    local top_c, mid_c, horizon_c = sky_palette()
    local horizon = floor(VIEW_CY)
    d.fill_rect(0, VIEW_TOP, SW, 20, top_c)
    d.fill_rect(0, VIEW_TOP + 20, SW, 20, mid_c)
    d.fill_rect(0, VIEW_TOP + 40, SW, horizon - (VIEW_TOP + 40), horizon_c)

    local sh = sun_height()

    -- Celestial body projector: treats the body as a fixed world-space
    -- direction at "infinity" so it anchors to the compass rather than
    -- rotating with the player.
    local function draw_celestial(dir_x, dir_z, height_px, core_col, halo_col, radius)
        local Z = 25
        local wx = dir_x * Z
        local wz = dir_z * Z
        local cxv = wx * yaw_cos - wz * yaw_sin
        local czv = wx * yaw_sin + wz * yaw_cos
        if czv <= NEAR then return end
        local sx = VIEW_CX + cxv * (FOCAL / czv)
        local sy = VIEW_TOP + height_px
        if sx > -30 and sx < SW + 30 then
            d.fill_circle(floor(sx), floor(sy), radius + 3, halo_col)
            d.fill_circle(floor(sx), floor(sy), radius, core_col)
        end
    end

    -- Sun/moon positions: parameterise by the same angle `ang` that drives
    -- sun_height(). `horiz = cos(ang)` runs east→overhead→west as the sun
    -- climbs and sets, so the horizontal component is maximal at the
    -- horizons (rise/set) and zero at the zenith. The vertical component
    -- is `sin(ang)` = sun_height (already computed above as `sh`).
    -- Using sin for horizontal — what I had before — collapses both
    -- bodies to the centre of the sky at sunrise/sunset, making them
    -- appear to converge on the same side.
    local ang = (time_of_day - 0.25) * 2 * pi
    local horiz = cos(ang)

    -- Sun: visible while above or near horizon.
    if sh > -0.15 then
        local hpx = 14 + floor((1 - sh) * 18)
        draw_celestial(horiz, 0.3, hpx,
                       rgb(255, 245, 190), rgb(255, 225, 120), 7)
    end

    -- Moon at the antipode — always on the opposite side of the sky.
    local moon_horiz = -horiz
    local moon_vert = -sh
    if moon_vert > -0.15 then
        local hpx = 14 + floor((1 - moon_vert) * 18)
        draw_celestial(moon_horiz, 0.3, hpx,
                       rgb(230, 230, 240), rgb(170, 170, 190), 6)
    end

    -- Deterministic starfield, visible only at night. Jittered LCG so
    -- the positions look random but don't flicker between frames.
    if sh < -0.1 then
        local intensity = math.min(1, -(sh + 0.1) / 0.4)
        local sc = floor(180 * intensity)
        local star_col = rgb(sc, sc, sc + 20)
        local seed = 137
        for i = 1, 24 do
            seed = (seed * 1103515 + 12345) % 2147483648
            local sxp = floor(seed / 256) % SW
            seed = (seed * 1103515 + 12345) % 2147483648
            local syp = VIEW_TOP + floor(seed / 256) % 34
            if (floor(seed / 32) + floor(anim_t / 22)) % 11 ~= 0 then
                d.fill_rect(sxp, syp, 1, 1, star_col)
            end
        end
    end

    -- Ground strip below horizon dimmed by scene_light so the ambient
    -- transition between sky and 3D geometry reads consistent.
    local glum = scene_light()
    local gc = rgb(floor(60 * glum), floor(90 * glum), floor(40 * glum))
    d.fill_rect(0, horizon, SW, SH - horizon, gc)
end

-- Shop catalogue. Items that should only show under certain conditions
-- (owning a weapon, having a key, etc.) expose an `available()` check.
-- The current shop list is rebuilt per-open by `build_shop_items` so
-- purchasing a weapon removes it from the menu.
local SHOP_CATALOGUE = {
    { label = "Ammo +20",       cost = 40,
      apply = function() ammo = ammo + 20 end },
    { label = "Health +50",     cost = 70,
      apply = function() health = math.min(max_health, health + 50) end },
    { label = "Max HP +25",     cost = 300,
      apply = function() max_health = max_health + 25
                         health = max_health end },
    { label = "Full Restock",   cost = 180,
      apply = function() ammo = ammo + 50
                         health = max_health end },
    { label = "Shotgun",        cost = 350,
      available = function() return not WEAPONS[2].owned end,
      apply = function() WEAPONS[2].owned = true
                         current_weapon = 2
                         ammo = ammo + 15 end },
    { label = "Rifle",          cost = 500,
      available = function() return not WEAPONS[3].owned end,
      apply = function() WEAPONS[3].owned = true
                         current_weapon = 3
                         ammo = ammo + 10 end },
    { label = "SMG",            cost = 420,
      available = function() return not WEAPONS[4].owned end,
      apply = function() WEAPONS[4].owned = true
                         current_weapon = 4
                         ammo = ammo + 30 end },
    { label = "Assault Rifle",  cost = 550,
      available = function() return not WEAPONS[5].owned end,
      apply = function() WEAPONS[5].owned = true
                         current_weapon = 5
                         ammo = ammo + 20 end },
    { label = "Crate x3",       cost = 60,
      apply = function() crates_held = crates_held + 3 end },
    { label = "Crate x10",      cost = 180,
      apply = function() crates_held = crates_held + 10 end },
}

local SHOP_ITEMS = {}  -- filtered per-open

local function build_shop_items()
    SHOP_ITEMS = {}
    for _, it in ipairs(SHOP_CATALOGUE) do
        if it.available == nil or it.available() then
            SHOP_ITEMS[#SHOP_ITEMS + 1] = it
        end
    end
    if ui.shop_sel > #SHOP_ITEMS then ui.shop_sel = 1 end
end

-- Update which shop (if any) the player is standing near. Called once
-- per frame from update(). The interaction prompt + menu gate off this.
local function update_shop_proximity()
    nearest_shop = nil
    local best_d2 = 1e9
    for _, s in ipairs(shops) do
        local dx = px - s.door_x
        local dz = pz - s.door_z
        local d2 = dx * dx + dz * dz
        if d2 < s.radius * s.radius and d2 < best_d2 then
            best_d2 = d2
            nearest_shop = s
        end
    end
    -- If the player walks away while the menu is open, close it.
    if ui.shop_open and nearest_shop == nil then ui.shop_open = false end
end

-- Shop overlay drawn on top of everything else when ui.shop_open. Simple
-- vertical list; SPACE confirms, UP/DOWN moves the selection, E/ESC
-- closes.
local function draw_shop_menu(d)
    -- Size the panel to the current item count so weapons don't get
    -- clipped off the bottom once the catalogue is filtered.
    local rows = #SHOP_ITEMS
    local mw = 200
    local mh = 60 + rows * 16
    local mx = floor((SW - mw) / 2)
    local my = floor((SH - mh) / 2)
    d.fill_rect(mx, my, mw, mh, rgb(20, 25, 18))
    d.draw_rect(mx, my, mw, mh, rgb(180, 200, 150))

    theme.set_font("small")
    local title = nearest_shop and nearest_shop.label or "SHOP"
    d.draw_text(mx + floor((mw - theme.text_width(title)) / 2),
                my + 4, title, rgb(230, 230, 180))
    d.draw_hline(mx + 6, my + 18, mw - 12, rgb(100, 120, 90))

    -- Score available
    local line = "Score: " .. score
    d.draw_text(mx + 6, my + 22, line, rgb(180, 220, 180))

    -- Items
    theme.set_font("tiny")
    for i, item in ipairs(SHOP_ITEMS) do
        local y = my + 40 + (i - 1) * 16
        local afford = score >= item.cost
        local sel = (i == ui.shop_sel)
        if sel then
            d.fill_rect(mx + 4, y - 2, mw - 8, 14, rgb(60, 80, 50))
        end
        local fg
        if not afford then fg = rgb(120, 120, 120)
        elseif sel then fg = rgb(255, 240, 150)
        else fg = rgb(200, 220, 200) end
        d.draw_text(mx + 8, y, item.label, fg)
        local cost = tostring(item.cost)
        d.draw_text(mx + mw - theme.text_width(cost) - 8, y, cost, fg)
    end

    theme.set_font("tiny")
    d.draw_text(mx + 6, my + mh - 12,
                "UP/DOWN select  SPACE buy  E/Q close",
                rgb(140, 160, 140))
end

-- Craft menu overlay — mirrors draw_shop_menu's look so both UIs feel
-- like siblings. Layout: title, materials readout, list of recipes
-- with inputs on the right, selection highlight, and a hint line.
local function draw_craft_menu(d)
    local rows = #CRAFT_RECIPES
    local mw = 220
    local mh = 78 + rows * 20
    local mx = floor((SW - mw) / 2)
    local my = floor((SH - mh) / 2)
    d.fill_rect(mx, my, mw, mh, rgb(20, 25, 18))
    d.draw_rect(mx, my, mw, mh, rgb(180, 200, 150))

    theme.set_font("small")
    local title = "WORKBENCH"
    d.draw_text(mx + floor((mw - theme.text_width(title)) / 2),
                my + 4, title, rgb(230, 230, 180))
    d.draw_hline(mx + 6, my + 18, mw - 12, rgb(100, 120, 90))

    -- Materials readout under the title. Using single-letter abbrevs
    -- so the line fits in the menu width.
    theme.set_font("tiny")
    local mline = string.format("W:%d  C:%d  S:%d   Boxes:%d",
                                wood, cloth, scrap, crates_held)
    d.draw_text(mx + 6, my + 22, mline, rgb(180, 220, 180))

    for i, r in ipairs(CRAFT_RECIPES) do
        local y = my + 36 + (i - 1) * 20
        local sel = (i == ui.craft_sel)

        -- Affordable only if every input count is available.
        local afford = true
        for mat, n in pairs(r.inputs) do
            if mat_count(mat) < n then afford = false; break end
        end

        if sel then
            d.fill_rect(mx + 4, y - 2, mw - 8, 18, rgb(60, 80, 50))
        end

        local fg
        if not afford then fg = rgb(120, 120, 120)
        elseif sel then fg = rgb(255, 240, 150)
        else fg = rgb(200, 220, 200) end

        d.draw_text(mx + 8, y, r.label, fg)
        d.draw_text(mx + 8, y + 9, r.desc, shade(fg, 0.6))

        -- Build compact cost string e.g. "3W 1S". Iterating sorted
        -- keys keeps display stable across runs.
        local parts = {}
        for _, mat in ipairs({ "wood", "cloth", "scrap" }) do
            local n = r.inputs[mat]
            if n then parts[#parts + 1] = n .. mat:sub(1, 1):upper() end
        end
        local cost_str = table.concat(parts, " ")
        d.draw_text(mx + mw - theme.text_width(cost_str) - 8, y, cost_str, fg)
    end

    d.draw_text(mx + 6, my + mh - 12,
                "UP/DOWN select  SPACE craft  C/Q close",
                rgb(140, 160, 140))
end

-- Pause menu: small centred list with selection highlight. UP/DOWN
-- moves, SPACE confirms, Q closes (resumes). Selecting an item invokes
-- the `on_select` callback — Resume closes, Restart triggers a fresh
-- run, Help opens the help overlay, Quit returns "pop" from
-- handle_key.
local PAUSE_ITEMS = {
    { label = "Resume" },
    { label = "Restart" },
    { label = "Help"   },
    { label = "Quit"   },
}

local function draw_pause_menu(d)
    local rows = #PAUSE_ITEMS
    local mw = 140
    local mh = 28 + rows * 16
    local mx = floor((SW - mw) / 2)
    local my = floor((SH - mh) / 2)
    d.fill_rect(mx, my, mw, mh, rgb(20, 25, 18))
    d.draw_rect(mx, my, mw, mh, rgb(180, 200, 150))

    theme.set_font("small")
    local title = "PAUSED"
    d.draw_text(mx + floor((mw - theme.text_width(title)) / 2),
                my + 4, title, rgb(230, 230, 180))
    d.draw_hline(mx + 6, my + 18, mw - 12, rgb(100, 120, 90))

    for i, item in ipairs(PAUSE_ITEMS) do
        local y = my + 24 + (i - 1) * 16
        local sel = (i == ui.pause_sel)
        if sel then
            d.fill_rect(mx + 4, y - 2, mw - 8, 14, rgb(60, 80, 50))
        end
        local fg = sel and rgb(255, 240, 150) or rgb(210, 225, 210)
        d.draw_text(mx + floor((mw - theme.text_width(item.label)) / 2),
                    y, item.label, fg)
    end
end

-- Inventory overlay. Weapons section is interactive — UP/DOWN cycle
-- through the owned weapons, SPACE equips the highlighted one. Below
-- that, a read-only block shows materials + held boxes. Matches the
-- pause panel's styling so the two feel like siblings.
local function draw_inventory(d)
    local mw = 190
    local mh = 156
    local mx = floor((SW - mw) / 2)
    local my = floor((SH - mh) / 2)
    d.fill_rect(mx, my, mw, mh, rgb(20, 25, 18))
    d.draw_rect(mx, my, mw, mh, rgb(180, 200, 150))

    theme.set_font("small")
    local title = "INVENTORY"
    d.draw_text(mx + floor((mw - theme.text_width(title)) / 2),
                my + 4, title, rgb(230, 230, 180))
    d.draw_hline(mx + 6, my + 18, mw - 12, rgb(100, 120, 90))

    theme.set_font("tiny")
    d.draw_text(mx + 6, my + 22, "WEAPONS", rgb(240, 215, 120))

    -- Weapons list. We iterate the full WEAPONS table so locked entries
    -- are visible too (with a greyed-out [locked] tag + current cost
    -- hint), then clamp ui.inv_sel to owned indices.
    for i, w in ipairs(WEAPONS) do
        local y = my + 34 + (i - 1) * 13
        local sel = (i == ui.inv_sel)
        if sel then
            d.fill_rect(mx + 4, y - 2, mw - 8, 12, rgb(60, 80, 50))
        end
        local fg
        if not w.owned then      fg = rgb(110, 110, 110)
        elseif sel then          fg = rgb(255, 240, 150)
        elseif i == current_weapon then fg = rgb(120, 220, 120)
        else                     fg = rgb(210, 225, 210) end

        local name = w.name
        if i == current_weapon then name = name .. "  <" end
        d.draw_text(mx + 10, y, name, fg)

        local right
        if not w.owned then right = "locked"
        else right = "[" .. i .. "]" end
        d.draw_text(mx + mw - theme.text_width(right) - 10, y, right, fg)
    end

    -- Materials block below the weapons.
    local my2 = my + 34 + #WEAPONS * 13 + 4
    d.draw_hline(mx + 6, my2, mw - 12, rgb(100, 120, 90))
    d.draw_text(mx + 6, my2 + 4, "MATERIALS", rgb(240, 215, 120))
    local m1 = string.format("Wood  %-4d  Cloth  %d", wood, cloth)
    local m2 = string.format("Scrap %-4d  Boxes  %d", scrap, crates_held)
    d.draw_text(mx + 6, my2 + 14, m1, rgb(210, 220, 210))
    d.draw_text(mx + 6, my2 + 22, m2, rgb(210, 220, 210))

    local hint = "UP/DOWN select  SPACE equip  I/Q close"
    d.draw_text(mx + floor((mw - theme.text_width(hint)) / 2),
                my + mh - 10, hint, rgb(150, 170, 150))
end

-- Help overlay: big informational sheet covering the whole screen.
-- Lists control bindings, the HUD resource letters, and the craft
-- recipes. Tiny font keeps line counts high. Any key (or Q) closes.
local function draw_help(d)
    d.fill_rect(0, 0, SW, SH, rgb(18, 22, 16))
    d.draw_rect(2, 2, SW - 4, SH - 4, rgb(180, 200, 150))

    theme.set_font("small")
    local title = "HELP"
    d.draw_text(floor((SW - theme.text_width(title)) / 2), 4, title,
                rgb(255, 240, 150))

    theme.set_font("tiny")
    local col1_x = 10
    local col2_x = 150
    local line_h = 8
    local function ln(col_x, line_i, text, color)
        d.draw_text(col_x, 18 + (line_i - 1) * line_h,
                    text, color or rgb(210, 220, 210))
    end
    local h = rgb(240, 215, 120)

    ln(col1_x, 1,  "CONTROLS",               h)
    ln(col1_x, 2,  "W/A/S/D   Move")
    ln(col1_x, 3,  "Shift     Sprint")
    ln(col1_x, 4,  "<- / ->   Turn")
    ln(col1_x, 5,  "Space     Fire")
    ln(col1_x, 6,  "1/2/3/4/5 Weapon slot")
    ln(col1_x, 7,  "I         Inventory")
    ln(col1_x, 8,  "E         Shop (near)")
    ln(col1_x, 9,  "B         Place crate")
    ln(col1_x, 10, "C         Workbench")
    ln(col1_x, 11, "R         Restart")
    ln(col1_x, 12, "Q         Pause / back")

    ln(col1_x, 13, "HUD LETTERS",            h)
    ln(col1_x, 14, "W  Wood     (35% drop)")
    ln(col1_x, 15, "C  Cloth    (25% drop)")
    ln(col1_x, 16, "S  Scrap    (15% drop)")
    ln(col1_x, 17, "B  Boxes    (placable)")
    ln(col1_x, 18, "K  Kills    (on game-over)")

    ln(col2_x, 1,  "WEAPONS",                h)
    ln(col2_x, 2,  "Pistol   fast, precise")
    ln(col2_x, 3,  "Shotgun  4 pellets")
    ln(col2_x, 4,  "Rifle    3 dmg, narrow")
    ln(col2_x, 5,  "SMG      auto, rapid")
    ln(col2_x, 6,  "Assault  auto, 2 dmg")

    ln(col2_x, 7,  "CRAFT RECIPES",          h)
    for i, r in ipairs(CRAFT_RECIPES) do
        local parts = {}
        for _, mat in ipairs({ "wood", "cloth", "scrap" }) do
            local n = r.inputs[mat]
            if n then parts[#parts + 1] = n .. mat:sub(1, 1):upper() end
        end
        ln(col2_x, 7 + i,
           string.format("%-11s %s", r.label, table.concat(parts, " ")))
    end

    ln(col2_x, 15, "TIPS",                   h)
    ln(col2_x, 16, "Drops on ground expire")
    ln(col2_x, 17, "Shoot crates = 1 wood")
    ln(col2_x, 18, "Fortify castle gateway")

    theme.set_font("tiny")
    local hint = "Press Q or Space to close"
    d.draw_text(floor((SW - theme.text_width(hint)) / 2),
                SH - 12, hint, rgb(160, 180, 160))
end

local function draw_hud(d)
    d.fill_rect(0, 0, SW, VIEW_TOP, rgb(25, 30, 20))
    d.draw_hline(0, VIEW_TOP - 1, SW, rgb(70, 85, 60))

    -- Layout (VIEW_TOP = 24):
    --   y=2..11   Row 1, small font  — HP bar / weapon+ammo
    --   y=13..20  Row 2, tiny font   — wave+clock+score / materials
    --   y=21..24  Stamina strip
    -- Rows are separated by a 1–2 px gap so descenders never collide
    -- with the next row's ascenders.
    theme.set_font("small")
    local hb_w = 46
    local hb_fill = floor(hb_w * health / 100)
    local hc
    if health > 50 then hc = rgb(0, 210, 0)
    elseif health > 25 then hc = rgb(230, 210, 0)
    else hc = rgb(230, 0, 0) end
    d.fill_rect(4, 2, hb_fill, 10, hc)
    d.draw_rect(4, 2, hb_w, 10, rgb(200, 200, 200))
    d.draw_text(hb_w + 8, 2, tostring(health), rgb(255, 255, 255))

    -- Weapon name + current ammo count on the right of row 1.
    local at = WEAPONS[current_weapon].name .. " " .. ammo
    d.draw_text(SW - theme.text_width(at) - 4, 2, at, rgb(255, 255, 255))

    -- Row 2 (tiny): wave + clock + score on the centre, materials on
    -- the right. Score moved to row 2 so we can drop the small-font
    -- centre text on row 1 that used to collide with the clock below.
    theme.set_font("tiny")
    local total_mins = floor(time_of_day * 24 * 60 + 0.5) % (24 * 60)
    local hh = floor(total_mins / 60)
    local mm = total_mins % 60
    local clock = string.format("%02d:%02d", hh, mm)
    local clock_col
    local sh = sun_height()
    if sh > 0.3 then clock_col = rgb(220, 220, 220)
    elseif sh > -0.15 then clock_col = rgb(240, 170, 90)
    else clock_col = rgb(140, 150, 220) end
    local centre = string.format("W%d  %s  %d", wave, clock, score)
    d.draw_text(floor(SW / 2 - theme.text_width(centre) / 2), 13,
                centre, clock_col)

    -- Inventory readout. Format dropped the kill count (shown only on
    -- game-over) so the line stays short enough to never overlap the
    -- centre at heavy-stack states like "W99 C99 S99 B25".
    local kt = string.format("W%d C%d S%d B%d",
                             wood, cloth, scrap, crates_held)
    d.draw_text(SW - theme.text_width(kt) - 4, 13, kt, rgb(180, 180, 180))

    -- Stamina strip at the bottom of the HUD, spanning the same width
    -- as the health bar. Outline keeps it readable when full. Turns
    -- amber while the sprint is in forced-cooldown.
    local sb_fill = floor(hb_w * stamina / MAX_STAMINA)
    local sc = sprint_locked and rgb(220, 130, 10) or rgb(60, 180, 230)
    d.fill_rect(4, VIEW_TOP - 5, hb_w, 4, rgb(40, 55, 70))
    d.fill_rect(4, VIEW_TOP - 5, sb_fill, 4, sc)
    d.draw_rect(4, VIEW_TOP - 5, hb_w, 4, rgb(150, 170, 190))

    -- Cheat badges — small gold letters inside the HUD strip on the
    -- right side of the stamina bar (no longer painted over the sky).
    local badges = ""
    if cheat_god then badges = badges .. "G" end
    if cheat_freeze then badges = badges .. "F" end
    if cheat_perf then badges = badges .. "P" end
    if #badges > 0 then
        d.draw_text(hb_w + 14, VIEW_TOP - 7, badges, rgb(255, 215, 0))
    end

    -- Perf overlay (toggled with P). Shows the rolling FPS estimate plus
    -- how many triangles the native renderer actually drew last frame.
    if cheat_perf then
        theme.set_font("small")
        local line = "FPS:" .. fps_display .. " T:" .. tris_last
        d.fill_rect(0, VIEW_TOP, theme.text_width(line) + 6, 12, rgb(0, 0, 0))
        d.draw_text(3, VIEW_TOP + 1, line, rgb(120, 255, 120))
    end
end

local function draw_weapon(d)
    local cx = floor(SW / 2)
    local w = WEAPONS[current_weapon]

    -- Muzzle flash during the cooldown window. Scales with barrel
    -- width so the shotgun's flash reads as a bigger bloom than the
    -- rifle's.
    if shoot_timer > 0 then
        local fw = w.barrel_w + 8
        d.fill_triangle(cx, SH - 90 - w.barrel_h + 30,
                         cx - fw, SH - 58, cx + fw, SH - 58,
                         rgb(255, 255, 100))
        d.fill_triangle(cx, SH - 96 - w.barrel_h + 30,
                         cx - fw/2, SH - 65, cx + fw/2, SH - 65,
                         rgb(255, 255, 210))
    end

    -- Barrel + slide: centred, heights from the weapon's stats so the
    -- rifle reads as long & thin while the shotgun is wide & stubby.
    local bw = w.barrel_w
    local bh = w.barrel_h
    local barrel_top = SH - 42 - bh
    d.fill_rect(cx - floor(bw / 2), barrel_top, bw, bh, w.color_barrel)
    -- Slim slide highlight on top of barrel
    d.fill_rect(cx - floor(bw / 2) - 2, barrel_top, bw + 4, 9,
                shade(w.color_barrel, 0.85))

    -- Receiver block between barrel and grip.
    d.fill_rect(cx - 12, SH - 44, 24, 16, rgb(130, 130, 145))
    -- Grip: wooden colour per-weapon for a quick visual cue.
    d.fill_rect(cx - 8, SH - 30, 16, 24, w.color_grip)
    d.fill_rect(cx + 6, SH - 40, 8, 2, rgb(110, 110, 125))

    -- Weapon-specific flourish: shotgun gets a second barrel, rifle
    -- gets a stock protruding to the right.
    if w.key == "shotgun" then
        d.fill_rect(cx - floor(bw / 2) - 4, barrel_top, 4, bh,
                    shade(w.color_barrel, 0.7))
        d.fill_rect(cx + floor(bw / 2), barrel_top, 4, bh,
                    shade(w.color_barrel, 0.7))
    elseif w.key == "rifle" then
        -- Scope: a small dark block on top of the slide.
        d.fill_rect(cx - 5, barrel_top - 7, 10, 6, rgb(30, 30, 40))
        d.fill_rect(cx - 2, barrel_top - 6, 4, 4, rgb(80, 80, 110))
    elseif w.key == "smg" then
        -- Curved magazine protruding forward of the trigger guard.
        d.fill_rect(cx - 4, SH - 26, 10, 18, rgb(40, 40, 50))
        d.fill_rect(cx - 2, SH - 22, 6, 12, rgb(60, 60, 75))
    elseif w.key == "assault" then
        -- Straight banana-style magazine below the receiver plus a
        -- short rail sight on top.
        d.fill_rect(cx - 5, SH - 26, 10, 18, rgb(35, 35, 45))
        d.fill_rect(cx - 3, SH - 22, 6, 12, rgb(55, 55, 70))
        d.fill_rect(cx - 4, barrel_top - 4, 8, 3, rgb(25, 25, 30))
    end
end

local function draw_crosshair(d)
    local cx, cy = floor(SW / 2), floor(VIEW_CY)
    local cc = rgb(0, 255, 0)
    d.fill_rect(cx - 8, cy, 6, 1, cc)
    d.fill_rect(cx + 3, cy, 6, 1, cc)
    d.fill_rect(cx, cy - 8, 1, 6, cc)
    d.fill_rect(cx, cy + 3, 1, 6, cc)
    d.fill_rect(cx, cy, 1, 1, cc)
end

local function draw_proximity(d)
    local nearest_sq = 999
    for _, e in ipairs(zombies) do
        if e.alive then
            local dx = e.x - px
            local dz = e.z - pz
            local d2 = dx * dx + dz * dz
            if d2 < nearest_sq then nearest_sq = d2 end
        end
    end
    if nearest_sq >= 3.0 then return end
    local nearest = sqrt(nearest_sq)
    local t = (1.7 - nearest) / 1.7
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local pulse = 0.6 + (sin(anim_t * 0.35) + 1) * 0.2
    local r = floor(80 + 175 * t * pulse)
    if r > 255 then r = 255 end
    local col = rgb(r, 0, 0)
    local sw = 2 + floor(t * 10)
    d.fill_rect(0, VIEW_TOP, sw, VIEW_H, col)
    d.fill_rect(SW - sw, VIEW_TOP, sw, VIEW_H, col)
    d.fill_rect(0, VIEW_TOP, SW, sw, col)
    d.fill_rect(0, SH - sw, SW, sw, col)
    if nearest < 1.1 then
        theme.set_font("medium")
        local msg = "CONTACT!"
        local flash = (floor(anim_t / 4) % 2 == 0) and rgb(255, 230, 0) or rgb(255, 60, 60)
        d.draw_text(floor((SW - theme.text_width(msg)) / 2),
                    VIEW_TOP + 20, msg, flash)
    end
end

local function draw_minimap(d)
    local mm_w = 58
    local mm_h = 58
    local ox = SW - mm_w - 4
    local oy = SH - mm_h - 4
    d.fill_rect(ox - 2, oy - 2, mm_w + 4, mm_h + 4, rgb(0, 0, 0))
    d.draw_rect(ox - 2, oy - 2, mm_w + 4, mm_h + 4, rgb(60, 80, 60))
    local scale = mm_w / GROUND_SIZE
    local function wx_to_mx(wx) return ox + floor((wx + GROUND_HALF) * scale) end
    local function wz_to_my(wz) return oy + floor((wz + GROUND_HALF) * scale) end
    for i = 1, #obstacles do
        local o = obstacles[i]
        if o.aabb then
            -- Draw AABB as a filled rectangle on the minimap.
            local ax = wx_to_mx(o.x1)
            local ay = wz_to_my(o.z1)
            local bx = wx_to_mx(o.x2)
            local by = wz_to_my(o.z2)
            d.fill_rect(ax, ay, math.max(1, bx - ax), math.max(1, by - ay),
                        rgb(120, 100, 70))
        else
            local mx = wx_to_mx(o[1])
            local my = wz_to_my(o[2])
            if o[3] > 1.0 then
                d.fill_rect(mx - 2, my - 2, 5, 5, rgb(110, 90, 60))
            else
                d.fill_rect(mx, my, 2, 2, rgb(60, 110, 50))
            end
        end
    end
    for _, e in ipairs(zombies) do
        if e.alive then
            d.fill_rect(wx_to_mx(e.x), wz_to_my(e.z), 2, 2, rgb(230, 30, 30))
        end
    end
    for _, p in ipairs(pickups) do
        if p.active then
            local c = (p.kind == "hp") and rgb(0, 220, 0) or rgb(220, 200, 0)
            d.fill_rect(wx_to_mx(p.x), wz_to_my(p.z), 2, 2, c)
        end
    end
    d.fill_rect(wx_to_mx(px), wz_to_my(pz), 3, 3, rgb(60, 180, 255))
    local fx = px + sin(p_yaw) * 1.5
    local fz = pz + cos(p_yaw) * 1.5
    d.fill_rect(wx_to_mx(fx), wz_to_my(fz), 1, 1, rgb(120, 200, 255))
end

---------------------------------------------------------------------------
-- Main frame
---------------------------------------------------------------------------
local function render(d)
    draw_sky(d)

    -- Push the camera state into the scene once per frame so the C
    -- billboard helpers can orient their quads without being passed
    -- the camera parameters on every call.
    ez.display.scene_set_camera(scene, px, pz, yaw_cos, yaw_sin,
                                BILLBOARD_FWD)

    -- Reset scene to static prefix, then append this frame's dynamic
    -- geometry (trees, hedges, zombies, pickups) as world-space tris.
    ez.display.scene_reset_to(scene, static_mark)

    for _, t in ipairs(trees) do
        local dx = t.x - px
        local dz = t.z - pz
        if dx * dx + dz * dz < TREE_CULL_SQ then
            if t.kind == 'pine' then add_pine(t) else add_oak(t) end
        end
    end
    for _, cf in ipairs(campfires) do add_campfire_flame(cf) end
    for _, lp in ipairs(lampposts) do add_lamp_glow(lp) end
    -- Placed crates are per-frame dynamic geometry so we don't need to
    -- rebuild the static prefix every time the player drops one. Same
    -- submission cost as a tree billboard set; obstacles handle the
    -- collision side once at placement time.
    for _, c in ipairs(placed_crates) do
        add_box(c.x, c.z, c.size, c.size, c.size,
                rgb(125, 85, 40), rgb(150, 105, 55))
    end
    for _, e in ipairs(zombies) do if e.alive then add_zombie(e) end end
    for _, p in ipairs(pickups) do if p.active then add_pickup(p) end end
    for _, d in ipairs(drops) do add_drop(d) end

    tris_last = ez.display.scene_render_z(scene,
        px, py, pz, yaw_cos, yaw_sin,
        FOCAL, VIEW_CX, VIEW_CY, NEAR, FOG_K, FAR, scene_light())
end

local function draw_end_screen(d)
    d.fill_rect(0, 0, SW, SH, rgb(0, 0, 0))
    theme.set_font("large")
    local title = "GAME OVER"
    local tc = rgb(215, 0, 0)
    d.draw_text(floor((SW - theme.text_width(title)) / 2), 30, title, tc)
    theme.set_font("medium")
    local sc = "Score: " .. score
    d.draw_text(floor((SW - theme.text_width(sc)) / 2), 70, sc,
        rgb(200, 200, 200))

    -- Top-5 board, rendered directly below the score line so the
    -- player always sees whether this run made the cut.
    theme.set_font("small")
    d.draw_text(floor((SW - theme.text_width("HIGH SCORES")) / 2), 100,
        "HIGH SCORES", rgb(170, 170, 170))
    theme.set_font("tiny_aa")
    local rows = highscores.format(HS_KEY, function(i, h)
        return string.format("%d.  %6d   wave %d", i, h.score, h.extra)
    end)
    for i, line in ipairs(rows) do
        d.draw_text(floor((SW - theme.text_width(line)) / 2),
            116 + (i - 1) * 12, line, rgb(210, 210, 210))
    end

    theme.set_font("small")
    local hint = "R:restart  Q:quit"
    d.draw_text(floor((SW - theme.text_width(hint)) / 2), SH - 20, hint,
        rgb(130, 130, 130))
end

---------------------------------------------------------------------------
-- Custom view node
---------------------------------------------------------------------------
if not node_mod.handler("wasteland_view") then
    node_mod.register("wasteland_view", {
        measure = function(n, mw, mh) return SW, SH end,
        draw = function(n, d, x, y, w, h)
            if not game_alive then draw_end_screen(d); return end
            render(d)
            draw_weapon(d)
            draw_crosshair(d)
            draw_proximity(d)
            draw_hud(d)
            draw_minimap(d)

            -- Shop interaction: "Press E" hint when near a shop; full
            -- menu overlay when it's open.
            if nearest_shop and not ui.shop_open then
                theme.set_font("small")
                local hint = "[E] " .. nearest_shop.label
                local tw = theme.text_width(hint)
                local tx = floor((SW - tw) / 2)
                d.fill_rect(tx - 6, SH - 26, tw + 12, 16, rgb(0, 0, 0))
                d.draw_rect(tx - 6, SH - 26, tw + 12, 16, rgb(230, 200, 80))
                d.draw_text(tx, SH - 23, hint, rgb(230, 220, 180))
            end
            if ui.shop_open then draw_shop_menu(d) end
            if ui.craft_open then draw_craft_menu(d) end
            if ui.inv_open then draw_inventory(d) end
            if ui.pause_open then draw_pause_menu(d) end
            if ui.help_open then draw_help(d) end
        end,
    })
end

---------------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------------
-- Sprint multiplier applied to every movement vector. Caller has
-- already drained stamina this frame so we just ask whether the player
-- is actively sprinting right now.
local function speed_mult()
    if sprint_locked or stamina <= 0 then return 1.0 end
    if ez.keyboard.is_shift_held() then return SPRINT_MULT end
    return 1.0
end

local function move_forward()
    local m = speed_mult()
    local nx = px + sin(p_yaw) * MOVE_SPD * m
    local nz = pz + cos(p_yaw) * MOVE_SPD * m
    try_move(nx, nz)
end
local function move_backward()
    local nx = px - sin(p_yaw) * MOVE_SPD
    local nz = pz - cos(p_yaw) * MOVE_SPD
    try_move(nx, nz)
end
local function strafe_left()
    local m = speed_mult()
    local nx = px + sin(p_yaw - pi / 2) * STRAFE_SPD * m
    local nz = pz + cos(p_yaw - pi / 2) * STRAFE_SPD * m
    try_move(nx, nz)
end
local function strafe_right()
    local m = speed_mult()
    local nx = px + sin(p_yaw + pi / 2) * STRAFE_SPD * m
    local nz = pz + cos(p_yaw + pi / 2) * STRAFE_SPD * m
    try_move(nx, nz)
end

---------------------------------------------------------------------------
-- Screen lifecycle
---------------------------------------------------------------------------
function Game:build(state) return { type = "wasteland_view" } end

function Game:on_enter()
    reset_game()
    saved_repeat_enabled = ez.keyboard.get_repeat_enabled()
    saved_repeat_delay   = ez.keyboard.get_repeat_delay()
    saved_repeat_rate    = ez.keyboard.get_repeat_rate()
    ez.keyboard.set_repeat_enabled(false)
    saved_tb_sens = ez.keyboard.get_trackball_sensitivity()
    ez.keyboard.set_trackball_sensitivity(1)

    -- Debug / remote-control namespace. Exposed as a global only while
    -- this screen is active so external code (the ez_remote -e flag)
    -- can drive the player around without touching the keyboard. All
    -- functions no-op quietly if called at the wrong time.
    --
    -- Usage from host:
    --   python tools/remote/ez_remote.py /dev/ttyACM0 \
    --       -e "wasteland.tp(8, 8); wasteland.face(8, 12)"
    _G.wasteland = {
        -- Teleport to (x, z) in world units. Y is fixed to eye height.
        -- Omit either coordinate to keep the current value.
        tp = function(x, z)
            if x then px = x end
            if z then pz = z end
        end,

        -- Point the camera at world coords (tx, tz) — computes the yaw
        -- from the player's current (px, pz) to the target.
        face = function(tx, tz)
            if not tx or not tz then return end
            local dx = tx - px
            local dz = tz - pz
            if dx * dx + dz * dz < 1e-6 then return end
            set_yaw(atan2(dx, dz))
        end,

        -- Set yaw directly in radians. 0 = facing +Z (north),
        -- pi/2 = +X (east).
        yaw = function(y) if y then set_yaw(y) end end,

        -- Report current pose. Returns x, z, yaw_radians.
        pos = function() return px, pz, p_yaw end,

        -- List of shop positions — handy for tp'ing to a doorway.
        shops = function()
            local out = {}
            for i, s in ipairs(shops) do
                out[i] = { x = s.x, z = s.z, door_x = s.door_x,
                           door_z = s.door_z, label = s.label }
            end
            return out
        end,

        -- Force time-of-day. Accepts 0..1.
        time = function(t) if t then time_of_day = t % 1 end end,

        -- Spawn a zombie immediately at (x, z). Useful for
        -- reproducing AI-specific scenarios.
        spawn_at = function(x, z, kind)
            for _, e in ipairs(zombies) do
                if not e.alive then
                    e.x = x; e.z = z
                    e.kind = kind or 'normal'
                    local def = ZOMBIE_KIND[e.kind] or ZOMBIE_KIND.normal
                    e.hp = def.hp
                    e.speed = def.speed
                    e.alive = true
                    e.cooldown = 0
                    e.respawn = 0
                    e.phase = random(0, 3)
                    return true
                end
            end
            return false
        end,

        -- Quick god/freeze toggles for scripted debugging.
        god    = function(v) cheat_god    = v ~= false end,
        freeze = function(v) cheat_freeze = v ~= false end,

        -- Score + weapon manipulation for shop testing.
        score  = function(n) if n then score = n end return score end,
        give   = function(key)
            for i, w in ipairs(WEAPONS) do
                if w.key == key then w.owned = true; current_weapon = i end
            end
        end,
        weapon = function(key)
            for i, w in ipairs(WEAPONS) do
                if w.key == key and w.owned then current_weapon = i end
            end
        end,

        -- Crate / wood manipulation
        give_crates = function(n) crates_held = crates_held + (n or 1) end,
        give_wood   = function(n) wood  = wood  + (n or 1) end,
        give_cloth  = function(n) cloth = cloth + (n or 1) end,
        give_scrap  = function(n) scrap = scrap + (n or 1) end,
        place       = function() return place_crate() end,
        craft       = function(i) return try_craft(CRAFT_RECIPES[i or 1]) end,
        materials   = function()
            return { wood = wood, cloth = cloth, scrap = scrap,
                     crates = crates_held, placed = #placed_crates,
                     drops = #drops }
        end,
        drop_list   = function()
            local out = {}
            for i, d in ipairs(drops) do
                out[i] = { x = d.x, z = d.z, kind = d.kind, ttl = d.ttl }
            end
            return out
        end,
        crates      = function() return #placed_crates, crates_held, wood end,
        shoot       = function()
            shoot_timer = 0
            do_shoot()
            return ammo, #placed_crates
        end,
    }
end

function Game:on_exit()
    if saved_repeat_enabled ~= nil then ez.keyboard.set_repeat_enabled(saved_repeat_enabled) end
    if saved_repeat_delay then ez.keyboard.set_repeat_delay(saved_repeat_delay) end
    if saved_repeat_rate  then ez.keyboard.set_repeat_rate(saved_repeat_rate)   end
    if saved_tb_sens      then ez.keyboard.set_trackball_sensitivity(saved_tb_sens) end
    _G.wasteland = nil
end

function Game:update()
    if game_alive then
        -- Block movement + zombie AI while the shop or craft menu is
        -- open so menu browsing isn't a death trap. The anim counter
        -- still ticks so lamp glow and other time-based visuals stay
        -- lively.
        if not ui.shop_open and not ui.craft_open and not ui.pause_open
           and not ui.inv_open then
            if ez.keyboard.is_held("w") then move_forward() end
            if ez.keyboard.is_held("s") then move_backward() end
            if ez.keyboard.is_held("a") then strafe_left() end
            if ez.keyboard.is_held("d") then strafe_right() end
            update_zombies()
            check_pickups()
            check_drops()
        end
        update_shop_proximity()
        if shoot_timer > 0 then shoot_timer = shoot_timer - 1 end
        anim_t = anim_t + 1

        -- Auto-fire: if the current weapon's `auto` flag is set and
        -- the trigger key (space) is held, fire again as soon as the
        -- cooldown expires. Edge-triggered handle_key keeps working
        -- for the semi-auto weapons without stepping on this.
        if (not ui.shop_open) and (not ui.craft_open) and (not ui.pause_open)
           and (not ui.inv_open) and game_alive and shoot_timer <= 0 then
            local w = WEAPONS[current_weapon]
            if w.auto and ez.keyboard.is_held(" ") then
                do_shoot()
            end
        end

        -- Advance time-of-day at a fixed rate. Wraps at 1.
        time_of_day = time_of_day + 1 / DAY_LENGTH
        if time_of_day >= 1 then time_of_day = time_of_day - 1 end

        -- Stamina tick: drain only while both shift is held AND the
        -- player is actually moving (pressing any held movement key).
        local holding_move = ez.keyboard.is_held("w") or ez.keyboard.is_held("s")
                          or ez.keyboard.is_held("a") or ez.keyboard.is_held("d")
        if (not sprint_locked) and ez.keyboard.is_shift_held() and holding_move then
            stamina = stamina - SPRINT_DRAIN
            if stamina <= 0 then
                stamina = 0
                sprint_locked = true  -- force a short cooldown
            end
        else
            if sprint_locked and stamina >= MAX_STAMINA * 0.3 then
                sprint_locked = false
            end
            stamina = stamina + SPRINT_REGEN
            if stamina > MAX_STAMINA then stamina = MAX_STAMINA end
        end
    end

    -- Rolling FPS counter: recompute every ~500ms so the number is
    -- stable enough to read. Cheap even when the overlay isn't shown.
    fps_frames = fps_frames + 1
    local now = ez.system.millis()
    if fps_last_ms == 0 then fps_last_ms = now end
    local dt = now - fps_last_ms
    if dt >= 500 then
        fps_display = floor(fps_frames * 1000 / dt + 0.5)
        fps_frames = 0
        fps_last_ms = now
    end

    screen_mod.invalidate()
end

-- Cheat: wipe every live zombie and credit their score.
local function cheat_killall()
    for _, e in ipairs(zombies) do
        if e.alive then
            e.alive = false
            e.respawn = 0
            score = score + 100
        end
    end
end

function Game:handle_key(key)
    -- Help overlay swallows all input; any key closes it and returns
    -- to whichever menu was open behind it (usually pause).
    if ui.help_open then
        if key.character or key.special then ui.help_open = false end
        return "handled"
    end

    -- Inventory menu: weapon selection + read-only materials panel.
    -- UP/DOWN scan through all weapons (locked included — just can't
    -- select them). SPACE equips. I / Q close.
    if ui.inv_open then
        if key.character == "q" or key.character == "i"
           or key.special == "ESCAPE" then
            ui.inv_open = false
            return "handled"
        end
        if key.special == "UP" then
            -- Walk backward, skipping locked weapons so the selection
            -- always rests on an owned entry.
            local n = #WEAPONS
            for _ = 1, n do
                ui.inv_sel = ((ui.inv_sel - 2) % n) + 1
                if WEAPONS[ui.inv_sel].owned then break end
            end
            return "handled"
        end
        if key.special == "DOWN" then
            local n = #WEAPONS
            for _ = 1, n do
                ui.inv_sel = (ui.inv_sel % n) + 1
                if WEAPONS[ui.inv_sel].owned then break end
            end
            return "handled"
        end
        if key.character == " " or key.special == "ENTER" then
            if WEAPONS[ui.inv_sel].owned then
                current_weapon = ui.inv_sel
            end
            -- Close the menu on equip: the game is paused behind the
            -- overlay, so leaving it open after a successful equip
            -- looks identical to a hang.
            ui.inv_open = false
            return "handled"
        end
        return "handled"
    end

    -- Pause menu navigation. Q closes (resumes); UP/DOWN move the
    -- selection; SPACE confirms. Quit selection returns "pop" so the
    -- screen manager unwinds this screen like the old raw-Q behaviour.
    if ui.pause_open then
        if key.character == "q" or key.special == "ESCAPE" then
            ui.pause_open = false
            return "handled"
        end
        if key.special == "UP" then
            ui.pause_sel = ((ui.pause_sel - 2) % #PAUSE_ITEMS) + 1
            return "handled"
        end
        if key.special == "DOWN" then
            ui.pause_sel = (ui.pause_sel % #PAUSE_ITEMS) + 1
            return "handled"
        end
        if key.character == " " or key.special == "ENTER" then
            local label = PAUSE_ITEMS[ui.pause_sel].label
            if label == "Resume" then
                ui.pause_open = false
            elseif label == "Restart" then
                reset_game()
                ui.pause_open = false
            elseif label == "Help" then
                ui.help_open = true
            elseif label == "Quit" then
                ui.pause_open = false
                return "pop"
            end
            return "handled"
        end
        return "handled"
    end

    -- Craft menu absorbs inputs while open, same ergonomics as the
    -- shop menu. C / Q / ESC close; up/down select; space crafts.
    if ui.craft_open then
        if key.character == "q" or key.special == "ESCAPE"
           or key.character == "c" then
            ui.craft_open = false
            return "handled"
        end
        if key.special == "UP" then
            ui.craft_sel = ((ui.craft_sel - 2) % #CRAFT_RECIPES) + 1
            return "handled"
        end
        if key.special == "DOWN" then
            ui.craft_sel = (ui.craft_sel % #CRAFT_RECIPES) + 1
            return "handled"
        end
        if key.character == " " or key.special == "ENTER" then
            try_craft(CRAFT_RECIPES[ui.craft_sel])
            return "handled"
        end
        return "handled"
    end

    -- Shop menu absorbs inputs while open — can't shoot, can't move,
    -- can only browse and buy. ESC/Q/E all close the menu; up/down
    -- select; space confirms a purchase.
    if ui.shop_open then
        if key.character == "q" or key.special == "ESCAPE"
           or key.character == "e" then
            ui.shop_open = false
            return "handled"
        end
        if key.special == "UP" then
            ui.shop_sel = ((ui.shop_sel - 2) % #SHOP_ITEMS) + 1
            return "handled"
        end
        if key.special == "DOWN" then
            ui.shop_sel = (ui.shop_sel % #SHOP_ITEMS) + 1
            return "handled"
        end
        if key.character == " " or key.special == "ENTER" then
            local item = SHOP_ITEMS[ui.shop_sel]
            if item and score >= item.cost then
                score = score - item.cost
                item.apply()
                -- Rebuild the menu in case the purchase removed an
                -- entry (e.g. weapon unlock) so the cursor doesn't
                -- point at a stale row.
                build_shop_items()
            end
            return "handled"
        end
        return "handled"
    end

    -- Q now opens the pause menu during gameplay (the T-Deck has no
    -- dedicated ESC key, so Q serves double duty). On the game-over
    -- screen we still pop so the player isn't stuck in a dead run.
    if key.character == "q" or key.special == "ESCAPE" then
        if not game_alive then return "pop" end
        ui.pause_open = true
        ui.pause_sel = 1
        return "handled"
    end
    if key.character == "r" then reset_game(); return "handled" end

    -- Cheats are available on the death screen too so you can toggle
    -- god + restart quickly while iterating.
    if key.character == "g" then cheat_god = not cheat_god; return "handled" end
    if key.character == "f" then cheat_freeze = not cheat_freeze; return "handled" end
    if key.character == "p" then cheat_perf = not cheat_perf; return "handled" end
    if key.character == "k" then cheat_killall(); return "handled" end
    if key.character == "m" then health = max_health; ammo = 99; return "handled" end
    -- Time-of-day jump: advance by a quarter-day so night/dawn/dusk are
    -- reachable without waiting for the DAY_LENGTH cycle.
    if key.character == "n" then
        time_of_day = (time_of_day + 0.25) % 1
        return "handled"
    end

    -- Shop open/interact: only when standing in a shop's prompt zone.
    if key.character == "e" then
        if nearest_shop then
            ui.shop_open = true
            ui.shop_sel = 1
            build_shop_items()
        end
        return "handled"
    end

    -- Place a crate in front of the player (from inventory).
    if key.character == "b" then
        place_crate()
        return "handled"
    end

    -- Open the craft menu. Available anywhere (no workbench gate) so
    -- the player can heal/reload in a pinch, but zombies still tick
    -- while the menu is... wait — actually they're paused (see
    -- update()). That's deliberate so scrolling recipes isn't a death
    -- trap. If it turns out to be too easy, gate it on `nearest_shop`.
    if key.character == "c" then
        ui.craft_open = true
        ui.craft_sel = 1
        return "handled"
    end

    -- Open the inventory menu. Lets the player equip a different
    -- weapon without needing the Sym+digit chord the T-Deck keyboard
    -- needs for the `1/2/3/4` shortcuts.
    if key.character == "i" then
        ui.inv_open = true
        -- Snap selection to currently-equipped weapon so the cursor
        -- starts "on the player's gun".
        ui.inv_sel = current_weapon
        return "handled"
    end

    if not game_alive then return "handled" end

    -- Weapon switching: 1/2/3 picks pistol/shotgun/rifle if owned.
    -- Ignored mid-cooldown so spamming the keys doesn't cancel a shot.
    if key.character == "1" and WEAPONS[1].owned then
        current_weapon = 1; return "handled"
    elseif key.character == "2" and WEAPONS[2].owned then
        current_weapon = 2; return "handled"
    elseif key.character == "3" and WEAPONS[3].owned then
        current_weapon = 3; return "handled"
    elseif key.character == "4" and WEAPONS[4].owned then
        current_weapon = 4; return "handled"
    elseif key.character == "5" and WEAPONS[5].owned then
        current_weapon = 5; return "handled"
    end

    if key.character == "w" then move_forward()
    elseif key.character == "s" then move_backward()
    elseif key.character == "a" then strafe_left()
    elseif key.character == "d" then strafe_right()
    elseif key.special == "LEFT" then set_yaw(p_yaw - TURN_SPD)
    elseif key.special == "RIGHT" then set_yaw(p_yaw + TURN_SPD)
    elseif key.character == " " or key.special == "ENTER" then do_shoot()
    end
    return "handled"
end

return Game
