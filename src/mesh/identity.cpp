#include "identity.h"
#include <Preferences.h>
#include <cstring>
#include <Arduino.h>
#include <Ed25519.h>
#include <Curve25519.h>
#include <SHA512.h>
#include <RNG.h>
#include "mbedtls/bignum.h"

// NVS namespace and keys
static const char* NVS_NAMESPACE = "meshcore";
static const char* KEY_PRIVATE_KEY = "privkey";
static const char* KEY_PUBLIC_KEY = "pubkey";
static const char* KEY_NODE_NAME = "nodename";
// Encrypted-at-rest wrapped private key blob (issue #118). Format is
// owned by `services/identity_lock` on the Lua side; this layer just
// stores and retrieves bytes. 15-char key max in NVS, "id_wrap" fits.
static const char* KEY_WRAPPED_KEY = "id_wrap";

Identity::Identity() {
    memset(_nodeName, 0, sizeof(_nodeName));
    memset(_privateKey, 0, sizeof(_privateKey));
    memset(_publicKey, 0, sizeof(_publicKey));
}

bool Identity::init() {
    // Inconsistent-state recovery: if BOTH the plaintext private key
    // and the wrapped blob exist, a previous wrap operation was
    // interrupted between writing the wrapped copy and deleting the
    // plaintext. Roll back to "unwrapped": delete the partial wrapped
    // blob so the device boots normally and the user can re-attempt
    // the wrap. This is safer than letting the user be locked behind
    // a passphrase whose KDF parameters they may not have committed.
    bool plain_present = false;
    {
        Preferences prefs;
        if (prefs.begin(NVS_NAMESPACE, true)) {
            plain_present = prefs.isKey(KEY_PRIVATE_KEY);
            prefs.end();
        }
    }
    bool wrapped_present = hasWrappedBlob();
    if (plain_present && wrapped_present) {
        Serial.println("[Identity] Inconsistent state (plain + wrapped); clearing wrap");
        deleteWrappedBlob();
        wrapped_present = false;
    }

    if (wrapped_present) {
        // Device is locked: the plaintext private key lives only in
        // the wrapped blob until Lua calls unlock(). Load the public
        // key + node name so the rest of the UI has something to show
        // on the unlock screen, but leave _hasKeypair false so mesh
        // init refuses to run until we have real keys.
        Preferences prefs;
        if (prefs.begin(NVS_NAMESPACE, true)) {
            size_t pubLen = prefs.getBytes(KEY_PUBLIC_KEY, _publicKey,
                                           ED25519_PUBLIC_KEY_SIZE);
            String name = prefs.getString(KEY_NODE_NAME, "");
            if (name.length() > 0) {
                strncpy(_nodeName, name.c_str(), MAX_NODE_NAME);
                _nodeName[MAX_NODE_NAME] = '\0';
            }
            prefs.end();
            if (pubLen != ED25519_PUBLIC_KEY_SIZE) {
                // Wrapped blob present but no public key -- something
                // is very wrong. Refuse to boot mesh; the user can
                // still reach the lockscreen via Lua to attempt
                // unlock or factory-reset.
                Serial.println("[Identity] Wrapped blob but no pubkey; identity locked");
            } else {
                char fingerprint[16];
                getPublicKeyFingerprint(fingerprint);
                Serial.printf("[Identity] Locked (pubkey %s); awaiting unlock\n",
                              fingerprint);
            }
        }
        _locked = true;
        _hasKeypair = false;
        return true;  // not a hard error -- normal locked-boot path
    }

    if (!loadFromNVS()) {
        // No saved identity, generate new keypair
        Serial.println("Generating new Ed25519 keypair...");
        if (!generateKeypair()) {
            Serial.println("Failed to generate keypair");
            return false;
        }

        // Set default name based on short ID
        char shortId[8];
        getShortId(shortId);
        snprintf(_nodeName, sizeof(_nodeName), "Node-%s", shortId);

        // Save the new identity
        if (!saveToNVS()) {
            Serial.println("Failed to save identity to NVS");
            return false;
        }

        Serial.println("Generated new keypair");
    } else {
        Serial.println("Loaded keypair from NVS");
    }

    // Print public key fingerprint for verification
    char fingerprint[16];
    getPublicKeyFingerprint(fingerprint);
    Serial.printf("Public key fingerprint: %s\n", fingerprint);
    Serial.printf("Path hash: %02X\n", getPathHash());

    _hasKeypair = true;
    _locked = false;
    return true;
}

