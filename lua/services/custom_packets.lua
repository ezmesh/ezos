-- Custom packets: P2P firmware-extension layer on MeshCore's RAW_CUSTOM.
--
-- The MeshCore reference firmware reserves PAYLOAD_TYPE_RAW_CUSTOM (0x0F)
-- as an application escape hatch — the core imposes no framing, the app
-- defines everything inside. Stock MeshCore repeaters refuse to re-flood
-- RAW_CUSTOM (src/Mesh.cpp:281 in ripplebiz/MeshCore), so this is best
-- understood as a direct-range or same-firmware-mesh mechanism. For
-- multi-hop reach through arbitrary relays, use TXT_MSG instead.
--
-- Wire envelope:
--   header:  [route | RAW_CUSTOM | version]
--   payload: [dest_hash:1][src_hash:1][MAC:2][ciphertext:N]
--
-- Ciphertext inner (plaintext before AES-ECB zero-padding):
--   [frame_len:2 LE][flags:1][subtype:4][app_data:M]
--
-- `frame_len` is the byte count of the meaningful plaintext so receivers
-- can recover M exactly regardless of `data`'s bytes. Length-prefix is
-- required because AES-ECB's trailing zero padding is unrecoverable for
-- payloads ending in 0x00 (nonces, binary protocols).
--
-- `flags` is a bitfield:
--   0x01  REQ_ACK  sender wants an ACK for this packet
--   0x02  IS_ACK   this packet IS the ACK response; data = 4-byte hash
--                  of the original packet's inner bytes.
--
-- Reliability is opt-in per send(). Fire-and-forget by default — PING /
-- GPS share / game moves don't pay the round-trip cost. Callers that
-- want delivery confirmation pass `{ack = true}`; the service stashes
-- the inner bytes' 4-byte sha256 tag as `expected_ack`, retries on
-- timeout (up to 2x), and fires `custom/delivered` or
-- `custom/undelivered` on the bus for each outcome.
--
-- `subtype` is four ASCII bytes chosen by the app (examples: "PING",
-- "PONG", "GPS\0", "FILE", "BRKO"). Handlers are registered per-subtype.
-- Collisions are the app author's problem; keep subtypes unique in your
-- firmware's registry.
--
-- Crypto is shared with the DM service via `dm._internal` — the
-- per-contact shared-secret cache, encrypt_then_mac / mac_then_decrypt
-- helpers (both async), and the build_candidates search are all
-- reused, so first-contact X25519 is a one-time cost regardless of
-- whether the first message is a DM or a custom packet.
--
-- Space budget per packet: MAX_PACKET_PAYLOAD (184) - envelope (4) =
-- 180 bytes of AES-padded ciphertext, minus the 4-byte subtype = up to
-- ~172 bytes of app-data before AES padding pushes over 180.

local dm = require("services.direct_messages")

local M = {}

local PAYLOAD_RAW_CUSTOM = 0x0F
local ROUTE_FLOOD  = 1
local ROUTE_DIRECT = 2
local HEADER_SIZE  = 2           -- dest_hash + src_hash
local MAC_SIZE     = 2
local LEN_SIZE     = 2           -- uint16 LE frame length prefix
local FLAGS_SIZE   = 1
local SUBTYPE_SIZE = 4
local MIN_FRAME    = LEN_SIZE + FLAGS_SIZE + SUBTYPE_SIZE  -- 7

local FLAG_REQ_ACK    = 0x01
local FLAG_IS_ACK     = 0x02
local ACK_HASH_SIZE   = 4
local ACK_TIMEOUT_MS  = 15000
local ACK_RETRY_CHECK_MS = 5000
local ACK_MAX_RETRIES = 2

-- Registered handlers keyed by their 4-byte subtype tag. A subtype
-- can also have metadata (id, label) for UIs that list installed
-- handlers, but only `subtype` and `on_receive` are required.
local handlers = {}
local initialized = false

