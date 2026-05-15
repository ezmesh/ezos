-- Sharing service
-- Encodes contact and channel-invite share URLs that ride inside DM
-- text bubbles, and provides the receive-side parser + redeem flow.
--
-- URL formats:
--   https://ezme.sh/#add/v1?k=<64-hex pubkey>&n=<urlencoded name>
--   https://ezme.sh/#join/v1?t=<base64url(nonce8 || aes128_ecb(secret, blob))>
--   https://ezme.sh/#time/v1?t=<unix_ts>
--   https://ezme.sh/#cal/v1?ts=<unix>&dur=<secs>&n=<title>[&lat=<e6>&lon=<e6>]
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
local CAL_VERB = "cal/v1"

local NONCE_SIZE = 8
local AES_BLOCK_SIZE = 16
local PUBKEY_HEX_LEN = 64

-- Hard length cap on the encrypted invite plaintext (1 byte name_len +
-- name + 1 byte pwd_len + password). Combined with the 8-byte nonce
-- and base64url overhead, this keeps the resulting URL under DM's
-- MAX_TEXT (120). Sender-side validation refuses encodes that would
-- exceed it -- better a clear failure than a silently-truncated URL.
local INVITE_BODY_MAX = 48

-- cal/v1 limits. Title is sanitized to printable ASCII (fonts are
-- ASCII-only) and truncated so the full URL fits in DM's MAX_TEXT=120
-- even when lat/lon are present. Duration is capped at 24h per spec to
-- keep the payload short and discourage long-running events.
local CAL_TITLE_MAX = 32
local CAL_DUR_MAX = 86400
-- Reject ts outside +/- 1 year of "now" so a stale or fat-fingered
-- value can't pollute the reminder queue. Receivers validate too.
local CAL_TS_WINDOW = 365 * 24 * 3600

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

-- Encode the current unix time into a share URL.
function sharing.encode_time()
    local ts = ez.system.get_time_unix()
    if not ts or ts == 0 then return nil, "clock not set" end
    return URL_PREFIX .. TIME_VERB .. "?t=" .. tostring(ts)
end

-- Strip the title down to printable ASCII so the on-device fonts can
-- render it and url_encode doesn't blow up the URL with %XX runs of
-- multi-byte UTF-8. Anything outside 0x20..0x7E is dropped (not
-- replaced) so the trimmed string remains a tight fit for the URL.
local function cal_sanitize_title(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("[^\32-\126]", "")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if #s > CAL_TITLE_MAX then s = s:sub(1, CAL_TITLE_MAX) end
    return s
end

-- Encode an event/meetup share URL. ts is the unix start time, dur is
-- the duration in seconds (capped at 24h), title is required, lat/lon
-- are optional decimal degrees. Returns (url, nil) or (nil, reason).
--
-- The URL fits inside DM's MAX_TEXT=120 even at worst case: the prefix
-- and fixed keys take ~50 bytes, ts/dur up to ~25, lat/lon up to ~28,
-- leaving room for CAL_TITLE_MAX (32) ASCII title bytes (no
-- percent-encoding overhead because we restrict charset upstream).
function sharing.encode_cal(ts, dur, title, lat, lon)
    ts = tonumber(ts)
    dur = tonumber(dur)
    if not ts or ts <= 0 then return nil, "missing start time" end
    if not dur or dur <= 0 then return nil, "missing duration" end
    if dur > CAL_DUR_MAX then return nil, "duration over 24h" end

    local now = ez.system.get_time_unix() or 0
    if now > 0 and math.abs(ts - now) > CAL_TS_WINDOW then
        return nil, "time outside +/-1y window"
    end

    local clean = cal_sanitize_title(title or "")
    if clean == "" then return nil, "missing title" end

    local parts = {
        "ts=" .. tostring(math.floor(ts)),
        "dur=" .. tostring(math.floor(dur)),
        "n=" .. url_encode(clean),
    }

    if lat ~= nil and lon ~= nil then
        local la = tonumber(lat)
        local lo = tonumber(lon)
        if la and lo and la >= -90 and la <= 90 and lo >= -180 and lo <= 180 then
            parts[#parts + 1] = "lat=" .. tostring(math.floor(la * 1e6))
            parts[#parts + 1] = "lon=" .. tostring(math.floor(lo * 1e6))
        end
    end

    return URL_PREFIX .. CAL_VERB .. "?" .. table.concat(parts, "&")
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
--   { kind = "cal", timestamp, duration, title, lat?, lon? }
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
    elseif verb == CAL_VERB then
        local ts = tonumber(params.ts)
        local dur = tonumber(params.dur)
        local n = params.n
        if not ts or ts < 1577836800 then return nil end
        -- Enforce the +/-1y window on receive too, not just on encode.
        -- Without this a peer can craft a far-future ts that the user
        -- adds to reminders; reminders.tick() only prunes entries
        -- whose fire_done is set, which never happens for year-2286
        -- timestamps -- the queue fills up and never recovers.
        local _now = ez.system.get_time_unix() or 0
        if _now > 0 and math.abs(ts - _now) > CAL_TS_WINDOW then return nil end
        if not dur or dur <= 0 or dur > CAL_DUR_MAX then return nil end
        if not n or n == "" then return nil end
        -- Defensive: strip non-ASCII the sender may have smuggled in.
        -- Receivers display via the bitmap fonts so a stray UTF-8 byte
        -- would render as []. cal_sanitize_title also trims length, so
        -- a malicious peer can't blow up the bubble layout either.
        local title = cal_sanitize_title(n)
        if title == "" then return nil end
        local lat = tonumber(params.lat)
        local lon = tonumber(params.lon)
        local out = {
            kind = "cal",
            timestamp = math.floor(ts),
            duration = math.floor(dur),
            title = title,
        }
        -- Coordinates ride as int_e6 on the wire. Reject impossible
        -- values so an oversize int can't corrupt the bubble's "Show
        -- on map" hand-off.
        if lat and lon then
            local la = lat / 1e6
            local lo = lon / 1e6
            if la >= -90 and la <= 90 and lo >= -180 and lo <= 180 then
                out.lat = la
                out.lon = lo
            end
        end
        return out
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
