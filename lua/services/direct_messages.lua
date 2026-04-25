-- Direct Messages service
-- Handles encrypted direct messaging over MeshCore.
--
-- MeshCore TXT_MSG over-the-air payload format:
--   [dest_hash:1][src_hash:1][MAC:2][ciphertext:N]
-- MAC: HMAC-SHA256 truncated to 2 bytes, keyed with 32-byte ECDH shared secret
-- Ciphertext: AES-128-ECB (key = first 16 bytes of shared secret)
-- Inner plaintext (after decryption, zero-padded to 16-byte boundary):
--   [timestamp:4 LE][flags:1][text:N]
--
-- ACK: On successful decryption, sends a flood ACK packet so the sender
-- knows the message was delivered. Sent messages track status:
-- "pending" → "delivered" (ACK received) or "failed" (max retries exhausted).

local contacts_svc = require("services.contacts")

local dm = {}

-- Constants
local MAX_HISTORY = 50
local MAX_TEXT = 120
local HEADER_SIZE = 2   -- dest_hash(1) + src_hash(1)
local MAC_SIZE = 2
local PAYLOAD_TXT_MSG = 2
local PAYLOAD_ACK = 3
local PAYLOAD_ADVERT = 4
local PAYLOAD_PATH = 8

local ROUTE_FLOOD = 1
local ROUTE_DIRECT = 2

-- MeshCore ACK payload is a 4-byte truncated SHA-256 over the inner
-- plaintext (timestamp + flags + text, without the null terminator)
-- concatenated with the sender's 32-byte Ed25519 pubkey. Both sides
-- compute the same 4 bytes: the sender stashes it as expected_ack, the
-- receiver echoes it back as the full ACK payload. See BaseChatMesh.cpp
-- in ripplebiz/MeshCore for the reference construction.
local ACK_HASH_SIZE = 4

-- Compute the 4-byte ACK hash tag given the exact inner bytes used for
-- encryption and the sender's pubkey (32 raw bytes). The sender always
-- passes their OWN pubkey, so sender and receiver arrive at the same
-- value from the same plaintext.
local function compute_ack_hash(inner_plaintext, sender_pubkey_bytes)
    return ez.crypto.sha256(inner_plaintext .. sender_pubkey_bytes):sub(1, ACK_HASH_SIZE)
end
local MAX_RETRIES = 2
local RETRY_INTERVAL = 10000  -- 10 seconds between retries
local ACK_TIMEOUT = 15000     -- Give up after 15 seconds with no ACK
local SAVE_PATH = "/fs/dm_history.json"
local SAVE_DELAY = 2000       -- Debounce: write at most every 2 seconds

-- Pending-ciphertext cap and TTL. If the sender never advertises and
-- never gets added as a contact, we drop the ciphertext after this
-- window so a hostile peer can't pin a growing buffer on us. 48 h is
-- long enough to cover overnight gaps but short enough that stale
-- mystery traffic doesn't linger forever.
local PENDING_MAX         = 32
local PENDING_TTL_MS      = 48 * 3600 * 1000     -- 48 hours
local PENDING_SWEEP_MS    = 5 * 60 * 1000        -- prune every 5 minutes
local ADVERT_PUB_KEY_SIZE = 32

-- State
local conversations = {}   -- { [pub_key_hex] = { messages... } }
local unread = {}           -- { [pub_key_hex] = count }
local secret_cache = {}     -- { [pub_key_hex] = { secret, key } }
-- Return-path cache, populated when we decrypt a PATH_RETURN from a
-- peer. Lets us send subsequent DMs as ROUTE_DIRECT instead of FLOOD,
-- which cuts airtime significantly on multi-hop meshes. In-memory only:
-- paths can go stale fast when topology shifts, and the cost of a cold
-- cache is a single FLOOD round-trip to re-learn.
--   { [pub_key_hex] = { bytes = "...", learned_at_ms = N } }
local return_paths = {}

-- Force a relearn 24 h after a path was cached. Meshes with mobile
-- nodes or sleepy repeaters change topology silently; a TTL bounds how
-- long we'll waste airtime routing through a dead hop. The next send
-- after expiry falls back to FLOOD, which produces a fresh PATH_RETURN.
local RETURN_PATH_TTL_MS    = 24 * 3600 * 1000
local RETURN_PATH_SWEEP_MS  = 15 * 60 * 1000
local pending_acks = {}     -- { [id] = { pub_key_hex, text, attempt, sent_at, msg_ref, expected_ack, used_direct } }
-- pending_ciphertexts: TXT_MSG packets whose sender pubkey wasn't known
-- at arrival. Re-decrypted when an ADVERT or new contact gives us a
-- matching pubkey. Keyed by a monotonic id so we can remove individual
-- entries during iteration without renumbering.
--   { [id] = { src_hash, ciphertext, rssi, snr, received_at_ms } }
local pending_ciphertexts = {}
local next_pending_id = 1
local pending_count = 0
local next_msg_id = 1
local initialized = false
local save_dirty = false
local save_timer = nil

-- =========================================================================
-- Helpers
-- =========================================================================

local function hex_to_bytes(hex)
    if not hex or #hex % 2 ~= 0 then return nil end
    local bytes = ""
    for i = 1, #hex, 2 do
        local b = tonumber(hex:sub(i, i + 1), 16)
        if not b then return nil end
        bytes = bytes .. string.char(b)
    end
    return bytes
end

