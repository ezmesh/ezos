-- services/identity_lock: wrap / unwrap the Ed25519 private key
-- behind a user passphrase (issue #118).
--
-- Wrap format (binary, little-endian fields):
--   [magic:4 "EZL1"]
--   [version:1 = 1]
--   [kdf_id:1 = 1 (PBKDF2-SHA256)]
--   [iterations:4 LE]
--   [salt_len:1]
--   [salt:salt_len]
--   [nonce_len:1]
--   [nonce:nonce_len]
--   [ct_len:2 LE]      -- ciphertext + 16-byte GCM tag
--   [ct:ct_len]
--
-- The KEK is PBKDF2-SHA256(passphrase, salt, iterations, 32) and the
-- ciphertext is AES-256-GCM(KEK, nonce, privkey, aad=pubkey). The
-- public key is mixed into the AEAD AAD so a wrapped blob bound to
-- one pubkey can't be replayed against another -- defence in depth.
--
-- Tunables: iterations is currently 100_000 which is roughly 1 s on
-- the ESP32-S3 (slow enough to deter dictionary attacks on extracted
-- bytes, fast enough that a manual unlock isn't painful). Change at
-- the call site if profiling shows otherwise.

local lock = {}

local MAGIC          = "EZL1"
local VERSION        = 1
local KDF_PBKDF2     = 1
local SALT_LEN       = 16
local NONCE_LEN      = 12
local KEK_LEN        = 32
local DEFAULT_ITERS  = 100000

local function pack_u8(v)
    return string.char(v & 0xFF)
end

local function pack_u16_le(v)
    return string.char(v & 0xFF, (v >> 8) & 0xFF)
end

local function pack_u32_le(v)
    return string.char(v & 0xFF, (v >> 8) & 0xFF,
                       (v >> 16) & 0xFF, (v >> 24) & 0xFF)
end

local function read_u8(s, off)  return s:byte(off), off + 1 end
local function read_u16_le(s, off)
    local b1, b2 = s:byte(off), s:byte(off + 1)
    return b1 | (b2 << 8), off + 2
end
local function read_u32_le(s, off)
    local b1, b2, b3, b4 = s:byte(off), s:byte(off + 1),
                           s:byte(off + 2), s:byte(off + 3)
    return b1 | (b2 << 8) | (b3 << 16) | (b4 << 24), off + 4
end

-- ---------------------------------------------------------------------------
-- Pubkey access: reads the plain `pubkey` NVS entry via the storage
-- binding. The pubkey is not secret so this is fine to expose; it's
-- bound into the AEAD AAD as identity tag.

local function read_pubkey_from_nvs()
    -- ez.mesh.get_node_id returns hex; we need raw bytes. Easiest is
    -- ez.crypto.hex_to_bytes on the full pubkey hex returned by the
    -- mesh module.
    if not (ez and ez.mesh and ez.mesh.get_public_key_hex) then
        -- Fallback: use the 6-byte node id padded -- but that's wrong.
        -- We require the full pubkey; signal failure.
        return nil
    end
    local hex = ez.mesh.get_public_key_hex()
    if not hex or #hex ~= 64 then return nil end
    return ez.crypto.hex_to_bytes(hex)
end

-- ---------------------------------------------------------------------------
-- Public API

-- True when a wrapped private-key blob currently exists in NVS,
-- regardless of whether the in-memory identity is locked or unlocked.
function lock.is_wrapped()
    return ez.identity and ez.identity.is_wrapped() or false
end

-- True when the identity is locked (wrapped blob exists AND the
-- plaintext private key is not in RAM). Boot-time predicate.
function lock.is_locked()
    return ez.identity and ez.identity.is_locked() or false
end

-- Encode a wrap blob given the raw fields.
local function encode_blob(iters, salt, nonce, ciphertext)
    return MAGIC
        .. pack_u8(VERSION)
        .. pack_u8(KDF_PBKDF2)
        .. pack_u32_le(iters)
        .. pack_u8(#salt)
        .. salt
        .. pack_u8(#nonce)
        .. nonce
        .. pack_u16_le(#ciphertext)
        .. ciphertext
end

-- Parse a wrap blob; returns iters, salt, nonce, ciphertext or nil + reason.
local function decode_blob(blob)
    if type(blob) ~= "string" or #blob < 4 + 2 + 4 + 1 + 1 + 2 then
        return nil, "too short"
    end
    if blob:sub(1, 4) ~= MAGIC then return nil, "bad magic" end
    local off = 5
    local version; version, off = read_u8(blob, off)
    if version ~= VERSION then return nil, "version mismatch" end
    local kdf; kdf, off = read_u8(blob, off)
    if kdf ~= KDF_PBKDF2 then return nil, "unsupported kdf" end
    local iters; iters, off = read_u32_le(blob, off)
    local saltLen; saltLen, off = read_u8(blob, off)
    if off + saltLen - 1 > #blob then return nil, "truncated salt" end
    local salt = blob:sub(off, off + saltLen - 1); off = off + saltLen
    local nonceLen; nonceLen, off = read_u8(blob, off)
    if off + nonceLen - 1 > #blob then return nil, "truncated nonce" end
    local nonce = blob:sub(off, off + nonceLen - 1); off = off + nonceLen
    local ctLen; ctLen, off = read_u16_le(blob, off)
    if off + ctLen - 1 > #blob then return nil, "truncated ct" end
    local ct = blob:sub(off, off + ctLen - 1)
    return iters, salt, nonce, ct
end

-- Re-read the wrapped blob from NVS and run the full decode + decrypt
-- path under `passphrase` + `pub`. Returns true iff the result matches
-- `priv` exactly. This is the round-trip used by `wrap` and `change`
-- before they touch the plaintext key -- it mirrors what `unwrap` does
-- at boot, so a buggy encode/decode framing or a silent NVS write
-- corruption is caught here, not on the next boot.
local function selftest_via_nvs(passphrase, priv, pub)
    local blob = ez.identity.read_wrapped_blob()
    if not blob then return false, "readback failed" end
    local iters, salt, nonce, ct = decode_blob(blob)
    if not iters then return false, "decode failed" end
    local kek = ez.crypto.pbkdf2_sha256(passphrase, salt, iters, KEK_LEN)
    if not kek then return false, "kdf failure" end
    local verify_pt = ez.crypto.aes_gcm_decrypt(kek, nonce, ct, pub)
    if not verify_pt or verify_pt ~= priv then
        return false, "decrypt mismatch"
    end
    return true
end

-- Wrap the current plaintext private key with `passphrase`. Returns
-- true on success, false + reason on failure. Two-phase commit: write
-- the wrapped blob first, then delete the plain copy. A power loss
-- between the two leaves both present and the C++ Identity::init()
-- rolls back to the unwrapped state on the next boot.
function lock.wrap(passphrase, opts)
    opts = opts or {}
    if type(passphrase) ~= "string" or passphrase == "" then
        return false, "passphrase required"
    end
    if lock.is_wrapped() then return false, "already wrapped" end
    if lock.is_locked()  then return false, "device is locked"   end
    if not (ez.identity and ez.identity.get_privkey_for_wrap) then
        return false, "ez.identity bindings missing"
    end

    local priv = ez.identity.get_privkey_for_wrap()
    if not priv or #priv ~= 64 then
        return false, "failed to read plaintext private key"
    end

    local pub = read_pubkey_from_nvs()
    if not pub or #pub ~= 32 then
        return false, "failed to read public key"
    end

    local iters = tonumber(opts.iterations) or DEFAULT_ITERS
    local salt  = ez.crypto.random_bytes(SALT_LEN)
    local nonce = ez.crypto.random_bytes(NONCE_LEN)
    if not salt or not nonce then return false, "rng failure" end

    local kek = ez.crypto.pbkdf2_sha256(passphrase, salt, iters, KEK_LEN)
    if not kek then return false, "kdf failure" end

    local ct = ez.crypto.aes_gcm_encrypt(kek, nonce, priv, pub)
    if not ct then return false, "encrypt failure" end

    local blob = encode_blob(iters, salt, nonce, ct)
    if not ez.identity.write_wrapped_blob(blob) then
        return false, "nvs write failed"
    end

    -- Verify round-trip BEFORE deleting the plaintext, so a buggy
    -- KDF / cipher / blob-encoding can't lock the user out. Read the
    -- blob back from NVS and exercise decode_blob + the full decrypt
    -- path, matching what lock.unwrap does at boot.
    local ok_test, reason = selftest_via_nvs(passphrase, priv, pub)
    if not ok_test then
        -- Roll back: remove the wrapped blob, leave plaintext alone.
        ez.identity.delete_wrapped_blob()
        return false, "self-test failed: " .. reason
    end

    if not ez.identity.delete_plain_privkey() then
        -- We have a wrapped blob and a plaintext key in NVS. Boot
        -- will roll back the wrap; the user will still have their
        -- identity. Surface the failure so they can retry.
        return false, "delete plaintext failed; reboot to roll back"
    end
    return true
end

-- Decrypt the wrapped blob using `passphrase`. Returns priv, pub on
-- success (both binary) or nil, reason on failure. Does NOT call
-- ez.identity.unlock() -- caller decides when to wire the keys in.
function lock.unwrap(passphrase)
    if type(passphrase) ~= "string" or passphrase == "" then
        return nil, "passphrase required"
    end
    if not lock.is_wrapped() then return nil, "not wrapped" end

    local blob = ez.identity.read_wrapped_blob()
    if not blob then return nil, "no wrapped blob" end

    local iters, salt, nonce, ct = decode_blob(blob)
    if not iters then return nil, "blob: " .. (salt or "decode error") end

    local pub = read_pubkey_from_nvs()
    if not pub or #pub ~= 32 then return nil, "no public key" end

    local kek = ez.crypto.pbkdf2_sha256(passphrase, salt, iters, KEK_LEN)
    if not kek then return nil, "kdf failure" end

    local priv = ez.crypto.aes_gcm_decrypt(kek, nonce, ct, pub)
    if not priv or #priv ~= 64 then return nil, "auth failed" end

    return priv, pub
end

-- Boot-time unlock: decrypts and feeds the keypair into the C++
-- Identity. Returns true on success, false + reason otherwise.
function lock.unlock(passphrase, node_name)
    local priv, pub = lock.unwrap(passphrase)
    if not priv then return false, pub end   -- pub holds reason on fail
    if not ez.identity.unlock(priv, pub, node_name) then
        return false, "identity unlock binding failed"
    end
    return true
end

-- "Remove passphrase": unwrap, write the plaintext back, then delete
-- the wrapped blob. Only callable in the unlocked state (the identity
-- binding refuses write_plain_privkey while locked).
function lock.remove(passphrase)
    if not lock.is_wrapped() then return false, "not wrapped" end
    if lock.is_locked() then return false, "unlock first" end
    local priv, _pub = lock.unwrap(passphrase)
    if not priv then return false, _pub end
    if not ez.identity.write_plain_privkey(priv) then
        return false, "write plain key failed"
    end
    if not ez.identity.delete_wrapped_blob() then
        return false, "delete wrapped blob failed"
    end
    return true
end

-- "Change passphrase": unwrap, re-wrap with the new passphrase. The
-- atomic story is the same as `wrap`: we write the new blob, verify
-- round-trip, then nothing to delete (the wrapped blob is replaced
-- in place by the write). If the new write fails the old blob
-- remains intact.
function lock.change(old_pass, new_pass, opts)
    opts = opts or {}
    if type(new_pass) ~= "string" or new_pass == "" then
        return false, "new passphrase required"
    end
    local priv, pub = lock.unwrap(old_pass)
    if not priv then return false, pub end

    local iters = tonumber(opts.iterations) or DEFAULT_ITERS
    local salt  = ez.crypto.random_bytes(SALT_LEN)
    local nonce = ez.crypto.random_bytes(NONCE_LEN)
    local kek   = ez.crypto.pbkdf2_sha256(new_pass, salt, iters, KEK_LEN)
    if not kek then return false, "kdf failure" end
    local ct = ez.crypto.aes_gcm_encrypt(kek, nonce, priv, pub)
    if not ct then return false, "encrypt failure" end

    -- Stash the current wrapped blob so we can roll back if the
    -- post-write NVS self-test fails.
    local old_blob = ez.identity.read_wrapped_blob()
    if not old_blob then return false, "old blob missing" end

    local blob = encode_blob(iters, salt, nonce, ct)
    if not ez.identity.write_wrapped_blob(blob) then
        return false, "nvs write failed"
    end

    -- Self-test through NVS + decode_blob, matching lock.unwrap. A
    -- buggy encoder or a corrupt NVS write would otherwise pass an
    -- in-memory check and only surface as a permanent lockout at the
    -- next boot.
    local ok_test, reason = selftest_via_nvs(new_pass, priv, pub)
    if not ok_test then
        -- Restore the previous blob so the user's existing passphrase
        -- still works. If restore itself fails the user is stuck on
        -- the new (broken) blob; surface that in the error.
        if not ez.identity.write_wrapped_blob(old_blob) then
            return false, "self-test failed: " .. reason ..
                          "; rollback also failed"
        end
        return false, "self-test failed: " .. reason
    end
    return true
end

return lock
