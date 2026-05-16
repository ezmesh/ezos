-- Channel message service
-- Manages joined channels, handles decryption, message storage, and persistence.

local channels = {}

-- Constants
local PREF_KEY = "joined_channels"  -- Preferences key for persistence

-- Per-channel preferences live under their own keys so the joined-list
-- format above (a single packed string) doesn't have to grow. NVS
-- caps key length at 15 characters, so the prefixes must be short
-- (`ch_h` / `ch_n`) and the sanitized channel name is truncated to
-- fit. The truncation isn't ambiguous in practice because users join
-- a handful of channels and they don't share long prefixes.
local NVS_KEY_MAX = 15
local function pref_key(prefix, name)
    local sanitized = (name or ""):gsub("[^%w]", "_")
    local budget = NVS_KEY_MAX - #prefix - 1   -- 1 for the separator
    if budget < 1 then return prefix end       -- shouldn't happen
    if #sanitized > budget then
        sanitized = sanitized:sub(1, budget)
    end
    return prefix .. "_" .. sanitized
end

-- History limit options + lookup helpers. The actual setter that mutates
-- live history lives further down (after `history` is declared);
-- store_message references the getter via the local below.
local HISTORY_OPTIONS = { 0, 50, 200, 500, 1000 }
local NOTIFY_MODES    = { "all", "mentions", "none" }
local function default_history_limit(name)
    if name == "#Public" then return 50 end
    return 200
end
local function get_history_limit(name)
    local raw = ez.storage and ez.storage.get_pref
                  and ez.storage.get_pref(pref_key("ch_h", name), nil)
    if raw == nil or raw == "" then return default_history_limit(name) end
    local n = tonumber(raw)
    if not n or n < 0 then return default_history_limit(name) end
    return math.floor(n)
end
local function default_notify_mode(name)
    if name == "#Public" then return "mentions" end
    return "all"
end

-- State
--   key    -- 16-byte AES-128 key (the actual cipher key)
--   secret -- 32-byte HMAC key. MeshCore stores GroupChannel.secret as
--             uint8_t[PUB_KEY_SIZE=32] and HMACs over the full 32 bytes
--             (Utils::encryptThenMAC). For 128-bit channel keys the
--             upper 16 bytes are zero, which we mirror here so wire
--             format stays compatible with the reference firmware.
local joined = {}       -- { [name] = { key=16B, secret=32B, hash=int, hidden=bool, password=str|nil } }
local history = {}      -- { [name] = { messages... } }
local unread = {}       -- { [name] = count }
local initialized = false

local MAC_SIZE = 2
local AES_BLOCK_SIZE = 16

-- Bitwise rather than float division: with LUA_32BITS=1 the runtime
-- uses single-precision floats and `v / 256` loses precision for
-- unix-second timestamps, which corrupted the second byte of the LE
-- u32 for many values. Identical fix to direct_messages.pack_u32le.
local function pack_u32le(v)
    v = v & 0xFFFFFFFF
    return string.char(v & 0xFF,
                       (v >> 8) & 0xFF,
                       (v >> 16) & 0xFF,
                       (v >> 24) & 0xFF)
end

