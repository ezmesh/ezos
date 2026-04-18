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
local MAX_RETRIES = 2
local RETRY_INTERVAL = 10000  -- 10 seconds between retries
local ACK_TIMEOUT = 15000     -- Give up after 15 seconds with no ACK
local SAVE_PATH = "/fs/dm_history.json"
local SAVE_DELAY = 2000       -- Debounce: write at most every 2 seconds

-- State
local conversations = {}   -- { [pub_key_hex] = { messages... } }
local unread = {}           -- { [pub_key_hex] = count }
local secret_cache = {}     -- { [pub_key_hex] = { secret, key } }
local pending_acks = {}     -- { [id] = { pub_key_hex, text, attempt, sent_at, msg_ref } }
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

-- Get or compute encryption keys for a contact
local function get_enc_key(pub_key_hex)
    local cached = secret_cache[pub_key_hex]
    if cached then return cached end

    local pub_key = hex_to_bytes(pub_key_hex)
    if not pub_key or #pub_key ~= 32 then return nil end

    local secret = ez.mesh.calc_shared_secret(pub_key)
    if not secret then return nil end

    local result = { secret = secret, key = secret:sub(1, 16) }
    secret_cache[pub_key_hex] = result
    return result
end

-- Encrypt-then-MAC: returns [MAC:2][ciphertext]
-- MAC uses the full 32-byte shared secret, encryption uses first 16 bytes
local function encrypt_then_mac(secret, key, plaintext)
    local ct = ez.crypto.aes128_ecb_encrypt(key, plaintext)
    if not ct then return nil end
    local hmac = ez.crypto.hmac_sha256(secret, ct)
    if not hmac then return nil end
    return hmac:sub(1, MAC_SIZE) .. ct
end

-- MAC-then-decrypt: input [MAC:2][ciphertext], returns plaintext or nil
local function mac_then_decrypt(secret, key, data)
    if #data < MAC_SIZE + 16 then return nil end
    local mac = data:sub(1, MAC_SIZE)
    local ct = data:sub(MAC_SIZE + 1)
    if #ct % 16 ~= 0 then return nil end
    local hmac = ez.crypto.hmac_sha256(secret, ct)
    if not hmac or hmac:sub(1, MAC_SIZE) ~= mac then return nil end
    return ez.crypto.aes128_ecb_decrypt(key, ct)
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