bool Identity::unlock(const uint8_t* privateKey, const uint8_t* publicKey,
                      const char* nodeName) {
    if (!_locked) return false;
    if (!privateKey || !publicKey) return false;

    memcpy(_privateKey, privateKey, ED25519_PRIVATE_KEY_SIZE);
    memcpy(_publicKey,  publicKey,  ED25519_PUBLIC_KEY_SIZE);
    if (nodeName && nodeName[0]) {
        strncpy(_nodeName, nodeName, MAX_NODE_NAME);
        _nodeName[MAX_NODE_NAME] = '\0';
    }
    _hasKeypair = true;
    _locked = false;
    return true;
}

bool Identity::getPrivateKeyForWrap(uint8_t* out) const {
    // One-way trapdoor: only allow Lua to read the plaintext private
    // key when the device is currently unwrapped AND no wrapped blob
    // exists yet. Once a wrapped blob is in place, this binding
    // refuses to return the plaintext -- you have to go through the
    // unlock path and then back through the wrap (which deletes the
    // plain copy) to get there.
    if (!_hasKeypair || _locked) return false;
    if (hasWrappedBlob()) return false;
    if (!out) return false;
    memcpy(out, _privateKey, ED25519_PRIVATE_KEY_SIZE);
    return true;
}

bool Identity::hasWrappedBlob() {
    Preferences prefs;
    if (!prefs.begin(NVS_NAMESPACE, true)) return false;
    bool present = prefs.isKey(KEY_WRAPPED_KEY);
    prefs.end();
    return present;
}

bool Identity::readWrappedBlob(uint8_t* out, size_t* outLen, size_t maxLen) {
    if (!out || !outLen) return false;
    Preferences prefs;
    if (!prefs.begin(NVS_NAMESPACE, true)) return false;
    size_t actualLen = prefs.getBytesLength(KEY_WRAPPED_KEY);
    if (actualLen == 0 || actualLen > maxLen) {
        prefs.end();
        return false;
    }
    size_t got = prefs.getBytes(KEY_WRAPPED_KEY, out, actualLen);
    prefs.end();
    if (got != actualLen) return false;
    *outLen = actualLen;
    return true;
}

bool Identity::writeWrappedBlob(const uint8_t* blob, size_t len) {
    if (!blob || len == 0) return false;
    Preferences prefs;
    if (!prefs.begin(NVS_NAMESPACE, false)) return false;
    size_t written = prefs.putBytes(KEY_WRAPPED_KEY, blob, len);
    prefs.end();
    return written == len;
}

bool Identity::deleteWrappedBlob() {
    Preferences prefs;
    if (!prefs.begin(NVS_NAMESPACE, false)) return false;
    bool ok = true;
    if (prefs.isKey(KEY_WRAPPED_KEY)) {
        ok = prefs.remove(KEY_WRAPPED_KEY);
    }
    prefs.end();
    return ok;
}

bool Identity::deletePlainPrivateKey() {
    Preferences prefs;
    if (!prefs.begin(NVS_NAMESPACE, false)) return false;
    bool ok = true;
    if (prefs.isKey(KEY_PRIVATE_KEY)) {
        ok = prefs.remove(KEY_PRIVATE_KEY);
    }
    prefs.end();
    return ok;
}

bool Identity::loadFromNVS() {
    Preferences prefs;

    if (!prefs.begin(NVS_NAMESPACE, true)) {  // Read-only
        return false;
    }

    // Load private key
    size_t privLen = prefs.getBytes(KEY_PRIVATE_KEY, _privateKey, ED25519_PRIVATE_KEY_SIZE);
    if (privLen != ED25519_PRIVATE_KEY_SIZE) {
        prefs.end();
        return false;
    }

    // Load public key
    size_t pubLen = prefs.getBytes(KEY_PUBLIC_KEY, _publicKey, ED25519_PUBLIC_KEY_SIZE);
    if (pubLen != ED25519_PUBLIC_KEY_SIZE) {
        prefs.end();
        return false;
    }

    // Load node name
    String name = prefs.getString(KEY_NODE_NAME, "");
    if (name.length() > 0) {
        strncpy(_nodeName, name.c_str(), MAX_NODE_NAME);
        _nodeName[MAX_NODE_NAME] = '\0';
    }

    prefs.end();
    return true;
}

bool Identity::saveNodeNameOnly() {
    Preferences prefs;
    if (!prefs.begin(NVS_NAMESPACE, false)) {
        return false;
    }
    size_t written = prefs.putString(KEY_NODE_NAME, _nodeName);
    prefs.end();
    return written > 0;
}

