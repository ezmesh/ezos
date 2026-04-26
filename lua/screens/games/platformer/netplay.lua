-- Two-player networking for the platformer.
--
-- Same shape as games/pong.lua: one tdeck is Host, brings up a SoftAP and
-- runs the authoritative simulation; the other is Join, associates with
-- the AP and acts as a thin client that sends input + renders received
-- state. The reasons UDP works here are also the same — at 30 Hz any
-- dropped datagram only stalls a render, the next packet replaces the
-- last, no head-of-line blocking matters.
--
-- Wire format (fixed-length so the parsers stay tight):
--
--   Client -> Host:    [0x10][seq:u16 LE][buttons:u8]
--     buttons bit 0 = left, bit 1 = right, bit 2 = jump
--
--   Host -> Client:    [0x11][tick:u16 LE][level_idx:u8][num_p:u8][num_e:u8]
--                      [flags:u8]                    -- bit0 won, bit1 anyone-died
--                      [cam_x:u16 LE]
--                      for each player:
--                          [x:i16 LE][y:i16 LE][vy:i8][alive_goal_face:u8]
--                              -- alive_goal_face: bit0 alive, bit1 reached_goal,
--                              --                 bit2 facing (1 = right)
--                      for each enemy:
--                          [x:i16 LE][y:i16 LE][alive:u8]
--
-- Cap MAX_ENEMIES at 16; level 11 has the most enemies (~5) so this is
-- generous. The packet size scales with player + enemy count, easily
-- under 200 bytes — well within UDP MTU.
--
-- No authentication, no encryption — the AP's WPA2 PSK is the only
-- barrier. Game lobby, not a secrets channel.

local N = {}

N.SSID = "tdeck-platform"
N.PASS = "platform"
N.PORT = 4245

N.MAX_ENEMIES = 16
N.STATE_TICK_MS = 33      -- host broadcasts state at 30 Hz
N.INPUT_TICK_MS = 50      -- client sends input at 20 Hz

-- ---------------------------------------------------------------------------
-- Codec helpers (little-endian throughout)
-- ---------------------------------------------------------------------------

local function pack_u16(v)
    v = v & 0xFFFF
    return string.char(v & 0xFF, (v >> 8) & 0xFF)
end
local function read_u16(s, o)
    return s:byte(o) + s:byte(o + 1) * 256
end
local function pack_i16(v)
    v = math.floor(v)
    if v < 0 then v = v + 65536 end
    return pack_u16(v)
end
local function read_i16(s, o)
    local v = read_u16(s, o)
    if v >= 0x8000 then v = v - 0x10000 end
    return v
end
local function pack_i8(v)
    v = math.floor(v)
    if v < 0 then v = v + 256 end
    return string.char(v & 0xFF)
end
local function read_i8(s, o)
    local v = s:byte(o)
    if v >= 0x80 then v = v - 256 end
    return v
end

-- Encode the client's per-tick input. seq lets the host detect drops
-- (purely diagnostic; we always honour the latest input regardless).
function N.encode_input(buttons, seq)
    return string.char(0x10) .. pack_u16(seq) .. string.char(buttons & 0xFF)
end

function N.decode_input(data)
    if not data or #data < 4 or data:byte(1) ~= 0x10 then return nil end
    return {
        seq     = read_u16(data, 2),
        buttons = data:byte(4),
    }
end

