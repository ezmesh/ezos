-- Realtime multiplayer Pong over UDP.
--
-- One tdeck is Host (brings up a SoftAP + runs the authoritative game
-- simulation), the other is Join (associates with the AP and just sends
-- its paddle intent + renders whatever state the host broadcasts).
-- UDP is the right transport here: the simulation ticks at 30 Hz and a
-- single dropped datagram only stalls us by 33 ms, no head-of-line
-- blocking like TCP would cause.
--
-- Wire format (both directions fixed-length for tight decoding):
--   Client → Host:   [0x01][dir:int8][seq:u16 LE]
--     dir: -1 up, 0 still, +1 down
--   Host → Client:   [0x02][ball_x:i16 LE][ball_y:i16 LE]
--                    [left_y:i16 LE][right_y:i16 LE]
--                    [score_l:u8][score_r:u8][flags:u8]
--
-- No authentication, no encryption — the AP's fixed-shared WPA2 PSK is
-- the only barrier. Game lobby, not a secrets channel.

local ui         = require("ezui")
local screen_mod = require("ezui.screen")
local theme      = require("ezui.theme")
local node       = require("ezui.node")

-- Shared WiFi parameters. Hardcoded so two devices running this screen
-- can lobby up without any out-of-band key exchange.
local SSID       = "tdeck-pong"
local PASS       = "pongpong"
local PORT       = 4244

-- Field geometry.
--   Screen:       320 x 240
--   Status bar:    20 px (always on top)  → content area height 220
--   HUD header:    28 px (14 score + 14 status, rendered inside the node)
--   Play field:   192 px                   (= 220 - 28, so nothing clips)
-- Measure returns FIELD_H + HEADER_H so the parent vbox reserves the
-- full region; any mismatch between measure and the draw rectangle
-- meant the bottom paddle + ball were drawn off-screen.
local HEADER_H           = 28
local FIELD_X0           = 0
local FIELD_W,  FIELD_H  = 320, 192
local PADDLE_W, PADDLE_H = 4, 36
local PADDLE_X_L = FIELD_X0 + 8
local PADDLE_X_R = FIELD_X0 + FIELD_W - 8 - PADDLE_W
local BALL_SIZE  = 6

-- Speeds (pixels per tick at ~30 Hz).
local PADDLE_SPEED   = 4
local BALL_START_VX  = 2.4
local BALL_START_VY  = 1.4
local BALL_SPIN_BUMP = 1.06  -- velocity multiplier per paddle bounce

local TICK_INTERVAL_MS = 33
local INPUT_INTERVAL_MS = 50    -- client sends its direction at 20 Hz

-- ---------------------------------------------------------------------------
-- Packet codec
-- ---------------------------------------------------------------------------

local function pack_i16(v)
    v = math.floor(v)
    if v < 0 then v = v + 65536 end
    return string.char(v & 0xFF, (v >> 8) & 0xFF)
end
local function read_i16(s, o)
    local v = s:byte(o) + s:byte(o + 1) * 256
    if v >= 0x8000 then v = v - 0x10000 end
    return v
end
local function pack_u16(v) return string.char(v & 0xFF, (v >> 8) & 0xFF) end
local function read_u16(s, o) return s:byte(o) + s:byte(o + 1) * 256 end

local function encode_input(dir, seq)
    -- dir is an int in -1..1; cast to byte two's-complement.
    local b = dir < 0 and (dir + 256) or dir
    return string.char(0x01, b) .. pack_u16(seq)
end

local function encode_state(st)
    return string.char(0x02)
        .. pack_i16(st.ball.x)    .. pack_i16(st.ball.y)
        .. pack_i16(st.left_y)    .. pack_i16(st.right_y)
        .. string.char(st.score_l & 0xFF)
        .. string.char(st.score_r & 0xFF)
        .. string.char(st.flags  & 0xFF)
end

-- ---------------------------------------------------------------------------
-- Field renderer (custom node)
-- ---------------------------------------------------------------------------