local function pack_u32le(v)
    return string.char(
        v % 256,
        math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256,
        math.floor(v / 16777216) % 256
    )
end

-- All crypto runs on the AsyncIO worker thread (Core 0). Every helper
-- below YIELDS and must only be called from inside a coroutine — use
-- `spawn(fn)` at every entry point that originates on the main loop
-- (bus callbacks, timers, UI handlers).

-- Get or compute encryption keys for a contact. Cache-hit returns
-- immediately without yielding; cache-miss yields once on the X25519
-- ECDH step. The X25519 curve op costs ~20-50 ms on ESP32-S3 with no
-- HW accel, so running it on the worker keeps the UI responsive on a
-- first-contact send.
local function get_enc_key(pub_key_hex)
    local cached = secret_cache[pub_key_hex]
    if cached then return cached end

    local pub_key = hex_to_bytes(pub_key_hex)
    if not pub_key or #pub_key ~= 32 then return nil end

    local secret = async_x25519_shared_secret(pub_key)
    if not secret then return nil end

    local result = { secret = secret, key = secret:sub(1, 16) }
    secret_cache[pub_key_hex] = result
    return result
end

-- Encrypt-then-MAC: returns [MAC:2][ciphertext]. MAC is keyed with the
-- full 32-byte shared secret, encryption with the first 16 bytes. Both
-- steps yield.
local function encrypt_then_mac(secret, key, plaintext)
    local ct = async_aes_encrypt(key, plaintext)
    if not ct then return nil end
    local hmac = async_hmac_sha256(secret, ct)
    if not hmac then return nil end
    return hmac:sub(1, MAC_SIZE) .. ct
end

-- MAC-then-decrypt: input [MAC:2][ciphertext], returns plaintext or nil.
-- HMAC runs first (async) so a wrong key is rejected before the AES
-- pass — saves a worker trip on the common "not my packet" path.
local function mac_then_decrypt(secret, key, data)
    if #data < MAC_SIZE + 16 then return nil end
    local mac = data:sub(1, MAC_SIZE)
    local ct = data:sub(MAC_SIZE + 1)
    if #ct % 16 ~= 0 then return nil end
    local hmac = async_hmac_sha256(secret, ct)
    if not hmac or hmac:sub(1, MAC_SIZE) ~= mac then return nil end
    return async_aes_decrypt(key, ct)
end

-- =========================================================================
-- Persistence
-- =========================================================================

local function do_save()
    local data = { conversations = {}, unread = {} }
    for key, msgs in pairs(conversations) do
        local saved = {}
        for _, msg in ipairs(msgs) do
            saved[#saved + 1] = {
                text = msg.text,
                sender_key = msg.sender_key,
                sender_name = msg.sender_name,
                timestamp = msg.timestamp,
                is_self = msg.is_self,
                status = msg.status,
                count = msg.count,
                rssi = msg.rssi,
                snr = msg.snr,
            }
        end
        data.conversations[key] = saved
    end
    for key, count in pairs(unread) do
        if count > 0 then
            data.unread[key] = count
        end
    end
    local json = ez.storage.json_encode(data)
    if json then
        ez.storage.write_file(SAVE_PATH, json)
    end
end

local function schedule_save()
    save_dirty = true
    if not save_timer then
        save_timer = ez.system.set_timer(SAVE_DELAY, function()
            save_timer = nil
            if save_dirty then
                save_dirty = false
                do_save()
            end
        end)
    end
end

