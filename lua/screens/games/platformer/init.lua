-- Platformer game with twelve hand-built levels across four
-- environments (forest, cave, ice, volcano). Single-player by default
-- with an optional 2P co-op mode over WiFi (SoftAP + UDP, mirroring
-- the pong netcode shape).
--
-- State machine:
--   "lobby"    Pick mode. Single player or P1 (host) / P2 (join).
--   "playing"  Active level. Host runs sim; client thin-renders.
--   "won"      Level cleared. Banner + space to advance.
--   "dead"     Run lost (lives gone). Banner + space to restart.
--   "all_done" All levels cleared. Banner + space to restart.
--   "lost_link" 2P link dropped. Banner + space to abort.
--
-- Input model:
--   LEFT/RIGHT  walk
--   UP / SPACE  jump (UP feels right next to LEFT/RIGHT on a T-Deck)
--   ENTER       confirm banners / lobby choices
--   Q / ESC     pop back to the games menu (also stops the AP/socket)

local screen_mod = require("ezui.screen")
local theme      = require("ezui.theme")
local node_mod   = require("ezui.node")
local engine     = require("screens.games.platformer.engine")
local levels_mod = require("screens.games.platformer.levels")
local net        = require("screens.games.platformer.netplay")

local Plat = {
    title = "Platformer",
    fullscreen = true,
}

-- ---------------------------------------------------------------------------
-- Run state — module-level so both update() and the custom render node
-- read the same authoritative copy without round-tripping through
-- set_state (which would trigger a tree rebuild every frame at 30 FPS,
-- the same trick pong uses).
-- ---------------------------------------------------------------------------

local STARTING_LIVES = 3

local mode          -- "lobby" | "playing" | "won" | "dead" | "all_done" | "lost_link"
local lobby_idx     -- 1=Single, 2=Host, 3=Join
local role          -- "single" | "host" | "client"
local level_idx     -- 1..#LEVELS
local lives
local world         -- engine world (host + single player only)
local remote_state  -- snapshot from the host for client rendering
local mode_timer    -- frames since entering current mode (for banners)

-- Input held this frame (set by handle_key, read by update()).
local input_state = { left = false, right = false, jump = false }
-- Keys are sticky in this firmware: there's no key-up event for chars,
-- so we drive movement via KEY_DOWN edges and clear on a per-frame
-- "no input received" fallback. Each LEFT/RIGHT press latches for
-- ~3 frames so a single tap moves the player a noticeable distance
-- without a release event.
local input_decay = { left = 0, right = 0 }
local INPUT_DECAY_FRAMES = 4

-- Networking handles.
local sock          -- UDP socket (host or client side)
local client_addr   -- host: address of the joined client (ip, port)
local host_ip       -- client: gateway/host IP we send input to
local last_seq      -- client: outgoing seq counter
local last_state_ms -- client: ms timestamp of the most recent state packet
local LINK_TIMEOUT_MS = 4000

-- ---------------------------------------------------------------------------
-- Lifecycle helpers
-- ---------------------------------------------------------------------------

local function start_level(idx)
    level_idx = idx
    local L, err = engine.load_level(idx)
    if not L then
        ez.log("[platformer] level load failed: " .. tostring(err))
        mode = "all_done"
        return
    end
    local n_players = (role == "single") and 1 or 2
    world = engine.new_world(L, n_players)
    mode = "playing"
    mode_timer = 0
end

local function reset_run()
    lives = STARTING_LIVES
    start_level(1)
end

local function lose_life()
    lives = lives - 1
    if lives <= 0 then
        mode = "dead"
        mode_timer = 0
    else
        -- Re-spawn at the start of the same level, keeping enemies
        -- fresh. Cheaper than checkpoints and reads as forgiving.
        start_level(level_idx)
    end
end

local function teardown_net()
    if role == "host" then
        net.host_stop(sock)
    elseif role == "client" then
        net.client_stop(sock)
    end
    sock = nil
    client_addr = nil
    host_ip = nil
end

-- ---------------------------------------------------------------------------
-- Network: host side
--   Each tick:
--     1. Drain any input packets in the recv queue, latch the latest as
--        player 2's intent.
--     2. Run engine.step with [P1 input from local keys, P2 input from net].
--     3. Broadcast world state to the client.
-- ---------------------------------------------------------------------------

