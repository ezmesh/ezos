-- Sharing service
-- Encodes contact and channel-invite share URLs that ride inside DM
-- text bubbles, and provides the receive-side parser + redeem flow.
--
-- URL formats:
--   https://ezme.sh/#add/v1?k=<64-hex pubkey>&n=<urlencoded name>
--   https://ezme.sh/#join/v1?t=<base64url(nonce8 || aes128_ecb(secret, blob))>
--   https://ezme.sh/#time/v1?t=<unix-seconds>
--   https://ezme.sh/#rxn/v1?h=<8-hex msg_hash>&e=<emoji_index>
--
-- The fragment-only design means non-ezOS receivers see a normal
-- clickable link; the ezme.sh landing page reads location.hash
-- client-side, so no payload data ever reaches the web server.
--
-- Channel invites are encrypted to the recipient's identity using the
-- same X25519 shared secret the DM service uses, so a leaked URL is
-- useless to anyone other than the intended recipient. There's no
-- single-use nonce check on top of that -- it added no real security
-- (the encryption already gates "who can read this") and traded UX
-- away: joining and later leaving the channel made the bubble look
-- dead, even though the user would happily rejoin via the same
-- (still valid) password. The 8-byte nonce field stays in the wire
-- format so each invite encrypts to different ciphertext, but the
-- receive side doesn't track redemption.
--
-- Contact shares carry the sender's-known pubkey in plaintext; pubkeys
-- are public-by-design (every advert puts them on the air), so wrapping
-- them adds no security and would just bloat the URL.

local sharing = {}

local URL_PREFIX = "https://ezme.sh/#"
local CONTACT_VERB = "add/v1"
local INVITE_VERB = "join/v1"
local TIME_VERB = "time/v1"
local REACTION_VERB = "rxn/v1"

local NONCE_SIZE = 8
local AES_BLOCK_SIZE = 16
local PUBKEY_HEX_LEN = 64

-- Hard length cap on the encrypted invite plaintext (1 byte name_len +
-- name + 1 byte pwd_len + password). Combined with the 8-byte nonce
-- and base64url overhead, this keeps the resulting URL under DM's
-- MAX_TEXT (120). Sender-side validation refuses encodes that would
-- exceed it -- better a clear failure than a silently-truncated URL.
local INVITE_BODY_MAX = 48

-- =========================================================================
-- Helpers
-- =========================================================================