-- Store message in conversation history
local function store_message(pub_key_hex, msg)
    if not conversations[pub_key_hex] then
        conversations[pub_key_hex] = {}
    end
    local h = conversations[pub_key_hex]

    -- Group consecutive duplicates
    local last = h[#h]
    if last and last.text == msg.text and last.is_self == msg.is_self then
        last.count = (last.count or 1) + 1
        last.timestamp = msg.timestamp
        return last
    end

    msg.count = 1
    h[#h + 1] = msg
    while #h > MAX_HISTORY do
        table.remove(h, 1)
    end
    schedule_save()
    return msg
end

-- Send an ACK packet to confirm receipt of a TXT_MSG
local function send_ack(src_hash)
    if not ez.mesh.is_initialized() then return end
    local my_hash = ez.mesh.get_path_hash()
    -- ACK payload: [dest_hash:1][src_hash:1] (minimal — just identifies the pair)
    local payload = string.char(src_hash) .. string.char(my_hash)
    local pkt = ez.mesh.build_packet(1, PAYLOAD_ACK, payload)
    if pkt then
        ez.mesh.queue_send(pkt)
    end
end

-- Internal: transmit a DM (used by both send and retry)
local function transmit(pub_key_hex, text, attempt)
    local enc = get_enc_key(pub_key_hex)
    if not enc then return false end

    local timestamp = 0
    if ez.system.get_time then
        local t = ez.system.get_time()
        if t and t.epoch then timestamp = t.epoch end
    end
    -- Lower 2 bits of flags = attempt number
    local flags = math.min(attempt or 0, 3)
    local inner = pack_u32le(timestamp) .. string.char(flags) .. text

    local encrypted = encrypt_then_mac(enc.secret, enc.key, inner)
    if not encrypted then return false end

    local pub_key = hex_to_bytes(pub_key_hex)
    local dest_hash = pub_key:byte(1)
    local our_hash = ez.mesh.get_path_hash()
    local payload = string.char(dest_hash) .. string.char(our_hash) .. encrypted

    local pkt = ez.mesh.build_packet(1, PAYLOAD_TXT_MSG, payload)
    if not pkt then return false end

    return ez.mesh.queue_send(pkt)
end

-- =========================================================================
-- Public API
-- =========================================================================

function dm.init()
    if initialized then return end
    initialized = true

    load_history()

    -- Subscribe to all incoming packets
    ez.bus.subscribe("mesh/packet", function(topic, pkt)
        if not pkt or not pkt.payload then return end

        -- Handle ACK packets: mark matching sent messages as delivered
        if pkt.payload_type == PAYLOAD_ACK and #pkt.payload >= 2 then
            local dest_hash = pkt.payload:byte(1)
            local src_hash = pkt.payload:byte(2)
            local my_hash = ez.mesh.get_path_hash()
            if dest_hash == my_hash then
                -- ACK addressed to us — mark all pending messages to this sender as delivered
                for id, pending in pairs(pending_acks) do
                    local pub = hex_to_bytes(pending.pub_key_hex)
                    if pub and pub:byte(1) == src_hash then
                        if pending.msg_ref then
                            pending.msg_ref.status = "delivered"
                        end
                        pending_acks[id] = nil
                        -- Auto-enable ACK tracking for this contact
                        contacts_svc.set_ack_enabled(pending.pub_key_hex, true)
                        ez.bus.post("dm/status", { pub_key_hex = pending.pub_key_hex, status = "delivered" })
                        schedule_save()
                    end
                end
            end
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
        local candidates = {}
        local all_contacts = contacts_svc.get_all()
        for _, c in ipairs(all_contacts) do
            local pub = hex_to_bytes(c.pub_key_hex)
            if pub and pub:byte(1) == src_hash then
                candidates[#candidates + 1] = c
            end
        end
        if ez.mesh.is_initialized() then
            local nodes = ez.mesh.get_nodes() or {}
            for _, node in ipairs(nodes) do
                if node.pub_key_hex and not contacts_svc.is_contact(node.pub_key_hex) then
                    local pub = hex_to_bytes(node.pub_key_hex)
                    if pub and pub:byte(1) == src_hash then
                        candidates[#candidates + 1] = {
                            pub_key_hex = node.pub_key_hex,
                            name = node.name,
                        }
                    end
                end
            end
        end

        if #candidates == 0 then return end

        for _, candidate in ipairs(candidates) do
            local enc = get_enc_key(candidate.pub_key_hex)
            if enc then
                local plaintext = mac_then_decrypt(enc.secret, enc.key, encrypted)
                if plaintext then
                    plaintext = plaintext:gsub("\0+$", "")

                    if #plaintext >= 6 then
                        local b1, b2, b3, b4 = plaintext:byte(1, 4)
                        local msg_timestamp = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
                        local flags = plaintext:byte(5)
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

                            -- Send ACK back to sender
                            send_ack(src_hash)
                            return
                        end
                    end
                end
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
                    -- Retry
                    pending.attempt = pending.attempt + 1
                    pending.sent_at = now
                    if pending.msg_ref then
                        pending.msg_ref.status = "pending"
                    end
                    transmit(pending.pub_key_hex, pending.text, pending.attempt)
                    ez.bus.post("dm/status", { pub_key_hex = pending.pub_key_hex, status = "retry", attempt = pending.attempt })
                else
                    -- ACK timeout: message was sent but delivery unconfirmed
                    if pending.msg_ref then
                        pending.msg_ref.status = "unconfirmed"
                    end
                    pending_acks[id] = nil
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

    local sent = transmit(pub_key_hex, text, 0)

    local msg = {
        sender_key = ez.mesh.get_public_key_hex(),
        sender_name = ez.mesh.get_node_name() or "Me",
        text = text,
        timestamp = ez.system.millis(),
        is_self = true,
        status = sent and "pending" or "failed",
    }
    local stored = store_message(pub_key_hex, msg)

    -- Only track for ACK/retry if send succeeded and contact supports ACK
    if sent then
        local ack_setting = contacts_svc.is_ack_enabled(pub_key_hex)
        if ack_setting == false then
            -- Contact known to not support ACKs: mark as sent immediately
            stored.status = "sent"
        else
            -- ACK enabled or unknown: track for delivery confirmation
            local id = next_msg_id
            next_msg_id = next_msg_id + 1
            pending_acks[id] = {
                pub_key_hex = pub_key_hex,
                text = text,
                attempt = 0,
                sent_at = ez.system.millis(),
                msg_ref = stored,
            }
        end
    end

    ez.bus.post("dm/message", msg)
    return sent
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