-- The whole play area draws from a single live `state` reference that
-- the host mutates in place and the client overwrites from received
-- packets. Draw reads this every frame (screen_mod.invalidate() on
-- tick), so the state DOESN'T need to round-trip through set_state —
-- avoiding 30 tree rebuilds per second on a low-MHz device. Score and
-- status text are drawn into the field for the same reason; putting
-- them in a separate text widget would bind the strings at build time.
node.register("pong_field", {
    measure = function(n, max_w, max_h)
        return max_w, FIELD_H + HEADER_H
    end,
    draw = function(n, d, x, y, w, h)
        local s = n.state or {}
        local score_l = s.score_l or 0
        local score_r = s.score_r or 0
        local status  = n.status or ""
        local floor = math.floor

        -- HUD row: big score centered, status on the next line. The
        -- display bindings' fill_rect / draw_text are int-typed, so we
        -- floor every derived coordinate — the physics update pushes
        -- ball.x / left_y to floats once the simulation starts and an
        -- un-floored coord raises "number has no integer representation"
        -- in the middle of a frame, which silently blanks the screen.
        theme.set_font("medium_aa", "bold")
        local score_text = score_l .. "  -  " .. score_r
        local sw = theme.text_width(score_text)
        d.draw_text(x + floor((w - sw) / 2), y, score_text,
            theme.color("TEXT"))

        theme.set_font("tiny_aa")
        if status ~= "" then
            local stw = theme.text_width(status)
            d.draw_text(x + floor((w - stw) / 2), y + 14, status,
                theme.color("TEXT_MUTED"))
        end

        -- Field.
        local fy = y + HEADER_H
        d.fill_rect(x, fy, w, FIELD_H, theme.color("BG"))
        d.draw_rect(x, fy, w, FIELD_H, theme.color("BORDER"))

        -- Dashed center line.
        local cx = x + floor(w / 2)
        for yy = fy + 4, fy + FIELD_H - 8, 8 do
            d.fill_rect(cx, yy, 2, 4, theme.color("TEXT_MUTED"))
        end

        local fg = theme.color("TEXT")
        local half_paddle = floor(PADDLE_H / 2)
        local half_ball   = floor(BALL_SIZE / 2)

        -- Paddles (state uses paddle-center y).
        local ly = floor(s.left_y  or FIELD_H / 2)
        local ry = floor(s.right_y or FIELD_H / 2)
        d.fill_rect(x + (PADDLE_X_L - FIELD_X0),
                    fy + ly - half_paddle,
                    PADDLE_W, PADDLE_H, fg)
        d.fill_rect(x + (PADDLE_X_R - FIELD_X0),
                    fy + ry - half_paddle,
                    PADDLE_W, PADDLE_H, fg)

        -- Ball.
        local bx = floor(s.ball and s.ball.x or FIELD_W / 2)
        local by = floor(s.ball and s.ball.y or FIELD_H / 2)
        d.fill_rect(x + bx - half_ball,
                    fy + by - half_ball,
                    BALL_SIZE, BALL_SIZE, fg)
    end,
})

-- ---------------------------------------------------------------------------
-- Game state (host-side source of truth)
-- ---------------------------------------------------------------------------

local function reset_ball(st, direction)
    st.ball.x = FIELD_W / 2
    st.ball.y = FIELD_H / 2
    st.ball.vx = BALL_START_VX * (direction or (math.random(2) == 1 and 1 or -1))
    st.ball.vy = BALL_START_VY * (math.random(2) == 1 and 1 or -1)
end

local function new_game_state()
    local st = {
        ball    = { x = 0, y = 0, vx = 0, vy = 0 },
        left_y  = FIELD_H / 2,
        right_y = FIELD_H / 2,
        score_l = 0,
        score_r = 0,
        flags   = 0,
    }
    reset_ball(st, 1)
    return st
end

-- Step the host simulation one tick. `left_dir` / `right_dir` are -1/0/1.
local function step_sim(st, left_dir, right_dir)
    -- Paddles. Clamp to field so they never leave the visible play area.
    st.left_y  = math.max(PADDLE_H / 2,
                 math.min(FIELD_H - PADDLE_H / 2,
                          st.left_y  + left_dir  * PADDLE_SPEED))
    st.right_y = math.max(PADDLE_H / 2,
                 math.min(FIELD_H - PADDLE_H / 2,
                          st.right_y + right_dir * PADDLE_SPEED))

    -- Ball integration.
    st.ball.x = st.ball.x + st.ball.vx
    st.ball.y = st.ball.y + st.ball.vy

    -- Top / bottom wall reflect.
    if st.ball.y < BALL_SIZE / 2 then
        st.ball.y = BALL_SIZE / 2
        st.ball.vy = -st.ball.vy
    elseif st.ball.y > FIELD_H - BALL_SIZE / 2 then
        st.ball.y = FIELD_H - BALL_SIZE / 2
        st.ball.vy = -st.ball.vy
    end

    -- Left paddle collision. Checked when the ball crosses the paddle
    -- front face from the right; hitting the back is a "miss" and
    -- scored below. A small vx bump on each bounce keeps rallies from
    -- stalling forever with the ball caught between two paddles.
    local left_face = PADDLE_X_L + PADDLE_W
    if st.ball.vx < 0 and st.ball.x - BALL_SIZE / 2 <= left_face
            and st.ball.x - BALL_SIZE / 2 >= PADDLE_X_L - 2 then
        if math.abs(st.ball.y - st.left_y) <= PADDLE_H / 2 + BALL_SIZE / 2 then
            st.ball.x = left_face + BALL_SIZE / 2
            st.ball.vx = -st.ball.vx * BALL_SPIN_BUMP
            -- Reflect angle by paddle-hit offset for a little control.
            st.ball.vy = st.ball.vy
                + (st.ball.y - st.left_y) / (PADDLE_H / 2) * 1.2
        end
    end

    -- Right paddle collision, mirror of the above.
    local right_face = PADDLE_X_R
    if st.ball.vx > 0 and st.ball.x + BALL_SIZE / 2 >= right_face
            and st.ball.x + BALL_SIZE / 2 <= right_face + PADDLE_W + 2 then
        if math.abs(st.ball.y - st.right_y) <= PADDLE_H / 2 + BALL_SIZE / 2 then
            st.ball.x = right_face - BALL_SIZE / 2
            st.ball.vx = -st.ball.vx * BALL_SPIN_BUMP
            st.ball.vy = st.ball.vy
                + (st.ball.y - st.right_y) / (PADDLE_H / 2) * 1.2
        end
    end

    -- Scoring: ball fully past an edge.
    if st.ball.x < -BALL_SIZE then
        st.score_r = st.score_r + 1
        reset_ball(st, 1)
    elseif st.ball.x > FIELD_W + BALL_SIZE then
        st.score_l = st.score_l + 1
        reset_ball(st, -1)
    end
