-- services/reactions: tiny-emoji reactions over RAW_CUSTOM packets.
--
-- Reactions are a low-information acknowledgement that should NOT pay the
-- full TXT_MSG round-trip cost. We send them as a custom packet with the
-- "RXN\0" subtype, payload `[target_msg_hash:4][emoji_index:1]`. Receivers
-- look the target message up in their local conversation history and
-- attach the reaction to it.
--
-- Storage shape (in-RAM, not persisted across reboots in v1):
--   reactions[target_pub_hex][target_msg_hash] = {
--       [sender_pub_hex] = emoji_index,
--   }
--
-- Lookup keys both ways:
--   * For an inbound DM you sent ("self bubble"), target_pub_hex is the
--     conversation partner -- the reaction comes FROM them and is ABOUT a
--     message you sent, so the bucket is indexed by their pubkey.
--   * For an inbound DM you received, the reaction (from you) goes into
--     the bucket indexed by your conversation partner -- same key.
--   * For your own outbound reaction, target_pub_hex is the partner.
--
-- target_msg_hash is `sha256([sender_pubkey:32][timestamp:4 LE][text])[:4]`.
-- Both peers can reproduce it: the original sender's pubkey is known to
-- both sides (it's in the conversation key on receive, our own pubkey on
-- self-sent). The fields fed to the hash are exactly the ones the bubble
-- carries; no extra metadata required.

local M = {}

local custom = require("services.custom_packets")

-- ASCII-only palette. Per CLAUDE.md "On-device font character set" the
-- bundled bitmap fonts only cover printable ASCII; a literal heart or
-- thumbs-up glyph would paint as `[]`. ASCII tokens are honest and
-- portable. Index 0 reserved as "unset" so we never send it.
M.EMOJI_PALETTE = {
    [1] = "+1",
    [2] = "<3",
    [3] = ":D",
    [4] = ":(",
    [5] = "^_^",
    [6] = "!!",
    [7] = "??",
    [8] = "OK",
}

-- target_pub_hex -> target_msg_hash (raw 4 bytes) -> sender_pub_hex -> idx
local reactions = {}

-- Map a pubkey hex into the unique 32-byte bytestring used in the hash
-- input. Borrows the conversion routine from custom_packets via dm.
local function hex_to_bytes(hex)
    return ez.crypto.hex_to_bytes(hex)
end

local function pack_u32_le(v)
    v = v or 0
    if v < 0 then v = v + 0x100000000 end
    return string.char(v & 0xFF, (v >> 8) & 0xFF,
                       (v >> 16) & 0xFF, (v >> 24) & 0xFF)
end

-- Stable 4-byte hash over the message's signed-by-the-original-sender
-- fields. Receivers can recompute the same hash without any extra wire
-- bits because the components (sender pubkey, timestamp, exact text)
-- are already present in their copy of the message.
function M.compute_msg_hash(sender_pub_hex, timestamp, text)
    if not sender_pub_hex or #sender_pub_hex ~= 64 then return nil end
    local pk = hex_to_bytes(sender_pub_hex)
    if not pk or #pk ~= 32 then return nil end
    local input = pk .. pack_u32_le(math.floor(timestamp or 0)) .. (text or "")
    local digest = ez.crypto.sha256(input)
    if not digest or #digest < 4 then return nil end
    return digest:sub(1, 4)
end

-- Map raw 4-byte hash to a stable hex key for the inner table -- using
-- raw bytes as Lua table keys is fine but harder to inspect.
local function hex(h)
    if not h or #h ~= 4 then return nil end
    return string.format("%02X%02X%02X%02X",
        h:byte(1), h:byte(2), h:byte(3), h:byte(4))
end

-- Record a (sender, target_msg, emoji) tuple. Posting the same emoji
-- from the same sender is a no-op (idempotent); posting a different
-- emoji replaces the previous one (the receiver only sees the latest).
local function record(target_pub_hex, target_msg_hash, sender_pub_hex, emoji_index)
    if not target_pub_hex or not sender_pub_hex then return end
    if not target_msg_hash or #target_msg_hash ~= 4 then return end
    if not M.EMOJI_PALETTE[emoji_index] then return end

    local target_bucket = reactions[target_pub_hex]
    if not target_bucket then
        target_bucket = {}
        reactions[target_pub_hex] = target_bucket
    end

    local hex_key = hex(target_msg_hash)
    local per_msg = target_bucket[hex_key]
    if not per_msg then
        per_msg = {}
        target_bucket[hex_key] = per_msg
    end

    per_msg[sender_pub_hex] = emoji_index
