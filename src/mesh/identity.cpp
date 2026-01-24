#include "identity.h"
#include <Preferences.h>
#include <cstring>
#include <Arduino.h>

// mbedTLS includes for Ed25519 and SHA256
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/sha256.h"
#include "esp_random.h"

// Ed25519 implementation using libsodium-style tweetnacl approach
// Since ESP-IDF mbedTLS doesn't include Ed25519 by default, we use a compact implementation

// Forward declarations for Ed25519 operations (implemented at end of file)
static void ed25519_create_keypair(uint8_t* publicKey, uint8_t* privateKey, const uint8_t* seed);
static void ed25519_sign(uint8_t* signature, const uint8_t* message, size_t messageLen,
                         const uint8_t* publicKey, const uint8_t* privateKey);
static bool ed25519_verify(const uint8_t* signature, const uint8_t* message, size_t messageLen,
                           const uint8_t* publicKey);

// NVS namespace and keys
static const char* NVS_NAMESPACE = "meshcore";
static const char* KEY_PRIVATE_KEY = "privkey";
static const char* KEY_PUBLIC_KEY = "pubkey";
static const char* KEY_NODE_NAME = "nodename";

Identity::Identity() {
    memset(_nodeName, 0, sizeof(_nodeName));
    memset(_privateKey, 0, sizeof(_privateKey));
    memset(_publicKey, 0, sizeof(_publicKey));
}

bool Identity::init() {
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
    return true;
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
    // Generate 32 bytes of random seed using ESP32 hardware RNG
    uint8_t seed[32];
    esp_fill_random(seed, sizeof(seed));

    // Generate Ed25519 keypair from seed
    ed25519_create_keypair(_publicKey, _privateKey, seed);

    // Clear seed from memory
    memset(seed, 0, sizeof(seed));

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

    ed25519_sign(signature, message, messageLen, _publicKey, _privateKey);
    return true;
}