bool Identity::saveToNVS() {
    Preferences prefs;

    if (!prefs.begin(NVS_NAMESPACE, false)) {  // Read-write
        return false;
    }

    // Save private key
    size_t written = prefs.putBytes(KEY_PRIVATE_KEY, _privateKey, ED25519_PRIVATE_KEY_SIZE);
    if (written != ED25519_PRIVATE_KEY_SIZE) {
        prefs.end();
        return false;
    }

    // Save public key
    written = prefs.putBytes(KEY_PUBLIC_KEY, _publicKey, ED25519_PUBLIC_KEY_SIZE);
    if (written != ED25519_PUBLIC_KEY_SIZE) {
        prefs.end();
        return false;
    }

    // Save node name
    prefs.putString(KEY_NODE_NAME, _nodeName);

    prefs.end();
    return true;
}

bool Identity::generateKeypair() {
    // Use rweather/Crypto Ed25519 library
    Ed25519::generatePrivateKey(_privateKey);
    Ed25519::derivePublicKey(_publicKey, _privateKey);
    return true;
}

void Identity::getShortId(char* buffer) const {
    // First 3 bytes of public key as hex (6 chars + null)
    static const char hex[] = "0123456789ABCDEF";
    for (int i = 0; i < 3; i++) {
        buffer[i * 2] = hex[(_publicKey[i] >> 4) & 0x0F];
        buffer[i * 2 + 1] = hex[_publicKey[i] & 0x0F];
    }
    buffer[6] = '\0';
}

void Identity::getFullId(char* buffer) const {
    // First 6 bytes of public key as hex (12 chars + null)
    static const char hex[] = "0123456789ABCDEF";
    for (int i = 0; i < 6; i++) {
        buffer[i * 2] = hex[(_publicKey[i] >> 4) & 0x0F];
        buffer[i * 2 + 1] = hex[_publicKey[i] & 0x0F];
    }
    buffer[12] = '\0';
}

void Identity::getPublicKeyHex(char* buffer) const {
    for (int i = 0; i < ED25519_PUBLIC_KEY_SIZE; i++) {
        sprintf(buffer + i * 2, "%02X", _publicKey[i]);
    }
    buffer[64] = '\0';
}

void Identity::getPublicKeyFingerprint(char* buffer) const {
    // Return first 8 hex characters of public key (4 bytes)
    for (int i = 0; i < 4; i++) {
        sprintf(buffer + i * 2, "%02X", _publicKey[i]);
    }
    buffer[8] = '\0';
}

bool Identity::sign(const uint8_t* message, size_t messageLen, uint8_t* signature) const {
    if (!_hasKeypair) {
        return false;
    }

    // Use rweather/Crypto Ed25519 library
    Ed25519::sign(signature, _privateKey, _publicKey, message, messageLen);
    return true;
}

bool Identity::verify(const uint8_t* message, size_t messageLen,
                      const uint8_t* signature, const uint8_t* publicKey) {
    // Use rweather/Crypto Ed25519 library
    return Ed25519::verify(signature, publicKey, message, messageLen);
}

bool Identity::setNodeName(const char* name) {
    if (!name || strlen(name) == 0) {
        return false;
    }

    strncpy(_nodeName, name, MAX_NODE_NAME);
    _nodeName[MAX_NODE_NAME] = '\0';

    return saveToNVS();
}

bool Identity::reset() {
    // Generate new keypair
    if (!generateKeypair()) {
        return false;
    }

    // Clear name and set default
    char shortId[8];
    getShortId(shortId);
    snprintf(_nodeName, sizeof(_nodeName), "Node-%s", shortId);

    _hasKeypair = true;
    return saveToNVS();
}