-- Encode authoritative world state. `world` is the engine's world table.
-- `flags`: bit0 won, bit1 any_dead.
function N.encode_state(world)
    local flags = 0
    if world.won      then flags = flags | 0x01 end
    if world.any_dead then flags = flags | 0x02 end

    local n_p = #world.players
    local n_e = math.min(#world.enemies, N.MAX_ENEMIES)

    local out = {
        string.char(0x11),
        pack_u16(world.tick & 0xFFFF),
        string.char(world.level.idx & 0xFF),
        string.char(n_p & 0xFF),
        string.char(n_e & 0xFF),
        string.char(flags & 0xFF),
        pack_u16(math.floor(world.camera_x) & 0xFFFF),
    }

    for i = 1, n_p do
        local p = world.players[i]
        local b = 0
        if p.alive          then b = b | 0x01 end
        if p.reached_goal   then b = b | 0x02 end
        if p.facing > 0     then b = b | 0x04 end
        out[#out + 1] = pack_i16(p.x)
        out[#out + 1] = pack_i16(p.y)
        out[#out + 1] = pack_i8(math.max(-127, math.min(127, p.vy)))
        out[#out + 1] = string.char(b)
    end

    for i = 1, n_e do
        local e = world.enemies[i]
        out[#out + 1] = pack_i16(e.x)
        out[#out + 1] = pack_i16(e.y)
        out[#out + 1] = string.char(e.alive and 1 or 0)
    end

    return table.concat(out)
end

-- Decode a state packet into a sparse table the renderer can consume.
-- Returns nil if the packet looks malformed.
function N.decode_state(data)
    if not data or #data < 9 or data:byte(1) ~= 0x11 then return nil end
    local s = {
        tick      = read_u16(data, 2),
        level_idx = data:byte(4),
        num_p     = data:byte(5),
        num_e     = data:byte(6),
        flags     = data:byte(7),
        camera_x  = read_u16(data, 8),
        players   = {},
        enemies   = {},
    }
    local off = 10
    for i = 1, s.num_p do
        if off + 5 > #data then return nil end
        local b = data:byte(off + 5)
        s.players[i] = {
            x            = read_i16(data, off),
            y            = read_i16(data, off + 2),
            vy           = read_i8(data, off + 4),
            alive        = (b & 0x01) ~= 0,
            reached_goal = (b & 0x02) ~= 0,
            facing       = (b & 0x04) ~= 0 and 1 or -1,
            id           = i,
            w            = 10, h = 14,
        }
        off = off + 6
    end
    for i = 1, s.num_e do
        if off + 4 > #data then return nil end
        s.enemies[i] = {
            x = read_i16(data, off),
            y = read_i16(data, off + 2),
            alive = data:byte(off + 4) == 1,
            w = 12, h = 12,
        }
        off = off + 5
    end
    s.won      = (s.flags & 0x01) ~= 0
    s.any_dead = (s.flags & 0x02) ~= 0
    return s
end

-- ---------------------------------------------------------------------------
-- Lifecycle helpers
-- ---------------------------------------------------------------------------

-- Bring up the SoftAP for hosting. Returns the UDP socket (or nil + err).
-- Caller is responsible for keeping the socket alive and calling teardown.
function N.host_start()
    if not (ez.wifi and ez.wifi.start_ap) then
        return nil, "wifi.start_ap unavailable"
    end
    local ok = ez.wifi.start_ap(N.SSID, N.PASS, 1, false, 2)
    if not ok then return nil, "start_ap failed" end
    local sock = ez.net.udp_open(N.PORT)
    if not sock then
        ez.wifi.stop_ap()
        return nil, "udp_open failed"
    end
    return sock
end

function N.host_stop(sock)
    if sock then pcall(ez.net.udp_close, sock) end
    if ez.wifi and ez.wifi.stop_ap then pcall(ez.wifi.stop_ap) end
end

-- Connect to a host's SoftAP. Blocks up to `timeout_s` seconds for
-- association. Returns (sock, host_ip) or nil + err.
function N.client_start(timeout_s)
    if not (ez.wifi and ez.wifi.connect) then
        return nil, nil, "wifi.connect unavailable"
    end
    ez.wifi.connect(N.SSID, N.PASS)
    local up = ez.wifi.wait_connected(timeout_s or 5)
    if not up then
        ez.wifi.disconnect()
        return nil, nil, "no AP found"
    end
    local gw = ez.wifi.get_gateway()
    if not gw or gw == "" then
        ez.wifi.disconnect()
        return nil, nil, "no gateway"
    end
    local sock = ez.net.udp_open(0)
    if not sock then
        ez.wifi.disconnect()
        return nil, nil, "udp_open failed"
    end
    return sock, gw
end

function N.client_stop(sock)
    if sock then pcall(ez.net.udp_close, sock) end
    if ez.wifi and ez.wifi.disconnect then pcall(ez.wifi.disconnect) end
end

return N