-- Outstanding ACKs: packets we've sent with {ack=true} and haven't
-- seen the response for yet. Keyed by a monotonic id so entries can
-- be removed mid-iteration without renumbering. Each entry carries
-- enough context to reconstruct and retransmit the frame.
--   [id] = { pub_key_hex, subtype, data, expected_ack, sent_at, attempts }
local pending_acks = {}
local next_ack_id = 1

-- Stable 4-byte hash tag over the exact inner bytes both sender and
-- receiver see (before AES-ECB padding on send, after strip-to-
-- frame_len on receive). Unkeyed SHA-256 truncated — the hash only
-- needs to be unique-enough within the peer+timeout window, which a
-- few minutes of traffic from one node isn't going to collide.
local function compute_ack_hash(inner_bytes)
    return ez.crypto.sha256(inner_bytes):sub(1, ACK_HASH_SIZE)
end

local function assert_subtype(s)
    assert(type(s) == "string" and #s == SUBTYPE_SIZE,
        "custom_packets: subtype must be exactly 4 bytes, got "
            .. tostring(s and #s or "nil"))
end

-- Register a handler for a subtype. Idempotent — reregistering the
-- same subtype replaces the existing handler (convenient during
-- hot-reload development).
-- Required fields: subtype (4-byte string), on_receive.
-- Optional: id, label — purely descriptive.
-- on_receive signature: function(sender_pub_hex, data_bytes, meta)
--   meta = { rssi, snr, name }
function M.register(app)
    assert(type(app) == "table", "register: expected table")
    assert_subtype(app.subtype)
    assert(type(app.on_receive) == "function", "register: on_receive required")
    handlers[app.subtype] = app
end

function M.unregister(subtype)
    assert_subtype(subtype)
    handlers[subtype] = nil
end

function M.list()
    local out = {}
    for _, h in pairs(handlers) do out[#out + 1] = h end
    return out
end

-- Internal: encrypt + queue a packet with explicit flags. Returns
-- (ok, inner) where `inner` is the plaintext frame bytes so the
-- caller can compute its ack_hash if this send is to be tracked.
-- Yields on crypto; must run inside a coroutine.
local function do_send(pub_key_hex, subtype, data, flags)
    if not ez.mesh.is_initialized() then return false end
    local enc = dm._internal.get_enc_key(pub_key_hex)
    if not enc then return false end

    data = data or ""
    local frame_len = LEN_SIZE + FLAGS_SIZE + SUBTYPE_SIZE + #data
    local lo = frame_len & 0xFF
    local hi = (frame_len >> 8) & 0xFF
    local inner = string.char(lo, hi, flags) .. subtype .. data

    local encrypted = dm._internal.encrypt_then_mac(enc.secret, enc.key, inner)
    if not encrypted then return false end

    local pub = dm._internal.hex_to_bytes(pub_key_hex)
    if not pub then return false end

    local dest_hash = pub:byte(1)
    local our_hash  = ez.mesh.get_path_hash()
    local payload   = string.char(dest_hash) .. string.char(our_hash) .. encrypted

    local path  = dm.get_return_path_bytes(pub_key_hex)
    local route = (path and #path > 0) and ROUTE_DIRECT or ROUTE_FLOOD

    local pkt = ez.mesh.build_packet(route, PAYLOAD_RAW_CUSTOM, payload, path)
    if not pkt then return false end

    local ok = ez.mesh.queue_send(pkt)
    return ok, inner
end

-- Send a custom packet. Yields on crypto, so callers originating on
-- the main loop (bus callbacks, timers, UI handlers) should wrap this
-- in `spawn(...)`.
--
-- opts (optional):
--   ack = true  Request a delivery ACK. The service stashes the
--               inner bytes' 4-byte sha256 tag as the expected
--               response, retries the send up to 2 times on timeout,
--               and fires `custom/delivered` or `custom/undelivered`
--               when resolved. Returns (true, ack_hash) on success.
--   Otherwise the send is fire-and-forget — PING / GPS share / game
--   moves don't pay the handshake cost.
--
-- Route selection: ROUTE_DIRECT with a cached path when available
-- (learned via DM's PATH_RETURN), else ROUTE_FLOOD. Stock MeshCore
-- relays don't re-flood RAW_CUSTOM, so FLOOD here means "broadcast to
-- direct-range nodes" — fine for P2P and games, but route reliable
-- long-haul messages through TXT_MSG instead.
local function send_in_coroutine(pub_key_hex, subtype, data, opts)
    opts = opts or {}
    local flags = opts.ack and FLAG_REQ_ACK or 0
    local ok, inner = do_send(pub_key_hex, subtype, data, flags)
    if not ok then return false end
    if not opts.ack then return true end

    -- Track for ACK response. The retry timer (installed in init())
    -- re-sends on timeout; once the remote's IS_ACK frame matches,
    -- the entry is removed and `custom/delivered` fires on the bus.
    local ack_hash = compute_ack_hash(inner)
    local id = next_ack_id
    next_ack_id = next_ack_id + 1
    pending_acks[id] = {
        pub_key_hex  = pub_key_hex,
        subtype      = subtype,
        data         = data or "",
        expected_ack = ack_hash,
        sent_at      = ez.system.millis(),
        attempts     = 0,
    }
    return true, ack_hash
end

function M.send(pub_key_hex, subtype, data, opts)
    assert_subtype(subtype)
    -- cp.send yields on crypto. If the caller is already inside a
    -- coroutine (from spawn(), async.task(), a packet-bus handler)
    -- we yield in-place so the caller can read the ack_hash
    -- synchronously. If the caller is on the main loop (UI key, timer
    -- one-shot), we auto-spawn so they don't have to wrap every call
    -- in spawn() themselves; the delivered/undelivered bus events
    -- carry enough context (pub_key_hex + subtype + ack_hash) to
    -- correlate from the main loop.
    if coroutine.isyieldable() then
        return send_in_coroutine(pub_key_hex, subtype, data, opts)
    end
    spawn(function() send_in_coroutine(pub_key_hex, subtype, data, opts) end)
    return true
end

-- Subscribe to incoming RAW_CUSTOM packets, decrypt with the sender's
-- shared secret (same candidate search as DM so prior-conversation
-- peers work without being in contacts), and dispatch to the subtype
-- handler. Missing handlers drop the packet silently.
function M.init()
    if initialized then return end
    initialized = true

    ez.bus.subscribe("mesh/packet", function(_topic, pkt)
        if not pkt or not pkt.payload then return end
        if pkt.payload_type ~= PAYLOAD_RAW_CUSTOM then return end
        if #pkt.payload < HEADER_SIZE + MAC_SIZE + 16 then return end

        local my_hash   = ez.mesh.get_path_hash()
        local dest_hash = pkt.payload:byte(1)
        local src_hash  = pkt.payload:byte(2)
        if dest_hash ~= my_hash then return end

        local enc_block  = pkt.payload:sub(HEADER_SIZE + 1)
        local candidates = dm._internal.build_candidates(src_hash)
        if #candidates == 0 then return end

        -- Decrypt must run in a coroutine — async AES/HMAC yield.
        spawn(function()
            for _, cand in ipairs(candidates) do
                local enc = dm._internal.get_enc_key(cand.pub_key_hex)
                if enc then
                    local pt = dm._internal.mac_then_decrypt(
                        enc.secret, enc.key, enc_block)
                    if pt and #pt >= MIN_FRAME then
                        -- Parse the length prefix (LE uint16) to recover
                        -- the exact original frame size. Bytes past
                        -- frame_len are AES-ECB zero padding.
                        local frame_len = pt:byte(1) + pt:byte(2) * 256
                        if frame_len >= MIN_FRAME and frame_len <= #pt then
                            local flags   = pt:byte(LEN_SIZE + 1)
                            local subtype = pt:sub(LEN_SIZE + FLAGS_SIZE + 1,
                                LEN_SIZE + FLAGS_SIZE + SUBTYPE_SIZE)
                            local data    = pt:sub(LEN_SIZE + FLAGS_SIZE + SUBTYPE_SIZE + 1,
                                frame_len)

                            -- IS_ACK: this is an acknowledgement for a
                            -- packet we sent earlier. Data is the 4-byte
                            -- hash that identifies the original frame;
                            -- match against pending_acks by (peer, hash).
                            if (flags & FLAG_IS_ACK) ~= 0 then
                                if #data >= ACK_HASH_SIZE then
                                    local hash = data:sub(1, ACK_HASH_SIZE)
                                    for id, p in pairs(pending_acks) do
                                        if p.pub_key_hex == cand.pub_key_hex
                                                and p.expected_ack == hash then
                                            pending_acks[id] = nil
                                            ez.bus.post("custom/delivered", {
                                                pub_key_hex = cand.pub_key_hex,
                                                subtype     = p.subtype,
                                                ack_hash    = hash,
                                                attempts    = p.attempts,
                                            })
                                            break
                                        end
                                    end
                                end
                                return
                            end

                            -- Regular packet: dispatch to the subtype
                            -- handler, then — if REQ_ACK — echo an ACK
                            -- response whose data is the hash of the
                            -- exact inner bytes we just received.
                            local h = handlers[subtype]
                            -- Handler can return `false` to refuse the
                            -- packet, which suppresses the ACK even if
                            -- the sender asked for one. File-transfer
                            -- uses this to make "delivered" mean the
                            -- receiver actually accepted the chunk.
                            local accepted = true
                            if h and h.on_receive then
                                local ok, result = pcall(h.on_receive,
                                    cand.pub_key_hex, data, {
                                        rssi = pkt.rssi,
                                        snr  = pkt.snr,
                                        name = cand.name,
                                    })
                                if not ok then
                                    ez.log("[custom_packets] handler "
                                        .. tostring(h.id or "?")
                                        .. " error: " .. tostring(result))
                                    accepted = false
                                elseif result == false then
                                    accepted = false
                                end
                            end

                            if accepted and (flags & FLAG_REQ_ACK) ~= 0 then
                                local ack_hash = compute_ack_hash(
                                    pt:sub(1, frame_len))
                                local peer = cand.pub_key_hex
                                spawn(function()
                                    do_send(peer, subtype, ack_hash, FLAG_IS_ACK)
                                end)
                            end
                            return
                        end
                    end
                end
            end
        end)
    end)

    -- Retry timer for opt-in ACK tracking. Scans pending_acks every
    -- ACK_RETRY_CHECK_MS; entries whose sent_at is older than
    -- ACK_TIMEOUT_MS either resend (up to ACK_MAX_RETRIES) or give up
    -- and fire custom/undelivered.
    ez.system.set_interval(ACK_RETRY_CHECK_MS, function()
        local now = ez.system.millis()
        for id, p in pairs(pending_acks) do
            if (now - p.sent_at) >= ACK_TIMEOUT_MS then
                if p.attempts < ACK_MAX_RETRIES then
                    p.attempts = p.attempts + 1
                    p.sent_at  = now
                    local peer, st, d = p.pub_key_hex, p.subtype, p.data
                    spawn(function() do_send(peer, st, d, FLAG_REQ_ACK) end)
                else
                    pending_acks[id] = nil
                    ez.bus.post("custom/undelivered", {
                        pub_key_hex = p.pub_key_hex,
                        subtype     = p.subtype,
                        ack_hash    = p.expected_ack,
                        attempts    = p.attempts,
                    })
                end
            end
        end
    end)

    ez.log("[CustomPackets] Service initialized")
end

-- ---------------------------------------------------------------------------
-- Convenience helpers for the built-in demo subtypes. Kept here so any
-- caller (UI, REPL, remote harness) can invoke them with a single call
-- from the main loop.
-- ---------------------------------------------------------------------------

local function random_u32_bytes()
    local r = math.random(0, 0x7FFFFFFF)
    return string.char(r & 0xFF, (r >> 8) & 0xFF, (r >> 16) & 0xFF, (r >> 24) & 0xFF)
end

-- Send a PING to `pub_key_hex`. The peer's installed PING handler
-- should reply with a PONG carrying the same 4-byte nonce, so the
-- caller can correlate ping -> pong. Returns the nonce so callers can
-- subscribe to the `custom/pong` bus event and match on it.
function M.ping(pub_key_hex)
    local nonce = random_u32_bytes()
    spawn(function()
        M.send(pub_key_hex, "PING", nonce)
    end)
    return nonce
end

-- Send our current GPS fix (or a synthetic one) to the peer. The
-- inner payload is a fixed-length 12-byte record:
--   [lat_e6:4 LE int32][lon_e6:4 LE int32][alt_m:2 LE int16][sat:1][flags:1]
-- Peers decode with the inverse layout; see register_gps_share() for
-- the reference receiver.
function M.send_gps(pub_key_hex, fix)
    local function pack_i32(v)
        v = v or 0
        if v < 0 then v = v + 0x100000000 end
        return string.char(v & 0xFF, (v >> 8) & 0xFF,
                           (v >> 16) & 0xFF, (v >> 24) & 0xFF)
    end
    local function pack_i16(v)
        v = v or 0
        if v < 0 then v = v + 0x10000 end
        return string.char(v & 0xFF, (v >> 8) & 0xFF)
    end
    fix = fix or {}
    local data = pack_i32(math.floor((fix.lat or 0) * 1e6))
              .. pack_i32(math.floor((fix.lon or 0) * 1e6))
              .. pack_i16(math.floor(fix.alt or 0))
              .. string.char(fix.sats or 0)
              .. string.char(fix.flags or 0)
    spawn(function()
        M.send(pub_key_hex, "GPS\0", data)
    end)
end

-- Register the built-in demo subtypes: PING (auto-reply with PONG),
-- PONG (surface on the bus), and GPS\0 (surface on the bus). Split
-- from init() so an app that doesn't want these can skip them.
function M.register_demos()
    -- PING: echo the nonce back in a PONG packet.
    M.register({
        id       = "ping",
        label    = "Ping",
        subtype  = "PING",
        on_receive = function(sender_pub, data, meta)
            spawn(function()
                M.send(sender_pub, "PONG", data)
            end)
        end,
    })

    -- PONG: fire a bus event; tests and UIs subscribe to custom/pong.
    M.register({
        id       = "pong",
        label    = "Pong",
        subtype  = "PONG",
        on_receive = function(sender_pub, data, meta)
            ez.bus.post("custom/pong", {
                sender_pub = sender_pub,
                nonce      = data,
                rssi       = meta.rssi,
                snr        = meta.snr,
                name       = meta.name,
            })
        end,
    })

    -- GPS share: decode the 12-byte record and fire custom/gps_fix.
    M.register({
        id       = "gps_share",
        label    = "GPS Share",
        subtype  = "GPS\0",
        on_receive = function(sender_pub, data, meta)
            if #data < 12 then return end
            local function u32(s, o)
                return s:byte(o) + s:byte(o+1) * 256
                     + s:byte(o+2) * 65536 + s:byte(o+3) * 16777216
            end
            local function i32(s, o)
                local v = u32(s, o)
                if v >= 0x80000000 then v = v - 0x100000000 end
                return v
            end
            local function i16(s, o)
                local v = s:byte(o) + s:byte(o+1) * 256
                if v >= 0x8000 then v = v - 0x10000 end
                return v
            end
            ez.bus.post("custom/gps_fix", {
                sender_pub = sender_pub,
                lat        = i32(data, 1) / 1e6,
                lon        = i32(data, 5) / 1e6,
                alt        = i16(data, 9),
                sats       = data:byte(11),
                flags      = data:byte(12),
                rssi       = meta.rssi,
                snr        = meta.snr,
                name       = meta.name,
            })
        end,
    })
end

return M
