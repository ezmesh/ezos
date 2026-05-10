-- 8-ball pool.
--
-- Three modes share the same screen:
--   1P  -- human vs simple AI ("pick the easiest legal shot, scale
--          power 60-90%"). Deliberately not a strong opponent.
--   Host / Join -- 2P over SoftAP + UDP, mirroring pong.lua. The host
--          runs the authoritative simulation and broadcasts ball
--          positions; the client just sends aim + power + shoot intent.
--
-- Wire format (sketched in issue #55):
--   Client -> Host:  [0x01][aim_q14:i16][power:u8][shoot:u8][seq:u16]
--                     aim_q14 = floor(angle_rad * 16384) ([-pi..pi])
--                     power   = 0..100 percent
--                     shoot   = 0/1 (rising edge releases the cue)
--   Host -> Client:  [0x02][turn:u8][cue_x:i16][cue_y:i16]
--                    [n:u8] {[id:u8][x:i16][y:i16][pocketed:u8]}*
--                    [ball_on:u8][p1_pot:u8][p2_pot:u8][flags:u8]
--
-- "Authoritative tick" means: host runs the full physics + rules
-- simulation; the client never simulates, only renders the snapshots
-- it receives. A dropped UDP packet is one stale frame, not a desync.
--
-- Physics is intentionally arcade-ish: circle/circle elastic collision
-- via 1D-along-normal exchange (equal masses), cushion reflection on
-- inner-rail intersection, frame-rate-independent friction decay. It
-- runs at the simulation tick (33 ms) -- not "as fast as possible" --
-- so host and (for cosmetic purposes) client see the same numbers when
-- you read them off the wire.

local ui         = require("ezui")
local screen_mod = require("ezui.screen")
local theme      = require("ezui.theme")
local node       = require("ezui.node")

-- ---------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------

-- 320x240 screen layout:
--   title bar:        20 px
--   HUD strip:        18 px (current player, ball-on, fouls)
--   table region:    140 px high, 280 px wide, centred (20 px borders)
--   power meter:      14 px below the table
--   total used:      192 px (leaves slack for the title bar inside ui.vbox)
local TABLE_W      = 280
local TABLE_H      = 140
local TABLE_X      = 20             -- left rail
local TABLE_Y      = 22             -- top rail (inside the field node)
local CUSHION      = 6              -- inner-rail thickness eaten from the felt
local PLAY_X0      = TABLE_X + CUSHION
local PLAY_Y0      = TABLE_Y + CUSHION
local PLAY_X1      = TABLE_X + TABLE_W - CUSHION
local PLAY_Y1      = TABLE_Y + TABLE_H - CUSHION

local BALL_R       = 4              -- 8 px diameter; tight but legible
local POCKET_R     = 7              -- forgiving for the small playfield

-- Six pockets at corners and rail mid-points. Coords are pocket
-- centres in screen-space, used both for drawing and for "did the ball
-- fall in" tests.
local POCKETS = {
    { x = TABLE_X,             y = TABLE_Y },
    { x = TABLE_X + TABLE_W/2, y = TABLE_Y - 1 },
    { x = TABLE_X + TABLE_W,   y = TABLE_Y },
    { x = TABLE_X,             y = TABLE_Y + TABLE_H },
    { x = TABLE_X + TABLE_W/2, y = TABLE_Y + TABLE_H + 1 },
    { x = TABLE_X + TABLE_W,   y = TABLE_Y + TABLE_H },
}

-- Ball IDs follow standard pool numbering. 0 is the cue, 1-7 solids,
-- 8 the eight, 9-15 stripes. The renderer only needs to know the ID
-- to pick a colour; the rules layer tracks which group each player
-- has been assigned.
local CUE_ID = 0
local EIGHT  = 8

-- Tick interval. Higher == jerkier physics, lower == more CPU.
-- 33 ms == ~30 Hz, matching pong.
local TICK_MS = 33

-- Friction. Multiply velocity by this per tick. 0.985 ^ 30 ~= 0.63 so
-- a hard shot decays to a stop over a few seconds, which feels right.
local FRICTION = 0.985
-- Anything slower than this is treated as stopped, so the simulation
-- doesn't dribble forever at sub-pixel speeds.
local STOP_EPS = 0.04

-- Power at full charge. Tuned so a max-power straight shot crosses
-- the table once and the cushion bounce dies before crossing again.
local MAX_SPEED = 7.5

-- Local UI tuning.
local POWER_BAR_W   = TABLE_W
local POWER_BAR_H   = 6
local CHARGE_TIME   = 1500          -- ms from 0 to full when holding ENTER

-- ---------------------------------------------------------------------
-- Wire codec (used by 2P modes only -- 1P never serialises)
-- ---------------------------------------------------------------------

local function pack_i16(v)
    v = math.floor(v + 0.5)
    if v < 0 then v = v + 65536 end
    return string.char(v & 0xFF, (v >> 8) & 0xFF)
end
local function read_i16(s, o)
    local v = s:byte(o) + s:byte(o + 1) * 256
    if v >= 0x8000 then v = v - 0x10000 end
    return v
end
local function pack_u16(v) return string.char(v & 0xFF, (v >> 8) & 0xFF) end

-- Encode angle as q14 (fractional fixed-point with 14 fraction bits).
-- 14 fraction bits across a [-pi, pi] range gives ~0.011 deg of
-- resolution, finer than the physics needs.
local function pack_angle(a)
    local q = math.floor(a * 16384 + 0.5)
    if q < -32768 then q = -32768 end
    if q >  32767 then q =  32767 end
    return pack_i16(q)
end
local function read_angle(s, o) return read_i16(s, o) / 16384 end

local function encode_input(aim, power, shoot, seq)
    return string.char(0x01)
        .. pack_angle(aim)
        .. string.char(power & 0xFF)
        .. string.char(shoot and 1 or 0)
        .. pack_u16(seq & 0xFFFF)
end

local function decode_input(data)
    if not data or #data < 7 or data:byte(1) ~= 0x01 then return nil end
    return {
        aim   = read_angle(data, 2),
        power = data:byte(4),
        shoot = data:byte(5) == 1,
        seq   = data:byte(6) + data:byte(7) * 256,
    }
end

local function encode_state(sim)
    local parts = {}
    parts[#parts + 1] = string.char(0x02)
    parts[#parts + 1] = string.char(sim.turn & 0xFF)
    local cue = sim.balls[1]
    parts[#parts + 1] = pack_i16(cue.x) .. pack_i16(cue.y)
    parts[#parts + 1] = string.char(#sim.balls & 0xFF)
    for _, b in ipairs(sim.balls) do
        parts[#parts + 1] = string.char(b.id & 0xFF)
            .. pack_i16(b.x) .. pack_i16(b.y)
            .. string.char(b.pocketed and 1 or 0)
    end
    parts[#parts + 1] = string.char(sim.ball_on & 0xFF)
    parts[#parts + 1] = string.char(sim.p1_pot & 0xFF)
    parts[#parts + 1] = string.char(sim.p2_pot & 0xFF)
    parts[#parts + 1] = string.char(sim.flags & 0xFF)
    return table.concat(parts)
end

local function decode_state(data)
    if not data or #data < 6 or data:byte(1) ~= 0x02 then return nil end
    local turn = data:byte(2)
    local cue_x = read_i16(data, 3)
    local cue_y = read_i16(data, 5)
    local n = data:byte(7)
    local balls = {}
    local off = 8
    for _ = 1, n do
        if off + 5 > #data then return nil end
        balls[#balls + 1] = {
            id       = data:byte(off),
            x        = read_i16(data, off + 1),
            y        = read_i16(data, off + 3),
            pocketed = data:byte(off + 5) == 1,
        }
        off = off + 6
    end
    if off + 3 > #data then return nil end
    return {
        turn   = turn,
        cue    = { x = cue_x, y = cue_y },
        balls  = balls,
        ball_on= data:byte(off),
        p1_pot = data:byte(off + 1),
        p2_pot = data:byte(off + 2),
        flags  = data:byte(off + 3),
    }
end

-- ---------------------------------------------------------------------
-- Initial rack
-- ---------------------------------------------------------------------

-- Standard 8-ball break: 8 in the centre of the rack, one solid + one
-- stripe in the back corners, the rest interleaved. Numbers don't
-- matter for play -- only the group (solids 1-7 vs stripes 9-15) does
-- -- so we hand-pick a layout that LOOKS right with the standard
-- coloured balls but keep the rules group-agnostic.
local function build_rack(rack_x, rack_y)
    -- Triangle apex at (rack_x, rack_y) pointing left toward the cue.
    -- Each row offsets by +sqrt(3)*r horizontally and +/- r vertically.
    -- We use 2*BALL_R + small gap between centres so balls don't
    -- visually overlap on the small screen.
    local spacing = BALL_R * 2 + 0.4
    local row_dx  = spacing * 0.866      -- cos(30deg)

    -- Layout grid: rows[1] = apex, rows[5] = back row.
    --   1
    --   2 9
    --  10 8 3
    --   4 11 12 5
    -- 13 6 14 7 15
    -- Picked so the 8-ball is dead-centre (rack[3][2]) and corners
    -- alternate solid / stripe per traditional rules.
    local rack = {
        { 1 },
        { 2, 9 },
        { 10, 8, 3 },
        { 4, 11, 12, 5 },
        { 13, 6, 14, 7, 15 },
    }
    local balls = {}
    for r, row in ipairs(rack) do
        local x = rack_x + (r - 1) * row_dx
        local y0 = rack_y - (r - 1) * spacing / 2
        for c, id in ipairs(row) do
            balls[#balls + 1] = {
                id       = id,
                x        = x,
                y        = y0 + (c - 1) * spacing,
                vx       = 0,
                vy       = 0,
                pocketed = false,
            }
        end
    end
    return balls
end

local function new_sim()
    -- Cue ball at the standard "head spot": 1/4 of the table from the
    -- left rail, vertically centred.
    local cue = {
        id = CUE_ID,
        x  = TABLE_X + TABLE_W * 0.25,
        y  = TABLE_Y + TABLE_H * 0.5,
        vx = 0, vy = 0,
        pocketed = false,
    }
    -- Rack apex 3/4 across the table, on the centre line.
    local rack = build_rack(TABLE_X + TABLE_W * 0.65, TABLE_Y + TABLE_H * 0.5)
    local balls = { cue }
    for _, b in ipairs(rack) do balls[#balls + 1] = b end

    return {
        balls   = balls,
        turn    = 1,         -- 1 or 2
        ball_on = 0,         -- 0 = unassigned, 1 = solids, 2 = stripes,
                             -- 8 = both players on 8-ball
        p1_group= 0,         -- 0 unassigned, 1 solids, 2 stripes
        p2_group= 0,
        p1_pot  = 0,         -- count of own group already pocketed
        p2_pot  = 0,
        flags   = 0,         -- bit0 = game_over, bit1 = p2 wins
        winner  = 0,         -- 0 = none, 1 / 2 = player N
        in_hand = false,     -- ball-in-hand pending; current player can
                             -- drag the cue before shooting
        message = "Player 1 to break",
        moving  = false,     -- true while balls are settling
        last_shot_pots = {}, -- ids pocketed during the most recent shot
        last_shot_first = nil, -- first ball-on-ball contact during shot
    }
end

-- ---------------------------------------------------------------------
-- Group helpers
-- ---------------------------------------------------------------------

local function group_of(id)
    if id == CUE_ID then return 0 end
    if id == EIGHT   then return 8 end
    if id <  EIGHT   then return 1 end
    return 2
end

local function group_remaining(sim, grp)
    local n = 0
    for _, b in ipairs(sim.balls) do
        if not b.pocketed and group_of(b.id) == grp then
            n = n + 1
        end
    end
    return n
end

local function find_ball(sim, id)
    for _, b in ipairs(sim.balls) do
        if b.id == id then return b end
    end
end

-- Player N's group, defaulting to "ball_on" semantics for the broadcast
-- packet.
local function group_for_player(sim, pn)
    if pn == 1 then return sim.p1_group end
    return sim.p2_group
end

-- ---------------------------------------------------------------------
-- Physics
-- ---------------------------------------------------------------------

-- Apply elastic collision between two balls. Equal masses, so velocity
-- exchange is along the contact normal; the tangential components are
-- preserved. Standard 2D billiards trick. Caller must have already
-- determined that the balls are touching; this routine pushes them
-- apart so they're not overlapping.
local function collide_balls(a, b)
    local dx = b.x - a.x
    local dy = b.y - a.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1e-6 then return end
    local nx = dx / dist
    local ny = dy / dist
    -- Resolve overlap so the next tick doesn't see them stuck.
    local overlap = (BALL_R * 2) - dist
    if overlap > 0 then
        a.x = a.x - nx * overlap * 0.5
        a.y = a.y - ny * overlap * 0.5
        b.x = b.x + nx * overlap * 0.5
        b.y = b.y + ny * overlap * 0.5
    end
    -- Project velocities onto the normal.
    local va_n = a.vx * nx + a.vy * ny
    local vb_n = b.vx * nx + b.vy * ny
    -- Only resolve if they're closing.
    if vb_n - va_n >= 0 then return end
    -- Swap normal components.
    a.vx = a.vx + (vb_n - va_n) * nx
    a.vy = a.vy + (vb_n - va_n) * ny
    b.vx = b.vx + (va_n - vb_n) * nx
    b.vy = b.vy + (va_n - vb_n) * ny
end

local function pocket_check(b)
    for _, p in ipairs(POCKETS) do
        local dx = b.x - p.x
        local dy = b.y - p.y
        if dx * dx + dy * dy <= POCKET_R * POCKET_R then
            return true
        end
    end
    return false
end

-- Step physics once. Mutates `sim` in place. Returns true while any
-- ball is still moving (so the host knows when the shot has settled
-- and rules can be evaluated).
local function step_physics(sim)
    local any_moving = false
    -- Integrate + cushion bounce.
    for _, b in ipairs(sim.balls) do
        if not b.pocketed then
            b.x = b.x + b.vx
            b.y = b.y + b.vy

            if b.x < PLAY_X0 + BALL_R then
                b.x = PLAY_X0 + BALL_R; b.vx = -b.vx
            elseif b.x > PLAY_X1 - BALL_R then
                b.x = PLAY_X1 - BALL_R; b.vx = -b.vx
            end
            if b.y < PLAY_Y0 + BALL_R then
                b.y = PLAY_Y0 + BALL_R; b.vy = -b.vy
            elseif b.y > PLAY_Y1 - BALL_R then
                b.y = PLAY_Y1 - BALL_R; b.vy = -b.vy
            end
        end
    end

    -- Pairwise ball-ball collisions. Naive O(n^2): with 16 balls that's
    -- 120 distance checks per tick, well under our budget.
    for i = 1, #sim.balls - 1 do
        local a = sim.balls[i]
        if not a.pocketed then
            for j = i + 1, #sim.balls do
                local bb = sim.balls[j]
                if not bb.pocketed then
                    local dx = bb.x - a.x
                    local dy = bb.y - a.y
                    if dx * dx + dy * dy <= (BALL_R * 2) * (BALL_R * 2) then
                        -- Track first ball-on-ball contact this shot.
                        if a.id == CUE_ID and not sim.last_shot_first then
                            sim.last_shot_first = bb.id
                        elseif bb.id == CUE_ID and not sim.last_shot_first then
                            sim.last_shot_first = a.id
                        end
                        collide_balls(a, bb)
                    end
                end
            end
        end
    end

    -- Pocket check + friction + stop.
    for _, b in ipairs(sim.balls) do
        if not b.pocketed then
            if pocket_check(b) then
                b.pocketed = true
                b.vx = 0; b.vy = 0
                sim.last_shot_pots[#sim.last_shot_pots + 1] = b.id
            else
                b.vx = b.vx * FRICTION
                b.vy = b.vy * FRICTION
                if math.abs(b.vx) < STOP_EPS then b.vx = 0 end
                if math.abs(b.vy) < STOP_EPS then b.vy = 0 end
                if b.vx ~= 0 or b.vy ~= 0 then any_moving = true end
            end
        end
    end

    return any_moving
end

-- ---------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------

-- Resolve the shot once balls have settled. Decides:
--   * group assignment (on the first non-8 pocket after the break)
--   * legality (ball-on hit first, at least one rail or pocket)
--   * turn change (potting your own ball keeps the turn)
--   * win/loss conditions on the 8-ball
local function resolve_shot(sim)
    local current   = sim.turn
    local cur_grp   = group_for_player(sim, current)
    local pots      = sim.last_shot_pots
    local first_hit = sim.last_shot_first

    local cue_pocketed = false
    local eight_pocketed = false
    local own_potted   = 0
    local opp_potted   = 0
    local stripes_potted = 0
    local solids_potted  = 0

    for _, id in ipairs(pots) do
        if id == CUE_ID then
            cue_pocketed = true
        elseif id == EIGHT then
            eight_pocketed = true
        else
            local g = group_of(id)
            if g == 1 then solids_potted = solids_potted + 1
            else            stripes_potted = stripes_potted + 1 end
            if cur_grp == 0 then
                -- Group not yet assigned -- decide after the loop, since
                -- only the first non-8 pocket counts.
            elseif g == cur_grp then
                own_potted = own_potted + 1
            else
                opp_potted = opp_potted + 1
            end
        end
    end

    -- Group assignment on first non-8 pocket. If both groups go down
    -- on the same shot, "table is open" = current player picks the
    -- one with the higher count, ties broken in favour of solids.
    if cur_grp == 0 and (solids_potted + stripes_potted) > 0 then
        local pick_solid = solids_potted >= stripes_potted
        if current == 1 then
            sim.p1_group = pick_solid and 1 or 2
            sim.p2_group = pick_solid and 2 or 1
        else
            sim.p2_group = pick_solid and 1 or 2
            sim.p1_group = pick_solid and 2 or 1
        end
        cur_grp = group_for_player(sim, current)
        own_potted = pick_solid and solids_potted or stripes_potted
        opp_potted = pick_solid and stripes_potted or solids_potted
    end

    -- Tally pocket counts (rolled-up, used for the HUD and broadcast).
    sim.p1_pot = group_remaining(sim, sim.p1_group ~= 0 and sim.p1_group or 1)
    sim.p1_pot = (sim.p1_group ~= 0 and 7 or 0) - sim.p1_pot
    sim.p2_pot = group_remaining(sim, sim.p2_group ~= 0 and sim.p2_group or 2)
    sim.p2_pot = (sim.p2_group ~= 0 and 7 or 0) - sim.p2_pot
    if sim.p1_pot < 0 then sim.p1_pot = 0 end
    if sim.p2_pot < 0 then sim.p2_pot = 0 end

    -- ball_on broadcast value.
    local rem_own = cur_grp ~= 0 and group_remaining(sim, cur_grp) or 99
    sim.ball_on = (rem_own == 0) and 8 or (cur_grp == 0 and 0 or cur_grp)

    -- Win / loss on the 8-ball.
    if eight_pocketed then
        local cleared_own = (cur_grp ~= 0) and (rem_own == 0)
        if cue_pocketed or not cleared_own then
            -- 8-ball pocketed too early or with a scratch -> lose.
            sim.flags = sim.flags | 1
            sim.winner = (current == 1) and 2 or 1
            sim.message = "Player " .. sim.winner .. " wins!"
        else
            sim.flags = sim.flags | 1
            sim.winner = current
            sim.message = "Player " .. current .. " wins!"
        end
        sim.last_shot_pots = {}
        sim.last_shot_first = nil
        return
    end

    -- Foul detection. Three core fouls covered:
    --   * scratch (cue ball pocketed)
    --   * no first contact (ball flew nowhere or hit nothing)
    --   * wrong-ball-first (ignored if "open table")
    local foul = false
    if cue_pocketed then foul = true end
    if not first_hit then foul = true end
    if first_hit and cur_grp ~= 0 then
        local fg = group_of(first_hit)
        if rem_own == 0 then
            -- Player must hit the 8 first.
            if fg ~= 8 then foul = true end
        else
            if fg ~= cur_grp and fg ~= 8 then foul = true end
            if fg == 8 then
                -- Hitting the 8 first while you still have balls left
                -- is technically a foul too.
                foul = true
            end
        end
    end

    -- Decide turn. Standard rule: pot one of your own + no foul ->
    -- shoot again; otherwise hand over (with ball-in-hand if foul).
    local switch = true
    if own_potted > 0 and not foul then switch = false end

    if switch then
        sim.turn = (current == 1) and 2 or 1
        sim.in_hand = foul
        sim.message = "Player " .. sim.turn .. " to shoot"
        if foul then sim.message = sim.message .. " (ball in hand)" end
    else
        sim.in_hand = false
        sim.message = "Player " .. current .. " continues"
    end

    -- If the cue was pocketed, respawn it (caller -- for ball-in-hand
    -- the human/AI moves it before shooting).
    if cue_pocketed then
        local cue = sim.balls[1]
        cue.pocketed = false
        cue.x  = TABLE_X + TABLE_W * 0.25
        cue.y  = TABLE_Y + TABLE_H * 0.5
        cue.vx = 0; cue.vy = 0
    end

    sim.last_shot_pots  = {}
    sim.last_shot_first = nil
end

-- Apply a shot: aim is radians, power is 0..100. Sets cue ball velocity
-- and arms the "moving" flag so the tick driver runs physics until
-- everything settles.
local function apply_shot(sim, aim, power)
    if sim.flags & 1 ~= 0 then return end
    local cue = sim.balls[1]
    if cue.pocketed then return end
    local p = (power or 0) / 100
    if p < 0.05 then p = 0.05 end
    local speed = MAX_SPEED * p
    cue.vx = math.cos(aim) * speed
    cue.vy = math.sin(aim) * speed
    sim.moving = true
    sim.last_shot_pots  = {}
    sim.last_shot_first = nil
end

-- ---------------------------------------------------------------------
-- Simple AI
-- ---------------------------------------------------------------------

-- Pick the easiest legal shot. "Easy" here means: own-group ball with
-- the largest dot(cue->ball, ball->pocket) score among all
-- (target, pocket) pairs, ignoring obstacles. Power scales 60-90% of
-- the alignment quality so a poorly-aligned shot also shoots softer.
local function ai_choose_shot(sim)
    local cue = sim.balls[1]
    local cur_grp = group_for_player(sim, sim.turn)
    local rem = cur_grp ~= 0 and group_remaining(sim, cur_grp) or 1
    -- "Open table" or cleared own group -> aim at the 8.
    local target_grp = cur_grp
    if cur_grp == 0 then target_grp = 0 end
    if rem == 0 then target_grp = 8 end

    local best_score = -math.huge
    local best_aim, best_target_id
    for _, b in ipairs(sim.balls) do
        if not b.pocketed and b.id ~= CUE_ID then
            local g = group_of(b.id)
            -- Filter to legal targets.
            local legal = (target_grp == 0)        -- table open
                or (target_grp == 8 and g == 8)
                or (target_grp ~= 8 and g == target_grp)
            if legal then
                for _, p in ipairs(POCKETS) do
                    -- Vectors cue->ball and ball->pocket.
                    local cbx, cby = b.x - cue.x, b.y - cue.y
                    local bpx, bpy = p.x - b.x, p.y - b.y
                    local cb_len = math.sqrt(cbx*cbx + cby*cby)
                    local bp_len = math.sqrt(bpx*bpx + bpy*bpy)
                    if cb_len > 1 and bp_len > 1 then
                        local dot = (cbx*bpx + cby*bpy) / (cb_len * bp_len)
                        if dot > 0 then
                            -- Aim slightly behind the target: cue
                            -- contact point is BALL_R*2 along the
                            -- cue->ball line offset by the pocket
                            -- direction.
                            local tx = b.x - bpx / bp_len * BALL_R * 2
                            local ty = b.y - bpy / bp_len * BALL_R * 2
                            local aim = math.atan(ty - cue.y, tx - cue.x)
                            -- Score: prefer high alignment AND short
                            -- ball->pocket distance (closer is easier).
                            local score = dot * 1000 - bp_len
                            if score > best_score then
                                best_score = score
                                best_aim   = aim
                                best_target_id = b.id
                            end
                        end
                    end
                end
            end
        end
    end

    if not best_aim then
        -- No legal shot found (every target blocked from every pocket
        -- by the dot-product test). Just smack toward the rack.
        best_aim = math.atan(
            TABLE_Y + TABLE_H/2 - cue.y,
            TABLE_X + TABLE_W*0.65 - cue.x)
        best_score = 0
    end

    -- Power 60-90% scaled by alignment quality. dot near 1 = aligned;
    -- normalise the score back to dot for the power decision.
    local quality = 0.7
    if best_target_id then
        -- Re-derive dot for the chosen pair.
        local b = find_ball(sim, best_target_id)
        local cbx, cby = b.x - cue.x, b.y - cue.y
        local cb_len = math.sqrt(cbx*cbx + cby*cby)
        local px, py = b.x + math.cos(best_aim) * 1000, b.y + math.sin(best_aim) * 1000
        local nx, ny = px - b.x, py - b.y
        local nl = math.sqrt(nx*nx + ny*ny)
        if cb_len > 1 and nl > 1 then
            quality = math.max(0, math.min(1, (cbx*nx + cby*ny) / (cb_len * nl)))
        end
    end
    local power = 60 + math.floor(quality * 30)
    return best_aim, power
end

-- ---------------------------------------------------------------------
-- Renderer
-- ---------------------------------------------------------------------

local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

-- Ball palette. Solids/stripes use the same hues; stripes get a
-- dimmer interior + accent ring drawn on top.
local function ball_color(id)
    if id == CUE_ID then return rgb(240, 240, 240) end
    if id == EIGHT  then return rgb(20,  20,  20)  end
    local hues = {
        rgb(220, 200, 30),   -- 1 yellow
        rgb(40,  90,  220),  -- 2 blue
        rgb(220, 40,  40),   -- 3 red
        rgb(140, 60,  220),  -- 4 purple
        rgb(220, 110, 40),   -- 5 orange
        rgb(40,  150, 60),   -- 6 green
        rgb(140, 30,  30),   -- 7 maroon
    }
    if id <= 7 then return hues[id] end
    return hues[id - 8]      -- stripes share the solid colour
end

local floor = math.floor

node.register("pool_field", {
    measure = function(n, max_w, max_h)
        return max_w, TABLE_Y + TABLE_H + POWER_BAR_H + 26
    end,
    draw = function(n, d, x, y, w, h)
        local sim = n.sim
        if not sim then return end

        local view = n.view or {}    -- aim, power, charging, in_hand_drag

        -- HUD strip.
        theme.set_font("tiny_aa")
        d.fill_rect(x, y, w, 18, theme.color("SURFACE"))
        local cur_grp = group_for_player(sim, sim.turn)
        local grp_name = (cur_grp == 1) and "solids"
                       or (cur_grp == 2) and "stripes"
                       or (cur_grp == 8) and "8-ball"
                       or "open"
        local p1 = "P1: " .. sim.p1_pot .. "/7"
        local p2 = "P2: " .. sim.p2_pot .. "/7"
        d.draw_text(x + 6, y + 4, p1, theme.color("TEXT"))
        d.draw_text(x + w - theme.text_width(p2) - 6, y + 4, p2,
            theme.color("TEXT"))
        local mid = "Turn: P" .. sim.turn .. " (" .. grp_name .. ")"
        local mw = theme.text_width(mid)
        d.draw_text(x + floor((w - mw) / 2), y + 4, mid,
            theme.color("ACCENT"))

        -- Table felt.
        local tx0 = x + TABLE_X
        local ty0 = y + TABLE_Y
        d.fill_rect(tx0, ty0, TABLE_W, TABLE_H, rgb(20, 80, 50))
        -- Inner cushion border.
        d.draw_rect(tx0 + CUSHION - 1, ty0 + CUSHION - 1,
            TABLE_W - (CUSHION - 1) * 2, TABLE_H - (CUSHION - 1) * 2,
            rgb(70, 40, 20))
        -- Outer rail.
        d.draw_rect(tx0, ty0, TABLE_W, TABLE_H, rgb(120, 70, 30))
        d.draw_rect(tx0 - 1, ty0 - 1, TABLE_W + 2, TABLE_H + 2,
            theme.color("BORDER"))

        -- Pockets.
        for _, p in ipairs(POCKETS) do
            d.fill_circle(x + floor(p.x), y + floor(p.y),
                POCKET_R, rgb(0, 0, 0))
        end

        -- Balls.
        for _, b in ipairs(sim.balls) do
            if not b.pocketed then
                local bx = x + floor(b.x)
                local by = y + floor(b.y)
                d.fill_circle(bx, by, BALL_R, ball_color(b.id))
                -- Stripe band: a thinner inner stripe in white across
                -- balls 9-15.
                if b.id > 8 and b.id <= 15 then
                    d.fill_rect(bx - BALL_R, by - 1,
                        BALL_R * 2 + 1, 2, rgb(240, 240, 240))
                end
                -- Cue ball outline: a 1-px white ring already, but the
                -- felt is dark so add a subtle border so the ball
                -- doesn't blend in.
                if b.id == CUE_ID then
                    d.draw_circle(bx, by, BALL_R, rgb(180, 180, 180))
                end
            end
        end

        -- Aim indicator: dashed line from cue ball along the aim
        -- vector, length scaled by current power.
        local cue = sim.balls[1]
        if not cue.pocketed and not sim.moving and view.aim
                and sim.flags & 1 == 0 then
            local len = 30 + (view.power or 30) * 0.6
            local cx = x + floor(cue.x)
            local cy = y + floor(cue.y)
            local ex = cx + math.cos(view.aim) * len
            local ey = cy + math.sin(view.aim) * len
            -- Dashed: 4 px on, 3 px off. Bindings expect integer
            -- coords -- floats raise "number has no integer
            -- representation" mid-frame and blank the screen.
            local cosA = math.cos(view.aim)
            local sinA = math.sin(view.aim)
            local steps = floor(len / 7)
            for i = 0, steps - 1 do
                local t0 = i * 7 / len
                local t1 = math.min(1, (i * 7 + 4) / len)
                d.draw_line(
                    floor(cx + cosA * len * t0),
                    floor(cy + sinA * len * t0),
                    floor(cx + cosA * len * t1),
                    floor(cy + sinA * len * t1),
                    theme.color("ACCENT"))
            end
            d.fill_rect(floor(ex) - 1, floor(ey) - 1, 3, 3,
                theme.color("ACCENT"))
        end

        -- Power meter.
        local meter_y = ty0 + TABLE_H + 6
        d.draw_rect(tx0, meter_y, POWER_BAR_W, POWER_BAR_H,
            theme.color("BORDER"))
        local pct = (view.power or 0) / 100
        if pct > 0 then
            d.fill_rect(tx0 + 1, meter_y + 1,
                floor((POWER_BAR_W - 2) * pct), POWER_BAR_H - 2,
                view.charging and theme.color("ACCENT")
                              or theme.color("TEXT_MUTED"))
        end

        -- Status line (under power meter).
        theme.set_font("tiny_aa")
        local msg = sim.message or ""
        if sim.in_hand then
            msg = msg .. " -- arrows to place cue, Enter to confirm"
        end
        local mh_w = theme.text_width(msg)
        d.draw_text(x + floor((w - mh_w) / 2),
            meter_y + POWER_BAR_H + 4, msg, theme.color("TEXT_MUTED"))
    end,
})

-- ---------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------

local MODE_MENU = "menu"
local MODE_1P   = "1p"
local MODE_HOST = "host"
local MODE_JOIN = "join"

-- WiFi shared parameters (same shape as pong).
local SSID = "tdeck-pool"
local PASS = "poolpool"
local PORT = 4245

local Pool = { title = "Pool" }

function Pool.initial_state()
    return {
        mode      = MODE_MENU,
        sim       = nil,         -- authoritative simulation (1P + host)
        remote    = nil,         -- last decoded snapshot (client only)
        net_state = "idle",
        status    = "",
        view      = {            -- input-side display state
            aim       = 0,
            power     = 0,
            charging  = false,
        },
        tick      = 0,
    }
end

-- Local-mode shared init: spawn sim and start the simulation tick.
local function start_local_or_host(self, mode)
    self._sim = new_sim()
    self._view = { aim = 0, power = 0, charging = false }
    self:set_state({
        mode = mode,
        sim  = self._sim,
        view = self._view,
        tick = 0,
        net_state = (mode == MODE_HOST) and "starting" or "idle",
    })

    -- Client-input cache (host only). Aim from the remote player.
    self._client_input = { aim = 0, power = 0, shoot = false }
    self._client_addr  = nil
    self._client_port  = nil

    -- AI-step deferral (1P only). When it's the AI's turn we wait for
    -- the table to settle, queue a shot, and pause briefly so the
    -- player can register that the AI is "thinking".
    self._ai_pending  = false
    self._ai_delay_ms = 0

    self._tick_timer = ez.system.set_interval(TICK_MS, function()
        local sim = self._sim

        -- Drain client input (host mode only).
        if mode == MODE_HOST and self._udp then
            while true do
                local data, ip, port = ez.net.udp_recv(self._udp)
                if not data then break end
                local inp = decode_input(data)
                if inp then
                    self._client_input.aim   = inp.aim
                    self._client_input.power = inp.power
                    -- Record the most recent shoot edge; we consume it
                    -- below when balls are stopped and it's P2's turn.
                    if inp.shoot then
                        self._client_input.shoot = true
                    end
                    if not self._client_addr then
                        self._client_addr = ip
                        self._client_port = port
                        self:set_state({
                            net_state = "playing",
                            status    = "Connected: " .. ip,
                        })
                    end
                end
            end
        end

        if sim.moving then
            local still = step_physics(sim)
            if not still then
                sim.moving = false
                resolve_shot(sim)
            end
            -- Broadcast snapshot to the client every tick during motion
            -- so its render stays in lockstep with the sim.
            if mode == MODE_HOST and self._udp and self._client_addr then
                ez.net.udp_send(self._udp, self._client_addr,
                    self._client_port, encode_state(sim))
            end
            screen_mod.invalidate()
            return
        end

        -- Idle (between shots). Apply queued shoot intents.
        if mode == MODE_1P and sim.turn == 2
                and sim.flags & 1 == 0 and not sim.moving then
            -- AI turn. Wait a beat, then pick a shot and apply it.
            if not self._ai_pending then
                self._ai_pending  = true
                self._ai_delay_ms = 600
            else
                self._ai_delay_ms = self._ai_delay_ms - TICK_MS
                if self._ai_delay_ms <= 0 then
                    -- Ball-in-hand: AI just nudges the cue toward the
                    -- centre line before shooting. Real CPU pool would
                    -- search for the best placement; this is fine for
                    -- a casual game.
                    if sim.in_hand then
                        local cue = sim.balls[1]
                        cue.x = TABLE_X + TABLE_W * 0.25
                        cue.y = TABLE_Y + TABLE_H * 0.5
                        sim.in_hand = false
                    end
                    local aim, pwr = ai_choose_shot(sim)
                    self._view.aim   = aim
                    self._view.power = pwr
                    apply_shot(sim, aim, pwr)
                    self._ai_pending = false
                    self:set_state({
                        view = self._view,
                        tick = (self._state.tick or 0) + 1,
                    })
                end
            end
        elseif mode == MODE_HOST and sim.turn == 2
                and self._client_input.shoot
                and sim.flags & 1 == 0 and not sim.moving then
            -- Consume the client's shoot edge.
            self._client_input.shoot = false
            -- Client doesn't yet support ball-in-hand placement; if a
            -- foul is pending we just plonk the cue back on the head
            -- spot so play continues.
            if sim.in_hand then
                local cue = sim.balls[1]
                cue.x = TABLE_X + TABLE_W * 0.25
                cue.y = TABLE_Y + TABLE_H * 0.5
                sim.in_hand = false
            end
            apply_shot(sim, self._client_input.aim,
                math.max(10, math.min(100, self._client_input.power)))
            self:set_state({ tick = (self._state.tick or 0) + 1 })
        end

        -- Even idle, broadcast every few ticks so a freshly joined
        -- client doesn't sit on a stale frame.
        if mode == MODE_HOST and self._udp and self._client_addr then
            ez.net.udp_send(self._udp, self._client_addr,
                self._client_port, encode_state(sim))
        end
        screen_mod.invalidate()
    end)
end

local function start_host(self)
    self:set_state({ mode = MODE_HOST, status = "Starting AP...",
                     net_state = "starting" })
    spawn(function()
        local ok = ez.wifi.start_ap(SSID, PASS, 1, false, 2)
        if not ok then
            self:set_state({ status = "AP failed", net_state = "idle" })
            return
        end
        local udp = ez.net.udp_open(PORT)
        if not udp then
            ez.wifi.stop_ap()
            self:set_state({ status = "UDP open failed", net_state = "idle" })
            return
        end
        self._udp = udp
        start_local_or_host(self, MODE_HOST)
        self:set_state({ status = "Waiting on '" .. SSID .. "'" })
    end)
end

local function start_join(self)
    self:set_state({ mode = MODE_JOIN,
                     status = "Joining " .. SSID .. "...",
                     net_state = "starting" })
    spawn(function()
        ez.wifi.connect(SSID, PASS)
        local up = false
        for _ = 1, 5 do
            up = ez.wifi.wait_connected(4)
            if up then break end
            ez.wifi.disconnect()
            local wake_at = ez.system.millis() + 1500
            while ez.system.millis() < wake_at do defer() end
        end
        if not up then
            self:set_state({ status = "Could not join AP",
                             net_state = "idle" })
            return
        end
        local gw = ez.wifi.get_gateway()
        if not gw or gw == "0.0.0.0" then
            self:set_state({ status = "No gateway",
                             net_state = "idle" })
            return
        end
        local udp = ez.net.udp_open(0)
        if not udp then
            self:set_state({ status = "UDP open failed",
                             net_state = "idle" })
            return
        end
        self._udp = udp
        self._gw  = gw
        self._view = { aim = 0, power = 0, charging = false }
        self._seq = 0
        self._shoot_pending = false
        self:set_state({
            status    = "Connected to " .. gw,
            net_state = "playing",
            view      = self._view,
            tick      = 0,
        })

        -- Input timer: send aim + power + shoot edge at ~20 Hz.
        self._input_timer = ez.system.set_interval(50, function()
            self._seq = (self._seq + 1) & 0xFFFF
            local shoot = self._shoot_pending
            self._shoot_pending = false
            ez.net.udp_send(self._udp, self._gw, PORT,
                encode_input(self._view.aim,
                    math.floor(self._view.power),
                    shoot, self._seq))
        end)

        -- Render timer: drain incoming snapshots, replace remote.
        self._render_timer = ez.system.set_interval(TICK_MS, function()
            while true do
                local data = ez.net.udp_recv(self._udp)
                if not data then break end
                local snap = decode_state(data)
                if snap then
                    -- Convert snapshot back into a shape the renderer
                    -- understands (it expects sim.balls[].x / y / etc).
                    local sim = self._state.remote or { balls = {} }
                    sim.turn   = snap.turn
                    sim.ball_on= snap.ball_on
                    sim.p1_pot = snap.p1_pot
                    sim.p2_pot = snap.p2_pot
                    sim.flags  = snap.flags
                    sim.balls  = snap.balls
                    sim.message= "Player " .. snap.turn .. " to shoot"
                    sim.moving = false
                    self._state.remote = sim
                end
            end
            screen_mod.invalidate()
        end)
    end)
end

local function shutdown_host(self)
    if self._tick_timer then
        ez.system.cancel_timer(self._tick_timer); self._tick_timer = nil
    end
    if self._udp then ez.net.udp_close(self._udp); self._udp = nil end
    ez.wifi.stop_ap()
end

local function shutdown_join(self)
    if self._input_timer then
        ez.system.cancel_timer(self._input_timer); self._input_timer = nil
    end
    if self._render_timer then
        ez.system.cancel_timer(self._render_timer); self._render_timer = nil
    end
    if self._udp then ez.net.udp_close(self._udp); self._udp = nil end
    ez.wifi.disconnect()
end

local function shutdown_local(self)
    if self._tick_timer then
        ez.system.cancel_timer(self._tick_timer); self._tick_timer = nil
    end
end

function Pool:on_exit()
    if self._state.mode == MODE_1P   then shutdown_local(self)
    elseif self._state.mode == MODE_HOST then shutdown_host(self)
    elseif self._state.mode == MODE_JOIN then shutdown_join(self)
    end
end

function Pool:build(state)
    if state.mode == MODE_MENU then
        return ui.vbox({ gap = 0, bg = "BG" }, {
            ui.title_bar("Pool", { back = true }),
            ui.padding({ 16, 18, 4, 18 },
                ui.text_widget("8-ball pool.", {
                    color = "TEXT_SEC", font = "small_aa",
                    text_align = "center" })),
            ui.padding({ 4, 18, 4, 18 },
                ui.text_widget(
                    "Arrows / trackball to aim, hold Enter to charge "
                    .. "power, release to shoot. Backspace to quit.",
                    { color = "TEXT_MUTED", font = "tiny_aa",
                      text_align = "center", wrap = true })),
            ui.padding({ 12, 40, 6, 40 },
                ui.button("1 Player (vs AI)", {
                    on_press = function()
                        start_local_or_host(self, MODE_1P)
                    end })),
            ui.padding({ 4, 40, 6, 40 },
                ui.button("2P WiFi: Host", {
                    on_press = function() start_host(self) end })),
            ui.padding({ 4, 40, 6, 40 },
                ui.button("2P WiFi: Join", {
                    on_press = function() start_join(self) end })),
        })
    end

    local sim = (state.mode == MODE_JOIN) and state.remote or self._sim
    local view = self._view or state.view or {}
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Pool", { back = true }),
        { type = "pool_field", sim = sim, view = view },
    })
end

-- Aim/power input shared by 1P and Host. Join uses the same path but
-- doesn't run the simulation locally -- the host owns turn ownership,
-- so allowing the joiner to "shoot" simply sends a shoot intent.
function Pool:handle_key(key)
    -- Always allow back-out, even mid-shot.
    if key.special == "BACKSPACE" or key.special == "ESCAPE"
            or (key.character == "q" and not key.alt) then
        return "pop"
    end
    if self._state.mode == MODE_MENU then return nil end

    -- During motion, ignore most keys -- the player is watching the
    -- shot resolve.
    local sim_local = (self._state.mode == MODE_JOIN)
        and self._state.remote or self._sim
    if not sim_local or sim_local.flags and (sim_local.flags & 1 ~= 0) then
        if key.special == "ENTER" then
            -- Game over: Enter starts a new rack (1P / Host).
            if self._state.mode == MODE_1P or self._state.mode == MODE_HOST then
                self._sim = new_sim()
                self._view = { aim = 0, power = 0, charging = false }
                self:set_state({
                    sim = self._sim, view = self._view,
                    tick = (self._state.tick or 0) + 1,
                })
            end
            return "handled"
        end
        return nil
    end

    -- Whose input matters this turn?
    local my_turn
    if self._state.mode == MODE_1P then
        my_turn = sim_local.turn == 1
    elseif self._state.mode == MODE_HOST then
        my_turn = sim_local.turn == 1
    else
        my_turn = sim_local.turn == 2
    end
    if not my_turn or sim_local.moving then return nil end

    local view = self._view
    local AIM_STEP = key.alt and 0.005 or 0.05    -- alt = fine

    -- Ball-in-hand placement uses arrows to drag the cue.
    if (self._state.mode == MODE_1P or self._state.mode == MODE_HOST)
            and sim_local.in_hand then
        local cue = sim_local.balls[1]
        local PLACE_STEP = 4
        if key.special == "LEFT" then
            cue.x = math.max(PLAY_X0 + BALL_R, cue.x - PLACE_STEP)
            screen_mod.invalidate(); return "handled"
        elseif key.special == "RIGHT" then
            cue.x = math.min(PLAY_X1 - BALL_R, cue.x + PLACE_STEP)
            screen_mod.invalidate(); return "handled"
        elseif key.special == "UP" then
            cue.y = math.max(PLAY_Y0 + BALL_R, cue.y - PLACE_STEP)
            screen_mod.invalidate(); return "handled"
        elseif key.special == "DOWN" then
            cue.y = math.min(PLAY_Y1 - BALL_R, cue.y + PLACE_STEP)
            screen_mod.invalidate(); return "handled"
        elseif key.special == "ENTER" then
            sim_local.in_hand = false
            screen_mod.invalidate(); return "handled"
        end
    end

    if key.special == "LEFT" then
        view.aim = view.aim - AIM_STEP
        screen_mod.invalidate(); return "handled"
    elseif key.special == "RIGHT" then
        view.aim = view.aim + AIM_STEP
        screen_mod.invalidate(); return "handled"
    elseif key.special == "UP" then
        view.aim = view.aim - AIM_STEP
        screen_mod.invalidate(); return "handled"
    elseif key.special == "DOWN" then
        view.aim = view.aim + AIM_STEP
        screen_mod.invalidate(); return "handled"
    elseif key.special == "ENTER" or key.character == " " then
        -- Two-tap power: first ENTER picks the power level, next ENTER
        -- shoots. We use a charging timer tied to wall clock so the
        -- bar fills smoothly even though we don't get key-up events.
        if not view.charging then
            view.charging  = true
            view.power     = 0
            view._charge_t = ez.system.millis()
            view._charge_timer = ez.system.set_interval(33, function()
                if not view.charging then return end
                local elapsed = ez.system.millis() - view._charge_t
                local p = math.floor(elapsed / CHARGE_TIME * 100)
                if p > 100 then p = 100 end
                view.power = p
                screen_mod.invalidate()
                if p >= 100 then
                    -- Auto-fire at full power so the meter doesn't sit
                    -- pegged forever waiting for the player.
                    view.charging = false
                    if view._charge_timer then
                        ez.system.cancel_timer(view._charge_timer)
                        view._charge_timer = nil
                    end
                    if self._state.mode == MODE_JOIN then
                        self._shoot_pending = true
                    else
                        apply_shot(sim_local, view.aim, view.power)
                    end
                end
            end)
        else
            view.charging = false
            if view._charge_timer then
                ez.system.cancel_timer(view._charge_timer)
                view._charge_timer = nil
            end
            if view.power < 5 then view.power = 5 end
            if self._state.mode == MODE_JOIN then
                self._shoot_pending = true
            else
                apply_shot(sim_local, view.aim, view.power)
            end
            screen_mod.invalidate()
        end
        return "handled"
    end
    return nil
end

return Pool