-- Percent-encode RFC3986-unreserved-only. ASCII letters, digits, and
-- the four unreserved punctuation marks pass through untouched;
-- everything else (including `&`, `=`, `#`, space, UTF-8 bytes from
-- non-ASCII names) becomes %XX. Receivers reverse this in url_decode.
local function url_encode(s)
    if not s then return "" end
    return (s:gsub("[^A-Za-z0-9%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function url_decode(s)
    if not s then return "" end
    local out, _ = s:gsub("+", " "):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return out
end

-- base64url is RFC 4648 -- standard base64 with `+/` swapped to `-_`
-- and trailing `=` padding stripped. Suits URL fragments because none
-- of the surviving characters need percent-encoding.
local function base64url_encode(bytes)
    local b64 = ez.crypto.base64_encode(bytes)
    -- Strip padding, swap URL-unsafe chars
    b64 = b64:gsub("=+$", "")
    b64 = b64:gsub("%+", "-"):gsub("/", "_")
    return b64
end

local function base64url_decode(s)
    if not s then return nil end
    -- Re-add padding, swap chars back
    local b64 = s:gsub("-", "+"):gsub("_", "/")
    local pad = (4 - #b64 % 4) % 4
    if pad > 0 then b64 = b64 .. string.rep("=", pad) end
    return ez.crypto.base64_decode(b64)
end

-- Parse a URL query string ("k=A&n=Bob") into a table.
local function parse_qs(qs)
    local t = {}
    for pair in qs:gmatch("([^&]+)") do
        local k, v = pair:match("^([^=]+)=(.*)$")
        if k then t[k] = url_decode(v) end
    end
    return t
end

local function hex_to_bytes(hex)
    return ez.crypto.hex_to_bytes(hex)
end

-- Build the 8-byte nonce that prefixes the ciphertext. Since we no
-- longer track redemption, the only job is to make repeat invites for
-- the same channel produce different tokens (otherwise re-sharing the
-- same channel would emit byte-identical URLs and chat dedup would
-- collapse them). esp_fill_random gives us 8 hardware-seeded bytes
-- directly, so the prior SHA-256 wrap of millis() + math.random + our
-- pubkey is no longer needed.
local function random_nonce()
    return ez.crypto.random_bytes(NONCE_SIZE)
end

-- =========================================================================
-- Public API
-- =========================================================================

-- Kept as a no-op so existing boot.lua / call sites remain valid.
-- Earlier revisions loaded a persisted nonce-redemption set; that's
-- gone now (see header).
function sharing.init()
end

-- Encode a contact pubkey + display name into a share URL. No
-- encryption: the pubkey is broadcast in every ADVERT anyway.
function sharing.encode_contact(pub_key_hex, name)
    if not pub_key_hex or #pub_key_hex ~= PUBKEY_HEX_LEN then return nil end
    local url = URL_PREFIX .. CONTACT_VERB .. "?k=" .. pub_key_hex:lower()
    if name and name ~= "" then
        url = url .. "&n=" .. url_encode(name)
    end
    return url
end

-- Encode a channel name + password into an invite URL targeted at a
-- specific recipient. Returns the URL on success, or (nil, "reason")
-- on failure (recipient unknown, channel too long, no shared secret).
--
-- The encrypted token = nonce(8) || AES-128-ECB(secret_with_recipient,
-- [name_len:1][name][pwd_len:1][password] padded to 16 bytes). Anyone
-- who picks up the URL but doesn't share an ECDH secret with the
-- sender (i.e. anyone other than the intended recipient) cannot
-- decrypt the token.
function sharing.encode_channel_invite(recipient_pub_key_hex, channel_name, channel_password)
    if not recipient_pub_key_hex or #recipient_pub_key_hex ~= PUBKEY_HEX_LEN then
        return nil, "invalid recipient"
    end
    if not channel_name or channel_name == "" then return nil, "missing channel name" end
    if not channel_password or channel_password == "" then return nil, "channel has no password" end

    if #channel_name > 80 or #channel_password > 80 then
        return nil, "channel name/password too long"
    end

    local body = string.char(#channel_name) .. channel_name
        .. string.char(#channel_password) .. channel_password
    if #body > INVITE_BODY_MAX then
        return nil, "name + password too long for one URL"
    end

    -- Pad to AES-128 block boundary with zero bytes; the redeemer
    -- recovers the exact lengths from the embedded length prefixes,
    -- so trailing zero bytes are unambiguous.
    local rem = #body % AES_BLOCK_SIZE
    if rem ~= 0 then body = body .. string.rep("\0", AES_BLOCK_SIZE - rem) end

    local recipient_pub = hex_to_bytes(recipient_pub_key_hex)
    if not recipient_pub or #recipient_pub ~= 32 then return nil, "bad recipient key" end

    local secret = ez.mesh.calc_shared_secret(recipient_pub)
    if not secret or #secret ~= 32 then return nil, "shared secret unavailable" end
    local key = secret:sub(1, 16)

    local ciphertext = ez.crypto.aes128_ecb_encrypt(key, body)
    if not ciphertext then return nil, "encrypt failed" end

    local nonce = random_nonce()
    local token = base64url_encode(nonce .. ciphertext)
    return URL_PREFIX .. INVITE_VERB .. "?t=" .. token
end

-- Encode a reaction into a share URL. `msg_hash` is the raw 4-byte
-- digest produced by services.reactions.compute_msg_hash (hex-encoded
-- inline so the URL is plain ASCII), `emoji_index` is a 1..255 small
-- integer indexing into the reactions palette. Reaction URLs ride
-- inside a normal DM TXT_MSG to inherit flood routing, retries, and
-- ACKs; the receive side intercepts them in services.direct_messages
-- before the bubble lands in conversation history.
function sharing.encode_reaction(msg_hash, emoji_index)
    if not msg_hash or #msg_hash ~= 4 then return nil end
    if type(emoji_index) ~= "number"
            or emoji_index < 1 or emoji_index > 255 then
        return nil
    end
    local hex_hash = string.format("%02X%02X%02X%02X",
        msg_hash:byte(1), msg_hash:byte(2),
        msg_hash:byte(3), msg_hash:byte(4))
    return URL_PREFIX .. REACTION_VERB
        .. "?h=" .. hex_hash
        .. "&e=" .. tostring(emoji_index)
end

-- Encode the current unix time into a share URL.
function sharing.encode_time()
    local ts = ez.system.get_time_unix()
    if not ts or ts == 0 then return nil, "clock not set" end
    return URL_PREFIX .. TIME_VERB .. "?t=" .. tostring(ts)
end

-- Parse arbitrary text and return a structured share descriptor if it
-- contains a recognised share URL, or nil otherwise. Looks for the
-- URL prefix anywhere in the text -- bubbles can have leading words
-- (e.g. "look at this https://ezme.sh/#...") and we still detect.
--
-- Returned shape:
--   { kind = "contact", pub_key_hex = "...", name = "..." }
--   { kind = "channel_invite", token = "<base64url>" }
--   { kind = "time", timestamp = <unix_ts> }
function sharing.parse(text)
    if not text or #text == 0 then return nil end

    local verb, qs = text:match("https://ezme%.sh/#([%w/]+)%?([^%s]+)")
    if not verb then return nil end
    local params = parse_qs(qs)

    if verb == CONTACT_VERB then
        local k = params.k
        if not k or #k ~= PUBKEY_HEX_LEN then return nil end
        if not k:match("^[0-9A-Fa-f]+$") then return nil end
        return {
            kind = "contact",
            pub_key_hex = k:upper(),
            name = params.n,
        }
    elseif verb == INVITE_VERB then
        if not params.t or params.t == "" then return nil end
        return {
            kind = "channel_invite",
            token = params.t,
        }
    elseif verb == TIME_VERB then
        local ts = tonumber(params.t)
        if not ts or ts < 1577836800 then return nil end  -- before 2020
        return {
            kind = "time",
            timestamp = ts,
        }
    elseif verb == REACTION_VERB then
        local h = params.h
        if not h or #h ~= 8 or not h:match("^[0-9A-Fa-f]+$") then return nil end
        local e = tonumber(params.e)
        if not e or e < 1 or e > 255 or e ~= math.floor(e) then return nil end
        local msg_hash = hex_to_bytes(h)
        if not msg_hash or #msg_hash ~= 4 then return nil end
        return {
            kind        = "reaction",
            msg_hash    = msg_hash,
            emoji_index = e,
        }
    end
    return nil
end

-- Decrypt a channel-invite token from a known sender. Returns the
-- recovered { name, password } on success, or (nil, "reason") on
-- cryptographic failure (bad pubkey, MAC fail, malformed plaintext).
-- The 8-byte nonce in the wire format is consumed but not exposed:
-- it exists to make every invite produce different ciphertext, not
-- to gate redemption.
function sharing.decode_channel_invite(token, sender_pub_key_hex)
    if not token or not sender_pub_key_hex or #sender_pub_key_hex ~= PUBKEY_HEX_LEN then
        return nil, "bad input"
    end

    local raw = base64url_decode(token)
    if not raw or #raw < NONCE_SIZE + AES_BLOCK_SIZE then return nil, "token too short" end
    if (#raw - NONCE_SIZE) % AES_BLOCK_SIZE ~= 0 then return nil, "token misaligned" end

    -- Skip the nonce -- it's a uniqueness salt, not a redeem token.
    local ciphertext = raw:sub(NONCE_SIZE + 1)

    local sender_pub = hex_to_bytes(sender_pub_key_hex)
    if not sender_pub or #sender_pub ~= 32 then return nil, "bad sender key" end

    local secret = ez.mesh.calc_shared_secret(sender_pub)
    if not secret or #secret ~= 32 then return nil, "no shared secret" end
    local key = secret:sub(1, 16)

    local plaintext = ez.crypto.aes128_ecb_decrypt(key, ciphertext)
    if not plaintext or #plaintext < 2 then return nil, "decrypt failed" end

    local name_len = plaintext:byte(1)
    if not name_len or name_len == 0 or 1 + name_len + 1 > #plaintext then
        return nil, "malformed name"
    end
    local name = plaintext:sub(2, 1 + name_len)
    local pwd_len = plaintext:byte(2 + name_len)
    if not pwd_len or pwd_len == 0 or 2 + name_len + pwd_len > #plaintext then
        return nil, "malformed password"
    end
    local password = plaintext:sub(3 + name_len, 2 + name_len + pwd_len)

    return { name = name, password = password }
end

return sharing
