-- Channels service
-- Handles channel joining, encryption/decryption, and message storage
-- Replaces C++ channel management in MeshCore

local Channels = {
    -- Joined channels: { name = { key, hash, is_encrypted, unread } }
    joined = {},
    -- Messages per channel: { channel_name = { messages } }
    messages = {},
    -- Message callbacks
    _on_message = nil,
    -- Constants
    MAX_MESSAGES = 100,
    MAX_CHANNEL_NAME = 32,
    MAX_MESSAGE_TEXT = 100,
}

local crypto = ez.crypto

-- Initialize the channels service
function Channels.init()
    -- Load saved channels
    Channels._load()

    -- Always join #Public
    if not Channels.joined["#Public"] then
        Channels._join_internal("#Public", crypto.public_channel_key(), false)
    end

    -- Subscribe to group packets via message bus
    if ez.bus and ez.bus.subscribe then
        ez.bus.subscribe("mesh/group_packet", function(topic, packet)
            -- packet is a table with channel_hash, data, sender_hash, rssi, snr
            Channels._handle_group_packet(packet)
        end)
    end

    print("[Channels] Initialized with " .. Channels._count_channels() .. " channels")
end

-- Join a channel
-- @param name Channel name (with or without #)
-- @param password Optional password for encrypted channels
-- @return true if joined successfully
function Channels.join(name, password)
    -- Normalize name
    if name:sub(1, 1) ~= "#" then
        name = "#" .. name
    end
    
    -- Already joined?
    if Channels.joined[name] then
        return true
    end
    
    -- Derive key
    local key
    local is_encrypted = false
    
    if name == "#Public" then
        key = crypto.public_channel_key()
    elseif password and #password > 0 then
        key = crypto.derive_channel_key(password)
        is_encrypted = true
    else
        key = crypto.derive_channel_key(name)
    end
    
    Channels._join_internal(name, key, is_encrypted)
    Channels._save()
    
    print("[Channels] Joined " .. name .. " (hash=" .. string.format("%02X", crypto.channel_hash(key)) .. ")")
    return true
end

-- Internal join (no save)
function Channels._join_internal(name, key, is_encrypted)
    local hash = crypto.channel_hash(key)
    Channels.joined[name] = {
        key = key,
        hash = hash,
        is_encrypted = is_encrypted,
        unread = 0,
        last_activity = 0,
    }
    Channels.messages[name] = Channels.messages[name] or {}
end

-- Leave a channel
-- @param name Channel name
-- @return true if left successfully
function Channels.leave(name)
    if name:sub(1, 1) ~= "#" then
        name = "#" .. name
    end
    
    -- Can't leave #Public
    if name == "#Public" then
        return false
    end
    
    if Channels.joined[name] then
        Channels.joined[name] = nil
        Channels._save()
        print("[Channels] Left " .. name)
        return true
    end
    
    return false
end

-- Check if joined to a channel
function Channels.is_joined(name)
    if name:sub(1, 1) ~= "#" then
        name = "#" .. name
    end
    return Channels.joined[name] ~= nil
end

-- Get all joined channels
-- @return table of { name, is_encrypted, unread, last_activity }
function Channels.get_all()
    local result = {}
    for name, info in pairs(Channels.joined) do
        table.insert(result, {
            name = name,
            is_encrypted = info.is_encrypted,
            unread = info.unread,
            last_activity = info.last_activity,
        })
    end
    -- Sort by name
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

-- Get messages for a channel
-- @param channel Channel name
-- @param limit Optional max messages to return
-- @return array of message tables
function Channels.get_messages(channel, limit)
    if channel:sub(1, 1) ~= "#" then
        channel = "#" .. channel
    end
    
    local msgs = Channels.messages[channel] or {}
    if limit and #msgs > limit then
        local result = {}
        for i = #msgs - limit + 1, #msgs do
            table.insert(result, msgs[i])
        end
        return result
    end
    return msgs
end

-- Send a message to a channel
-- @param channel Channel name
-- @param text Message text
-- @return true if sent successfully
function Channels.send(channel, text)
    if channel:sub(1, 1) ~= "#" then
        channel = "#" .. channel
    end
    
    local info = Channels.joined[channel]
    if not info then
        print("[Channels] Not in channel: " .. channel)
        return false
    end
    
    -- Build plaintext: [timestamp:4][flags:1][sender: text\0]
    local timestamp = ez.system.millis() // 1000
    local sender = ez.mesh.get_node_name() or "Unknown"
    local content = sender .. ": " .. text .. "\0"
    
    -- Pack timestamp as little-endian uint32 + flags byte
    local plaintext = string.char(
        timestamp & 0xFF,
        (timestamp >> 8) & 0xFF,
        (timestamp >> 16) & 0xFF,
        (timestamp >> 24) & 0xFF,
        0  -- flags
    ) .. content
    
    -- Encrypt
    local ciphertext = crypto.aes128_ecb_encrypt(info.key, plaintext)
    if not ciphertext then
        print("[Channels] Encryption failed")
        return false
    end
    
    -- Compute MAC: HMAC-SHA256(key..zeros16, ciphertext)[0:2]
    local hmac_key = info.key .. string.rep("\0", 16)
    local full_mac = crypto.hmac_sha256(hmac_key, ciphertext)
    local mac = full_mac:sub(1, 2)
    
    -- Build encrypted payload: [MAC:2][ciphertext]
    local encrypted = mac .. ciphertext
    
    -- Send via mesh
    local ok = ez.mesh.send_group_packet(info.hash, encrypted)
    if not ok then
        print("[Channels] Failed to send packet")
        return false
    end
    
    -- Store our own message
    Channels._store_message(channel, {
        sender = sender,
        text = text,
        timestamp = ez.system.millis(),
        is_ours = true,
        sender_hash = ez.mesh.get_path_hash(),
    })
    
    return true
end

-- Mark channel messages as read
function Channels.mark_read(channel)
    if channel:sub(1, 1) ~= "#" then
        channel = "#" .. channel
    end
    
    local info = Channels.joined[channel]
    if info then
        info.unread = 0
    end
    
    local msgs = Channels.messages[channel]
    if msgs then
        for _, msg in ipairs(msgs) do
            msg.is_read = true
        end
    end
end

-- Set callback for incoming messages
-- @param callback Function(channel, message) called on new message
function Channels.on_message(callback)
    Channels._on_message = callback
end

-- Handle incoming group packet
function Channels._handle_group_packet(packet)
    local channel_hash = packet.channel_hash
    local data = packet.data
    local sender_hash = packet.sender_hash
    
    -- Find matching channel
    local channel_name = nil
    local channel_key = nil
    
    for name, info in pairs(Channels.joined) do
        if info.hash == channel_hash then
            channel_name = name
            channel_key = info.key
            break
        end
    end
    
    if not channel_name then
        -- Unknown channel hash, ignore
        return
    end
    
    -- Decrypt
    local text, sender = Channels._decrypt(channel_key, data)
    if not text then
        print("[Channels] Decryption failed for " .. channel_name)
        return
    end
    
    -- Check for duplicate (same text within 30 seconds)
    local msgs = Channels.messages[channel_name] or {}
    local now = ez.system.millis()
    for i = #msgs, math.max(1, #msgs - 10), -1 do
        local m = msgs[i]
        if m.text == text and m.sender == sender and (now - m.timestamp) < 30000 then
            -- Duplicate, ignore
            return
        end
    end
    
    -- Store message
    local msg = {
        sender = sender or string.format("%02X", sender_hash),
        text = text,
        timestamp = now,
        is_ours = false,
        is_read = false,
        sender_hash = sender_hash,
        rssi = packet.rssi,
        snr = packet.snr,
    }
    
    Channels._store_message(channel_name, msg)

    -- Update channel info
    local info = Channels.joined[channel_name]
    if info then
        info.unread = info.unread + 1
        info.last_activity = now

        -- Publish unread count change event
        if ez.bus and ez.bus.post then
            ez.bus.post("channel/unread", channel_name .. ":" .. info.unread)
        end
    end

    -- Publish channel message event
    if ez.bus and ez.bus.post then
        ez.bus.post("channel/message", {
            channel = channel_name,
            sender = msg.sender or "",
            text = text
        })
    end

    -- Call callback
    if Channels._on_message then
        Channels._on_message(channel_name, msg)
    end
end

-- Decrypt a channel message
-- @return text, sender or nil on error
function Channels._decrypt(key, data)
    -- Data format: [MAC:2][ciphertext]
    if #data < 18 then  -- 2 + 16 minimum
        return nil
    end
    
    local mac = data:sub(1, 2)
    local ciphertext = data:sub(3)
    
    -- Verify MAC
    local hmac_key = key .. string.rep("\0", 16)
    local computed_mac = crypto.hmac_sha256(hmac_key, ciphertext):sub(1, 2)
    
    if mac ~= computed_mac then
        -- Try with just 16-byte key (fallback)
        computed_mac = crypto.hmac_sha256(key, ciphertext):sub(1, 2)
        if mac ~= computed_mac then
            return nil
        end
    end
    
    -- Decrypt
    local plaintext = crypto.aes128_ecb_decrypt(key, ciphertext)
    if not plaintext then
        return nil
    end
    
    -- Parse: [timestamp:4][flags:1][sender: text\0]
    if #plaintext < 6 then
        return nil
    end
    
    local content = plaintext:sub(6)  -- Skip timestamp and flags
    
    -- Find null terminator
    local null_pos = content:find("\0")
    if null_pos then
        content = content:sub(1, null_pos - 1)
    end
    
    -- Split sender and text
    local sep = content:find(": ")
    if sep then
        local sender = content:sub(1, sep - 1)
        local text = content:sub(sep + 2)
        return text, sender
    end
    
    -- No separator, return as-is
    return content, nil
end

-- Store a message
function Channels._store_message(channel, msg)
    if not Channels.messages[channel] then
        Channels.messages[channel] = {}
    end
    
    local msgs = Channels.messages[channel]
    table.insert(msgs, msg)
    
    -- Trim to max
    while #msgs > Channels.MAX_MESSAGES do
        table.remove(msgs, 1)
    end
end

-- Count joined channels
function Channels._count_channels()
    local count = 0
    for _ in pairs(Channels.joined) do
        count = count + 1
    end
    return count
end

-- Save channels to storage
function Channels._save()
    local data = {
        version = 1,
        channels = {}
    }
    
    for name, info in pairs(Channels.joined) do
        -- Don't save #Public (always auto-joined)
        if name ~= "#Public" then
            table.insert(data.channels, {
                name = name,
                key = crypto.bytes_to_hex(info.key),
                is_encrypted = info.is_encrypted,
            })
        end
    end
    
    local json = ez.storage.json_encode(data)
    if json then
        ez.storage.write("/channels.json", json)
    end
end

-- Load channels from storage
function Channels._load()
    local json = ez.storage.read("/channels.json")
    if not json then
        return
    end
    
    local data = ez.storage.json_decode(json)
    if not data or data.version ~= 1 then
        return
    end
    
    for _, ch in ipairs(data.channels or {}) do
        local key = crypto.hex_to_bytes(ch.key)
        if key and #key == 16 then
            Channels._join_internal(ch.name, key, ch.is_encrypted)
        end
    end
end

return Channels