end

-- Returns the per-message reactions table or nil. Map is keyed by sender
-- pubkey hex (so callers can render counts + de-duplicate by sender).
function M.get_for(target_pub_hex, target_msg_hash)
    if not target_pub_hex or not target_msg_hash then return nil end
    local target_bucket = reactions[target_pub_hex]
    if not target_bucket then return nil end
    return target_bucket[hex(target_msg_hash)]
end

-- Render the per-message reactions as a "compressed" view: a list of
-- { emoji, count, senders } entries sorted by descending count so the
-- most-popular reaction paints first. Returns an empty list for no
-- reactions (so callers don't have to special-case).
function M.compress(target_pub_hex, target_msg_hash)
    local per_msg = M.get_for(target_pub_hex, target_msg_hash)
    if not per_msg then return {} end
    local counts = {}      -- emoji_index -> count
    local senders = {}     -- emoji_index -> list of sender_pub_hex
    for sender, idx in pairs(per_msg) do
        counts[idx] = (counts[idx] or 0) + 1
        senders[idx] = senders[idx] or {}
        senders[idx][#senders[idx] + 1] = sender
    end
    local out = {}
    for idx, count in pairs(counts) do
        out[#out + 1] = {
            emoji_index = idx,
            emoji       = M.EMOJI_PALETTE[idx],
            count       = count,
            senders     = senders[idx],
        }
    end
    table.sort(out, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.emoji_index < b.emoji_index
    end)
    return out
end

-- Send a reaction to `target_pub_hex` about the message whose hash is
-- `target_msg_hash`. The local record is updated synchronously so the UI
-- can refresh without waiting on the radio.
function M.send(target_pub_hex, target_msg_hash, emoji_index)
    if not target_pub_hex or not target_msg_hash then return false end
    if not M.EMOJI_PALETTE[emoji_index] then return false end

    -- Optimistically reflect our own reaction locally so the user sees
    -- their tap immediately.
    local self_pub = ez.mesh.get_public_key_hex()
    if self_pub then
        record(target_pub_hex, target_msg_hash, self_pub, emoji_index)
        ez.bus.post("chat/reaction", {
            target_pub  = target_pub_hex,
            target_hash = target_msg_hash,
            sender_pub  = self_pub,
            emoji_index = emoji_index,
            is_self     = true,
        })
    end

    spawn(function()
        custom.send(target_pub_hex, "RXN\0",
            target_msg_hash .. string.char(emoji_index))
    end)
    return true
end

-- Bus subscriber that wires inbound RXN\0 packets into the store. Split
-- from init() so it's clear what gets registered.
local function on_receive(sender_pub_hex, data, meta)
    if #data < 5 then return end
    local target_hash  = data:sub(1, 4)
    local emoji_index  = data:byte(5)
    if not M.EMOJI_PALETTE[emoji_index] then return end

    -- A reaction "about" a message you sent goes into the bucket keyed
    -- by the sender of the reaction. A reaction "about" a message
    -- THEY sent (i.e. you reacted to one of their messages, and they
    -- got the reaction echo somehow) -- doesn't happen in v1; we only
    -- emit reactions about the bubble the user tapped. So
    -- target_pub_hex == sender_pub_hex always for inbound RXN\0.
    record(sender_pub_hex, target_hash, sender_pub_hex, emoji_index)

    ez.bus.post("chat/reaction", {
        target_pub  = sender_pub_hex,
        target_hash = target_hash,
        sender_pub  = sender_pub_hex,
        emoji_index = emoji_index,
        sender_name = meta and meta.name,
        is_self     = false,
    })
end

local initialized = false
function M.init()
    if initialized then return end
    initialized = true
    custom.register({
        id        = "reaction",
        label     = "Reaction",
        subtype   = "RXN\0",
        on_receive = on_receive,
    })
end

return M
