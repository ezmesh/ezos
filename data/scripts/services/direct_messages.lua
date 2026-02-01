-- Direct Messages service
-- Handles encrypted direct messaging over MeshCore with Ed25519 signature verification

local DirectMessages = {
    -- Conversations: { pub_key_hex = { messages, unread, last_activity, contact_name } }
    conversations = {},
    -- Message callbacks
    _on_message = nil,
    -- Request callbacks: { request_type = handler_function }
    _request_handlers = {},
    -- Pending requests awaiting response: { request_id = { callback, timeout, pub_key_hex } }
    _pending_requests = {},
    -- Sequence counter for ordering messages within same second
    _seq = 0,
    -- Shared secret cache: { pub_key_hex = { secret, key } }
    _secret_cache = {},
    -- Pending TXT_MSG packets from unknown senders (waiting for ADVERT)
    -- { path_hash = { packet, received_at } }
    _pending_packets = {},
    -- How long to keep pending packets (30 seconds)
    PENDING_PACKET_TTL = 30 * 1000,
    -- Constants
    MAX_MESSAGES = 100,
    MAX_MESSAGE_TEXT = 120,
    ROUTE_REFRESH_INTERVAL = 5 * 60 * 1000,  -- Refresh route every 5 minutes via FLOOD
    ACK_TIMEOUT = 10 * 1000,       -- Wait 10 seconds for ACK before retry
    MAX_ACK_RETRIES = 3,           -- Max REQ_ACK retries before marking failed
    GAP_RETRY_INTERVAL = 10 * 1000, -- Retry gap fill every 10 seconds
    MAX_GAP_RETRIES = 3,           -- Max gap retry requests before marking failed
    PAYLOAD_TYPE_REQ = 0,      -- PayloadType::REQ
    PAYLOAD_TYPE_RESPONSE = 1, -- PayloadType::RESPONSE
    PAYLOAD_TYPE_TXT_MSG = 2,  -- PayloadType::TXT_MSG
    PAYLOAD_TYPE_ACK = 3,      -- PayloadType::ACK
    PAYLOAD_TYPE_PATH = 8,     -- PayloadType::PATH
    ROUTE_TYPE_FLOOD = 1,      -- RouteType::FLOOD
    ROUTE_TYPE_DIRECT = 2,     -- RouteType::DIRECT
    MAC_SIZE = 2,              -- MeshCore uses 2-byte MAC for TXT_MSG
    REQ_MAC_SIZE = 16,         -- REQ/RESPONSE use 16-byte MAC
    -- Request types (MeshCore reserved)
    REQ_TYPE_GET_STATUS = 0x01,
    REQ_TYPE_KEEP_ALIVE = 0x02,
    -- Custom request types (0x80+)
    REQ_TYPE_REQ_ACK = 0x80,    -- Request ACK for a specific message
    REQ_TYPE_RETRY_MSG = 0x81,  -- Request resend of a specific message
}

-- Helper: Convert binary string to hex
local function bytes_to_hex(str)
    if not str then return nil end
    local hex = ""
    for i = 1, #str do
        hex = hex .. string.format("%02X", string.byte(str, i))
    end
    return hex
end

-- Helper: Convert hex string to binary
local function hex_to_bytes(hex)
    if not hex or #hex % 2 ~= 0 then return nil end
    local bytes = ""
    for i = 1, #hex, 2 do
        local byte = tonumber(hex:sub(i, i + 1), 16)
        if not byte then return nil end
        bytes = bytes .. string.char(byte)
    end
    return bytes
end

-- Get or compute shared secret and encryption key for a contact
-- Returns { secret = 32-byte shared secret, key = 16-byte AES key }
local function get_encryption_key(pub_key_hex)
    -- Check cache
    local cached = DirectMessages._secret_cache[pub_key_hex]
    if cached then
        return cached
    end

    -- Calculate shared secret
    local pub_key_bytes = hex_to_bytes(pub_key_hex)
    if not pub_key_bytes or #pub_key_bytes ~= 32 then
        ez.log("[DirectMessages] Invalid public key for encryption")
        return nil
    end

    local secret = ez.mesh.calc_shared_secret(pub_key_bytes)
    if not secret then
        ez.log("[DirectMessages] Failed to calculate shared secret")
        return nil
    end

    -- Derive 16-byte AES key from 32-byte shared secret (use first 16 bytes)
    local key = secret:sub(1, 16)

    -- Cache the result
    local result = { secret = secret, key = key }
    DirectMessages._secret_cache[pub_key_hex] = result

    ez.log("[DirectMessages] Computed encryption key for " .. pub_key_hex:sub(1, 8))
    return result
end

-- Encrypt plaintext using AES-128-ECB with encrypt-then-MAC
-- Returns: [MAC:2][ciphertext:variable]
local function encrypt_message(key, plaintext)
    if not key or #key ~= 16 then
        return nil
    end

    -- Encrypt with AES-128-ECB
    local ciphertext = ez.crypto.aes128_ecb_encrypt(key, plaintext)
    if not ciphertext then
        return nil
    end

    -- Compute MAC (first 2 bytes of HMAC-SHA256 of ciphertext)
    local hmac = ez.crypto.hmac_sha256(key, ciphertext)
    if not hmac then
        return nil
    end
    local mac = hmac:sub(1, 2)

    return mac .. ciphertext
end

-- Decrypt ciphertext with MAC verification
-- Input: [MAC:2][ciphertext:variable]
-- Returns decrypted bytes or nil on MAC failure
local function decrypt_message(key, mac_and_ciphertext)
    if not key or #key ~= 16 then
        return nil
    end

    if #mac_and_ciphertext < 2 + 16 then  -- MAC + at least one AES block
        return nil
    end

    local mac = mac_and_ciphertext:sub(1, 2)
    local ciphertext = mac_and_ciphertext:sub(3)

    -- Verify MAC
    local computed_hmac = ez.crypto.hmac_sha256(key, ciphertext)
    if not computed_hmac then
        return nil
    end
    local computed_mac = computed_hmac:sub(1, 2)

    if mac ~= computed_mac then
        ez.log("[DirectMessages] MAC verification failed")
        return nil
    end

    -- Decrypt with AES-128-ECB
    local decrypted = ez.crypto.aes128_ecb_decrypt(key, ciphertext)
    return decrypted
end

-- Encrypt payload for REQ/RESPONSE packets (16-byte MAC)
-- Returns: [MAC:16][ciphertext:variable]
local function encrypt_req_payload(key, plaintext)
    if not key or #key ~= 16 then
        return nil
    end

    -- Encrypt with AES-128-ECB
    local ciphertext = ez.crypto.aes128_ecb_encrypt(key, plaintext)
    if not ciphertext then
        return nil
    end

    -- Compute 16-byte MAC (first 16 bytes of HMAC-SHA256 of ciphertext)
    local hmac = ez.crypto.hmac_sha256(key, ciphertext)
    if not hmac then
        return nil
    end
    local mac = hmac:sub(1, 16)

    return mac .. ciphertext
end

-- Decrypt REQ/RESPONSE payload with 16-byte MAC verification
-- Input: [MAC:16][ciphertext:variable]
-- Returns decrypted bytes or nil on MAC failure
local function decrypt_req_payload(key, mac_and_ciphertext)
    if not key or #key ~= 16 then
        return nil
    end

    if #mac_and_ciphertext < 16 + 16 then  -- 16-byte MAC + at least one AES block
        return nil
    end

    local mac = mac_and_ciphertext:sub(1, 16)
    local ciphertext = mac_and_ciphertext:sub(17)

    -- Verify MAC
    local computed_hmac = ez.crypto.hmac_sha256(key, ciphertext)
    if not computed_hmac then
        return nil
    end
    local computed_mac = computed_hmac:sub(1, 16)

    if mac ~= computed_mac then
        ez.log("[DirectMessages] REQ/RESPONSE MAC verification failed")
        return nil
    end

    -- Decrypt with AES-128-ECB
    local decrypted = ez.crypto.aes128_ecb_decrypt(key, ciphertext)
    return decrypted
end

-- Helper: Get storage path for a conversation
local function get_conversation_path(pub_key_hex)
    -- Use first 8 chars of pub key as filename
    local short = pub_key_hex:sub(1, 8):upper()
    if ez.storage.is_sd_available() then
        local dir = "/sd/data/messages"
        if not ez.storage.exists("/sd/data") then
            ez.storage.mkdir("/sd/data")
        end
        if not ez.storage.exists(dir) then
            ez.storage.mkdir(dir)
        end
        return dir .. "/" .. short .. ".json"
    end
    return "/messages_" .. short .. ".json"
end

-- Helper: Generate unique message ID
local function generate_message_id(timestamp, text, sender_hex)
    -- Include millis for uniqueness even with same timestamp/text
    local millis = ez.system.millis()
    local data = tostring(timestamp) .. tostring(millis) .. (text or ""):sub(1, 20) .. (sender_hex or ""):sub(1, 8)
    local hash = 0
    for i = 1, #data do
        hash = (hash * 31 + string.byte(data, i)) % 0xFFFFFFFF
    end
    return string.format("%08X", hash)
end

-- Helper: Pack uint16 as little-endian
local function pack_uint16_le(n)
    return string.char(n & 0xFF, (n >> 8) & 0xFF)
end

-- Helper: Unpack uint16 from little-endian
local function unpack_uint16_le(str, offset)
    offset = offset or 1
    if #str < offset + 1 then return nil end
    return string.byte(str, offset) + string.byte(str, offset + 1) * 256
end

-- Helper: Pack uint32 as little-endian
local function pack_uint32_le(n)
    return string.char(
        n & 0xFF,
        (n >> 8) & 0xFF,
        (n >> 16) & 0xFF,
        (n >> 24) & 0xFF
    )
end

-- Helper: Unpack uint32 from little-endian
local function unpack_uint32_le(str, offset)
    offset = offset or 1
    if #str < offset + 3 then return nil end
    return string.byte(str, offset) +
           string.byte(str, offset + 1) * 256 +
           string.byte(str, offset + 2) * 65536 +
           string.byte(str, offset + 3) * 16777216
