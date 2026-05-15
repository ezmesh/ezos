// ez.identity: thin Lua surface over the C++ Identity instance held by
// the global mesh object. The vast majority of the API (sign, verify,
// pubkey accessors, set_node_name) flows through ez.mesh.*; this module
// only exposes the lock / wrap / unwrap operations for issue #118.
//
// Trust model reminder: anything Lua can call, the terminal can call.
// The wrap trapdoor (`get_privkey_for_wrap` refuses once the wrapped
// blob exists) is the load-bearing guarantee that prevents a wrapped
// device from leaking its plaintext private key back to Lua.

#include "../lua_bindings.h"
#include "../../mesh/identity.h"
#include "../../mesh/meshcore.h"
#include <Arduino.h>
#include <Preferences.h>
#include <cstring>

extern MeshCore* mesh;  // defined in main.cpp

static Identity* getIdentity() {
    if (!mesh) return nullptr;
    return const_cast<Identity*>(&mesh->getIdentity());
}

// @module ez.identity
// @brief Identity-key lock state and wrap/unwrap helpers (issue #118)
// @description
// The user's Ed25519 keypair lives in NVS as the `privkey` / `pubkey`
// pair. Settings -> Security can wrap the private key behind a
// passphrase: PBKDF2-SHA256 derives a 32-byte KEK from the passphrase
// and a per-device random salt; AES-256-GCM wraps the 64-byte private
// key under that KEK. The wrapped blob lives at NVS key `id_wrap`;
// the plaintext `privkey` is deleted after a successful wrap.
//
// On wrapped boot the C++ Identity sits in `is_locked() == true`
// state -- public key + node name are loaded so the UI can show
// "Unlock <fingerprint>", but signing / mesh init refuse until Lua
// calls `unlock()` with the unwrapped bytes.
// @end

// @lua ez.identity.is_locked() -> boolean
// @brief True when the identity is encrypted-at-rest and not yet unlocked
LUA_FUNCTION(l_identity_is_locked) {
    Identity* id = getIdentity();
    lua_pushboolean(L, id && id->isLocked() ? 1 : 0);
    return 1;
}

// @lua ez.identity.is_wrapped() -> boolean
// @brief True when a wrapped-private-key NVS blob exists (whether or
// not the identity is currently unlocked in RAM)
LUA_FUNCTION(l_identity_is_wrapped) {
    lua_pushboolean(L, Identity::hasWrappedBlob() ? 1 : 0);
    return 1;
}

