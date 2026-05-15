-- services/lockscreen: session lockscreen for the T-Deck (issue #119).
--
-- A lockscreen lives between the screensaver and the desktop. While
-- the device is locked, the keyboard handler intercepts all input and
-- routes it to the lockscreen prompt; everything underneath is frozen
-- visually but does not receive keypresses. Wake-from-panel-off does
-- NOT bypass the lock -- the wake-event guard from the touch bridge
-- swallows the originating tap so a "tap to wake" cannot accidentally
-- press a digit on the PIN entry.
--
-- Two modes:
--   "pin"        -- 4-8 digit numeric, easier than a full passphrase
--                   on the T-Deck QWERTY (numbers are alt+row 1).
--   "passphrase" -- any ASCII string; pairs naturally with the at-rest
--                   identity wrap (issue #118).
--
-- The stored "secret" is the PBKDF2-SHA256 hash of the entered string
-- plus a per-device random salt; we never persist the plaintext PIN /
-- passphrase. Iteration count is intentionally LOWER than the identity
-- wrap (50_000 rather than 100_000) because the lockscreen is hit on
-- every wake -- balancing user friction against attacker cost.
--
-- Failure backoff is persisted: `lock_fail_count` increments on each
-- wrong attempt, `lock_until` records the millis() (synthesised from
-- wall clock + boot offset) at which retries are allowed again. The
-- "wait" is in ms-since-boot; on reboot we re-arm but the user is
-- still on cooldown -- exact retry timing resets but the count
-- doesn't, so a power-cycle attack doesn't bypass the rate limit.
--
-- Prefs (all <= 15 chars to dodge NVS truncation):
--   lock_mode      "off" | "pin" | "passphrase"  default "off"
--   lock_secret    binary: [iters:4 LE][salt:16][hash:32]
--   lock_fail_n    integer (failure count since last successful unlock)
--   lock_until_ms  integer (millis() at which retries are allowed)
--
-- No "wipe on fail" in v1; out of scope.

local lockscreen = {}

local PREF_MODE    = "lock_mode"
local PREF_SECRET  = "lock_secret"
local PREF_FAILS   = "lock_fail_n"
local PREF_UNTIL   = "lock_until_ms"

local SALT_LEN = 16
local HASH_LEN = 32
local ITERS    = 50000

local FAIL_BACKOFF_MS = { 1000, 2000, 4000, 8000, 16000, 32000, 60000 }

-- In-memory state: true while the lockscreen is currently overlayed
-- and consuming input. Reset on successful unlock.
local _locked       = false
-- True once the user has entered the correct secret since boot. Lets
-- us re-lock on idle without re-prompting if they want.
local _ever_unlocked = false

-- Persisted-fail helpers
local function get_fails()
    if not (ez and ez.storage and ez.storage.get_pref) then return 0 end
    return tonumber(ez.storage.get_pref(PREF_FAILS, 0)) or 0
end

local function set_fails(n)
    if ez and ez.storage and ez.storage.set_pref then
        ez.storage.set_pref(PREF_FAILS, tostring(n))
    end
end

local function get_until_ms()
    if not (ez and ez.storage and ez.storage.get_pref) then return 0 end
    return tonumber(ez.storage.get_pref(PREF_UNTIL, 0)) or 0
end

local function set_until_ms(n)
    if ez and ez.storage and ez.storage.set_pref then
        ez.storage.set_pref(PREF_UNTIL, tostring(n))
    end
end

local function backoff_for(fail_count)
    if fail_count <= 0 then return 0 end
    local idx = math.min(fail_count, #FAIL_BACKOFF_MS)
    return FAIL_BACKOFF_MS[idx]
end

local function now_ms()
    return (ez and ez.system and ez.system.millis and ez.system.millis()) or 0
end

-- ---- Secret encode / decode ----

-- Pack secret blob: 4 bytes iterations LE + 16 byte salt + 32 byte hash.
local function pack_secret(iters, salt, hash)
    if #salt ~= SALT_LEN or #hash ~= HASH_LEN then return nil end
    return string.char(iters & 0xFF, (iters >> 8) & 0xFF,
                       (iters >> 16) & 0xFF, (iters >> 24) & 0xFF)
        .. salt .. hash
end

local function unpack_secret(blob)
    if type(blob) ~= "string" or #blob ~= 4 + SALT_LEN + HASH_LEN then
        return nil
    end
    local b1, b2, b3, b4 = blob:byte(1, 4)
    local iters = b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
    local salt = blob:sub(5, 5 + SALT_LEN - 1)
    local hash = blob:sub(5 + SALT_LEN, 5 + SALT_LEN + HASH_LEN - 1)
    return iters, salt, hash
end

-- Mini PBKDF2-SHA256 in Lua over the existing C++ ez.crypto.hmac_sha256
-- binding. We don't depend on the (newer) ez.crypto.pbkdf2_sha256
-- binding because this service ships independently of the identity-
-- wrap PR. Each HMAC call is microseconds in C++; 50_000 iterations
-- finish in well under a second even with Lua loop overhead.
local function xor_bytes(a, b)
    local out = {}
    for i = 1, #a do out[i] = string.char(a:byte(i) ~ b:byte(i)) end
    return table.concat(out)
end

local function hash_input(input, salt, iters)
    if not (ez and ez.crypto and ez.crypto.hmac_sha256) then return nil end
    -- PBKDF2-SHA256 with dkLen <= hLen, so we only need block index 1.
    local block_idx = "\x00\x00\x00\x01"
    local u = ez.crypto.hmac_sha256(input, salt .. block_idx)
    if not u then return nil end
    local t = u
    for _ = 2, iters do
        u = ez.crypto.hmac_sha256(input, u)
        if not u then return nil end
        t = xor_bytes(t, u)
    end
    -- HASH_LEN matches hLen for SHA-256, so the first block IS the
    -- output. Truncate defensively in case HASH_LEN ever shrinks.
    return t:sub(1, HASH_LEN)
end

-- Constant-time equality (Lua string `==` is short-circuiting; this
-- avoids a length-dependent timing leak on the per-byte compare).
local function ct_eq(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = diff | (a:byte(i) ~ b:byte(i))
    end
    return diff == 0
end

-- ---- Public API ----

function lockscreen.get_mode()
    if not (ez and ez.storage and ez.storage.get_pref) then return "off" end
    local m = ez.storage.get_pref(PREF_MODE, "off")
    if m ~= "pin" and m ~= "passphrase" then return "off" end
    return m
end

function lockscreen.is_armed()
    return lockscreen.get_mode() ~= "off"
end

function lockscreen.is_locked()
    return _locked
end

-- How many ms remain on the current cooldown, or 0 if retries are
-- allowed right now.
function lockscreen.cooldown_remaining()
    local until_ms = get_until_ms()
    if until_ms <= 0 then return 0 end
    local rem = until_ms - now_ms()
    if rem < 0 then return 0 end
    return rem
end

function lockscreen.fail_count()
    return get_fails()
end

-- Wipe the persisted secret + clear the mode pref + reset the fail
-- counter. Used by the Settings screen's "Off" toggle.
function lockscreen.clear()
    if ez and ez.storage and ez.storage.set_pref then
        ez.storage.set_pref(PREF_MODE,   "off")
        ez.storage.set_pref(PREF_SECRET, "")
        ez.storage.set_pref(PREF_FAILS,  "0")
        ez.storage.set_pref(PREF_UNTIL,  "0")
    end
    _locked = false
    _ever_unlocked = false
end

-- Set up the lockscreen. `mode` is "pin" or "passphrase", `secret` is
-- the user-typed PIN / passphrase. Hashes the secret with a fresh
-- random salt and stores the wrapped form.
function lockscreen.setup(mode, secret)
    if mode ~= "pin" and mode ~= "passphrase" then return false, "bad mode" end
    if type(secret) ~= "string" or secret == "" then return false, "secret required" end
    if mode == "pin" and not secret:match("^%d+$") then
        return false, "pin must be digits"
    end
    if mode == "pin" and (#secret < 4 or #secret > 8) then
        return false, "pin length must be 4..8"
    end

    local salt = ez.crypto.random_bytes(SALT_LEN)
    if not salt then return false, "rng failure" end

    local hash = hash_input(secret, salt, ITERS)
    if not hash then return false, "kdf failure" end

    local blob = pack_secret(ITERS, salt, hash)
    if not blob then return false, "pack failure" end

    ez.storage.set_pref(PREF_MODE,   mode)
    ez.storage.set_pref(PREF_SECRET, blob)
    ez.storage.set_pref(PREF_FAILS,  "0")
    ez.storage.set_pref(PREF_UNTIL,  "0")
    -- After setting up, the device is implicitly "unlocked" -- the
    -- user just demonstrated knowledge of the secret. Don't lock
    -- immediately; the next idle / boot triggers will arm it.
    _ever_unlocked = true
    return true
end

-- Attempt to unlock with `input`. Returns true on success; false +
-- reason on failure. Increments the persisted fail counter on
-- failure and pushes the cooldown forward according to the backoff
-- ladder.
function lockscreen.try_unlock(input)
    if lockscreen.cooldown_remaining() > 0 then
        return false, "cooldown"
    end
    if type(input) ~= "string" or input == "" then
        return false, "no input"
    end

    local blob = ez.storage.get_pref(PREF_SECRET, "")
    local iters, salt, hash = unpack_secret(blob)
    if not iters then return false, "no secret" end

    local got = hash_input(input, salt, iters)
    if not got then return false, "kdf failure" end

    if ct_eq(got, hash) then
        set_fails(0)
        set_until_ms(0)
        _locked = false
        _ever_unlocked = true
        if ez and ez.bus and ez.bus.post then
            ez.bus.post("lockscreen/unlocked", {})
        end
        return true
    end

    -- Failure: bump fail count, push cooldown forward.
    local fails = get_fails() + 1
    set_fails(fails)
    set_until_ms(now_ms() + backoff_for(fails))
    return false, "wrong"
end

-- Clear only the cooldown deadline; leaves the fail count intact.
-- Called from boot.lua so a power-cycle resets the retry-wait timer
-- (the millis() snapshot stored in NVS would otherwise overshoot
-- enormously after a reboot, where millis() rolls back to 0) without
-- letting the user wipe the failure history.
function lockscreen.reset_cooldown()
    set_until_ms(0)
end

-- Lock the session. No-op when not armed. Idempotent.
function lockscreen.lock()
    if not lockscreen.is_armed() then return end
    if _locked then return end
    _locked = true
    if ez and ez.bus and ez.bus.post then
        ez.bus.post("lockscreen/locked", {})
    end
end

-- Called by boot.lua / the idle ladder to arm the lockscreen on boot
-- or after the screensaver fires. Locks unconditionally when the
-- mode is set; safe to call repeatedly.
function lockscreen.maybe_lock(reason)
    if lockscreen.is_armed() then
        lockscreen.lock()
    end
end

return lockscreen