end

-- Sort messages in a conversation by counter
-- Sent and received have separate counters, so we sort by counter with direction as tiebreaker
-- This ensures: sent1, recv1, sent2, recv2, etc. (approximately chronological)
local function sort_messages(messages)
    table.sort(messages, function(a, b)
        -- Primary sort: by counter
        if a.counter ~= b.counter then
            return a.counter < b.counter
        end
        -- Secondary sort: sent before received for same counter (we usually send first)
        if a.direction ~= b.direction then
            return a.direction == "sent"
        end
        -- Tertiary sort: by seq (arrival order) as final tiebreaker
        return (a.seq or 0) < (b.seq or 0)
    end)
end

-- Helper: Get contact name from Contacts service or nodes
local function get_contact_name(pub_key_hex)
    -- Check saved contacts first
    if _G.Contacts and _G.Contacts.is_saved then
        local contact = _G.Contacts.is_saved(pub_key_hex)
        if contact then
            return contact.name
        end
    end

    -- Check mesh nodes
    if ez.mesh.is_initialized() then
        local nodes = ez.mesh.get_nodes() or {}
        for _, node in ipairs(nodes) do
            if node.pub_key_hex == pub_key_hex then
                return node.name
            end
        end
    end

    -- Fallback to short hex
    return pub_key_hex:sub(1, 8)
end

-- Initialize the direct messages service
function DirectMessages.init()
    -- Load existing conversations from storage
    DirectMessages._load_all()

    -- Subscribe to incoming packets via message bus
    if ez.bus and ez.bus.subscribe then
        ez.bus.subscribe("mesh/packet", function(topic, packet)
            -- packet is a table with route_type, payload_type, path, payload, rssi, snr, timestamp
            DirectMessages._handle_packet(packet)
        end)
    end

    -- Start periodic send queue processor (every 5 seconds)
    if _G.set_interval then
        _G.set_interval(function()
            DirectMessages._process_send_queue()
        end, 5000)

        -- Start periodic retry processor (every 2 seconds)
        _G.set_interval(function()
            DirectMessages._process_retries()
        end, 2000)
    end

    -- Register handlers for custom request types
    DirectMessages._register_builtin_handlers()

    -- Subscribe to node discovery events via bus
    -- This decouples DirectMessages from Contacts service
    if ez.bus and ez.bus.subscribe then
        ez.bus.subscribe("mesh/node_discovered", function(topic, node)
            -- node is a table with path_hash, name, pub_key_hex, etc.
            DirectMessages._on_node_discovered(node)
        end)
    end

    -- Clean up old pending packets periodically
    if _G.set_interval then
        _G.set_interval(function()
            DirectMessages._cleanup_pending_packets()
        end, 10000)  -- Every 10 seconds
    end

    ez.log("[DirectMessages] Initialized with " .. DirectMessages._count_conversations() .. " conversations")
end

-- Handle node discovery - retry any pending packets from this node
-- Called via bus subscription to mesh/node_discovered events
function DirectMessages._on_node_discovered(node)
    if not node or not node.path_hash then return end

    local pending = DirectMessages._pending_packets[node.path_hash]
    if pending then
        ez.log(string.format("[DirectMessages] Node discovered with hash %02X, retrying pending packet",
              node.path_hash))
        -- Remove from pending before retry (to avoid infinite loop)
        DirectMessages._pending_packets[node.path_hash] = nil
        -- Retry handling the packet
        DirectMessages._handle_packet(pending.packet)
    end
end

-- Cleanup old pending packets
function DirectMessages._cleanup_pending_packets()
    local now = ez.system.millis()
    local expired = {}

    for hash, pending in pairs(DirectMessages._pending_packets) do
        if now - pending.received_at > DirectMessages.PENDING_PACKET_TTL then
            table.insert(expired, hash)
        end
    end

    for _, hash in ipairs(expired) do
        ez.log(string.format("[DirectMessages] Expired pending packet from hash %02X", hash))
        DirectMessages._pending_packets[hash] = nil
    end
end

-- Register built-in request handlers
function DirectMessages._register_builtin_handlers()
    -- REQ_ACK: Someone is requesting ACKs for messages they sent us
    -- Request data: [count:1][counter1:2][counter2:2]... (batched counters)
    DirectMessages.on_request(DirectMessages.REQ_TYPE_REQ_ACK, function(sender_pub_key_hex, data, timestamp)
        if #data < 1 then return nil end
        local count = string.byte(data, 1)
        if count == 0 or #data < 1 + count * 2 then return nil end

        ez.log(string.format("[DirectMessages] REQ_ACK for %d counters from %s",
              count, sender_pub_key_hex:sub(1, 8)))

        -- Find the conversation
        local conv = DirectMessages.conversations[sender_pub_key_hex]
        if not conv then return nil end

        -- Process each requested counter
        for i = 1, count do
            local offset = 2 + (i - 1) * 2
            local counter = unpack_uint16_le(data, offset)
            if counter then
                -- Find the message in our received messages
                for _, msg in ipairs(conv.messages) do
                    if msg.direction == "received" and msg.counter == counter then
                        -- Send ACK for this message
                        local text_hash = DirectMessages._compute_text_hash(msg.text)
                        DirectMessages._send_ack(sender_pub_key_hex, counter, text_hash)
                        ez.log(string.format("[DirectMessages] Sent ACK for counter %d", counter))
                        break
                    end
                end
            end
        end

        return nil  -- ACKs sent separately, no RESPONSE needed
    end)

    -- RETRY_MSG: Someone is requesting we resend messages
    -- Request data: [count:1][counter1:2][counter2:2]... (batched counters)
    DirectMessages.on_request(DirectMessages.REQ_TYPE_RETRY_MSG, function(sender_pub_key_hex, data, timestamp)
        if #data < 1 then return nil end
        local count = string.byte(data, 1)
        if count == 0 or #data < 1 + count * 2 then return nil end

        ez.log(string.format("[DirectMessages] RETRY_MSG for %d counters from %s",
              count, sender_pub_key_hex:sub(1, 8)))

        -- Find the conversation
        local conv = DirectMessages.conversations[sender_pub_key_hex]
        if not conv then return nil end

        -- Process each requested counter
        for i = 1, count do
            local offset = 2 + (i - 1) * 2
            local counter = unpack_uint16_le(data, offset)
            if counter then
                -- Find the message in our sent messages
                for _, msg in ipairs(conv.messages) do
                    if msg.direction == "sent" and msg.counter == counter then
                        -- Resend this message
                        ez.log("[DirectMessages] Resending message #" .. counter)
                        DirectMessages._try_send_message(sender_pub_key_hex, msg)
                        break
                    end
                end
            end
        end

        return nil  -- Messages resent, no RESPONSE needed
    end)
end

-- Get or create conversation, returns the conversation table
local function get_or_create_conversation(pub_key_hex)
    if not DirectMessages.conversations[pub_key_hex] then
        DirectMessages.conversations[pub_key_hex] = {
            messages = {},
            unread = 0,
            last_activity = 0,
            contact_name = get_contact_name(pub_key_hex),
            send_counter = 0,      -- Counter for outgoing messages
            recv_counter = 0,      -- Last received counter from this contact
            out_path = nil,        -- Learned path to contact (nil = unknown, flood required)
            route_refreshed_at = 0, -- Last time we sent via FLOOD to refresh route
        }
    end
    return DirectMessages.conversations[pub_key_hex]
end

-- Queue a direct message to be sent
-- Message is stored immediately and sent asynchronously
-- @param recipient_pub_key_hex Public key of recipient as hex string
-- @param text Message text
-- @return true if queued successfully
function DirectMessages.send(recipient_pub_key_hex, text)
    if not text or #text == 0 then
        return false
    end

    if #text > DirectMessages.MAX_MESSAGE_TEXT then
        text = text:sub(1, DirectMessages.MAX_MESSAGE_TEXT)
    end

    -- Get conversation and increment send counter
    local conv = get_or_create_conversation(recipient_pub_key_hex)
    conv.send_counter = (conv.send_counter or 0) + 1
    local counter = conv.send_counter

    local our_pub_key_hex = ez.mesh.get_public_key_hex()
    DirectMessages._seq = DirectMessages._seq + 1

    local msg = {
        id = generate_message_id(counter, text, our_pub_key_hex),
        direction = "sent",
        text = text,
        counter = counter,  -- Message sequence counter
        seq = DirectMessages._seq,  -- Local ordering
        verified = true,
        sendCount = 0,  -- Not yet sent
        recipient = recipient_pub_key_hex,
    }

    DirectMessages._store_message(recipient_pub_key_hex, msg)
    ez.log("[DirectMessages] Queued message #" .. counter .. " to " .. recipient_pub_key_hex:sub(1, 8))

    -- Try to send immediately
    DirectMessages._try_send_message(recipient_pub_key_hex, msg)

    return true
end