local function load_history()
    if not ez.storage.exists(SAVE_PATH) then return end
    local json = ez.storage.read_file(SAVE_PATH)
    if not json or #json == 0 then return end
    local data, err = ez.storage.json_decode(json)
    if not data then
        ez.log("[DM] Failed to load history: " .. (err or "unknown"))
        return
    end
    if data.conversations then
        for key, msgs in pairs(data.conversations) do
            conversations[key] = {}
            for _, msg in ipairs(msgs) do
                if msg.status == "pending" then
                    msg.status = "unconfirmed"
                end
                conversations[key][#conversations[key] + 1] = msg
            end
        end
    end
    if data.unread then
        for key, count in pairs(data.unread) do
            unread[key] = count
        end
    end
    local count = 0
    for _ in pairs(conversations) do count = count + 1 end
    ez.log("[DM] Loaded " .. count .. " conversations from storage")
end

-- ---------------------------------------------------------------------------
-- Pending-ciphertext buffer
-- ---------------------------------------------------------------------------

-- Drop entries older than the TTL. Called on a periodic sweep and
-- opportunistically before adding new entries so we never exceed the
-- cap by more than one entry transiently.
local function prune_expired_pending()
    local now = ez.system.millis()
    for id, p in pairs(pending_ciphertexts) do
        if (now - p.received_at_ms) > PENDING_TTL_MS then
            pending_ciphertexts[id] = nil
            pending_count = pending_count - 1
        end
    end
end

-- If the buffer is at capacity, evict the oldest entry. Keeping this
-- simple (linear scan) is fine — the cap is tiny and insertions are
-- rare.
local function evict_oldest_pending()
    local oldest_id, oldest_ts = nil, math.huge
    for id, p in pairs(pending_ciphertexts) do
        if p.received_at_ms < oldest_ts then
            oldest_id, oldest_ts = id, p.received_at_ms
        end
    end
    if oldest_id then
        pending_ciphertexts[oldest_id] = nil
        pending_count = pending_count - 1
    end
end

-- Store a ciphertext we couldn't decrypt. The payload already has the
-- envelope header stripped, so what we stash is exactly what the decrypt
-- routine expects when we later retry.
local function stash_pending(src_hash, ciphertext, rssi, snr)
    prune_expired_pending()
    if pending_count >= PENDING_MAX then
        evict_oldest_pending()
    end
    local id = next_pending_id
    next_pending_id = next_pending_id + 1
    pending_ciphertexts[id] = {
        src_hash       = src_hash,
        ciphertext     = ciphertext,
        rssi           = rssi,
        snr            = snr,
        received_at_ms = ez.system.millis(),
    }
    pending_count = pending_count + 1
    ez.bus.post("dm/pending", { count = pending_count })
end

-- Decrypt a single stashed entry against a candidate pubkey and, on
-- success, promote it into the normal conversation store. Forward
-- declaration so it's visible before the packet handler closes over it.
local store_message  -- defined below
local function try_decrypt_pending(id, pending, candidate_pub_key_hex)
    local enc = get_enc_key(candidate_pub_key_hex)
    if not enc then return false end

    local plaintext = mac_then_decrypt(enc.secret, enc.key, pending.ciphertext)
    if not plaintext then return false end
    plaintext = plaintext:gsub("\0+$", "")
    if #plaintext < 6 then return false end

    local b1, b2, b3, b4 = plaintext:byte(1, 4)
    local msg_timestamp = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    local _flags = plaintext:byte(5)
    local text = plaintext:sub(6)
    if #text == 0 then return false end

    local contact = contacts_svc.get(candidate_pub_key_hex)
    local msg = {
        sender_key  = candidate_pub_key_hex,
        sender_name = (contact and contact.name)
                       or candidate_pub_key_hex:sub(1, 8),
        text        = text,
        timestamp   = msg_timestamp,
        rssi        = pending.rssi,
        snr         = pending.snr,
        is_self     = false,
        -- Marker so the UI can indicate this was a retroactive delivery.
        retroactive = true,
    }
    store_message(candidate_pub_key_hex, msg)
    unread[candidate_pub_key_hex] = (unread[candidate_pub_key_hex] or 0) + 1

    pending_ciphertexts[id] = nil
    pending_count = pending_count - 1

    ez.bus.post("dm/message", msg)
    ez.bus.post("dm/pending", { count = pending_count })

    -- Now that we can read the message we can also ACK it — the sender
    -- may still be within their ACK-timeout window, so belatedly
    -- acknowledging is worthwhile. Same hash construction as the live
    -- RX path.
    local sender_pub = hex_to_bytes(candidate_pub_key_hex)
    if sender_pub then
        local ack_hash = compute_ack_hash(plaintext, sender_pub)
        send_ack(ack_hash)
    end
    return true
end

-- Walk every pending entry whose src_hash matches the candidate
-- pubkey's first byte and try to decrypt. Returns how many entries
-- were promoted — useful for diagnostics / logs.
local function retry_pending_for_pubkey(pub_key_hex)
    if pending_count == 0 then return 0 end
    local pub = hex_to_bytes(pub_key_hex)
    if not pub or #pub ~= 32 then return 0 end
    local target_hash = pub:byte(1)

    local promoted = 0
    -- Snapshot ids first because try_decrypt_pending mutates the table.
    local ids = {}
    for id, p in pairs(pending_ciphertexts) do
        if p.src_hash == target_hash then
            ids[#ids + 1] = id
        end
    end
    for _, id in ipairs(ids) do
        local p = pending_ciphertexts[id]
        if p and try_decrypt_pending(id, p, pub_key_hex) then
            promoted = promoted + 1
        end
    end
    return promoted
end

-- Window inside which two received messages with identical text count as
-- the same logical message (typically: the sender didn't get an ACK and
-- retransmitted). Beyond this, a user who genuinely re-types the same
-- text gets a fresh bubble.
local RECV_DEDUP_WINDOW_S = 60

-- Store message in conversation history. Dedup policy differs by
-- direction: user-initiated self messages are always separate bubbles
-- so back-to-back identical sends show as two entries; received
-- messages only merge when they arrive within the retransmit window,
-- so the mesh-level ACK retry (every ~10-15 s) is hidden but a true
-- second message from the peer isn't.
store_message = function(pub_key_hex, msg)
    if not conversations[pub_key_hex] then
        conversations[pub_key_hex] = {}
    end
    local h = conversations[pub_key_hex]

    if not msg.is_self then
        local last = h[#h]
        if last and not last.is_self
                and last.text == msg.text
                and (msg.timestamp or 0) - (last.timestamp or 0) <= RECV_DEDUP_WINDOW_S then
            last.count = (last.count or 1) + 1
            last.timestamp = msg.timestamp
            return last
        end
    end

    msg.count = 1
    h[#h + 1] = msg
    while #h > MAX_HISTORY do
        table.remove(h, 1)
    end
    schedule_save()
    return msg
end

-- Send a MeshCore-protocol ACK packet to confirm receipt of a TXT_MSG
-- that arrived via DIRECT (path already known). Payload is exactly the
-- 4-byte ack hash the original sender is expecting; sender matches it
-- against its pre-computed `expected_ack`.
local function send_ack(ack_hash)
    if not ez.mesh.is_initialized() then return end
    if not ack_hash or #ack_hash ~= ACK_HASH_SIZE then return end
    local pkt = ez.mesh.build_packet(ROUTE_FLOOD, PAYLOAD_ACK, ack_hash)
    if pkt then
        ez.mesh.queue_send(pkt)
    end
end

-- Send a MeshCore PATH_RETURN in response to a FLOOD TXT_MSG. The
-- packet carries the hop chain the inbound flood took (so the sender
-- can cache a return path and use DIRECT for subsequent DMs) plus the
-- 4-byte ACK piggybacked inside the same encrypted block. Must run
-- inside a coroutine because encrypt_then_mac yields.
--
-- Wire format (after the header byte):
--   dest_hash:1       — sender's pubkey[0]
--   src_hash:1        — our pubkey[0]
--   encrypted_block:N — encrypt_then_mac(shared_secret, data) where
--     data = path_len:1 || path_bytes || 0x03 (ACK) || ack_hash:4
local function send_path_return(sender_pub_hex, enc, inbound_path, ack_hash)
    if not ez.mesh.is_initialized() then return end
    if not ack_hash or #ack_hash ~= ACK_HASH_SIZE then return end

    local sender_pub = hex_to_bytes(sender_pub_hex)
    if not sender_pub then return end

    -- path_len byte encodes hop_count in the low 6 bits and hash_size
    -- in the top 2 bits (size = (b >> 6) + 1). Stock MeshCore uses
    -- 1-byte hashes, so the top bits are zero and path_len == #path.
    local path_bytes = inbound_path or ""
    local path_len = #path_bytes
    if path_len > 63 then path_len = 63 end

    local data = string.char(path_len)
        .. path_bytes:sub(1, path_len)
        .. string.char(PAYLOAD_ACK)
        .. ack_hash

    local encrypted = encrypt_then_mac(enc.secret, enc.key, data)
    if not encrypted then return end

    local our_hash = ez.mesh.get_path_hash()
    local dest_hash = sender_pub:byte(1)
    local payload = string.char(dest_hash) .. string.char(our_hash) .. encrypted

    local pkt = ez.mesh.build_packet(ROUTE_FLOOD, PAYLOAD_PATH, payload)
    if pkt then
        ez.mesh.queue_send(pkt)
    end
end

-- Build the wire-format payload and queue it on the radio. Sync helper
-- — no yielding. `encrypted` is the [MAC:2][ciphertext] blob already
-- produced by encrypt_then_mac. If a return path is cached for the
-- recipient, the packet goes out as ROUTE_DIRECT with that path;
-- otherwise FLOOD. Returns (ok, used_direct) so the caller can tag the
-- pending-ack entry — stale cached paths are dropped on ACK timeout.
local function build_and_queue_txt_msg(pub_key_hex, encrypted)
    local pub_key = hex_to_bytes(pub_key_hex)
    local dest_hash = pub_key:byte(1)
    local our_hash = ez.mesh.get_path_hash()
    local payload = string.char(dest_hash) .. string.char(our_hash) .. encrypted

    local rp = return_paths[pub_key_hex]
    local path = rp and rp.bytes
    local route = (path and #path > 0) and ROUTE_DIRECT or ROUTE_FLOOD
    local pkt = ez.mesh.build_packet(route, PAYLOAD_TXT_MSG, payload, path)
    if not pkt then return false end

    local ok = ez.mesh.queue_send(pkt)
    return ok, route == ROUTE_DIRECT
end

local function build_inner(text, attempt)
    local timestamp = 0
    if ez.system.get_time then
        local t = ez.system.get_time()
        if t and t.epoch then timestamp = t.epoch end
    end
    -- Lower 2 bits of flags = attempt number
    local flags = math.min(attempt or 0, 3)
    return pack_u32le(timestamp) .. string.char(flags) .. text
end

-- Transmit a DM. Must run inside a coroutine — calls both async crypto
-- helpers, which yield. Returns `(sent, expected_ack, used_direct)`:
--   sent        — true if the packet was queued on the radio
--   expected_ack — 4-byte hash tag to stash in pending_acks so incoming
--                  ACKs can be matched (nil on any crypto / build fail)
--   used_direct — true if the packet went out via ROUTE_DIRECT using a
--                 cached return path; the caller tags pending_acks so
--                 an ACK timeout can drop the stale path.
local function transmit(pub_key_hex, text, attempt)
    local enc = get_enc_key(pub_key_hex)
    if not enc then return false end
    local inner = build_inner(text, attempt)
    local encrypted = encrypt_then_mac(enc.secret, enc.key, inner)
    if not encrypted then return false end
    local ok, used_direct = build_and_queue_txt_msg(pub_key_hex, encrypted)
    if not ok then return false end
    -- The ACK hash is keyed by OUR pubkey — the receiver will do the
    -- same hash with the same key (which it knows from our identity)
    -- and send the 4 bytes back.
    local expected_ack = compute_ack_hash(inner, ez.mesh.get_public_key())
    return true, expected_ack, used_direct
end

-- =========================================================================
-- Public API
-- =========================================================================

-- Build the decrypt candidate list for an inbound packet. A "candidate"
-- is any 32-byte pubkey we might have a shared secret with whose first
-- byte matches the packet's src_hash. Sources, in preference order:
--
--   1. Contacts — explicit user-added peers.
--   2. Mesh nodes seen via ADVERT (minus those already in contacts, to
--      avoid duplicates).
--   3. Prior conversation peers. If we've successfully exchanged with
--      someone before, their pubkey is a conversation key, and the
--      shared secret is likely still in secret_cache. This matters
--      when a peer falls out of both contacts and the node cache —
--      without this, we'd lose the ability to decrypt their DMs.
--
-- Returns a list of { pub_key_hex, name } tables.
local function build_candidates(src_hash)
    local seen = {}
    local out = {}

    local function add(pub_key_hex, name)
        if not pub_key_hex or seen[pub_key_hex] then return end
        local pub = hex_to_bytes(pub_key_hex)
        if not pub or pub:byte(1) ~= src_hash then return end
        seen[pub_key_hex] = true
        out[#out + 1] = { pub_key_hex = pub_key_hex, name = name }
    end

    for _, c in ipairs(contacts_svc.get_all()) do
        add(c.pub_key_hex, c.name)
    end
    if ez.mesh.is_initialized() then
        for _, node in ipairs(ez.mesh.get_nodes() or {}) do
            add(node.pub_key_hex, node.name)
        end
    end
    -- Prior peers we've already exchanged with. The pub_key_hex is the
    -- conversation key, and chat bubbles carry sender_name when we
    -- stored them so the name is recoverable without the contact.
    for pub_key_hex, msgs in pairs(conversations) do
        local fallback_name = pub_key_hex:sub(1, 8)
        for i = #msgs, 1, -1 do
            if msgs[i].sender_name and not msgs[i].is_self then
                fallback_name = msgs[i].sender_name
                break
            end
        end
        add(pub_key_hex, fallback_name)
    end

    return out
end

-- Forward-declare so the mesh/packet subscriber can reach both the
-- plain-ACK handler and the PATH_RETURN path without duplicating logic.
local function process_ack_hash(ack_hash)
    for id, pending in pairs(pending_acks) do
        if pending.expected_ack == ack_hash then
            if pending.msg_ref then
                pending.msg_ref.status = "delivered"
            end
            pending_acks[id] = nil
            -- ACK proves the peer has our pubkey (they decrypted our
            -- DM); flip both flags so the next DM skips the extra
            -- advert and the contact is auto-enabled for ACK tracking.
            contacts_svc.set_ack_enabled(pending.pub_key_hex, true)
            contacts_svc.set_known_by(pending.pub_key_hex, true)
            ez.bus.post("dm/status", {
                pub_key_hex = pending.pub_key_hex,
                status      = "delivered",
            })
            schedule_save()
            return  -- expected_ack is ~unique per outbound; one match is enough
        end
    end
end

function dm.init()
    if initialized then return end
    initialized = true

    load_history()

    -- Subscribe to all incoming packets
    ez.bus.subscribe("mesh/packet", function(topic, pkt)
        if not pkt or not pkt.payload then return end

        -- ADVERT: the first 32 bytes of the payload are the sender's
        -- Ed25519 public key. Retry any pending ciphertexts whose
        -- src_hash matches pubkey[0] against this key directly — we
        -- don't wait for C++ to add it to the nodes list because the
        -- mesh/packet event fires before that happens.
        -- retry_pending_for_pubkey yields on crypto (X25519 on
        -- cache-miss, plus AES+HMAC per candidate entry), so it must
        -- run inside a coroutine.
        if pkt.payload_type == PAYLOAD_ADVERT
                and #pkt.payload >= ADVERT_PUB_KEY_SIZE
                and pending_count > 0 then
            local pub_key = pkt.payload:sub(1, ADVERT_PUB_KEY_SIZE)
            local hex = ""
            for i = 1, #pub_key do
                hex = hex .. string.format("%02X", pub_key:byte(i))
            end
            spawn(function()
                local promoted = retry_pending_for_pubkey(hex)
                if promoted > 0 then
                    ez.log("[DM] Retroactively delivered " .. promoted
                        .. " DM(s) from " .. hex:sub(1, 8))
                end
            end)
            -- Fall through so the C++ handler still processes the ADVERT
            -- for the nodes list. We don't return here.
        end

        -- Handle MeshCore ACK packets: payload is exactly the 4-byte
        -- ack hash the original sender computed over its own inner
        -- plaintext keyed by its own pubkey. Match by exact bytewise
        -- compare against each pending_acks entry's expected_ack.
        if pkt.payload_type == PAYLOAD_ACK and #pkt.payload == ACK_HASH_SIZE then
            process_ack_hash(pkt.payload)
            return
        end

        -- Handle PATH_RETURN packets. Envelope matches a normal DM:
        -- [dest_hash:1][src_hash:1][MAC:2][ct:N]. The decrypted block
        -- contains the return path the sender traveled to reach us,
        -- plus an optional embedded sub-payload (0x03 + 4-byte ACK).
        -- Cache the path for ROUTE_DIRECT use next time, and process
        -- the embedded ACK if present.
        if pkt.payload_type == PAYLOAD_PATH
                and #pkt.payload >= HEADER_SIZE + MAC_SIZE + 16 then
            local dest_hash = pkt.payload:byte(1)
            local src_hash  = pkt.payload:byte(2)
            local enc_block = pkt.payload:sub(HEADER_SIZE + 1)
            local my_hash   = ez.mesh.get_path_hash()
            if dest_hash ~= my_hash then return end

            local candidates = build_candidates(src_hash)
            if #candidates == 0 then return end

            spawn(function()
                for _, cand in ipairs(candidates) do
                    local enc = get_enc_key(cand.pub_key_hex)
                    if enc then
                        local data = mac_then_decrypt(enc.secret, enc.key, enc_block)
                        if data and #data >= 1 then
                            local path_len = data:byte(1)
                            local hop_count = path_len % 64  -- low 6 bits
                            local hash_size = (path_len >> 6) + 1
                            local path_bytes_len = hop_count * hash_size
                            if #data >= 1 + path_bytes_len then
                                local path_bytes = data:sub(2, 1 + path_bytes_len)
                                return_paths[cand.pub_key_hex] = {
                                    bytes = path_bytes,
                                    learned_at_ms = ez.system.millis(),
                                }
                                -- Optional embedded sub-payload
                                local after = 1 + path_bytes_len
                                if #data >= after + 1 then
                                    local extra_type = data:byte(after + 1)
                                    local extra = data:sub(after + 2)
                                    if extra_type == PAYLOAD_ACK
                                            and #extra >= ACK_HASH_SIZE then
                                        process_ack_hash(extra:sub(1, ACK_HASH_SIZE))
                                    end
                                end
                                return
                            end
                        end
                    end
                end
            end)
            return
        end

        -- Handle TXT_MSG packets
        if pkt.payload_type ~= PAYLOAD_TXT_MSG then return end
        if #pkt.payload < HEADER_SIZE + MAC_SIZE + 16 then return end

        local dest_hash = pkt.payload:byte(1)
        local src_hash = pkt.payload:byte(2)
        local encrypted = pkt.payload:sub(HEADER_SIZE + 1)

        local my_hash = ez.mesh.get_path_hash()
        if dest_hash ~= my_hash then return end

        -- Build candidate list matching src_hash
        local candidates = build_candidates(src_hash)

        -- No known sender at all: stash for retroactive delivery when an
        -- ADVERT or contacts/changed event later surfaces the pubkey.
        if #candidates == 0 then
            stash_pending(src_hash, encrypted, pkt.rssi, pkt.snr)
            return
        end

        -- Decrypt runs in a coroutine because mac_then_decrypt yields on
        -- async HMAC and async AES. The bus callback itself is called
        -- from C++ on the main loop and can't yield directly.
        spawn(function()
            for _, candidate in ipairs(candidates) do
                local enc = get_enc_key(candidate.pub_key_hex)
                if enc then
                    local plaintext = mac_then_decrypt(enc.secret, enc.key, encrypted)
                    if plaintext then
                        plaintext = plaintext:gsub("\0+$", "")

                        if #plaintext >= 6 then
                            local b1, b2, b3, b4 = plaintext:byte(1, 4)
                            local msg_timestamp = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
                            local _flags = plaintext:byte(5)
                            local text = plaintext:sub(6)

                            if #text > 0 then
                                local msg = {
                                    sender_key = candidate.pub_key_hex,
                                    sender_name = candidate.name or candidate.pub_key_hex:sub(1, 8),
                                    text = text,
                                    timestamp = msg_timestamp,
                                    rssi = pkt.rssi,
                                    snr = pkt.snr,
                                    is_self = false,
                                }

                                store_message(candidate.pub_key_hex, msg)
                                unread[candidate.pub_key_hex] = (unread[candidate.pub_key_hex] or 0) + 1
                                ez.bus.post("dm/message", msg)

                                -- Receiving a DM proves the sender has our
                                -- pubkey (they did ECDH with it). Record it
                                -- so our next outbound DM to this contact
                                -- can skip the auto-advert.
                                if contacts_svc.is_contact(candidate.pub_key_hex) then
                                    contacts_svc.set_known_by(candidate.pub_key_hex, true)
                                end

                                -- MeshCore-compliant ACK: hash the
                                -- inner plaintext (which after the
                                -- trailing-zero strip is exactly
                                -- timestamp + flags + text that the
                                -- sender encrypted) keyed by the
                                -- sender's pubkey.
                                --
                                -- For FLOOD-routed TXT_MSGs, echo the
                                -- ACK inside a PATH_RETURN so the
                                -- sender also learns a return path
                                -- through the hop chain we received.
                                -- For DIRECT (already has a path),
                                -- a plain 4-byte ACK is enough.
                                local sender_pub = hex_to_bytes(candidate.pub_key_hex)
                                if sender_pub then
                                    local ack_hash = compute_ack_hash(plaintext, sender_pub)
                                    if pkt.route_type == ROUTE_FLOOD then
                                        send_path_return(
                                            candidate.pub_key_hex,
                                            enc,
                                            pkt.path or "",
                                            ack_hash
                                        )
                                    else
                                        send_ack(ack_hash)
                                    end
                                end
                                return
                            end
                        end
                    end
                end
            end

            -- All candidates had matching src_hash but none produced a
            -- valid MAC+plaintext. That can happen when the true
            -- sender's pubkey hash-collides with one we know on the
            -- first byte, so stash for retry once we learn the actual
            -- sender. Hash-collision on one byte is 1-in-256, so this
            -- path is uncommon but not exotic.
            stash_pending(src_hash, encrypted, pkt.rssi, pkt.snr)
        end)
    end)

    -- React to new contacts: the user may have just added the sender we
    -- were sitting on ciphertext for. Drain the pending buffer against
    -- the new contact's pubkey — inside a coroutine because the decrypt
    -- path yields.
    ez.bus.subscribe("contacts/changed", function(_topic, pub_key_hex)
        if pub_key_hex and contacts_svc.is_contact(pub_key_hex) then
            spawn(function()
                local promoted = retry_pending_for_pubkey(pub_key_hex)
                if promoted > 0 then
                    ez.log("[DM] Retroactively delivered " .. promoted
                        .. " DM(s) after contact add")
                end
            end)
        end
    end)

    -- Periodic TTL sweep so the pending buffer can't accumulate silently.
    ez.system.set_interval(PENDING_SWEEP_MS, function()
        prune_expired_pending()
    end)

    -- TTL sweep for the return-path cache. Drop any entry whose
    -- learned_at is older than RETURN_PATH_TTL_MS so long-running
    -- sessions don't keep routing through stale topology. A fresh
    -- PATH_RETURN on the next DM will repopulate it.
    ez.system.set_interval(RETURN_PATH_SWEEP_MS, function()
        local now = ez.system.millis()
        for k, rp in pairs(return_paths) do
            if (now - (rp.learned_at_ms or 0)) > RETURN_PATH_TTL_MS then
                return_paths[k] = nil
            end
        end
    end)

    -- Retry timer: check pending messages every 5 seconds
    ez.system.set_interval(5000, function()
        local now = ez.system.millis()
        for id, pending in pairs(pending_acks) do
            local elapsed = now - pending.sent_at
            if elapsed >= ACK_TIMEOUT then
                if pending.attempt < MAX_RETRIES then
                    -- Retry. If the peer still hasn't proven knowledge
                    -- of our pubkey, each retry also sends an advert —
                    -- cheap and it gives the receiver a second chance
                    -- to learn us in case the first advert was missed.
                    pending.attempt = pending.attempt + 1
                    pending.sent_at = now
                    if pending.msg_ref then
                        pending.msg_ref.status = "pending"
                    end
                    if not contacts_svc.is_known_by(pending.pub_key_hex)
                            and ez.mesh.send_announce then
                        ez.mesh.send_announce()
                    end
                    -- transmit() yields at every crypto step, so it
                    -- must run inside a coroutine. Capture the loop
                    -- values so retries fire correctly per-pending.
                    -- Each attempt encodes the retry number into the
                    -- inner plaintext's flags byte, which means the
                    -- expected_ack hash changes per attempt — refresh
                    -- pending.expected_ack when the new packet is built
                    -- so incoming ACKs from the retry match.
                    local pk, txt, att = pending.pub_key_hex, pending.text, pending.attempt
                    local entry = pending
                    spawn(function()
                        local ok, new_ack, direct = transmit(pk, txt, att)
                        if ok and new_ack then
                            entry.expected_ack = new_ack
                            entry.used_direct = direct
                        end
                    end)
                    ez.bus.post("dm/status", { pub_key_hex = pending.pub_key_hex, status = "retry", attempt = pending.attempt })
                else
                    -- ACK timeout: message was sent but delivery unconfirmed.
                    -- Conservatively assume the peer no longer has our
                    -- pubkey (e.g. they cleared their node cache or
                    -- rebooted without us as a contact) so the NEXT DM
                    -- to them will re-bundle an advert. Also evict the
                    -- cached return path if this attempt used it —
                    -- odds are good the path has gone stale (dead hop),
                    -- and forcing a FLOOD next time will re-learn via
                    -- the eventual PATH_RETURN.
                    if pending.msg_ref then
                        pending.msg_ref.status = "unconfirmed"
                    end
                    if pending.used_direct then
                        return_paths[pending.pub_key_hex] = nil
                    end
                    pending_acks[id] = nil
                    contacts_svc.set_known_by(pending.pub_key_hex, false)
                    ez.bus.post("dm/status", { pub_key_hex = pending.pub_key_hex, status = "unconfirmed" })
                    schedule_save()
                end
            end
        end
    end)

    ez.log("[DM] Service initialized")
end

function dm.send(pub_key_hex, text)
    if not text or #text == 0 then return false end
    if #text > MAX_TEXT then text = text:sub(1, MAX_TEXT) end
    if not ez.mesh.is_initialized() then return false end

    -- Create the local bubble FIRST and notify the UI so the chat
    -- screen paints the "pending" message on the next frame. Then
    -- hand the expensive half off to a coroutine: X25519 derivation
    -- (first send only), AES + HMAC, packet assembly. Every crypto
    -- step yields onto the AsyncIO worker thread, so the main loop
    -- stays free to draw and handle input while the worker grinds.
    local msg = {
        sender_key  = ez.mesh.get_public_key_hex(),
        sender_name = ez.mesh.get_node_name() or "Me",
        text        = text,
        timestamp   = ez.system.millis(),
        is_self     = true,
        status      = "pending",
    }
    local stored = store_message(pub_key_hex, msg)
    ez.bus.post("dm/message", msg)

    spawn(function()
        -- Auto-advert for first-contact DMs. send_announce itself is
        -- sync (a tiny build + queue_send), so one small blocking
        -- step on the worker trip, but it happens before the longer
        -- X25519 / AES / HMAC sequence and is dwarfed by them.
        if contacts_svc.is_contact(pub_key_hex)
                and not contacts_svc.is_known_by(pub_key_hex) then
            if ez.mesh.send_announce then
                ez.mesh.send_announce()
            end
        end

        local sent, expected_ack, used_direct = transmit(pub_key_hex, text, 0)
        if not sent then
            stored.status = "failed"
            ez.bus.post("dm/status", {
                pub_key_hex = pub_key_hex, status = "failed",
            })
            schedule_save()
            return
        end

        local ack_setting = contacts_svc.is_ack_enabled(pub_key_hex)
        if ack_setting == false then
            stored.status = "sent"
            ez.bus.post("dm/status", {
                pub_key_hex = pub_key_hex, status = "sent",
            })
            schedule_save()
        else
            local id = next_msg_id
            next_msg_id = next_msg_id + 1
            pending_acks[id] = {
                pub_key_hex  = pub_key_hex,
                text         = text,
                attempt      = 0,
                sent_at      = ez.system.millis(),
                msg_ref      = stored,
                expected_ack = expected_ack,
                used_direct  = used_direct,
            }
        end
    end)

    -- Return true for callers that check — actual delivery outcome
    -- surfaces asynchronously via the dm/status bus.
    return true
end

function dm.get_history(pub_key_hex)
    return conversations[pub_key_hex] or {}
end

function dm.get_unread(pub_key_hex)
    return unread[pub_key_hex] or 0
end

function dm.delete_message(pub_key_hex, index)
    local h = conversations[pub_key_hex]
    if not h or not h[index] then return end
    table.remove(h, index)
    if #h == 0 then
        conversations[pub_key_hex] = nil
    end
    schedule_save()
end

function dm.mark_read(pub_key_hex)
    if (unread[pub_key_hex] or 0) > 0 then
        unread[pub_key_hex] = 0
        schedule_save()
    end
end

function dm.get_total_unread()
    local total = 0
    for _, count in pairs(unread) do
        total = total + count
    end
    return total
end

-- Number of encrypted DMs we received but couldn't decrypt because the
-- sender was unknown at arrival time. These are not readable until an
-- ADVERT or contact add reveals the sender's pubkey, at which point they
-- auto-promote into the normal conversation store.
function dm.get_pending_count()
    return pending_count
end

-- Return-path diagnostics: a snapshot of every cached ROUTE_DIRECT
-- path. Each entry has the contact's pub_key_hex, their display name
-- (from the contact list, or the 8-char pubkey prefix if they aren't a
-- contact), the hop count, a human-readable hex-string view of the
-- path, and how long ago the path was learned in milliseconds.
function dm.get_return_paths()
    local out = {}
    local now = ez.system.millis()
    for pk, rp in pairs(return_paths) do
        local contact = contacts_svc.get(pk)
        local hex = ""
        for i = 1, #rp.bytes do
            hex = hex .. string.format("%02X ", rp.bytes:byte(i))
        end
        out[#out + 1] = {
            pub_key_hex = pk,
            name        = contact and contact.name or pk:sub(1, 8),
            hop_count   = #rp.bytes,
            path_hex    = hex:gsub("%s+$", ""),
            age_ms      = now - (rp.learned_at_ms or now),
        }
    end
    table.sort(out, function(a, b) return a.age_ms < b.age_ms end)
    return out
end

-- Force-drop the cached return path for a peer — handy when testing or
-- when a user wants to manually force the next DM back to FLOOD.
function dm.clear_return_path(pub_key_hex)
    return_paths[pub_key_hex] = nil
end

-- Raw-bytes accessor for sibling services (custom_packets) that want
-- to route their own datagrams through the same cached path. Returns
-- the byte string for ez.mesh.build_packet's `path` argument, or nil
-- if no path is cached.
function dm.get_return_path_bytes(pub_key_hex)
    local rp = return_paths[pub_key_hex]
    return rp and rp.bytes or nil
end

-- Internal helpers exposed for sibling services (notably the
-- custom_packets layer) that need the same crypto + candidate search.
-- Sharing the same get_enc_key means secret_cache is a single table
-- across DM and custom packets — first-contact X25519 only happens
-- once per peer. Prefixed with underscore to signal "not for app use".
dm._internal = {
    hex_to_bytes     = hex_to_bytes,
    get_enc_key      = get_enc_key,
    encrypt_then_mac = encrypt_then_mac,
    mac_then_decrypt = mac_then_decrypt,
    build_candidates = build_candidates,
}

-- Group the pending buffer by src_hash for UI display. Returns a list of
-- { src_hash, count, latest_ms } sorted by most recent first. The src_hash
-- is a single byte — far from unique across the mesh, but it's the only
-- identifying info we have before decryption.
function dm.get_pending_summary()
    local buckets = {}
    for _, p in pairs(pending_ciphertexts) do
        local b = buckets[p.src_hash]
        if not b then
            b = { src_hash = p.src_hash, count = 0, latest_ms = 0 }
            buckets[p.src_hash] = b
        end
        b.count = b.count + 1
        if p.received_at_ms > b.latest_ms then
            b.latest_ms = p.received_at_ms
        end
    end
    local out = {}
    for _, b in pairs(buckets) do out[#out + 1] = b end
    table.sort(out, function(a, b) return a.latest_ms > b.latest_ms end)
    return out
end

-- Get list of conversations with last message info, sorted by recency
function dm.get_conversations()
    local result = {}
    for key, msgs in pairs(conversations) do
        if #msgs > 0 then
            local last = msgs[#msgs]
            local contact = contacts_svc.get(key)
            result[#result + 1] = {
                pub_key_hex = key,
                name = contact and contact.name or key:sub(1, 8),
                last_msg = last,
                unread = unread[key] or 0,
                last_time = last.timestamp or 0,
            }
        end
    end
    table.sort(result, function(a, b) return a.last_time > b.last_time end)
    return result
end

return dm