end

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

local MODE_MENU = "menu"
local MODE_HOST = "host"
local MODE_JOIN = "join"

local Pong = { title = "Pong" }

function Pong.initial_state()
    return {
        mode       = MODE_MENU,
        status     = "",
        sim        = nil,          -- game state (host only)
        remote     = nil,          -- last decoded state (client only)
        net_state  = "idle",       -- "starting" | "waiting" | "playing"
        key_dir    = 0,            -- local input from kb (-1, 0, 1)
        client_ip  = nil,          -- host-side: the one client's address
        client_port= nil,
        last_seq   = 0,
    }
end

-- Start a host session: bring up AP, open UDP, enter wait-for-client.
local function start_host(self)
    self:set_state({
        mode   = MODE_HOST,
        status = "Starting AP...",
        net_state = "starting",
    })
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
        self._sim = new_game_state()
        self:set_state({
            sim       = self._sim,
            status    = "Waiting for player 2 on '" .. SSID .. "'",
            net_state = "waiting",
        })

        -- Tick timer drives the authoritative simulation. Input comes
        -- from two sources: (a) the local key_dir for the host player,
        -- (b) the last received client_dir from the remote player.
        self._client_dir = 0
        self._tick_timer = ez.system.set_interval(TICK_INTERVAL_MS, function()
            -- Drain any pending client input first — keeps the remote
            -- paddle responsive even if we're behind a frame.
            while true do
                local data, from_ip, from_port = ez.net.udp_recv(self._udp)
                if not data then break end
                if #data >= 4 and data:byte(1) == 0x01 then
                    local b = data:byte(2)
                    local dir = (b > 127) and (b - 256) or b
                    self._client_dir = dir
                    -- Latch the client's address on first packet so
                    -- we know where to send the state back.
                    if not self._state.client_ip then
                        self._state.client_ip = from_ip
                        self._state.client_port = from_port
                        self:set_state({
                            status    = "Playing vs " .. from_ip,
                            net_state = "playing",
                        })
                    end
                end
            end

            if self._state.net_state == "playing" then
                step_sim(self._sim, self._state.key_dir, self._client_dir)
                -- Broadcast state. Fire and forget — if the client
                -- misses a packet the next tick's snapshot will
                -- overwrite it anyway.
                if self._state.client_ip then
                    ez.net.udp_send(self._udp, self._state.client_ip,
                        self._state.client_port, encode_state(self._sim))
                end
            end
            screen_mod.invalidate()
        end)
    end)
end