-- Actually attempt to send a message over the mesh
-- Uses FLOOD routing if no path known, DIRECT routing if path is cached
-- @return true if sent successfully
function DirectMessages._try_send_message(recipient_pub_key_hex, msg)
    if not ez.mesh.is_initialized() then
        return false
    end

    -- For the first message (counter=1), send an ADVERT first to ensure the
    -- recipient knows our public key. Without this, the recipient may not be
    -- able to decrypt our message if they haven't added us as a contact.
    local conv = DirectMessages.conversations[recipient_pub_key_hex]
    if msg.counter == 1 and conv and not conv._sent_intro_advert then
        ez.log("[DirectMessages] First message - sending ADVERT to introduce ourselves")
        if ez.mesh.send_announce then
            ez.mesh.send_announce()
            conv._sent_intro_advert = true
        end
    end

    -- Get our path hash and recipient path hash
    local our_hash = ez.mesh.get_path_hash()
    local recipient_pub_key = hex_to_bytes(recipient_pub_key_hex)
    if not recipient_pub_key or #recipient_pub_key ~= 32 then
        return false
    end
    local recipient_hash = string.byte(recipient_pub_key, 1)

    -- Build inner payload: [counter:2][reserved:2][signature:64][text]
    local counter = msg.counter or 0
    local reserved = 0
    local sign_data = pack_uint16_le(counter) .. pack_uint16_le(reserved) .. msg.text
    local signature = ez.mesh.ed25519_sign(sign_data)
    if not signature then
        return false
    end

    local inner_payload = pack_uint16_le(counter) .. pack_uint16_le(reserved) .. signature .. msg.text

    -- Encrypt the payload
    local enc_key_data = get_encryption_key(recipient_pub_key_hex)
    if not enc_key_data then
        ez.log("[DirectMessages] Failed to get encryption key for " .. recipient_pub_key_hex:sub(1, 8))
        return false
    end

    local encrypted_payload = encrypt_message(enc_key_data.key, inner_payload)
    if not encrypted_payload then
        ez.log("[DirectMessages] Failed to encrypt message")
        return false
    end

    -- Check if we have a cached path to this contact
    local conv = DirectMessages.conversations[recipient_pub_key_hex]
    local out_path = conv and conv.out_path
    local route_type
    local path
    local now = ez.system.millis()

    -- Check if route needs refresh (periodic FLOOD to discover better paths)
    local needs_refresh = false
    if conv and out_path then
        local last_refresh = conv.route_refreshed_at or 0
        if now - last_refresh > DirectMessages.ROUTE_REFRESH_INTERVAL then
            needs_refresh = true
        end
    end

    if out_path and #out_path >= 0 and not needs_refresh then
        -- DIRECT routing: we know the path and it's fresh
        -- Path format: [our_hash, hop1, hop2, ..., recipient_hash]
        route_type = DirectMessages.ROUTE_TYPE_DIRECT
        path = string.char(our_hash) .. out_path .. string.char(recipient_hash)
        ez.log("[DirectMessages] Using DIRECT routing via " .. #out_path .. " hops")
    else
        -- FLOOD routing: path unknown OR time to refresh route
        -- Path format: [our_hash] - repeaters will append their hashes
        route_type = DirectMessages.ROUTE_TYPE_FLOOD
        path = string.char(our_hash)
        if needs_refresh then
            ez.log("[DirectMessages] Using FLOOD routing (periodic route refresh)")
            conv.route_refreshed_at = now
        else
            ez.log("[DirectMessages] Using FLOOD routing (no path cached)")
        end
    end

    local packet_data = ez.mesh.build_packet(
        route_type,
        DirectMessages.PAYLOAD_TYPE_TXT_MSG,
        encrypted_payload,
        path
    )

    if not packet_data then
        return false
    end

    local ok = ez.mesh.queue_send(packet_data)
    if ok then
        -- Update sendCount and sent_at timestamp
        msg.sendCount = (msg.sendCount or 0) + 1
        if not msg.sent_at then
            msg.sent_at = ez.system.millis()
        end
        DirectMessages._save_conversation(recipient_pub_key_hex)
        ez.log("[DirectMessages] Sent #" .. counter .. " to " .. recipient_pub_key_hex:sub(1, 8) .. ": " .. msg.text:sub(1, 20))
        return true
    end

    return false
end

-- Process send queue - find unsent messages and try to send them
function DirectMessages._process_send_queue()
    if not ez.mesh.is_initialized() then
        return
    end

    for pub_key_hex, conv in pairs(DirectMessages.conversations) do
        for _, msg in ipairs(conv.messages) do
            -- Only process our outgoing messages that haven't been sent
            if msg.direction == "sent" and (msg.sendCount or 0) < 1 then
                DirectMessages._try_send_message(pub_key_hex, msg)
            end
        end
    end
end

-- Process retries for unacked messages and gap fills
function DirectMessages._process_retries()
    if not ez.mesh.is_initialized() then
        return
    end

    local now = ez.system.millis()
    local needs_save = {}
    local needs_refresh = false

    for pub_key_hex, conv in pairs(DirectMessages.conversations) do
        local conv_needs_save = false

        -- Collect messages needing ACK retries (batch them)
        local ack_retry_msgs = {}
        -- Collect messages needing gap retries (batch them)
        local gap_retry_msgs = {}

        for _, msg in ipairs(conv.messages) do
            -- Skip already failed messages
            if msg.failed then
                goto continue
            end

            -- Process unacked sent messages
            if msg.direction == "sent" and not msg.acked and (msg.sendCount or 0) >= 1 then
                local sent_at = msg.sent_at or msg.seq * 1000  -- Fallback to seq-based estimate
                local last_retry = msg.last_ack_retry or sent_at
                local retry_count = msg.ack_retry_count or 0

                -- Check if enough time has passed since send/last retry
                if now - last_retry >= DirectMessages.ACK_TIMEOUT then
                    if retry_count >= DirectMessages.MAX_ACK_RETRIES then
                        -- Max retries exceeded - mark as failed and reset route
                        msg.failed = true
                        conv_needs_save = true
                        needs_refresh = true
                        ez.log(string.format("[DirectMessages] Message #%d failed after %d ACK retries",
                              msg.counter, retry_count))

                        -- Reset route for this conversation
                        if conv.out_path then
                            ez.log("[DirectMessages] Resetting route due to failed message")
                            conv.out_path = nil
                            conv.route_refreshed_at = 0
                        end
                    else
                        -- Collect for batched ACK request
                        table.insert(ack_retry_msgs, msg)
                    end
                end
            end

            -- Process gap messages (missing received messages)
            if msg.is_gap and not msg.failed then
                local created_at = msg.created_at or msg.seq * 1000
                local last_retry = msg.last_gap_retry or created_at
                local retry_count = msg.gap_retry_count or 0

                -- First retry is immediate (created_at == last_retry), then every GAP_RETRY_INTERVAL
                local should_retry = false
                if retry_count == 0 then
                    -- Immediate first retry
                    should_retry = true
                elseif now - last_retry >= DirectMessages.GAP_RETRY_INTERVAL then
                    should_retry = true
                end

                if should_retry then
                    if retry_count >= DirectMessages.MAX_GAP_RETRIES then
                        -- Max retries exceeded - mark as permanently failed
                        msg.failed = true
                        conv_needs_save = true
                        needs_refresh = true
                        ez.log(string.format("[DirectMessages] Gap #%d failed after %d retries",
                              msg.counter, retry_count))

                        -- Reset route for this conversation
                        if conv.out_path then
                            ez.log("[DirectMessages] Resetting route due to failed gap fill")
                            conv.out_path = nil
                            conv.route_refreshed_at = 0
                        end
                    else
                        -- Collect for batched gap retry request
                        table.insert(gap_retry_msgs, msg)
                    end
                end
            end

            ::continue::
        end

        -- Send batched ACK requests (max 10 per packet to stay within payload limits)
        if #ack_retry_msgs > 0 then
            local counters = {}
            for _, msg in ipairs(ack_retry_msgs) do
                table.insert(counters, msg.counter)
                if #counters >= 10 then
                    -- Send batch and start new one
                    local ok = DirectMessages.request_acks(pub_key_hex, counters)
                    if ok then
                        for _, c in ipairs(counters) do
                            for _, m in ipairs(ack_retry_msgs) do
                                if m.counter == c then
                                    m.ack_retry_count = (m.ack_retry_count or 0) + 1
                                    m.last_ack_retry = now
                                    break
                                end
                            end
                        end
                        conv_needs_save = true
                        ez.log(string.format("[DirectMessages] Requesting ACKs for %d messages (batched)", #counters))
                    end
                    counters = {}
                end
            end
            -- Send remaining
            if #counters > 0 then
                local ok = DirectMessages.request_acks(pub_key_hex, counters)
                if ok then
                    for _, c in ipairs(counters) do
                        for _, m in ipairs(ack_retry_msgs) do
                            if m.counter == c then
                                m.ack_retry_count = (m.ack_retry_count or 0) + 1
                                m.last_ack_retry = now
                                break
                            end
                        end
                    end
                    conv_needs_save = true
                    ez.log(string.format("[DirectMessages] Requesting ACKs for %d messages (batched)", #counters))
                end
            end
        end

        -- Send batched gap retry requests (max 10 per packet)
        if #gap_retry_msgs > 0 then
            local counters = {}
            for _, msg in ipairs(gap_retry_msgs) do
                table.insert(counters, msg.counter)
                if #counters >= 10 then
                    -- Send batch and start new one
                    local ok = DirectMessages.request_retries(pub_key_hex, counters)
                    if ok then
                        for _, c in ipairs(counters) do
                            for _, m in ipairs(gap_retry_msgs) do
                                if m.counter == c then
                                    m.gap_retry_count = (m.gap_retry_count or 0) + 1
                                    m.last_gap_retry = now
                                    break
                                end
                            end
                        end
                        conv_needs_save = true
                        ez.log(string.format("[DirectMessages] Requesting retries for %d gaps (batched)", #counters))
                    end
                    counters = {}
                end
            end
            -- Send remaining
            if #counters > 0 then
                local ok = DirectMessages.request_retries(pub_key_hex, counters)
                if ok then
                    for _, c in ipairs(counters) do
                        for _, m in ipairs(gap_retry_msgs) do
                            if m.counter == c then
                                m.gap_retry_count = (m.gap_retry_count or 0) + 1
                                m.last_gap_retry = now
                                break
                            end
                        end
                    end
                    conv_needs_save = true
                    ez.log(string.format("[DirectMessages] Requesting retries for %d gaps (batched)", #counters))
                end
            end
        end

        if conv_needs_save then
            needs_save[pub_key_hex] = true
        end
    end

    -- Save conversations that changed
    for pub_key_hex, _ in pairs(needs_save) do
        DirectMessages._save_conversation(pub_key_hex)
    end

    -- Refresh UI if any messages changed state
    if needs_refresh and _G.ScreenManager then
        local current = _G.ScreenManager.peek()
        if current and current.mark_needs_refresh then
            current:mark_needs_refresh()
        end
        _G.ScreenManager.invalidate()
    end
end

-- Get list of conversations for display
-- @return array of { pub_key_hex, name, last_message, last_timestamp, unread_count }
function DirectMessages.get_conversations()
    local result = {}

    for pub_key_hex, conv in pairs(DirectMessages.conversations) do
        local last_msg = conv.messages[#conv.messages]
        table.insert(result, {
            pub_key_hex = pub_key_hex,
            name = conv.contact_name or get_contact_name(pub_key_hex),
            last_message = last_msg and last_msg.text or "",
            last_timestamp = conv.last_activity or 0,
            unread_count = conv.unread or 0,
        })
    end

    -- Sort by last activity (most recent first)
    table.sort(result, function(a, b)
        return a.last_timestamp > b.last_timestamp
    end)

    return result
end

-- Get messages for a specific conversation
-- @param pub_key_hex Contact's public key
-- @param limit Optional max messages to return
-- @return array of message tables
function DirectMessages.get_messages(pub_key_hex, limit)
    local conv = DirectMessages.conversations[pub_key_hex]
    if not conv then
        return {}
    end

    local msgs = conv.messages or {}
    if limit and #msgs > limit then
        local result = {}
        for i = #msgs - limit + 1, #msgs do
            table.insert(result, msgs[i])
        end
        return result
    end
    return msgs
end

-- Mark conversation as read
-- @param pub_key_hex Contact's public key
function DirectMessages.mark_read(pub_key_hex)
    local conv = DirectMessages.conversations[pub_key_hex]
    if conv then
        conv.unread = 0
        for _, msg in ipairs(conv.messages or {}) do
            msg.is_read = true
        end
    end
end

-- Clear conversation history
-- @param pub_key_hex Contact's public key
function DirectMessages.clear_conversation(pub_key_hex)
    DirectMessages.conversations[pub_key_hex] = nil
    -- Delete storage file
    local path = get_conversation_path(pub_key_hex)
    if ez.storage.exists(path) then
        ez.storage.remove(path)
    end
end

-- Reset cached route to a contact (forces flood routing on next message)
-- @param pub_key_hex Contact's public key
function DirectMessages.reset_route(pub_key_hex)
    local conv = DirectMessages.conversations[pub_key_hex]
    if conv then
        local old_hops = conv.out_path and #conv.out_path or 0
        conv.out_path = nil
        conv.route_refreshed_at = 0  -- Reset refresh timer too
        DirectMessages._save_conversation(pub_key_hex)
        ez.log(string.format("[DirectMessages] Reset route to %s (was %d hops)",
              pub_key_hex:sub(1, 8), old_hops))
    end
end

-- Get current route info for a contact
-- @param pub_key_hex Contact's public key
-- @return { hops = number, path_hex = string } or nil if no route
function DirectMessages.get_route_info(pub_key_hex)
    local conv = DirectMessages.conversations[pub_key_hex]
    if not conv or not conv.out_path then
        return nil
    end
    return {
        hops = #conv.out_path,
        path_hex = bytes_to_hex(conv.out_path),
    }
end

-- Set callback for incoming messages
-- @param callback Function(pub_key_hex, message) called on new message
function DirectMessages.on_message(callback)
    DirectMessages._on_message = callback
end

-- Send an ACK packet for a received message
-- @param sender_pub_key_hex Sender's public key (to send ACK back)
-- @param counter Original message counter
-- @param text_hash Hash of the message text (for identification)
function DirectMessages._send_ack(sender_pub_key_hex, counter, text_hash)
    if not ez.mesh.is_initialized() then
        return false
    end

    -- Get our path hash and sender's path hash
    local our_hash = ez.mesh.get_path_hash()
    local sender_pub_key = hex_to_bytes(sender_pub_key_hex)
    if not sender_pub_key or #sender_pub_key ~= 32 then
        return false
    end
    local sender_hash = string.byte(sender_pub_key, 1)

    -- Build ACK payload: [counter:2][reserved:2][text_hash:4]
    local payload = pack_uint16_le(counter) .. pack_uint16_le(0) .. pack_uint32_le(text_hash)
    local path = string.char(our_hash, sender_hash)

    ez.log(string.format("[DirectMessages] _send_ack: counter=%d hash=%08X path=%02X->%02X",
          counter, text_hash, our_hash, sender_hash))

    local packet_data = ez.mesh.build_packet(
        DirectMessages.ROUTE_TYPE_DIRECT,
        DirectMessages.PAYLOAD_TYPE_ACK,
        payload,
        path
    )

    if not packet_data then
        return false
    end

    local ok = ez.mesh.queue_send(packet_data)
    if ok then
        ez.log("[DirectMessages] ACK sent to " .. sender_pub_key_hex:sub(1, 8))
    end
    return ok
end

-- Send PATH packet with learned route back to sender (piggybacks ACK)
-- Called after receiving a FLOOD TXT_MSG so sender learns the route to us
-- @param sender_pub_key_hex Sender's public key
-- @param incoming_path The path from the received packet (as binary string)
-- @param counter Message counter (for piggybacked ACK)
-- @param text_hash Message text hash (for piggybacked ACK)
function DirectMessages._send_path_response(sender_pub_key_hex, incoming_path, counter, text_hash)
    if not ez.mesh.is_initialized() then
        return false
    end

    local our_hash = ez.mesh.get_path_hash()
    local sender_pub_key = hex_to_bytes(sender_pub_key_hex)
    if not sender_pub_key or #sender_pub_key ~= 32 then
        return false
    end
    local sender_hash = string.byte(sender_pub_key, 1)

    -- Reverse the incoming path to get route back to sender
    -- incoming_path is [sender_hash, hop1, hop2, ...]
    -- We want to send back [hop2, hop1] (intermediate hops, reversed, excluding sender)
    local reversed_hops = ""
    if #incoming_path > 1 then
        -- Skip first byte (sender_hash), reverse the rest
        for i = #incoming_path, 2, -1 do
            reversed_hops = reversed_hops .. incoming_path:sub(i, i)
        end
    end

    -- Build PATH payload: [path_len:1][path:variable][extra_type:1][extra_data:variable]
    -- Piggyback ACK: extra_type=ACK, extra_data=[counter:2][reserved:2][text_hash:4]
    local path_len = #reversed_hops
    local ack_data = pack_uint16_le(counter) .. pack_uint16_le(0) .. pack_uint32_le(text_hash)
    local payload = string.char(path_len) .. reversed_hops ..
                    string.char(DirectMessages.PAYLOAD_TYPE_ACK) .. ack_data

    -- Use DIRECT routing with the reversed path we just learned
    local packet_path
    if #reversed_hops > 0 then
        packet_path = string.char(our_hash) .. reversed_hops .. string.char(sender_hash)
    else
        -- Direct neighbor, no intermediate hops
        packet_path = string.char(our_hash, sender_hash)
    end

    ez.log(string.format("[DirectMessages] Sending PATH response: %d hops, ACK counter=%d",
          path_len, counter))

    local packet_data = ez.mesh.build_packet(
        DirectMessages.ROUTE_TYPE_DIRECT,
        DirectMessages.PAYLOAD_TYPE_PATH,
        payload,
        packet_path
    )

    if not packet_data then
        return false
    end

    local ok = ez.mesh.queue_send(packet_data)
    if ok then
        ez.log("[DirectMessages] PATH+ACK sent to " .. sender_pub_key_hex:sub(1, 8))
    end
    return ok
end

-- Handle incoming PATH packet (learn route to sender)
-- @param packet The PATH packet
-- @return handled (boolean)
function DirectMessages._handle_path(packet)
    local payload = packet.payload
    if #payload < 2 then
        ez.log("[DirectMessages] PATH payload too short: " .. #payload)
        return false
    end

    -- Parse PATH payload: [path_len:1][path:variable][extra_type:1][extra_data:variable]
    local path_len = string.byte(payload, 1)
    if #payload < 1 + path_len + 1 then
        ez.log("[DirectMessages] PATH payload truncated")
        return false
    end

    local learned_path = payload:sub(2, 1 + path_len)
    local extra_type = string.byte(payload, 2 + path_len)
    local extra_data = payload:sub(3 + path_len)

    -- Get sender's public key from path hash
    local path = packet.path
    if not path or #path < 1 then
        ez.log("[DirectMessages] PATH has no path")
        return false
    end
    local sender_hash = string.byte(path, 1)

    -- Ignore PATH from ourselves
    local our_hash = ez.mesh.get_path_hash()
    if sender_hash == our_hash then
        return true
    end

    -- Find sender's public key
    local sender_pub_key_hex = nil

    -- Check saved contacts
    if _G.Contacts and _G.Contacts.get_saved then
        local saved = _G.Contacts.get_saved() or {}
        for _, contact in ipairs(saved) do
            if contact.pub_key_hex then
                local contact_pub_key = hex_to_bytes(contact.pub_key_hex)
                if contact_pub_key and #contact_pub_key >= 1 then
                    if string.byte(contact_pub_key, 1) == sender_hash then
                        sender_pub_key_hex = contact.pub_key_hex
                        break
                    end
                end
            end
        end
    end

    -- Check live nodes
    if not sender_pub_key_hex and ez.mesh.is_initialized() then
        local nodes = ez.mesh.get_nodes() or {}
        for _, node in ipairs(nodes) do
            if node.path_hash == sender_hash and node.pub_key_hex then
                sender_pub_key_hex = node.pub_key_hex
                break
            end
        end
    end

    if not sender_pub_key_hex then
        ez.log(string.format("[DirectMessages] PATH from unknown hash %02X", sender_hash))
        return true
    end

    -- Reverse the learned path to get our out_path to them
    -- They sent us the route from them to us, we need the reverse
    local new_out_path = ""
    for i = #learned_path, 1, -1 do
        new_out_path = new_out_path .. learned_path:sub(i, i)
    end

    -- Only update if: no existing path OR new path is shorter (better route)
    local conv = get_or_create_conversation(sender_pub_key_hex)
    local current_path = conv.out_path
    local should_update = false

    if not current_path then
        should_update = true
        ez.log(string.format("[DirectMessages] PATH: Learned new route to %s: %d hops",
              sender_pub_key_hex:sub(1, 8), #new_out_path))
    elseif #new_out_path < #current_path then
        should_update = true
        ez.log(string.format("[DirectMessages] PATH: Upgraded route to %s: %d -> %d hops",
              sender_pub_key_hex:sub(1, 8), #current_path, #new_out_path))
    else
        ez.log(string.format("[DirectMessages] PATH: Keeping existing route to %s: %d hops (new was %d)",
              sender_pub_key_hex:sub(1, 8), #current_path, #new_out_path))
    end

    if should_update then
        conv.out_path = new_out_path
        conv.route_refreshed_at = ez.system.millis()  -- Reset refresh timer
        DirectMessages._save_conversation(sender_pub_key_hex)
    end

    -- Process piggybacked extra data (e.g., ACK)
    if extra_type == DirectMessages.PAYLOAD_TYPE_ACK and #extra_data >= 8 then
        local ack_counter = unpack_uint16_le(extra_data, 1)
        local ack_reserved = unpack_uint16_le(extra_data, 3)
        local ack_text_hash = unpack_uint32_le(extra_data, 5)

        ez.log(string.format("[DirectMessages] PATH contains piggybacked ACK: counter=%d hash=%08X",
              ack_counter, ack_text_hash))

        -- Find and mark the message as acked
        if conv then
            for _, msg in ipairs(conv.messages) do
                if msg.direction == "sent" and msg.counter == ack_counter then
                    local msg_text_hash = DirectMessages._compute_text_hash(msg.text)
                    if msg_text_hash == ack_text_hash then
                        msg.acked = true
                        msg.failed = nil  -- Clear failed status if ACK received late
                        ez.log("[DirectMessages] Message #" .. ack_counter .. " ACKed via PATH")
                        DirectMessages._save_conversation(sender_pub_key_hex)

                        -- Publish message acked event
                        if ez.bus and ez.bus.post then
                            ez.bus.post("message/acked", msg.id or tostring(ack_counter))
                        end

                        -- Refresh UI
                        if _G.ScreenManager then
                            local current = _G.ScreenManager.peek()
                            if current and current.mark_needs_refresh then
                                if current.contact_pub_key == sender_pub_key_hex or
                                   (current.title == "Messages" and not current.contact_pub_key) then
                                    current:mark_needs_refresh()
                                end
                            end
                            _G.ScreenManager.invalidate()
                        end
                        break
                    end
                end
            end
        end
    end

    return true
end

-- Handle incoming ACK packet
-- @param packet The ACK packet
-- @return handled (boolean)
function DirectMessages._handle_ack(packet)
    local payload = packet.payload
    if #payload < 8 then
        ez.log("[DirectMessages] ACK payload too short: " .. #payload)
        return false
    end

    local counter = unpack_uint16_le(payload, 1)
    local reserved = unpack_uint16_le(payload, 3)
    local text_hash = unpack_uint32_le(payload, 5)

    -- Get the ACK sender's hash from path (first byte is originator)
    local path = packet.path
    if not path or #path < 1 then
        ez.log("[DirectMessages] ACK has no path")
        return false
    end
    local acker_hash = string.byte(path, 1)

    -- Ignore ACKs from ourselves (radio echo)
    local our_hash = ez.mesh.get_path_hash()
    if acker_hash == our_hash then
        return true  -- Silently ignore
    end

    ez.log(string.format("[DirectMessages] ACK from hash %02X, counter=%d, text_hash=%08X",
          acker_hash, counter, text_hash))

    -- Find the acker's public key
    local acker_pub_key_hex = nil
    local acker_name = nil

    -- First check saved contacts (trusted, user-added)
    if _G.Contacts and _G.Contacts.get_saved then
        local saved = _G.Contacts.get_saved() or {}
        for _, contact in ipairs(saved) do
            if contact.pub_key_hex then
                local contact_pub_key = hex_to_bytes(contact.pub_key_hex)
                if contact_pub_key and #contact_pub_key >= 1 then
                    local contact_hash = string.byte(contact_pub_key, 1)
                    if contact_hash == acker_hash then
                        acker_pub_key_hex = contact.pub_key_hex
                        acker_name = contact.name
                        ez.log("[DirectMessages] ACK sender found in contacts: " .. (acker_name or "?"))
                        break
                    end
                end
            end
        end
    end

    -- If not found in contacts, check live discovered nodes
    if not acker_pub_key_hex and ez.mesh.is_initialized() then
        local nodes = ez.mesh.get_nodes() or {}
        for _, node in ipairs(nodes) do
            if node.path_hash == acker_hash and node.pub_key_hex then
                acker_pub_key_hex = node.pub_key_hex
                acker_name = node.name
                ez.log("[DirectMessages] ACK sender found in live nodes: " .. (acker_name or "?"))
                break
            end
        end
    end

    if not acker_pub_key_hex then
        ez.log(string.format("[DirectMessages] ACK from unknown hash %02X - no matching contact or node", acker_hash))
        return true
    end

    -- Find the message this ACK is for and mark it as acked
    local conv = DirectMessages.conversations[acker_pub_key_hex]
    if conv then
        for _, msg in ipairs(conv.messages) do
            if msg.direction == "sent" and msg.counter == counter then
                -- Verify text hash matches
                local msg_text_hash = DirectMessages._compute_text_hash(msg.text)
                if msg_text_hash == text_hash then
                    msg.acked = true
                    msg.failed = nil  -- Clear failed status if ACK received late
                    ez.log("[DirectMessages] Message #" .. counter .. " ACKed: " .. msg.text:sub(1, 20))
                    DirectMessages._save_conversation(acker_pub_key_hex)

                    -- Publish message acked event
                    if ez.bus and ez.bus.post then
                        ez.bus.post("message/acked", msg.id or tostring(counter))
                    end

                    -- Force refresh on conversation screen or messages list if open
                    if _G.ScreenManager then
                        local current = _G.ScreenManager.peek()
                        if current and current.mark_needs_refresh then
                            -- Refresh conversation screen if it's for this contact
                            if current.contact_pub_key == acker_pub_key_hex then
                                current:mark_needs_refresh()
                            -- Refresh Messages list screen
                            elseif current.title == "Messages" and not current.contact_pub_key then
                                current:mark_needs_refresh()
                            end
                        end
                        _G.ScreenManager.invalidate()
                    end
                    return true
                end
            end
        end
    end

    return true
end

-- Handle incoming REQ packet
-- Payload format: [dest_hash:1][src_hash:1][MAC:16][encrypted_payload]
-- Encrypted payload: [timestamp:4][request_type:1][request_data:variable]
function DirectMessages._handle_req(packet)
    local payload = packet.payload
    if #payload < 2 + 16 + 16 then  -- dest + src + MAC + min encrypted (1 AES block)
        ez.log("[DirectMessages] REQ payload too short: " .. #payload)
        return false
    end

    local dest_hash = string.byte(payload, 1)
    local src_hash = string.byte(payload, 2)
    local mac_and_encrypted = payload:sub(3)

    -- Check if addressed to us
    local our_hash = ez.mesh.get_path_hash()
    if dest_hash ~= our_hash then
        return false  -- Not for us
    end

    -- Find sender's public key
    local sender_pub_key_hex = DirectMessages._find_pub_key_by_hash(src_hash)
    if not sender_pub_key_hex then
        ez.log(string.format("[DirectMessages] REQ from unknown hash %02X", src_hash))
        return true  -- Handled (but can't decrypt)
    end

    -- Get decryption key
    local enc_key_data = get_encryption_key(sender_pub_key_hex)
    if not enc_key_data then
        ez.log("[DirectMessages] Failed to get decryption key for REQ")
        return true
    end

    -- Decrypt payload
    local decrypted = decrypt_req_payload(enc_key_data.key, mac_and_encrypted)
    if not decrypted or #decrypted < 5 then  -- timestamp(4) + type(1)
        ez.log("[DirectMessages] Failed to decrypt REQ")
        return true
    end

    -- Parse decrypted payload: [timestamp:4][request_type:1][request_data:variable]
    local timestamp = unpack_uint32_le(decrypted, 1)
    local request_type = string.byte(decrypted, 5)
    local request_data = decrypted:sub(6)

    -- Note: Don't strip null bytes from request_data - it's binary data
    -- The AES padding may add nulls, but handlers should know the expected data size

    ez.log(string.format("[DirectMessages] REQ from %s: type=%d data_len=%d",
          sender_pub_key_hex:sub(1, 8), request_type, #request_data))

    -- Call registered handler for this request type
    local handler = DirectMessages._request_handlers[request_type]
    if handler then
        local response_data = handler(sender_pub_key_hex, request_data, timestamp)
        if response_data then
            DirectMessages.send_response(sender_pub_key_hex, response_data)
        end
    else
        ez.log("[DirectMessages] No handler for request type " .. request_type)
    end

    return true
end

-- Handle incoming RESPONSE packet
-- Payload format: [dest_hash:1][src_hash:1][MAC:16][encrypted_payload]
-- Encrypted payload: [timestamp:4][response_data:variable]
function DirectMessages._handle_response(packet)
    local payload = packet.payload
    if #payload < 2 + 16 + 16 then  -- dest + src + MAC + min encrypted
        ez.log("[DirectMessages] RESPONSE payload too short: " .. #payload)
        return false
    end

    local dest_hash = string.byte(payload, 1)
    local src_hash = string.byte(payload, 2)
    local mac_and_encrypted = payload:sub(3)

    -- Check if addressed to us
    local our_hash = ez.mesh.get_path_hash()
    if dest_hash ~= our_hash then
        return false  -- Not for us
    end

    -- Find sender's public key
    local sender_pub_key_hex = DirectMessages._find_pub_key_by_hash(src_hash)
    if not sender_pub_key_hex then
        ez.log(string.format("[DirectMessages] RESPONSE from unknown hash %02X", src_hash))
        return true
    end

    -- Get decryption key
    local enc_key_data = get_encryption_key(sender_pub_key_hex)
    if not enc_key_data then
        ez.log("[DirectMessages] Failed to get decryption key for RESPONSE")
        return true
    end

    -- Decrypt payload
    local decrypted = decrypt_req_payload(enc_key_data.key, mac_and_encrypted)
    if not decrypted or #decrypted < 4 then  -- timestamp(4)
        ez.log("[DirectMessages] Failed to decrypt RESPONSE")
        return true
    end

    -- Parse: [timestamp:4][response_data:variable]
    local timestamp = unpack_uint32_le(decrypted, 1)
    local response_data = decrypted:sub(5)

    -- Note: Don't strip null bytes from response_data - it's binary data

    ez.log(string.format("[DirectMessages] RESPONSE from %s: data_len=%d",
          sender_pub_key_hex:sub(1, 8), #response_data))

    -- Find pending request for this sender and call callback
    local pending = DirectMessages._pending_requests[sender_pub_key_hex]
    if pending and pending.callback then
        pending.callback(response_data, timestamp)
        DirectMessages._pending_requests[sender_pub_key_hex] = nil
    end

    return true
end

-- Helper: Find public key hex by path hash
function DirectMessages._find_pub_key_by_hash(path_hash)
    -- Check saved contacts
    if _G.Contacts and _G.Contacts.get_saved then
        local saved = _G.Contacts.get_saved() or {}
        for _, contact in ipairs(saved) do
            if contact.pub_key_hex then
                local pub_key = hex_to_bytes(contact.pub_key_hex)
                if pub_key and #pub_key >= 1 and string.byte(pub_key, 1) == path_hash then
                    return contact.pub_key_hex
                end
            end
        end
    end

    -- Check mesh nodes
    if ez.mesh.is_initialized() then
        local nodes = ez.mesh.get_nodes() or {}
        for _, node in ipairs(nodes) do
            if node.path_hash == path_hash and node.pub_key_hex then
                return node.pub_key_hex
            end
        end
    end

    return nil
end

-- Send a request to a contact
-- @param recipient_pub_key_hex Public key of recipient
-- @param request_type Request type (use DirectMessages.REQ_TYPE_* constants)
-- @param request_data Request data (binary string)
-- @param callback Optional callback(response_data, timestamp) for response
-- @return true if sent
function DirectMessages.send_request(recipient_pub_key_hex, request_type, request_data, callback)
    if not ez.mesh.is_initialized() then
        return false
    end

    local our_hash = ez.mesh.get_path_hash()
    local recipient_pub_key = hex_to_bytes(recipient_pub_key_hex)
    if not recipient_pub_key or #recipient_pub_key ~= 32 then
        return false
    end
    local recipient_hash = string.byte(recipient_pub_key, 1)

    -- Get encryption key
    local enc_key_data = get_encryption_key(recipient_pub_key_hex)
    if not enc_key_data then
        ez.log("[DirectMessages] Failed to get encryption key for REQ")
        return false
    end

    -- Build inner payload: [timestamp:4][request_type:1][request_data:variable]
    local timestamp = math.floor(ez.system.millis() / 1000)
    local inner_payload = pack_uint32_le(timestamp) .. string.char(request_type) .. (request_data or "")

    -- Encrypt with 16-byte MAC
    local encrypted = encrypt_req_payload(enc_key_data.key, inner_payload)
    if not encrypted then
        ez.log("[DirectMessages] Failed to encrypt REQ")
        return false
    end

    -- Build outer payload: [dest_hash:1][src_hash:1][MAC:16][encrypted]
    local outer_payload = string.char(recipient_hash, our_hash) .. encrypted

    -- Build and send packet (use FLOOD routing for now)
    local path = string.char(our_hash)
    local packet_data = ez.mesh.build_packet(
        DirectMessages.ROUTE_TYPE_FLOOD,
        DirectMessages.PAYLOAD_TYPE_REQ,
        outer_payload,
        path
    )

    if not packet_data then
        return false
    end

    local ok = ez.mesh.queue_send(packet_data)
    if ok then
        ez.log(string.format("[DirectMessages] REQ sent to %s: type=%d",
              recipient_pub_key_hex:sub(1, 8), request_type))
        -- Store callback for response
        if callback then
            DirectMessages._pending_requests[recipient_pub_key_hex] = {
                callback = callback,
                timeout = ez.system.millis() + 30000,  -- 30 second timeout
                request_type = request_type,
            }
        end
    end

    return ok
end

-- Send a response to a contact
-- @param recipient_pub_key_hex Public key of recipient
-- @param response_data Response data (binary string)
-- @return true if sent
function DirectMessages.send_response(recipient_pub_key_hex, response_data)
    if not ez.mesh.is_initialized() then
        return false
    end

    local our_hash = ez.mesh.get_path_hash()
    local recipient_pub_key = hex_to_bytes(recipient_pub_key_hex)
    if not recipient_pub_key or #recipient_pub_key ~= 32 then
        return false
    end
    local recipient_hash = string.byte(recipient_pub_key, 1)

    -- Get encryption key
    local enc_key_data = get_encryption_key(recipient_pub_key_hex)
    if not enc_key_data then
        ez.log("[DirectMessages] Failed to get encryption key for RESPONSE")
        return false
    end

    -- Build inner payload: [timestamp:4][response_data:variable]
    local timestamp = math.floor(ez.system.millis() / 1000)
    local inner_payload = pack_uint32_le(timestamp) .. (response_data or "")

    -- Encrypt with 16-byte MAC
    local encrypted = encrypt_req_payload(enc_key_data.key, inner_payload)
    if not encrypted then
        ez.log("[DirectMessages] Failed to encrypt RESPONSE")
        return false
    end

    -- Build outer payload: [dest_hash:1][src_hash:1][MAC:16][encrypted]
    local outer_payload = string.char(recipient_hash, our_hash) .. encrypted

    -- Build and send packet (use FLOOD routing)
    local path = string.char(our_hash)
    local packet_data = ez.mesh.build_packet(
        DirectMessages.ROUTE_TYPE_FLOOD,
        DirectMessages.PAYLOAD_TYPE_RESPONSE,
        outer_payload,
        path
    )

    if not packet_data then
        return false
    end

    local ok = ez.mesh.queue_send(packet_data)
    if ok then
        ez.log(string.format("[DirectMessages] RESPONSE sent to %s",
              recipient_pub_key_hex:sub(1, 8)))
    end

    return ok
end

-- Register a handler for a request type
-- @param request_type Request type constant
-- @param handler Function(sender_pub_key_hex, request_data, timestamp) -> response_data or nil
function DirectMessages.on_request(request_type, handler)
    DirectMessages._request_handlers[request_type] = handler
end

-- Request ACKs for sent messages that haven't been acknowledged (batched)
-- @param contact_pub_key_hex Contact's public key
-- @param counters Array of message counters to request ACKs for
-- @return true if request sent
function DirectMessages.request_acks(contact_pub_key_hex, counters)
    if not counters or #counters == 0 then return false end
    if #counters > 255 then counters = {table.unpack(counters, 1, 255)} end

    -- Build batched data: [count:1][counter1:2][counter2:2]...
    local data = string.char(#counters)
    for _, counter in ipairs(counters) do
        data = data .. pack_uint16_le(counter)
    end
    return DirectMessages.send_request(contact_pub_key_hex, DirectMessages.REQ_TYPE_REQ_ACK, data)
end

-- Request an ACK for a single sent message (convenience wrapper)
-- @param contact_pub_key_hex Contact's public key
-- @param counter Message counter to request ACK for
-- @return true if request sent
function DirectMessages.request_ack(contact_pub_key_hex, counter)
    return DirectMessages.request_acks(contact_pub_key_hex, {counter})
end

-- Request a contact to resend messages we may have missed (batched)
-- @param contact_pub_key_hex Contact's public key
-- @param counters Array of message counters to request
-- @return true if request sent
function DirectMessages.request_retries(contact_pub_key_hex, counters)
    if not counters or #counters == 0 then return false end
    if #counters > 255 then counters = {table.unpack(counters, 1, 255)} end

    -- Build batched data: [count:1][counter1:2][counter2:2]...
    local data = string.char(#counters)
    for _, counter in ipairs(counters) do
        data = data .. pack_uint16_le(counter)
    end
    return DirectMessages.send_request(contact_pub_key_hex, DirectMessages.REQ_TYPE_RETRY_MSG, data)
end

-- Request a contact to resend a single message (convenience wrapper)
-- @param contact_pub_key_hex Contact's public key
-- @param counter Message counter to request
-- @return true if request sent
function DirectMessages.request_retry(contact_pub_key_hex, counter)
    return DirectMessages.request_retries(contact_pub_key_hex, {counter})
end

-- Get a specific message by counter from a conversation
-- @param contact_pub_key_hex Contact's public key
-- @param counter Message counter
-- @return message table or nil
function DirectMessages.get_message_by_counter(contact_pub_key_hex, counter)
    local conv = DirectMessages.conversations[contact_pub_key_hex]
    if not conv then return nil end

    for _, msg in ipairs(conv.messages) do
        if msg.counter == counter then
            return msg
        end
    end
    return nil
end

-- Compute a simple hash of text for ACK identification
function DirectMessages._compute_text_hash(text)
    if not text or #text == 0 then
        return 1  -- Non-zero default
    end
    -- Simple sum-based hash to avoid Lua modulo issues
    local hash = 0
    for i = 1, #text do
        hash = hash + string.byte(text, i) * i
    end
    -- Keep in reasonable range using math.fmod
    hash = math.floor(math.fmod(hash, 2147483647))
    if hash == 0 then hash = 1 end  -- Ensure non-zero
    return hash
end

-- Handle incoming packet (called from on_packet callback)
-- @return handled (boolean), rebroadcast (boolean)
function DirectMessages._handle_packet(packet)
    -- Debug: log all incoming packets
    ez.log(string.format("[DirectMessages] Packet: route=%d payload=%d pathLen=%d",
        packet.route_type or -1, packet.payload_type or -1, packet.path and #packet.path or 0))

    -- Handle PATH packets (route learning with optional piggybacked ACK)
    if packet.payload_type == DirectMessages.PAYLOAD_TYPE_PATH then
        local handled = DirectMessages._handle_path(packet)
        return handled, false
    end

    -- Handle ACK packets
    if packet.payload_type == DirectMessages.PAYLOAD_TYPE_ACK then
        local handled = DirectMessages._handle_ack(packet)
        return handled, false
    end

    -- Handle REQ packets
    if packet.payload_type == DirectMessages.PAYLOAD_TYPE_REQ then
        local handled = DirectMessages._handle_req(packet)
        return handled, false
    end

    -- Handle RESPONSE packets
    if packet.payload_type == DirectMessages.PAYLOAD_TYPE_RESPONSE then
        local handled = DirectMessages._handle_response(packet)
        return handled, false
    end

    -- Only handle TXT_MSG packets
    if packet.payload_type ~= DirectMessages.PAYLOAD_TYPE_TXT_MSG then
        return false, false
    end

    ez.log(string.format("[DirectMessages] Received TXT_MSG! route=%d pathLen=%d payloadLen=%d",
        packet.route_type or -1, packet.path and #packet.path or 0, packet.payload and #packet.payload or 0))

    -- For DIRECT routing, check if addressed to us
    local path = packet.path
    local our_hash = ez.mesh.get_path_hash()

    if packet.route_type == DirectMessages.ROUTE_TYPE_DIRECT then
        -- DIRECT routing: destination is last byte in path
        if not path or #path < 2 then
            ez.log("[DirectMessages] DIRECT but path too short")
            return false, false
        end
        local dest_hash = string.byte(path, #path)
        if dest_hash ~= our_hash then
            ez.log(string.format("[DirectMessages] Not for us: dest=%02X our=%02X", dest_hash, our_hash))
            return false, false
        end
    end
    -- For FLOOD routing, accept all TXT_MSG (broadcast)

    -- Get sender's hash from path (first byte is originator)
    local sender_hash = string.byte(path, 1)
    ez.log(string.format("[DirectMessages] Sender path_hash: %02X", sender_hash))

    -- Find sender's public key FIRST (needed for decryption)
    local sender_pub_key = nil
    local sender_pub_key_hex = nil
    local sender_name = nil

    -- First check saved contacts (trusted, user-added)
    if _G.Contacts and _G.Contacts.get_saved then
        local saved = _G.Contacts.get_saved() or {}
        ez.log(string.format("[DirectMessages] Searching %d saved contacts for hash %02X", #saved, sender_hash))
        for _, contact in ipairs(saved) do
            if contact.pub_key_hex then
                -- Compute path_hash from public key (first byte)
                local contact_pub_key = hex_to_bytes(contact.pub_key_hex)
                if contact_pub_key and #contact_pub_key >= 1 then
                    local contact_hash = string.byte(contact_pub_key, 1)
                    ez.log(string.format("[DirectMessages] Contact %s has hash %02X", contact.name or "?", contact_hash))
                    if contact_hash == sender_hash then
                        sender_pub_key_hex = contact.pub_key_hex
                        sender_pub_key = contact_pub_key
                        sender_name = contact.name
                        ez.log("[DirectMessages] Found sender in saved contacts: " .. (sender_name or "?"))
                        break
                    end
                end
            else
                ez.log("[DirectMessages] Contact missing pub_key_hex: " .. (contact.name or "?"))
            end
        end
    else
        ez.log("[DirectMessages] Contacts service not available")
    end

    -- If not found in contacts, check live discovered nodes
    if not sender_pub_key_hex and ez.mesh.is_initialized() then
        local nodes = ez.mesh.get_nodes() or {}
        for _, node in ipairs(nodes) do
            if node.path_hash == sender_hash and node.pub_key_hex then
                sender_pub_key_hex = node.pub_key_hex
                sender_pub_key = hex_to_bytes(sender_pub_key_hex)
                sender_name = node.name
                ez.log("[DirectMessages] Found sender in live nodes: " .. (sender_name or "?"))
                break
            end
        end
    end

    -- Decrypt the payload if we have sender's public key
    local payload = packet.payload
    local decrypted_payload = nil

    if sender_pub_key_hex then
        -- Get encryption key for this sender
        local enc_key_data = get_encryption_key(sender_pub_key_hex)
        if enc_key_data then
            decrypted_payload = decrypt_message(enc_key_data.key, payload)
            if decrypted_payload then
                ez.log("[DirectMessages] Decrypted message from " .. sender_pub_key_hex:sub(1, 8))
                payload = decrypted_payload
            else
                ez.log("[DirectMessages] Decryption failed - MAC mismatch or corrupt data")
                return true, false  -- Drop packet
            end
        else
            ez.log("[DirectMessages] Failed to get decryption key")
            return true, false  -- Drop packet
        end
    else
        ez.log(string.format("[DirectMessages] Unknown sender hash %02X - caching packet for later", sender_hash))
        -- Cache the packet in case an ADVERT arrives soon with this sender's public key
        DirectMessages._pending_packets[sender_hash] = {
            packet = packet,
            received_at = ez.system.millis(),
        }
        return true, false  -- Cannot decrypt yet, but cached for retry
    end

    -- Parse decrypted payload: [counter:2][reserved:2][signature:64][text]
    if #payload < 68 then  -- 2 + 2 + 64 minimum
        ez.log("[DirectMessages] Decrypted payload too short: " .. #payload)
        return true, false
    end

    local counter = unpack_uint16_le(payload, 1)
    local reserved = unpack_uint16_le(payload, 3)
    local signature = payload:sub(5, 68)
    local text = payload:sub(69)

    -- Remove null terminator/padding if present
    local null_pos = text:find("\0")
    if null_pos then
        text = text:sub(1, null_pos - 1)
    end

    -- Verify signature
    local verified = false
    if sender_pub_key then
        local sign_data = pack_uint16_le(counter) .. pack_uint16_le(reserved) .. text
        verified = ez.mesh.ed25519_verify(sign_data, signature, sender_pub_key)
        if not verified then
            ez.log("[DirectMessages] Signature verification FAILED")
        end
    end

    -- Get or create conversation
    local conv = get_or_create_conversation(sender_pub_key_hex)
    local last_counter = conv.recv_counter or 0

    -- Check for duplicate or gap-fill
    local gap_fill_index = nil  -- Track position for gap fills
    local was_failed_gap = false
    if counter <= last_counter and counter > 0 then
        -- Check if this fills a gap (replaces a gap placeholder)
        local fills_gap = false
        for i, msg in ipairs(conv.messages) do
            if msg.counter == counter and msg.is_gap then
                fills_gap = true
                gap_fill_index = i
                was_failed_gap = msg.failed or false
                break
            end
        end

        if fills_gap then
            ez.log("[DirectMessages] Filling gap for message #" .. counter .. " at index " .. gap_fill_index ..
                  (was_failed_gap and " (was failed)" or ""))
            -- Remove the gap placeholder, we'll insert the real message at this position
            table.remove(conv.messages, gap_fill_index)
        else
            ez.log("[DirectMessages] Duplicate message #" .. counter .. " (last=" .. last_counter .. ")")
            return true, false
        end
    end

    -- Detect gaps and insert placeholder messages
    if counter > last_counter + 1 and last_counter > 0 then
        local gap_count = counter - last_counter - 1
        ez.log("[DirectMessages] Gap detected: " .. gap_count .. " missed messages (" .. (last_counter+1) .. "-" .. (counter-1) .. ")")
        for gap_counter = last_counter + 1, counter - 1 do
            DirectMessages._seq = DirectMessages._seq + 1
            local gap_msg = {
                id = generate_message_id(gap_counter, "_gap_", sender_pub_key_hex),
                direction = "received",
                text = "",
                counter = gap_counter,
                seq = DirectMessages._seq,
                verified = false,
                is_read = true,
                is_gap = true,  -- Mark as gap/missed message
                created_at = ez.system.millis(),  -- For retry timing
                gap_retry_count = 0,
            }
            table.insert(conv.messages, gap_msg)
        end
    end

    -- Update received counter (only if this is a new high water mark)
    if counter > last_counter then
        conv.recv_counter = counter
    end

    -- Store message with sequence number for ordering
    DirectMessages._seq = DirectMessages._seq + 1
    local msg = {
        id = generate_message_id(counter, text, sender_pub_key_hex),
        direction = "received",
        text = text,
        counter = counter,
        seq = DirectMessages._seq,
        verified = verified,
        is_read = false,
        rssi = packet.rssi,
        snr = packet.snr,
    }

    -- Insert message and ensure correct order
    if gap_fill_index then
        -- Gap fill: insert and re-sort to ensure correct order
        table.insert(conv.messages, msg)
        sort_messages(conv.messages)
        conv.last_activity = msg.timestamp
        -- Trim to max (remove oldest)
        while #conv.messages > DirectMessages.MAX_MESSAGES do
            table.remove(conv.messages, 1)
        end
        DirectMessages._save_conversation(sender_pub_key_hex)
    else
        DirectMessages._store_message(sender_pub_key_hex, msg)
    end

    -- Publish message received event
    if ez.bus and ez.bus.post then
        ez.bus.post("message/received", {
            from = sender_pub_key_hex:sub(1, 16),
            text = text:sub(1, 50)
        })
    end

    -- Update unread count
    local c = DirectMessages.conversations[sender_pub_key_hex]
    if c then
        c.unread = (c.unread or 0) + 1
        c.contact_name = sender_name or c.contact_name
    end

    -- Play notification sound if available
    if _G.SoundUtils and _G.SoundUtils.play_notification then
        _G.SoundUtils.play_notification()
    end

    -- Force refresh on conversation screen or messages list if open
    if _G.ScreenManager then
        local current = _G.ScreenManager.peek()
        if current then
            if current.mark_needs_refresh then
                -- Refresh conversation screen if it's for this contact
                if current.contact_pub_key == sender_pub_key_hex then
                    current:mark_needs_refresh()
                -- Refresh Messages list screen (has title "Messages" but no contact_pub_key)
                elseif current.title == "Messages" and not current.contact_pub_key then
                    current:mark_needs_refresh()
                end
            end
            -- Update main menu message counter if we're on main menu
            if current.set_message_count then
                current:set_message_count(DirectMessages.get_unread_total())
            end
        end
        _G.ScreenManager.invalidate()
    end

    -- Call callback
    if DirectMessages._on_message then
        DirectMessages._on_message(sender_pub_key_hex, msg)
    end

    ez.log("[DirectMessages] Received from " .. (sender_name or sender_pub_key_hex:sub(1, 8)) ..
          " (verified=" .. tostring(verified) .. "): " .. text:sub(1, 20))

    -- Learn the path from this message for future direct routing to sender
    -- For FLOOD: path = [sender, hop1, hop2, ...] - reverse for our out_path
    -- For DIRECT: path = [sender, hop1, hop2, ..., us] - also useful
    -- Only update if: no existing path OR new path is shorter (better route)
    local incoming_path = packet.path
    if sender_pub_key_hex and incoming_path and #incoming_path > 0 then
        -- Extract intermediate hops (exclude sender at start, exclude us at end for DIRECT)
        local hops_start = 2  -- Skip sender hash
        local hops_end = #incoming_path
        if packet.route_type == DirectMessages.ROUTE_TYPE_DIRECT then
            hops_end = hops_end - 1  -- Exclude our hash at end
        end

        local new_out_path = ""
        if hops_end >= hops_start then
            -- Reverse the intermediate hops for our out_path
            for i = hops_end, hops_start, -1 do
                new_out_path = new_out_path .. incoming_path:sub(i, i)
            end
        end
        -- new_out_path = "" means direct neighbor (0 hops)

        -- Check if we should update the cached path
        local sender_conv = DirectMessages.conversations[sender_pub_key_hex]
        if sender_conv then
            local current_path = sender_conv.out_path
            local should_update = false

            if not current_path then
                -- No existing path - always learn
                should_update = true
                ez.log(string.format("[DirectMessages] Learned new path to %s: %d hops",
                      sender_pub_key_hex:sub(1, 8), #new_out_path))
            elseif #new_out_path < #current_path then
                -- New path is shorter - upgrade!
                should_update = true
                ez.log(string.format("[DirectMessages] Upgraded path to %s: %d -> %d hops",
                      sender_pub_key_hex:sub(1, 8), #current_path, #new_out_path))
            else
                -- Existing path is same length or shorter - keep it
                ez.log(string.format("[DirectMessages] Keeping existing path to %s: %d hops (new was %d)",
                      sender_pub_key_hex:sub(1, 8), #current_path, #new_out_path))
            end

            if should_update then
                sender_conv.out_path = new_out_path
                sender_conv.route_refreshed_at = ez.system.millis()  -- Reset refresh timer
                DirectMessages._save_conversation(sender_pub_key_hex)
            end
        end
    end

    -- Send response back to sender
    if sender_pub_key_hex and not sender_pub_key_hex:match("_UNKNOWN_") then
        local text_hash = DirectMessages._compute_text_hash(text)

        if packet.route_type == DirectMessages.ROUTE_TYPE_FLOOD then
            -- FLOOD message: send PATH response with piggybacked ACK
            -- This teaches the sender the route to us
            ez.log(string.format("[DirectMessages] Sending PATH+ACK: counter=%d text_hash=%08X",
                  counter, text_hash))
            DirectMessages._send_path_response(sender_pub_key_hex, incoming_path, counter, text_hash)
        else
            -- DIRECT message: just send ACK (route already established)
            ez.log(string.format("[DirectMessages] Sending ACK: counter=%d text_hash=%08X",
                  counter, text_hash))
            DirectMessages._send_ack(sender_pub_key_hex, counter, text_hash)
        end
    end

    return true, false  -- Handled, no rebroadcast
end

-- Store a message in a conversation
function DirectMessages._store_message(pub_key_hex, msg)
    if not DirectMessages.conversations[pub_key_hex] then
        DirectMessages.conversations[pub_key_hex] = {
            messages = {},
            unread = 0,
            last_activity = 0,
            contact_name = get_contact_name(pub_key_hex),
            send_counter = 0,
            recv_counter = 0,
            out_path = nil,
            route_refreshed_at = 0,
        }
    end

    local conv = DirectMessages.conversations[pub_key_hex]
    table.insert(conv.messages, msg)

    -- Sort messages by counter to maintain correct order
    sort_messages(conv.messages)

    conv.last_activity = msg.timestamp

    -- Trim to max (remove oldest by counter, which is now first)
    while #conv.messages > DirectMessages.MAX_MESSAGES do
        table.remove(conv.messages, 1)
    end

    -- Save conversation to storage
    DirectMessages._save_conversation(pub_key_hex)
end

-- Save a conversation to storage
function DirectMessages._save_conversation(pub_key_hex)
    local conv = DirectMessages.conversations[pub_key_hex]
    if not conv then return end

    -- Convert out_path binary to hex for JSON storage
    local out_path_hex = nil
    if conv.out_path and #conv.out_path > 0 then
        out_path_hex = bytes_to_hex(conv.out_path)
    end

    local data = {
        version = 4,
        contact_pub_key = pub_key_hex,
        messages = conv.messages,
        send_counter = conv.send_counter or 0,
        recv_counter = conv.recv_counter or 0,
        out_path = out_path_hex,  -- Cached route to contact (hex)
        route_refreshed_at = conv.route_refreshed_at or 0,  -- Last FLOOD refresh timestamp
    }

    local json = ez.storage.json_encode(data)
    if json then
        local path = get_conversation_path(pub_key_hex)
        ez.storage.write(path, json)
    end
end

-- Load a conversation from storage
function DirectMessages._load_conversation(pub_key_hex)
    local path = get_conversation_path(pub_key_hex)
    local json = ez.storage.read(path)
    if not json then return nil end

    local data = ez.storage.json_decode(json)
    if not data then return nil end
    -- Accept version 1, 2, 3, or 4
    if data.version ~= 1 and data.version ~= 2 and data.version ~= 3 and data.version ~= 4 then return nil end

    -- Convert out_path from hex back to binary
    local out_path = nil
    if data.out_path and #data.out_path > 0 then
        out_path = hex_to_bytes(data.out_path)
    end

    return {
        messages = data.messages or {},
        unread = 0,
        last_activity = data.messages and #data.messages > 0 and
                        (data.messages[#data.messages].counter or data.messages[#data.messages].timestamp or 0) or 0,
        contact_name = get_contact_name(pub_key_hex),
        send_counter = data.send_counter or 0,
        recv_counter = data.recv_counter or 0,
        out_path = out_path,  -- Cached route to contact (binary)
        route_refreshed_at = data.route_refreshed_at or 0,  -- Last FLOOD refresh timestamp
    }
end

-- Load all conversations from storage by scanning message directory
function DirectMessages._load_all()
    DirectMessages.conversations = {}
    local max_seq = 0

    -- Scan message directories for conversation files
    local dirs = {"/sd/data/messages"}
    for _, dir in ipairs(dirs) do
        if ez.storage.exists(dir) then
            local files = ez.storage.list_dir(dir) or {}
            for _, entry in ipairs(files) do
                -- list_dir returns {name, size, is_dir} entries
                local filename = entry.name or entry[1]
                if filename and not entry.is_dir then
                    -- Match pattern: XXXXXXXX.json (8 hex chars)
                    local pub_key_short = filename:match("^(%x%x%x%x%x%x%x%x)%.json$")
                    if pub_key_short then
                        local full_path = dir .. "/" .. filename
                        local json = ez.storage.read(full_path)
                        if json then
                            local data = ez.storage.json_decode(json)
                            if data and (data.version == 1 or data.version == 2 or data.version == 3 or data.version == 4) and data.contact_pub_key then
                                local pub_key_hex = data.contact_pub_key
                                local messages = data.messages or {}
                                -- Find max sequence number in this conversation
                                for _, msg in ipairs(messages) do
                                    if msg.seq and msg.seq > max_seq then
                                        max_seq = msg.seq
                                    end
                                end
                                -- Convert out_path from hex to binary
                                local out_path = nil
                                if data.out_path and #data.out_path > 0 then
                                    out_path = hex_to_bytes(data.out_path)
                                end
                                -- Sort messages by counter to ensure correct order
                                sort_messages(messages)
                                DirectMessages.conversations[pub_key_hex] = {
                                    messages = messages,
                                    unread = 0,
                                    last_activity = #messages > 0 and
                                                    (messages[#messages].counter or messages[#messages].timestamp or 0) or 0,
                                    contact_name = get_contact_name(pub_key_hex),
                                    send_counter = data.send_counter or 0,
                                    recv_counter = data.recv_counter or 0,
                                    out_path = out_path,
                                    route_refreshed_at = data.route_refreshed_at or 0,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    -- Restore sequence counter to continue from max
    DirectMessages._seq = max_seq
end

-- Count conversations
function DirectMessages._count_conversations()
    local count = 0
    for _ in pairs(DirectMessages.conversations) do
        count = count + 1
    end
    return count
end

-- Get total unread count (for status bar badge)
function DirectMessages.get_unread_total()
    local total = 0
    for _, conv in pairs(DirectMessages.conversations) do
        total = total + (conv.unread or 0)
    end
    return total
end

return DirectMessages