-- Expand a 16-byte channel key into the 32-byte secret MeshCore HMACs
-- against. MeshCore::Utils::encryptThenMAC keys HMAC-SHA256 with
-- PUB_KEY_SIZE=32 bytes; 128-bit channel keys live in the lower half
-- with zero padding above.
local function key_to_secret(key)
    return key .. string.rep('\0', 32 - #key)
end

-- Resolve sender name from node list by path hash
local function resolve_sender(sender_hash)
    if not ez.mesh.is_initialized() then return nil end
    local nodes = ez.mesh.get_nodes()
    if nodes then
        for _, node in ipairs(nodes) do
            if node.path_hash == sender_hash then
                return node.name
            end
        end
    end
    return nil
end

-- Track running signal-quality ranges across collapsed duplicates so
-- the bubble's context menu can show e.g. "RSSI: -110..-90 dBm" instead
-- of just the most recent value. Called both when a fresh msg first
-- lands (seed from its own values) and when a duplicate is folded in
-- (extend the range).
local function fold_signal(target, src)
    if src.rssi then
        target.rssi_min = math.min(target.rssi_min or src.rssi, src.rssi)
        target.rssi_max = math.max(target.rssi_max or src.rssi, src.rssi)
    end
    if src.snr then
        target.snr_min = math.min(target.snr_min or src.snr, src.snr)
        target.snr_max = math.max(target.snr_max or src.snr, src.snr)
    end
    if src.hop_count then
        target.hops_min = math.min(target.hops_min or src.hop_count, src.hop_count)
        target.hops_max = math.max(target.hops_max or src.hop_count, src.hop_count)
    end
end

-- Store a decoded message into history, grouping consecutive duplicates
local function store_message(channel_name, msg)
    if not history[channel_name] then
        history[channel_name] = {}
    end
    local h = history[channel_name]

    -- Group consecutive messages from the same sender with the same text
    local last = h[#h]
    if last and last.sender_name == msg.sender_name and last.text == msg.text then
        last.count = (last.count or 1) + 1
        last.rssi = msg.rssi
        last.timestamp = msg.timestamp
        fold_signal(last, msg)
        return
    end

    msg.count = 1
    fold_signal(msg, msg)
    h[#h + 1] = msg
    -- Trim to max(limit, 1): with limit=0 ("None"), the chat screen
    -- still rebuilds from get_history() on the channel/message bus
    -- event, so we have to keep the just-added message around for at
    -- least the current frame. The next store_message call will
    -- evict it, matching the "no retention beyond the next message"
    -- intent. set_history_limit drains all the way down -- that's an
    -- explicit user action on pre-existing history.
    local limit = math.max(get_history_limit(channel_name), 1)
    while #h > limit do
        table.remove(h, 1)
    end
end

-- Save joined channels to persistent storage (excludes #Public which is always present)
local function save_channels()
    local data = {}
    for name, info in pairs(joined) do
        if name ~= "#Public" then
            data[#data + 1] = {
                name = name,
                password = info.password,
                hidden = info.hidden or false,
            }
        else
            -- Only save hidden state for Public
            if info.hidden then
                data[#data + 1] = { name = "#Public", hidden = true }
            end
        end
    end
    -- Encode as simple string: "name|password|hidden;name|password|hidden;..."
    local parts = {}
    for _, ch in ipairs(data) do
        parts[#parts + 1] = (ch.name or "") .. "|" .. (ch.password or "") .. "|" .. (ch.hidden and "1" or "0")
    end
    ez.storage.set_pref(PREF_KEY, table.concat(parts, ";"))
end

-- Load joined channels from persistent storage
local function load_channels()
    local raw = ez.storage.get_pref(PREF_KEY, "")
    if raw == "" then return end
    for entry in raw:gmatch("[^;]+") do
        local name, password, hidden_str = entry:match("^([^|]*)|([^|]*)|([^|]*)$")
        if name and name ~= "" and name ~= "#Public" then
            local key = ez.crypto.derive_channel_key(password)
            local hash = ez.crypto.channel_hash(key)
            joined[name] = {
                key = key,
                secret = key_to_secret(key),
                hash = hash,
                password = password,
                hidden = hidden_str == "1",
            }
            if not history[name] then history[name] = {} end
            if not unread[name] then unread[name] = 0 end
        elseif name == "#Public" then
            -- Restore hidden state for Public
            if joined["#Public"] then
                joined["#Public"].hidden = hidden_str == "1"
            end
        end
    end
end

-- =========================================================================
-- Public API
-- =========================================================================

-- Join a channel. For Public, pass nil password.
function channels.join(name, password)
    local key
    if name == "#Public" then
        key = ez.crypto.public_channel_key()
    else
        if not password or password == "" then return false end
        key = ez.crypto.derive_channel_key(password)
    end

    local hash = ez.crypto.channel_hash(key)
    joined[name] = {
        key = key,
        secret = key_to_secret(key),
        hash = hash,
        password = password,
        hidden = false,
    }
    if not history[name] then history[name] = {} end
    if not unread[name] then unread[name] = 0 end

    if name ~= "#Public" then
        save_channels()
    end

    ez.log("[Channels] Joined: " .. name .. " (hash=" .. hash .. ")")
    ez.bus.post("channel/list_changed", name)
    return true
end

-- Leave/delete a channel (cannot delete Public)
function channels.leave(name)
    if name == "#Public" then return false end
    joined[name] = nil
    history[name] = nil
    unread[name] = nil
    save_channels()
    ez.bus.post("channel/list_changed", name)
    return true
end

-- Toggle hidden state for a channel
function channels.set_hidden(name, hidden)
    if joined[name] then
        joined[name].hidden = hidden
        save_channels()
        ez.bus.post("channel/list_changed", name)
    end
end

-- Check if a channel exists
function channels.is_joined(name)
    return joined[name] ~= nil
end

-- Get info about a channel
function channels.get_info(name)
    return joined[name]
end

-- Get message history for a channel
function channels.get_history(name)
    return history[name] or {}
end

-- Get unread count for a channel
function channels.get_unread(name)
    return unread[name] or 0
end

-- Mark a channel as read
function channels.mark_read(name)
    unread[name] = 0
end

-- Send a text message to a channel. Builds the MeshCore GRP_TXT
-- plaintext ([ts:4 LE][type:1=0x00 plain][sender: text]), AES-encrypts
-- under the channel's 16-byte key, prepends a 2-byte HMAC truncation
-- (Utils::encryptThenMAC), and ships it via send_group_packet. The
-- bubble is also stored locally with is_self=true so the chat screen
-- can paint it immediately -- the wire packet itself isn't echoed back
-- (MeshCore filters our own path hash before posting), so without this
-- self-store the sender wouldn't see their own messages.
function channels.send(name, text)
    local info = joined[name]
    if not info then return false end
    if not text or text == "" then return false end
    if not ez.mesh.is_initialized() then return false end

    local sender = ez.mesh.get_node_name() or "?"
    local content = sender .. ": " .. text

    -- Use real wall-clock time when available so receivers can render
    -- "x mins ago" against the timestamp embedded in the plaintext;
    -- fall back to 0 on devices that haven't synced NTP.
    local timestamp = 0
    if ez.system.get_time then
        local t = ez.system.get_time()
        if t and t.epoch then timestamp = t.epoch end
    end

    local plaintext = pack_u32le(timestamp) .. string.char(0x00) .. content
    local rem = #plaintext % AES_BLOCK_SIZE
    if rem ~= 0 then
        plaintext = plaintext .. string.rep('\0', AES_BLOCK_SIZE - rem)
    end

    local ciphertext = ez.crypto.aes128_ecb_encrypt(info.key, plaintext)
    if not ciphertext or #ciphertext == 0 then return false end

    local mac = ez.crypto.hmac_sha256(info.secret, ciphertext):sub(1, MAC_SIZE)
    local data = mac .. ciphertext

    local sent = ez.mesh.send_group_packet(info.hash, data)
    if not sent then return false end

    local msg = {
        channel = name,
        sender_hash = ez.mesh.get_path_hash(),
        sender_name = sender,
        text = text,
        timestamp = timestamp,
        is_self = true,
    }
    store_message(name, msg)
    ez.bus.post("channel/message", msg)
    return true
end

-- Get ordered list of channel info for display
function channels.get_list()
    local result = {}
    -- Public always first
    if joined["#Public"] then
        local info = joined["#Public"]
        local msgs = history["#Public"] or {}
        result[#result + 1] = {
            name = "#Public",
            hidden = info.hidden or false,
            unread = unread["#Public"] or 0,
            last_msg = msgs[#msgs],
            is_public = true,
        }
    end
    -- Other channels sorted by name
    local others = {}
    for name, _ in pairs(joined) do
        if name ~= "#Public" then
            others[#others + 1] = name
        end
    end
    table.sort(others)
    for _, name in ipairs(others) do
        local info = joined[name]
        local msgs = history[name] or {}
        result[#result + 1] = {
            name = name,
            hidden = info.hidden or false,
            unread = unread[name] or 0,
            last_msg = msgs[#msgs],
            is_public = false,
        }
    end
    return result
end

-- Per-channel history limit. 0 disables retention beyond the next
-- store_message call. Setting trims live history immediately so the
-- user sees the new cap without waiting for fresh traffic.
channels.HISTORY_OPTIONS = HISTORY_OPTIONS
function channels.get_history_limit(name) return get_history_limit(name) end
function channels.set_history_limit(name, limit)
    limit = tonumber(limit) or 0
    if limit < 0 then limit = 0 end
    ez.storage.set_pref(pref_key("ch_h", name), tostring(math.floor(limit)))
    local h = history[name]
    if h then
        while #h > limit do table.remove(h, 1) end
    end
end

-- Per-channel notification mode: "all" / "mentions" / "none". Read by
-- the boot-side channel/message subscriber that posts into
-- services.notifications. Defaults: "mentions" for #Public,
-- "all" for everything else.
channels.NOTIFY_MODES = NOTIFY_MODES
function channels.get_notify_mode(name)
    local v = ez.storage and ez.storage.get_pref
                and ez.storage.get_pref(pref_key("ch_n", name), nil)
    if v == "all" or v == "mentions" or v == "none" then return v end
    return default_notify_mode(name)
end
function channels.set_notify_mode(name, mode)
    if mode ~= "all" and mode ~= "mentions" and mode ~= "none" then return end
    ez.storage.set_pref(pref_key("ch_n", name), mode)
end

-- Initialize: set up group packet handler and join public channel
function channels.init()
    if initialized then return end
    initialized = true

    -- Join the default public channel
    channels.join("#Public", nil)

    -- Load saved channels from storage
    load_channels()

    -- Register the group packet callback to enable reception
    ez.mesh.on_group_packet(function(pkt)
        -- Find which channel this packet belongs to
        local target_name, target_info
        for name, info in pairs(joined) do
            if info.hash == pkt.channel_hash then
                target_name = name
                target_info = info
                break
            end
        end
        if not target_name then return end

        -- pkt.data wire format: [MAC:2][ciphertext:N*16]. MeshCore
        -- (Utils::MACThenDecrypt) authenticates with HMAC-SHA256 keyed
        -- by the channel's full 32-byte secret over the ciphertext, then
        -- truncates to 2 bytes; reject anything whose recomputed MAC
        -- doesn't match. Drops random AES-aligned noise that would
        -- otherwise be "decrypted" into garbage and stored as messages.
        if #pkt.data <= MAC_SIZE then return end
        local received_mac = pkt.data:sub(1, MAC_SIZE)
        local ciphertext = pkt.data:sub(MAC_SIZE + 1)
        if #ciphertext == 0 or #ciphertext % AES_BLOCK_SIZE ~= 0 then return end

        local expected_mac = ez.crypto.hmac_sha256(target_info.secret, ciphertext):sub(1, MAC_SIZE)
        if received_mac ~= expected_mac then return end

        local plaintext = ez.crypto.aes128_ecb_decrypt(target_info.key, ciphertext)
        if not plaintext or #plaintext == 0 then return end

        -- Strip trailing null bytes from AES padding
        plaintext = plaintext:gsub("\0+$", "")
        if #plaintext == 0 then return end

        -- MeshCore plaintext format: [timestamp:4][type:1][sendername: text]
        -- Minimum: 4 (timestamp) + 1 (type) + 3 (at least "x: y") = 8 bytes
        if #plaintext < 8 then return end

        -- Extract 4-byte timestamp (little-endian) and 1-byte type flag
        local b1, b2, b3, b4 = plaintext:byte(1, 4)
        local msg_timestamp = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        local msg_type = plaintext:byte(5)
        local content = plaintext:sub(6)

        -- Parse "sendername: messagetext" from content
        local sender_name, text
        local colon_pos = content:find(": ", 1, true)
        if colon_pos then
            sender_name = content:sub(1, colon_pos - 1)
            text = content:sub(colon_pos + 2)
        else
            sender_name = nil
            text = content
        end

        if not text or text == "" then return end

        -- Handle room server relays: the text may contain a nested
        -- [timestamp:4][type:1][original_sender: original_text] structure.
        -- Detect by checking if text starts with 5+ bytes where byte 5
        -- is a valid type (0-2) followed by another "sender: text" pattern.
        if #text > 8 then
            local inner_type = text:byte(5)
            if inner_type and inner_type <= 2 then
                local inner_content = text:sub(6)
                local inner_colon = inner_content:find(": ", 1, true)
                if inner_colon and inner_colon <= 32 then
                    -- Check that the inner sender name is printable ASCII
                    local inner_sender = inner_content:sub(1, inner_colon - 1)
                    local printable = true
                    for i = 1, #inner_sender do
                        local c = inner_sender:byte(i)
                        if c < 0x20 or c > 0x7E then
                            printable = false
                            break
                        end
                    end
                    if printable and #inner_sender > 0 then
                        -- Unwrap the relay: use inner sender and text
                        local ib1, ib2, ib3, ib4 = text:byte(1, 4)
                        msg_timestamp = ib1 + ib2 * 256 + ib3 * 65536 + ib4 * 16777216
                        sender_name = inner_sender
                        text = inner_content:sub(inner_colon + 2)
                    end
                end
            end
        end

        if not text or text == "" then return end

        -- Check if this is from ourselves
        local my_hash = ez.mesh.get_path_hash()
        local is_self = (pkt.sender_hash == my_hash)

        -- Fall back to path hash lookup or hex if no sender in plaintext
        if not sender_name or sender_name == "" then
            sender_name = resolve_sender(pkt.sender_hash)
            if is_self then
                sender_name = ez.mesh.get_node_name() or "Me"
            end
            if not sender_name or sender_name == "" then
                sender_name = string.format("%02X", pkt.sender_hash)
            end
        end

        local msg = {
            channel = target_name,
            sender_hash = pkt.sender_hash,
            sender_name = sender_name,
            text = text,
            timestamp = msg_timestamp,
            rssi = pkt.rssi,
            snr = pkt.snr,
            -- Outer-packet hop count. Surfaced by mesh_bindings.cpp's
            -- group-packet callback (pkt.hop_count == pathLen, which
            -- equals hops because PATH_HASH_SIZE=1).
            hop_count = pkt.hop_count or 0,
            is_self = is_self,
        }

        store_message(target_name, msg)

        -- Track unread
        unread[target_name] = (unread[target_name] or 0) + 1

        -- Post decoded message to bus for any listening screens
        ez.bus.post("channel/message", msg)
    end)

    ez.log("[Channels] Service initialized, " .. #channels.get_list() .. " channel(s)")
end

return channels