-- Start a client session: connect to AP, open UDP, start input + render.
local function start_client(self)
    self:set_state({
        mode   = MODE_JOIN,
        status = "Joining " .. SSID .. "...",
        net_state = "starting",
    })
    spawn(function()
        ez.wifi.connect(SSID, PASS)
        -- Same retry pattern as the file transfer client — ESP32 STA
        -- marks "not found" after a failed scan and won't auto-retry.
        local up = false
        for _ = 1, 5 do
            up = ez.wifi.wait_connected(4)
            if up then break end
            ez.wifi.disconnect()
            local wake_at = ez.system.millis() + 1500
            while ez.system.millis() < wake_at do defer() end
        end
        if not up then
            self:set_state({ status = "Could not join AP", net_state = "idle" })
            return
        end
        local gw = ez.wifi.get_gateway()
        if not gw or gw == "0.0.0.0" then
            self:set_state({ status = "No gateway", net_state = "idle" })
            return
        end
        local udp = ez.net.udp_open(0)
        if not udp then
            self:set_state({ status = "UDP open failed", net_state = "idle" })
            return
        end
        self._udp = udp
        self._gw  = gw
        self:set_state({
            status    = "Connected to " .. gw,
            net_state = "playing",
            remote    = new_game_state(),
        })

        self._seq = 0
        -- Input timer: send our paddle direction periodically.
        self._input_timer = ez.system.set_interval(INPUT_INTERVAL_MS, function()
            self._seq = (self._seq + 1) & 0xFFFF
            ez.net.udp_send(self._udp, self._gw, PORT,
                encode_input(self._state.key_dir, self._seq))
        end)

        -- Render timer: drain incoming state packets, update remote,
        -- invalidate so the tree rebuilds with the new state.
        self._render_timer = ez.system.set_interval(TICK_INTERVAL_MS, function()
            while true do
                local data = ez.net.udp_recv(self._udp)
                if not data then break end
                if #data >= 11 and data:byte(1) == 0x02 then
                    local r = self._state.remote
                    r.ball.x  = read_i16(data, 2)
                    r.ball.y  = read_i16(data, 4)
                    r.left_y  = read_i16(data, 6)
                    r.right_y = read_i16(data, 8)
                    r.score_l = data:byte(10)
                    r.score_r = data:byte(11)
                    r.flags   = data:byte(12) or 0
                end
            end
            screen_mod.invalidate()
        end)
    end)
end

local function shutdown_host(self)
    if self._tick_timer then
        ez.system.cancel_timer(self._tick_timer)
        self._tick_timer = nil
    end
    if self._udp then ez.net.udp_close(self._udp); self._udp = nil end
    ez.wifi.stop_ap()
end

local function shutdown_client(self)
    if self._input_timer then
        ez.system.cancel_timer(self._input_timer)
        self._input_timer = nil
    end
    if self._render_timer then
        ez.system.cancel_timer(self._render_timer)
        self._render_timer = nil
    end
    if self._udp then ez.net.udp_close(self._udp); self._udp = nil end
    ez.wifi.disconnect()
end

function Pong:build(state)
    if state.mode == MODE_MENU then
        return ui.vbox({ gap = 0, bg = "BG" }, {
            ui.title_bar("Pong", { back = true }),
            ui.padding({ 20, 20, 6, 20 },
                ui.text_widget("2-player Pong over WiFi.", {
                    color = "TEXT_SEC", font = "small_aa",
                    text_align = "center",
                })
            ),
            ui.padding({ 4, 20, 2, 20 },
                ui.text_widget(
                    "One tdeck hosts, one joins. Use UP / DOWN to move "
                    .. "your paddle.",
                    { color = "TEXT_MUTED", font = "tiny_aa",
                      text_align = "center", wrap = true })
            ),
            ui.padding({ 14, 40, 6, 40 },
                ui.button("Host", {
                    on_press = function() start_host(self) end,
                })
            ),
            ui.padding({ 4, 40, 6, 40 },
                ui.button("Join", {
                    on_press = function() start_client(self) end,
                })
            ),
        })
    end

    -- Playing (or in lobby-connect state). We reuse the same layout for
    -- host and client; the remote copy of the state is what the client
    -- renders, the authoritative one is what the host renders.
    local render_state
    if state.mode == MODE_HOST then
        render_state = self._sim
    else
        render_state = state.remote
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        { type = "pong_field", state = render_state, status = state.status },
    })
end

function Pong:handle_key(key)
    -- Paddle control. Keys set direction; release returns to 0.
    if key.special == "UP" or key.character == "w" then
        self._state.key_dir = -1
        return "handled"
    elseif key.special == "DOWN" or key.character == "s" then
        self._state.key_dir = 1
        return "handled"
    elseif key.special == "ENTER" or key.character == " " then
        -- The T-Deck keyboard doesn't emit release events; instead we
        -- treat Enter / Space as a "stop" so the player can park the
        -- paddle. Fine for a quick demo; a real port would poll
        -- ez.keyboard.is_pressed() for held-key state.
        self._state.key_dir = 0
        return "handled"
    elseif key.special == "BACKSPACE" or key.special == "ESCAPE"
            or key.character == "q" then
        return "pop"
    end
    return nil
end

function Pong:on_exit()
    if self._state.mode == MODE_HOST then shutdown_host(self)
    elseif self._state.mode == MODE_JOIN then shutdown_client(self) end
end

return Pong
