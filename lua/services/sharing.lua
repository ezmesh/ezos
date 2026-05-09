-- Sharing service
-- Encodes contact and channel-invite share URLs that ride inside DM
-- text bubbles, and provides the receive-side parser + redeem flow.
--
-- URL formats:
--   https://ezme.sh/#add/v1?k=<64-hex pubkey>&n=<urlencoded name>
--   https://ezme.sh/#join/v1?t=<base64url(nonce8 || aes128_ecb(secret, blob))>
--
-- The fragment-only design means non-ezOS receivers see a normal
-- clickable link; the ezme.sh landing page reads location.hash
-- client-side, so no payload data ever reaches the web server.
--
-- Channel invites are encrypted to the recipient's identity using the
-- same X25519 shared secret the DM service uses, so a leaked URL is
-- useless to anyone other than the intended recipient. A persisted
-- nonce-redemption set defeats accidental re-tap (or re-share back).
--
-- Contact shares carry the sender's-known pubkey in plaintext; pubkeys
-- are public-by-design (every advert puts them on the air), so wrapping
-- them adds no security and would just bloat the URL.

local sharing = {}

local URL_PREFIX = "https://ezme.sh/#"
local CONTACT_VERB = "add/v1"
local INVITE_VERB = "join/v1"

local NONCE_SIZE = 8
local AES_BLOCK_SIZE = 16
local PUBKEY_HEX_LEN = 64

-- Hard length cap on the encrypted invite plaintext (1 byte name_len +
-- name + 1 byte pwd_len + password). Combined with the 8-byte nonce
-- and base64url overhead, this keeps the resulting URL under DM's
-- MAX_TEXT (120). Sender-side validation refuses encodes that would
-- exceed it -- better a clear failure than a silently-truncated URL.
local INVITE_BODY_MAX = 48

-- Persisted set of redeemed nonces. Bounded by REDEEMED_MAX so a long
-- session can't grow it unbounded; oldest entries fall off when the
-- cap is hit. Stored hex-encoded under PREF_KEY for cross-boot
-- replay protection. Empty set is the common case (no invites yet).
local REDEEMED_MAX = 64
local PREF_KEY = "share_redeemed"
local redeemed = {}        -- { [nonce_hex] = true }
local redeemed_order = {}  -- { nonce_hex, ... } -- LRU-style insertion order

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

local function bytes_to_hex(bytes)
    return ez.crypto.bytes_to_hex(bytes)
end

local function hex_to_bytes(hex)
    return ez.crypto.hex_to_bytes(hex)
end

local function random_nonce()
    -- math.random isn't seeded with HW entropy; use ez.crypto.sha256 over
    -- a millis() probe + a counter for a "good enough" non-repeating
    -- nonce. Replay protection comes from the persisted redeemed set,
    -- not from cryptographic uniqueness, so this is sufficient.
    local seed = string.format("%d:%d:%s",
        ez.system.millis(),
        math.random(0, 0x7FFFFFFF),
        ez.mesh.get_public_key_hex() or "")
    return ez.crypto.sha256(seed):sub(1, NONCE_SIZE)
end

-- =========================================================================
-- Persistence
-- =========================================================================

local function load_redeemed()
    local raw = ez.storage.get_pref(PREF_KEY, "")
    if not raw or raw == "" then return end
    for hex in raw:gmatch("[^,]+") do
        if #hex == NONCE_SIZE * 2 and not redeemed[hex] then
            redeemed[hex] = true
            redeemed_order[#redeemed_order + 1] = hex
        end
    end
end

local function save_redeemed()
    ez.storage.set_pref(PREF_KEY, table.concat(redeemed_order, ","))
end

local function mark_nonce_redeemed(nonce)
    local hex = bytes_to_hex(nonce):lower()
    if redeemed[hex] then return end
    redeemed[hex] = true
    redeemed_order[#redeemed_order + 1] = hex
    -- Cap the persisted set; oldest entries roll off so the pref
    -- doesn't grow unbounded over months of channel-invite traffic.
    while #redeemed_order > REDEEMED_MAX do
        local dropped = table.remove(redeemed_order, 1)
        redeemed[dropped] = nil
    end
    save_redeemed()
end

local function is_nonce_redeemed(nonce)
    local hex = bytes_to_hex(nonce):lower()
    return redeemed[hex] == true
end

-- =========================================================================
-- Public API
-- =========================================================================

function sharing.init()
    load_redeemed()
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

-- Parse arbitrary text and return a structured share descriptor if it
-- contains a recognised share URL, or nil otherwise. Looks for the
-- URL prefix anywhere in the text -- bubbles can have leading words
-- (e.g. "look at this https://ezme.sh/#...") and we still detect.
--
-- Returned shape:
--   { kind = "contact", pub_key_hex = "...", name = "..." }
--   { kind = "channel_invite", token = "<base64url>" }
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
    end
    return nil
end

-- Decrypt and validate a channel-invite token from a known sender.
-- Returns { name, password } on success, or (nil, "reason") on failure
-- (replay, bad pubkey, MAC fail, malformed plaintext). The caller is
-- responsible for marking the nonce redeemed via accept_invite().
function sharing.decode_channel_invite(token, sender_pub_key_hex)
    if not token or not sender_pub_key_hex or #sender_pub_key_hex ~= PUBKEY_HEX_LEN then
        return nil, "bad input"
    end

    local raw = base64url_decode(token)
    if not raw or #raw < NONCE_SIZE + AES_BLOCK_SIZE then return nil, "token too short" end
    if (#raw - NONCE_SIZE) % AES_BLOCK_SIZE ~= 0 then return nil, "token misaligned" end

    local nonce = raw:sub(1, NONCE_SIZE)
    local ciphertext = raw:sub(NONCE_SIZE + 1)

    if is_nonce_redeemed(nonce) then return nil, "already redeemed" end

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

    return { name = name, password = password, nonce = nonce }
end

-- Mark a successfully-redeemed invite's nonce as consumed so a later
-- re-tap of the same URL fails with "already redeemed". Call this only
-- after the user has accepted the invite (joined the channel) so an
-- ignored invite doesn't burn the nonce.
function sharing.accept_invite(invite)
    if invite and invite.nonce then
        mark_nonce_redeemed(invite.nonce)
    end
end

return sharing