local p2_input = { left = false, right = false, jump = false }
local p2_jump_edge = false  -- set on rising edge of bit2; cleared each tick

local function host_drain_inputs()
    if not sock then return end
    while true do
        local data, from_ip, from_port = ez.net.udp_recv(sock)
        if not data then break end
        local pkt = net.decode_input(data)
        if pkt then
            client_addr = client_addr or { ip = from_ip, port = from_port }
            p2_input.left  = (pkt.buttons & 0x01) ~= 0
            p2_input.right = (pkt.buttons & 0x02) ~= 0
            local jump_held = (pkt.buttons & 0x04) ~= 0
            -- Edge-detect the jump bit so a held button doesn't fire a
            -- new jump every frame (the engine already buffers + uses
            -- coyote, but it expects a one-frame "request").
            if jump_held and not p2_input._jump_held_prev then
                p2_jump_edge = true
            end
            p2_input._jump_held_prev = jump_held
        end
    end
end

local function host_broadcast_state()
    if not (sock and client_addr and world) then return end
    local pkt = net.encode_state(world)
    pcall(ez.net.udp_send, sock, client_addr.ip, client_addr.port, pkt)
end

-- ---------------------------------------------------------------------------
-- Network: client side
-- ---------------------------------------------------------------------------

local function client_send_input()
    if not (sock and host_ip) then return end
    local b = 0
    if input_state.left  then b = b | 0x01 end
    if input_state.right then b = b | 0x02 end
    if input_state.jump  then b = b | 0x04 end
    last_seq = (last_seq or 0) + 1
    local pkt = net.encode_input(b, last_seq & 0xFFFF)
    pcall(ez.net.udp_send, sock, host_ip, net.PORT, pkt)
end

local function client_drain_state()
    if not sock then return end
    while true do
        local data = ez.net.udp_recv(sock)
        if not data then break end
        local s = net.decode_state(data)
        if s then
            -- Level transitions from the host: load the matching local
            -- level so our renderer has tile data.
            if s.level_idx ~= (remote_state and remote_state.level_idx) then
                local L = engine.load_level(s.level_idx)
                if L then s._level = L end
            else
                s._level = remote_state and remote_state._level
            end
            remote_state = s
            last_state_ms = ez.system.millis()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Per-frame update
-- ---------------------------------------------------------------------------

local function decay_input()
    if input_decay.left > 0 then
        input_decay.left = input_decay.left - 1
        input_state.left = input_decay.left > 0
    end
    if input_decay.right > 0 then
        input_decay.right = input_decay.right - 1
        input_state.right = input_decay.right > 0
    end
end

function Plat:update()
    mode_timer = (mode_timer or 0) + 1

    if mode == "playing" then
        decay_input()

        if role == "single" then
            local local_input = {
                left  = input_state.left,
                right = input_state.right,
                jump  = input_state.jump,
            }
            input_state.jump = false
            engine.step(world, { local_input })
        elseif role == "host" then
            host_drain_inputs()
            local p1 = {
                left  = input_state.left,
                right = input_state.right,
                jump  = input_state.jump,
            }
            input_state.jump = false
            local p2 = {
                left  = p2_input.left,
                right = p2_input.right,
                jump  = p2_jump_edge,
            }
            p2_jump_edge = false
            engine.step(world, { p1, p2 })
            host_broadcast_state()
        elseif role == "client" then
            client_drain_state()
            client_send_input()
            input_state.jump = false  -- consume the edge

            if last_state_ms
               and ez.system.millis() - last_state_ms > LINK_TIMEOUT_MS then
                mode = "lost_link"
                mode_timer = 0
            end
        end

        -- Single-player + host transition logic. The client's local
        -- mode tracks the host via remote_state.won/any_dead; we read
        -- that in render and let the user trigger advancement with
        -- ENTER like the local game.
        if role ~= "client" and world then
            if world.won then
                mode = "won"
                mode_timer = 0
            elseif world.any_dead and lives ~= nil then
                lose_life()
            end
        elseif role == "client" and remote_state then
            if remote_state.won then
                mode = "won"
                mode_timer = 0
            end
        end
    end

    screen_mod.invalidate()
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function fmt_hud()
    local env_label = world and world.level and world.level.env or ""
    return {
        left = string.format("L%d  %s  Lives %d", level_idx,
            env_label:sub(1,1):upper() .. env_label:sub(2),
            lives or 0),
        right = (role == "host") and "P1+P2"
             or (role == "client") and "P2"
             or "",
    }