bool Identity::verify(const uint8_t* message, size_t messageLen,
                      const uint8_t* signature, const uint8_t* publicKey) {
    return ed25519_verify(signature, message, messageLen, publicKey);
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

// =============================================================================
// Ed25519 Implementation
// Based on TweetNaCl with modifications for ESP32
// =============================================================================

// Field element (represented as 16 limbs of 16 bits each)
typedef int64_t gf[16];

static const uint8_t D[32] = {
    0xa3, 0x78, 0x59, 0x13, 0xca, 0x4d, 0xeb, 0x75,
    0xab, 0xd8, 0x41, 0x41, 0x4d, 0x0a, 0x70, 0x00,
    0x98, 0xe8, 0x79, 0x77, 0x79, 0x40, 0xc7, 0x8c,
    0x73, 0xfe, 0x6f, 0x2b, 0xee, 0x6c, 0x03, 0x52
};

static const uint8_t D2[32] = {
    0x59, 0xf1, 0xb2, 0x26, 0x94, 0x9b, 0xd6, 0xeb,
    0x56, 0xb1, 0x83, 0x82, 0x9a, 0x14, 0xe0, 0x00,
    0x30, 0xd1, 0xf3, 0xee, 0xf2, 0x80, 0x8e, 0x19,
    0xe7, 0xfc, 0xdf, 0x56, 0xdc, 0xd9, 0x06, 0x24
};

static const uint8_t X[32] = {
    0xd5, 0x18, 0x19, 0x70, 0xae, 0xf1, 0x1a, 0xab,
    0x31, 0xae, 0xb2, 0x32, 0xdc, 0x03, 0xbb, 0x36,
    0xc7, 0x5a, 0x11, 0xcd, 0x90, 0x89, 0xdb, 0x12,
    0x1e, 0x6e, 0x27, 0xf4, 0x3c, 0xc9, 0xbb, 0x21
};

static const uint8_t Y[32] = {
    0x58, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
    0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
    0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
    0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66
};

static const gf gf0 = {0};
static const gf gf1 = {1};

static void set25519(gf r, const gf a) {
    for (int i = 0; i < 16; i++) r[i] = a[i];
}

static void car25519(gf o) {
    for (int i = 0; i < 16; i++) {
        o[(i+1) % 16] += (i < 15 ? 1 : 38) * (o[i] >> 16);
        o[i] &= 0xffff;
    }
}

static void sel25519(gf p, gf q, int b) {
    int64_t t, c = ~(b - 1);
    for (int i = 0; i < 16; i++) {
        t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}

static void pack25519(uint8_t* o, const gf n) {
    gf m, t;
    set25519(t, n);
    car25519(t);
    car25519(t);
    car25519(t);
    for (int j = 0; j < 2; j++) {
        m[0] = t[0] - 0xffed;
        for (int i = 1; i < 15; i++) {
            m[i] = t[i] - 0xffff - ((m[i-1] >> 16) & 1);
            m[i-1] &= 0xffff;
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        int b = (m[15] >> 16) & 1;
        m[14] &= 0xffff;
        sel25519(t, m, 1 - b);
    }
    for (int i = 0; i < 16; i++) {
        o[2*i] = t[i] & 0xff;
        o[2*i+1] = t[i] >> 8;
    }
}

static void unpack25519(gf o, const uint8_t* n) {
    for (int i = 0; i < 16; i++) o[i] = n[2*i] + ((int64_t)n[2*i+1] << 8);
    o[15] &= 0x7fff;
}

static void A(gf o, const gf a, const gf b) {
    for (int i = 0; i < 16; i++) o[i] = a[i] + b[i];
}

static void Z(gf o, const gf a, const gf b) {
    for (int i = 0; i < 16; i++) o[i] = a[i] - b[i];
}

static void M(gf o, const gf a, const gf b) {
    int64_t t[31];
    for (int i = 0; i < 31; i++) t[i] = 0;
    for (int i = 0; i < 16; i++) {
        for (int j = 0; j < 16; j++) {
            t[i+j] += a[i] * b[j];
        }
    }
    for (int i = 0; i < 15; i++) t[i] += 38 * t[i+16];
    for (int i = 0; i < 16; i++) o[i] = t[i];
    car25519(o);
    car25519(o);
}

static void S(gf o, const gf a) {
    M(o, a, a);
}

static void inv25519(gf o, const gf i) {
    gf c;
    set25519(c, i);
    for (int a = 253; a >= 0; a--) {
        S(c, c);
        if (a != 2 && a != 4) M(c, c, i);
    }
    set25519(o, c);
}

static void pow2523(gf o, const gf i) {
    gf c;
    set25519(c, i);
    for (int a = 250; a >= 0; a--) {
        S(c, c);
        if (a != 1) M(c, c, i);
    }
    set25519(o, c);
}

static void add(gf p[4], gf q[4]) {
    gf a, b, c, d, t, e, f, g, h;

    Z(a, p[1], p[0]);
    Z(t, q[1], q[0]);
    M(a, a, t);
    A(b, p[0], p[1]);
    A(t, q[0], q[1]);
    M(b, b, t);
    M(c, p[3], q[3]);
    gf d2;
    unpack25519(d2, D2);
    M(c, c, d2);
    M(d, p[2], q[2]);
    A(d, d, d);
    Z(e, b, a);
    Z(f, d, c);
    A(g, d, c);
    A(h, b, a);

    M(p[0], e, f);
    M(p[1], h, g);
    M(p[2], g, f);
    M(p[3], e, h);
}

static void cswap(gf p[4], gf q[4], uint8_t b) {
    for (int i = 0; i < 4; i++) sel25519(p[i], q[i], b);
}

static void pack(uint8_t* r, gf p[4]) {
    gf tx, ty, zi;
    inv25519(zi, p[2]);
    M(tx, p[0], zi);
    M(ty, p[1], zi);
    pack25519(r, ty);
    r[31] ^= (tx[0] & 1) << 7;
}

static void scalarmult(gf p[4], gf q[4], const uint8_t* s) {
    set25519(p[0], gf0);
    set25519(p[1], gf1);
    set25519(p[2], gf1);
    set25519(p[3], gf0);
    for (int i = 255; i >= 0; --i) {
        uint8_t b = (s[i/8] >> (i & 7)) & 1;
        cswap(p, q, b);
        add(q, p);
        add(p, p);
        cswap(p, q, b);
    }
}

static void scalarbase(gf p[4], const uint8_t* s) {
    gf q[4];
    unpack25519(q[0], X);
    unpack25519(q[1], Y);
    set25519(q[2], gf1);
    M(q[3], q[0], q[1]);
    scalarmult(p, q, s);
}

static const uint64_t L[32] = {
    0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
    0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0x10
};

static void modL(uint8_t* r, int64_t x[64]) {
    for (int i = 63; i >= 32; --i) {
        int64_t carry = 0;
        for (int j = i - 32; j < i - 12; ++j) {
            x[j] += carry - 16 * x[i] * L[j - (i - 32)];
            carry = (x[j] + 128) >> 8;
            x[j] -= carry << 8;
        }
        x[i - 12] += carry;
        x[i] = 0;
    }
    int64_t carry = 0;
    for (int j = 0; j < 32; ++j) {
        x[j] += carry - (x[31] >> 4) * L[j];
        carry = x[j] >> 8;
        x[j] &= 255;
    }
    for (int j = 0; j < 32; ++j) x[j] -= carry * L[j];
    for (int i = 0; i < 32; ++i) {
        x[i + 1] += x[i] >> 8;
        r[i] = x[i] & 255;
    }
}

static void reduce(uint8_t* r) {
    int64_t x[64];
    for (int i = 0; i < 64; ++i) x[i] = (uint64_t)r[i];
    for (int i = 0; i < 64; ++i) r[i] = 0;
    modL(r, x);
}

static int unpackneg(gf r[4], const uint8_t p[32]) {
    gf t, chk, num, den, den2, den4, den6;
    set25519(r[2], gf1);
    unpack25519(r[1], p);
    S(num, r[1]);
    gf d;
    unpack25519(d, D);
    M(den, num, d);
    Z(num, num, r[2]);
    A(den, r[2], den);

    S(den2, den);
    S(den4, den2);
    M(den6, den4, den2);
    M(t, den6, num);
    M(t, t, den);

    pow2523(t, t);
    M(t, t, num);
    M(t, t, den);
    M(t, t, den);
    M(r[0], t, den);

    S(chk, r[0]);
    M(chk, chk, den);
    if (!memcmp(chk, num, sizeof(gf))) {
        gf I;
        I[0] = 0xa0b0; I[1] = 0x4a0e; I[2] = 0x1b27; I[3] = 0xc4ee;
        I[4] = 0xe478; I[5] = 0xad2f; I[6] = 0x1806; I[7] = 0x2f43;
        I[8] = 0xd7a7; I[9] = 0x3dfb; I[10] = 0x0099; I[11] = 0x2b4d;
        I[12] = 0xdf0b; I[13] = 0x4fc1; I[14] = 0x2480; I[15] = 0x2b83;
        M(r[0], r[0], I);
    }

    S(chk, r[0]);
    M(chk, chk, den);
    if (memcmp(chk, num, sizeof(gf))) return -1;

    if ((r[0][0] & 1) == (p[31] >> 7)) Z(r[0], gf0, r[0]);

    M(r[3], r[0], r[1]);
    return 0;
}

static void ed25519_create_keypair(uint8_t* publicKey, uint8_t* privateKey, const uint8_t* seed) {
    uint8_t h[64];
    gf p[4];

    // Copy seed to private key
    memcpy(privateKey, seed, 32);

    // Hash private key to get scalar
    mbedtls_sha512(privateKey, 32, h, 0);
    h[0] &= 248;
    h[31] &= 127;
    h[31] |= 64;

    // Compute public key
    scalarbase(p, h);
    pack(publicKey, p);
}

static void ed25519_sign(uint8_t* signature, const uint8_t* message, size_t messageLen,
                         const uint8_t* publicKey, const uint8_t* privateKey) {
    uint8_t h[64], r[64];
    int64_t x[64];
    gf p[4];

    // Hash private key
    mbedtls_sha512(privateKey, 32, h, 0);
    h[0] &= 248;
    h[31] &= 127;
    h[31] |= 64;

    // Compute r = H(h[32..64] || message)
    mbedtls_sha512_context ctx;
    mbedtls_sha512_init(&ctx);
    mbedtls_sha512_starts(&ctx, 0);
    mbedtls_sha512_update(&ctx, h + 32, 32);
    mbedtls_sha512_update(&ctx, message, messageLen);
    mbedtls_sha512_finish(&ctx, r);
    mbedtls_sha512_free(&ctx);

    reduce(r);
    scalarbase(p, r);
    pack(signature, p);

    // Compute S = (r + H(R || A || M) * s) mod L
    mbedtls_sha512_init(&ctx);
    mbedtls_sha512_starts(&ctx, 0);
    mbedtls_sha512_update(&ctx, signature, 32);
    mbedtls_sha512_update(&ctx, publicKey, 32);
    mbedtls_sha512_update(&ctx, message, messageLen);
    mbedtls_sha512_finish(&ctx, h);
    mbedtls_sha512_free(&ctx);

    reduce(h);

    for (int i = 0; i < 64; i++) x[i] = 0;
    for (int i = 0; i < 32; i++) x[i] = (uint64_t)r[i];
    for (int i = 0; i < 32; i++) {
        for (int j = 0; j < 32; j++) {
            x[i + j] += h[i] * (uint64_t)privateKey[j];
        }
    }
    // Re-hash private key for scalar
    uint8_t hh[64];
    mbedtls_sha512(privateKey, 32, hh, 0);
    hh[0] &= 248;
    hh[31] &= 127;
    hh[31] |= 64;
    for (int i = 0; i < 64; i++) x[i] = 0;
    for (int i = 0; i < 32; i++) x[i] = (uint64_t)r[i];
    for (int i = 0; i < 32; i++) {
        for (int j = 0; j < 32; j++) {
            x[i + j] += h[i] * (uint64_t)hh[j];
        }
    }
    modL(signature + 32, x);
}

static bool ed25519_verify(const uint8_t* signature, const uint8_t* message, size_t messageLen,
                           const uint8_t* publicKey) {
    uint8_t h[64];
    uint8_t rcheck[32];
    gf p[4], q[4];

    if (signature[63] & 224) return false;
    if (unpackneg(q, publicKey)) return false;

    // h = H(R || A || M)
    mbedtls_sha512_context ctx;
    mbedtls_sha512_init(&ctx);
    mbedtls_sha512_starts(&ctx, 0);
    mbedtls_sha512_update(&ctx, signature, 32);
    mbedtls_sha512_update(&ctx, publicKey, 32);
    mbedtls_sha512_update(&ctx, message, messageLen);
    mbedtls_sha512_finish(&ctx, h);
    mbedtls_sha512_free(&ctx);

    reduce(h);
    scalarmult(p, q, h);
    scalarbase(q, signature + 32);
    add(p, q);
    pack(rcheck, p);

    return memcmp(rcheck, signature, 32) == 0;
}
