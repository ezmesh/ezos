#pragma once

#include <cstdint>
#include <cstddef>

// Maximum node name length
constexpr size_t MAX_NODE_NAME = 16;

// Ed25519 key sizes
// Note: rweather/Crypto uses 64-byte private keys (32-byte seed + 32-byte derived)
constexpr size_t ED25519_PRIVATE_KEY_SIZE = 64;
constexpr size_t ED25519_PUBLIC_KEY_SIZE = 32;
constexpr size_t ED25519_SIGNATURE_SIZE = 64;

// Node identity management
// Handles Ed25519 keypair generation, storage, and signing/verification
class Identity {
public:
    Identity();
    ~Identity() = default;

    // Initialize identity (loads from NVS or generates new keypair)
    bool init();

    // Get path hash (first byte of public key, used for routing)
    uint8_t getPathHash() const { return _publicKey[0]; }

    // Get our node name
    const char* getNodeName() const { return _nodeName; }

    // Set node name (persisted to NVS)
    bool setNodeName(const char* name);

    // Get short ID string (first 3 bytes of pubkey as hex, 7 chars including null)
    void getShortId(char* buffer) const;

    // Get full ID string (first 6 bytes of pubkey as hex, 13 chars including null)
    void getFullId(char* buffer) const;

    // Get public key (32 bytes)
    const uint8_t* getPublicKey() const { return _publicKey; }

    // Get public key as hex string (requires 65 byte buffer: 64 hex chars + null)
    void getPublicKeyHex(char* buffer) const;

    // Get public key fingerprint (first 8 hex chars of public key)
    void getPublicKeyFingerprint(char* buffer) const;

    // Sign a message using Ed25519
    // Returns true on success, signature is 64 bytes
    bool sign(const uint8_t* message, size_t messageLen, uint8_t* signature) const;

    // Verify a signature using a public key
    // Returns true if signature is valid
    static bool verify(const uint8_t* message, size_t messageLen,
                       const uint8_t* signature, const uint8_t* publicKey);

    // Reset identity (generates new keypair, clears name)
    bool reset();

    // Calculate shared secret with another node using ECDH (X25519)
    // Converts Ed25519 keys to X25519 internally
    // sharedSecret must be 32 bytes
    bool calcSharedSecret(const uint8_t* otherEd25519PubKey, uint8_t* sharedSecret) const;

    // Static helper: Convert Ed25519 public key to X25519 public key
    // Both arrays must be 32 bytes
    static bool ed25519PubKeyToX25519(const uint8_t* ed25519PubKey, uint8_t* x25519PubKey);

private:
    char _nodeName[MAX_NODE_NAME + 1];
    uint8_t _privateKey[ED25519_PRIVATE_KEY_SIZE];
    uint8_t _publicKey[ED25519_PUBLIC_KEY_SIZE];
    bool _hasKeypair = false;

    bool loadFromNVS();
    bool saveToNVS();
    bool generateKeypair();
};