// Convert Ed25519 public key to X25519 public key
// Formula: u = (1 + y) / (1 - y) mod p
// where p = 2^255 - 19 and y is the Ed25519 public key (little-endian)
bool Identity::ed25519PubKeyToX25519(const uint8_t* ed25519PubKey, uint8_t* x25519PubKey) {
    // The Ed25519 public key is the y-coordinate (little-endian) with sign bit in MSB
    // We compute: u = (1 + y) / (1 - y) mod p
    // Division is done via modular inverse: u = (1 + y) * (1 - y)^(-1) mod p

    mbedtls_mpi p, y, one, one_plus_y, one_minus_y, u;

    mbedtls_mpi_init(&p);
    mbedtls_mpi_init(&y);
    mbedtls_mpi_init(&one);
    mbedtls_mpi_init(&one_plus_y);
    mbedtls_mpi_init(&one_minus_y);
    mbedtls_mpi_init(&u);

    bool success = false;

    // Set p = 2^255 - 19
    if (mbedtls_mpi_lset(&p, 1) != 0) goto cleanup;
    if (mbedtls_mpi_shift_l(&p, 255) != 0) goto cleanup;
    if (mbedtls_mpi_sub_int(&p, &p, 19) != 0) goto cleanup;

    // Set one = 1
    if (mbedtls_mpi_lset(&one, 1) != 0) goto cleanup;

    // Read y from Ed25519 public key (little-endian), clear sign bit
    // mbedtls uses big-endian, so we need to reverse
    {
        uint8_t y_bytes[32];
        for (int i = 0; i < 32; i++) {
            y_bytes[31 - i] = ed25519PubKey[i];
        }
        y_bytes[0] &= 0x7F;  // Clear sign bit (now in MSB position after reversal)

        if (mbedtls_mpi_read_binary(&y, y_bytes, 32) != 0) goto cleanup;
    }

    // Compute (1 + y) mod p
    if (mbedtls_mpi_add_mpi(&one_plus_y, &one, &y) != 0) goto cleanup;
    if (mbedtls_mpi_mod_mpi(&one_plus_y, &one_plus_y, &p) != 0) goto cleanup;

    // Compute (1 - y) mod p
    if (mbedtls_mpi_sub_mpi(&one_minus_y, &one, &y) != 0) goto cleanup;
    if (mbedtls_mpi_mod_mpi(&one_minus_y, &one_minus_y, &p) != 0) goto cleanup;

    // Compute u = (1 + y) * (1 - y)^(-1) mod p
    // Using modular inverse
    if (mbedtls_mpi_inv_mod(&one_minus_y, &one_minus_y, &p) != 0) goto cleanup;
    if (mbedtls_mpi_mul_mpi(&u, &one_plus_y, &one_minus_y) != 0) goto cleanup;
    if (mbedtls_mpi_mod_mpi(&u, &u, &p) != 0) goto cleanup;

    // Write result as little-endian (reverse from mbedtls big-endian)
    {
        uint8_t u_bytes[32];
        memset(u_bytes, 0, 32);

        if (mbedtls_mpi_write_binary(&u, u_bytes, 32) != 0) goto cleanup;

        // Reverse to little-endian
        for (int i = 0; i < 32; i++) {
            x25519PubKey[i] = u_bytes[31 - i];
        }
    }

    success = true;

cleanup:
    mbedtls_mpi_free(&p);
    mbedtls_mpi_free(&y);
    mbedtls_mpi_free(&one);
    mbedtls_mpi_free(&one_plus_y);
    mbedtls_mpi_free(&one_minus_y);
    mbedtls_mpi_free(&u);

    return success;
}

bool Identity::calcSharedSecret(const uint8_t* otherEd25519PubKey, uint8_t* sharedSecret) const {
    if (!_hasKeypair) {
        return false;
    }

    // Derive X25519 private key from Ed25519 private key seed
    // The Ed25519 private key is [32-byte seed][32-byte derived public]
    // We hash the seed with SHA512 and use first 32 bytes, clamped
    SHA512 sha512;
    uint8_t hash[64];

    sha512.reset();
    sha512.update(_privateKey, 32);  // Hash only the seed (first 32 bytes)
    sha512.finalize(hash, 64);

    // Clamp the private scalar for X25519
    uint8_t x25519Private[32];
    memcpy(x25519Private, hash, 32);
    x25519Private[0] &= 0xF8;   // Clear bottom 3 bits
    x25519Private[31] &= 0x7F;  // Clear top bit
    x25519Private[31] |= 0x40;  // Set second-to-top bit

    // Convert other party's Ed25519 public key to X25519
    uint8_t x25519OtherPub[32];
    if (!ed25519PubKeyToX25519(otherEd25519PubKey, x25519OtherPub)) {
        return false;
    }

    // Perform X25519 ECDH: shared = x25519Private * x25519OtherPub
    // Using Curve25519::eval(result, scalar, point)
    bool success = Curve25519::eval(sharedSecret, x25519Private, x25519OtherPub);

    // Clear sensitive data
    memset(x25519Private, 0, 32);
    memset(hash, 0, 64);

    return success;
}
