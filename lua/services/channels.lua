-- Channel message service
-- Manages joined channels, handles decryption, message storage, and persistence.

local channels = {}

-- Constants
local MAX_HISTORY = 50
local PREF_KEY = "joined_channels"  -- Preferences key for persistence

-- State
local joined = {}       -- { [name] = { key=str, hash=int, hidden=bool, password=str|nil } }
local history = {}      -- { [name] = { messages... } }
local unread = {}       -- { [name] = count }
local initialized = false

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
        return
    end

    msg.count = 1
    h[#h + 1] = msg
    while #h > MAX_HISTORY do
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

        -- Strip 2-byte MAC prefix, then decrypt the ciphertext
        if #pkt.data <= 2 then return end
        local ciphertext = pkt.data:sub(3)
        if #ciphertext % 16 ~= 0 then return end

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