// @lua ez.identity.unlock(privkey, pubkey [, node_name]) -> boolean
// @brief Feed the unwrapped keypair into a locked identity.
// @description Caller is responsible for verifying the AES-GCM auth
// tag at decrypt time -- this function trusts whatever bytes you give
// it. Returns false if the device is not locked.
// @param privkey 64-byte Ed25519 private key (binary)
// @param pubkey 32-byte Ed25519 public key (binary)
// @param node_name Optional name to apply on top of the persisted one
LUA_FUNCTION(l_identity_unlock) {
    Identity* id = getIdentity();
    if (!id) {
        lua_pushboolean(L, 0);
        return 1;
    }
    size_t privLen, pubLen, nameLen = 0;
    const char* priv = luaL_checklstring(L, 1, &privLen);
    const char* pub  = luaL_checklstring(L, 2, &pubLen);
    const char* name = nullptr;
    if (lua_gettop(L) >= 3 && !lua_isnil(L, 3)) {
        name = luaL_checklstring(L, 3, &nameLen);
    }
    if (privLen != ED25519_PRIVATE_KEY_SIZE ||
        pubLen  != ED25519_PUBLIC_KEY_SIZE) {
        lua_pushboolean(L, 0);
        return 1;
    }
    bool ok = id->unlock(reinterpret_cast<const uint8_t*>(priv),
                         reinterpret_cast<const uint8_t*>(pub),
                         name);
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

// @lua ez.identity.get_privkey_for_wrap() -> string | nil
// @brief Read the plaintext private key for the wrap ceremony.
// @description One-way trapdoor: succeeds only when the device is
// currently unwrapped AND no `id_wrap` blob already exists. After a
// successful wrap (caller writes the wrapped blob and deletes the
// plain copy via `delete_plain_privkey()`), this binding returns nil
// forever -- the only way to get back to plaintext is to unwrap on
// boot and call `delete_wrapped_blob()` first.
LUA_FUNCTION(l_identity_get_privkey_for_wrap) {
    Identity* id = getIdentity();
    if (!id) {
        lua_pushnil(L);
        return 1;
    }
    uint8_t priv[ED25519_PRIVATE_KEY_SIZE];
    if (!id->getPrivateKeyForWrap(priv)) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushlstring(L, reinterpret_cast<char*>(priv), ED25519_PRIVATE_KEY_SIZE);
    memset(priv, 0, ED25519_PRIVATE_KEY_SIZE);
    return 1;
}

// @lua ez.identity.write_wrapped_blob(blob) -> boolean
// @brief Persist a wrapped private-key blob to NVS at `id_wrap`.
// @description Format is owned by the Lua caller; this just stores
// bytes. Refuses empty input. The intent is that the caller writes
// the blob FIRST, then calls `delete_plain_privkey()` so a power loss
// between the two leaves the device in the "both present" recovery
// state (Identity::init clears the partial wrapped blob on boot).
LUA_FUNCTION(l_identity_write_wrapped_blob) {
    size_t len;
    const char* blob = luaL_checklstring(L, 1, &len);
    bool ok = Identity::writeWrappedBlob(reinterpret_cast<const uint8_t*>(blob), len);
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

// @lua ez.identity.read_wrapped_blob() -> string | nil
// @brief Read the wrapped blob from NVS; nil if not present.
LUA_FUNCTION(l_identity_read_wrapped_blob) {
    uint8_t buf[256];   // generous upper bound for wrap format
    size_t len = 0;
    if (!Identity::readWrappedBlob(buf, &len, sizeof(buf))) {
        lua_pushnil(L);
        return 1;
    }
    lua_pushlstring(L, reinterpret_cast<char*>(buf), len);
    return 1;
}

// @lua ez.identity.delete_wrapped_blob() -> boolean
// @brief Remove the wrapped blob from NVS. Used by the "Remove
// passphrase" flow after writing the plaintext key back.
LUA_FUNCTION(l_identity_delete_wrapped_blob) {
    lua_pushboolean(L, Identity::deleteWrappedBlob() ? 1 : 0);
    return 1;
}

// @lua ez.identity.delete_plain_privkey() -> boolean
// @brief Remove the plaintext private-key NVS entry. Used as the
// second step of the wrap ceremony.
LUA_FUNCTION(l_identity_delete_plain_privkey) {
    lua_pushboolean(L, Identity::deletePlainPrivateKey() ? 1 : 0);
    return 1;
}

// @lua ez.identity.write_plain_privkey(privkey) -> boolean
// @brief Restore the plaintext private key to NVS. Used by the
// "Remove passphrase" flow after a successful unwrap.
// @description This function is gated on the device currently being
// in the unlocked state to limit what the terminal can do without
// the user's passphrase.
LUA_FUNCTION(l_identity_write_plain_privkey) {
    Identity* id = getIdentity();
    if (!id || id->isLocked()) {
        lua_pushboolean(L, 0);
        return 1;
    }
    size_t len;
    const char* priv = luaL_checklstring(L, 1, &len);
    if (len != ED25519_PRIVATE_KEY_SIZE) {
        lua_pushboolean(L, 0);
        return 1;
    }
    Preferences prefs;
    if (!prefs.begin("meshcore", false)) {
        lua_pushboolean(L, 0);
        return 1;
    }
    size_t written = prefs.putBytes("privkey",
                                    reinterpret_cast<const uint8_t*>(priv), len);
    prefs.end();
    lua_pushboolean(L, written == len ? 1 : 0);
    return 1;
}

static const luaL_Reg identity_funcs[] = {
    {"is_locked",            l_identity_is_locked},
    {"is_wrapped",           l_identity_is_wrapped},
    {"unlock",               l_identity_unlock},
    {"get_privkey_for_wrap", l_identity_get_privkey_for_wrap},
    {"write_wrapped_blob",   l_identity_write_wrapped_blob},
    {"read_wrapped_blob",    l_identity_read_wrapped_blob},
    {"delete_wrapped_blob",  l_identity_delete_wrapped_blob},
    {"delete_plain_privkey", l_identity_delete_plain_privkey},
    {"write_plain_privkey",  l_identity_write_plain_privkey},
    {nullptr, nullptr},
};

void registerIdentityModule(lua_State* L) {
    lua_register_module(L, "identity", identity_funcs);
    Serial.println("[LuaRuntime] Registered ez.identity");
}