end

-- Render a "fake world" for the client side using only the snapshot from
-- the host. Reuses engine.render by constructing a minimal world-shaped
-- table that points at the locally-loaded level + decoded entities.
local function render_client(d)
    if not (remote_state and remote_state._level) then
        d.fill_rect(0, 0, engine.SCREEN_W, engine.SCREEN_H, ez.display.rgb(20, 20, 30))
        theme.set_font("medium_aa")
        local s = "Waiting for host..."
        local tw = theme.text_width(s)
        d.draw_text((engine.SCREEN_W - tw) // 2,
                    engine.SCREEN_H // 2,
                    s, ez.display.rgb(220, 220, 230))
        return
    end
    local stub = {
        level    = remote_state._level,
        players  = remote_state.players,
        enemies  = remote_state.enemies,
        camera_x = remote_state.camera_x,
        won      = remote_state.won,
    }
    local hud = {
        left  = "L" .. tostring(remote_state.level_idx) .. "  P2",
        right = "Linked",
    }
    engine.render(d, stub, hud)
    if remote_state.won then
        engine.draw_banner(d, stub, "Level clear", "Wait for host or press SPACE")
    end
end

-- Lobby layout: three options. UP/DOWN moves the cursor, ENTER picks.
local function render_lobby(d)
    local pal = engine.colors("forest")
    d.fill_rect(0, 0, engine.SCREEN_W, engine.SCREEN_H, pal.bg)

    theme.set_font("medium_aa")
    local fh = theme.font_height()
    local title = "Platformer"
    local tw = theme.text_width(title)
    d.draw_text((engine.SCREEN_W - tw) // 2, 30, title, pal.hud_fg)

    theme.set_font("small_aa")
    local sub = "12 levels, 4 environments"
    local sw = theme.text_width(sub)
    d.draw_text((engine.SCREEN_W - sw) // 2, 30 + fh + 6, sub, pal.hud_dim)

    local options = {
        { title = "Single player",      sub = "" },
        { title = "Host (Player 1)",    sub = "Bring up Wi-Fi AP, wait for P2" },
        { title = "Join (Player 2)",    sub = "Connect to a Player 1 nearby" },
    }
    local row_h = 36
    local base_y = 100
    for i, opt in ipairs(options) do
        local y = base_y + (i - 1) * row_h
        if i == lobby_idx then
            d.fill_rect(20, y - 4, engine.SCREEN_W - 40, row_h - 6, pal.block)
            d.draw_rect(20, y - 4, engine.SCREEN_W - 40, row_h - 6, pal.block_edge)
            theme.set_font("medium_aa")
            d.draw_text(28, y, opt.title, pal.hud_fg)
            if opt.sub ~= "" then
                theme.set_font("tiny_aa")
                d.draw_text(28, y + 16, opt.sub, pal.hud_dim)
            end
        else
            theme.set_font("medium_aa")
            d.draw_text(28, y, opt.title, pal.hud_dim)
        end
    end

    theme.set_font("tiny_aa")
    local hint = "UP/DOWN choose, ENTER start, Q quit"
    local hw = theme.text_width(hint)
    d.draw_text((engine.SCREEN_W - hw) // 2,
                engine.SCREEN_H - 16, hint, pal.hud_dim)
end

if not node_mod.handler("platformer_view") then
    node_mod.register("platformer_view", {
        measure = function(n, max_w, max_h)
            return engine.SCREEN_W, engine.SCREEN_H
        end,
        draw = function(n, d, x, y, w, h)
            if mode == "lobby" then
                render_lobby(d)
                return
            end

            if role == "client" then
                render_client(d)
                if mode == "lost_link" then
                    engine.draw_banner({ level = { palette = engine.colors("cave") } },
                        nil, "Link lost", "Press SPACE to abort")
                end
                return
            end

            if not world then return end
            engine.render(d, world, fmt_hud())

            if mode == "won" then
                if level_idx >= #levels_mod.LEVELS then
                    engine.draw_banner(d, world, "All levels clear!",
                        "Press SPACE to play again")
                else
                    engine.draw_banner(d, world,
                        "Level " .. level_idx .. " clear",
                        "Press SPACE for L" .. (level_idx + 1))
                end
            elseif mode == "dead" then
                engine.draw_banner(d, world, "Game over",
                    "Press SPACE to restart")
            elseif mode == "all_done" then
                engine.draw_banner(d, world, "Run complete",
                    "Press SPACE to restart")
            end
        end,
    })
end

function Plat:build(state)
    return { type = "platformer_view" }
end

-- ---------------------------------------------------------------------------
-- Screen lifecycle
-- ---------------------------------------------------------------------------

function Plat:on_enter()
    mode = "lobby"
    lobby_idx = 1
    role = nil
    level_idx = 1
    lives = STARTING_LIVES
    world = nil
    remote_state = nil
    sock = nil
    client_addr = nil
    host_ip = nil
    last_seq = 0
    last_state_ms = nil
    input_state.left, input_state.right, input_state.jump = false, false, false
    input_decay.left, input_decay.right = 0, 0
end

function Plat:on_exit()
    teardown_net()
end

-- ---------------------------------------------------------------------------
-- Lobby actions
-- ---------------------------------------------------------------------------

local function start_single()
    role = "single"
    reset_run()
end

local function start_host()
    local s, err = net.host_start()
    if not s then
        ez.log("[platformer] host start failed: " .. tostring(err))
        return
    end
    sock = s
    role = "host"
    reset_run()
end

local function start_join()
    -- Show "connecting..." instantly so a stuck wait_connected isn't
    -- mistaken for a freeze. We push the lobby into a transient state
    -- by parking the role; render() will see role == "client" but
    -- world == nil and draw the waiting banner.
    role = "client"
    mode = "playing"  -- so render path goes to render_client
    screen_mod.invalidate()
    local s, gw, err = net.client_start(6)
    if not s then
        ez.log("[platformer] client start failed: " .. tostring(err))
        role = nil
        mode = "lobby"
        return
    end
    sock = s
    host_ip = gw
    last_state_ms = ez.system.millis()
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function Plat:handle_key(key)
    -- Universal back key.
    if key.character == "q" or key.character == "Q" or key.special == "ESCAPE" then
        teardown_net()
        return "pop"
    end

    if mode == "lobby" then
        if key.special == "UP"   then lobby_idx = math.max(1, lobby_idx - 1); return "handled" end
        if key.special == "DOWN" then lobby_idx = math.min(3, lobby_idx + 1); return "handled" end
        if key.special == "ENTER" or key.character == " " then
            if     lobby_idx == 1 then start_single()
            elseif lobby_idx == 2 then start_host()
            elseif lobby_idx == 3 then start_join()
            end
            return "handled"
        end
        return "handled"
    end

    -- Playing / banner state.
    if mode == "won" then
        if key.special == "ENTER" or key.character == " " then
            if level_idx >= #levels_mod.LEVELS then
                reset_run()
            else
                start_level(level_idx + 1)
            end
        end
        return "handled"
    elseif mode == "dead" or mode == "all_done" then
        if key.special == "ENTER" or key.character == " " then
            reset_run()
        end
        return "handled"
    elseif mode == "lost_link" then
        if key.special == "ENTER" or key.character == " " then
            teardown_net()
            mode = "lobby"
            role = nil
        end
        return "handled"
    end

    -- Movement. LEFT/RIGHT latch for INPUT_DECAY_FRAMES so the lack of
    -- key-up events doesn't make movement feel jittery on tap.
    if key.special == "LEFT" then
        input_state.left  = true
        input_state.right = false
        input_decay.left  = INPUT_DECAY_FRAMES
        input_decay.right = 0
        return "handled"
    elseif key.special == "RIGHT" then
        input_state.right = true
        input_state.left  = false
        input_decay.right = INPUT_DECAY_FRAMES
        input_decay.left  = 0
        return "handled"
    elseif key.special == "UP" or key.character == " " or key.special == "ENTER" then
        input_state.jump = true
        return "handled"
    end

    return "handled"
end

return Plat
