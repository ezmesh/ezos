// ez.crypto module bindings
// Provides cryptographic primitives for Lua

#include "../lua_bindings.h"
#include <Arduino.h>
#include <esp_random.h>

// @module ez.crypto
// @brief Cryptographic primitives for hashing, encryption, and encoding
// @description
// Provides SHA-256/512 hashing, HMAC, AES-128-ECB encryption, base64 and
// hex encoding/decoding, and secure random number generation. Used internally
// for MeshCore channel encryption and message authentication. All operations
// use hardware-accelerated mbedTLS where available.
// @end

// mbedTLS includes
#include "mbedtls/aes.h"
#include "mbedtls/md.h"
#include "mbedtls/sha256.h"
#include "mbedtls/sha512.h"
#include "mbedtls/base64.h"

// AES block size
constexpr size_t AES_BLOCK_SIZE = 16;

// @lua ez.crypto.sha256(data) -> string
// @brief Compute SHA-256 hash
// @description Computes a SHA-256 cryptographic hash of the input data. Returns
// a 32-byte binary string. Use bytes_to_hex() to convert to readable hex format.
// SHA-256 is used for message digests, integrity checks, and key derivation.
// @param data Binary string to hash
// @return 32-byte hash as binary string
// @example
// local hash = ez.crypto.sha256("hello world")
// print("SHA256:", ez.crypto.bytes_to_hex(hash))
// -- Output: b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
// @end
LUA_FUNCTION(l_crypto_sha256) {
    LUA_CHECK_ARGC(L, 1);

    size_t dataLen;
    const char* data = luaL_checklstring(L, 1, &dataLen);

    uint8_t hash[32];
    mbedtls_sha256_context ctx;

    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);  // 0 = SHA-256 (not SHA-224)
    mbedtls_sha256_update(&ctx, reinterpret_cast<const uint8_t*>(data), dataLen);
    mbedtls_sha256_finish(&ctx, hash);
    mbedtls_sha256_free(&ctx);

    lua_pushlstring(L, reinterpret_cast<char*>(hash), 32);
    return 1;
}

// @lua ez.crypto.sha512(data) -> string
// @brief Compute SHA-512 hash
// @description Computes a SHA-512 cryptographic hash of the input data. Returns
// a 64-byte binary string. SHA-512 provides stronger security than SHA-256 but
// is slower. Use for high-security applications or when 256-bit hash is insufficient.
// @param data Binary string to hash
// @return 64-byte hash as binary string
// @example
// local hash = ez.crypto.sha512("secret data")
// print("SHA512:", ez.crypto.bytes_to_hex(hash))
// @end
LUA_FUNCTION(l_crypto_sha512) {
    LUA_CHECK_ARGC(L, 1);

    size_t dataLen;
    const char* data = luaL_checklstring(L, 1, &dataLen);

    uint8_t hash[64];
    mbedtls_sha512_context ctx;

    mbedtls_sha512_init(&ctx);
    mbedtls_sha512_starts(&ctx, 0);  // 0 = SHA-512 (not SHA-384)
    mbedtls_sha512_update(&ctx, reinterpret_cast<const uint8_t*>(data), dataLen);
    mbedtls_sha512_finish(&ctx, hash);
    mbedtls_sha512_free(&ctx);

    lua_pushlstring(L, reinterpret_cast<char*>(hash), 64);
    return 1;
}

// @lua ez.crypto.hmac_sha256(key, data) -> string
// @brief Compute HMAC-SHA256
// @description Computes a keyed-hash message authentication code (HMAC) using
// SHA-256. Unlike plain hashing, HMAC requires a secret key, making it suitable
// for message authentication where both parties share a secret. Returns nil and
// error message on failure.
// @param key Binary string key (any length, but 32 bytes recommended)
// @param data Binary string to authenticate
// @return 32-byte MAC as binary string, or nil and error on failure
// @example
// local key = ez.crypto.random_bytes(32)
// local mac = ez.crypto.hmac_sha256(key, "message to authenticate")
// -- Verify by recomputing and comparing
// local verify = ez.crypto.hmac_sha256(key, "message to authenticate")
// if mac == verify then print("Authentic") end
// @end
LUA_FUNCTION(l_crypto_hmac_sha256) {
    LUA_CHECK_ARGC(L, 2);

    size_t keyLen, dataLen;
    const char* key = luaL_checklstring(L, 1, &keyLen);
    const char* data = luaL_checklstring(L, 2, &dataLen);

    uint8_t mac[32];
    mbedtls_md_context_t ctx;
    mbedtls_md_init(&ctx);

    const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (!info) {
        mbedtls_md_free(&ctx);
        lua_pushnil(L);
        lua_pushstring(L, "SHA256 not available");
        return 2;
    }

    int ret = mbedtls_md_setup(&ctx, info, 1);  // 1 = use HMAC
    if (ret != 0) {
        mbedtls_md_free(&ctx);
        lua_pushnil(L);
        lua_pushstring(L, "HMAC setup failed");
        return 2;
    }

    ret = mbedtls_md_hmac_starts(&ctx, reinterpret_cast<const uint8_t*>(key), keyLen);
    if (ret != 0) {
        mbedtls_md_free(&ctx);
        lua_pushnil(L);
        lua_pushstring(L, "HMAC start failed");
        return 2;
    }

    ret = mbedtls_md_hmac_update(&ctx, reinterpret_cast<const uint8_t*>(data), dataLen);
    if (ret != 0) {
        mbedtls_md_free(&ctx);
        lua_pushnil(L);
        lua_pushstring(L, "HMAC update failed");
        return 2;
    }

    ret = mbedtls_md_hmac_finish(&ctx, mac);
    mbedtls_md_free(&ctx);

    if (ret != 0) {
        lua_pushnil(L);
        lua_pushstring(L, "HMAC finish failed");
        return 2;
    }

    lua_pushlstring(L, reinterpret_cast<char*>(mac), 32);
    return 1;
}

// @lua ez.crypto.aes128_ecb_encrypt(key, plaintext) -> string
// @brief Encrypt data with AES-128-ECB
// @description Encrypts data using AES-128 in ECB mode. ECB mode encrypts each
// 16-byte block independently - use for short data or when simplicity is needed.
// Input is zero-padded to 16-byte boundary. For secure encryption of longer data,
// consider using channel encryption which uses proper IV/nonce handling.
// @param key 16-byte key (use derive_channel_key to create from password)
// @param plaintext Data to encrypt (will be zero-padded to block boundary)
// @return Encrypted data as binary string, or nil and error on failure
// @example
// local key = ez.crypto.derive_channel_key("my secret")
// local encrypted = ez.crypto.aes128_ecb_encrypt(key, "hello")
// print("Encrypted:", ez.crypto.bytes_to_hex(encrypted))
// @end
LUA_FUNCTION(l_crypto_aes128_ecb_encrypt) {
    LUA_CHECK_ARGC(L, 2);

    size_t keyLen, plaintextLen;
    const char* key = luaL_checklstring(L, 1, &keyLen);
    const char* plaintext = luaL_checklstring(L, 2, &plaintextLen);

    if (keyLen != 16) {
        lua_pushnil(L);
        lua_pushstring(L, "Key must be 16 bytes");
        return 2;
    }

    // Pad to block boundary
    size_t paddedLen = ((plaintextLen + AES_BLOCK_SIZE - 1) / AES_BLOCK_SIZE) * AES_BLOCK_SIZE;
    if (paddedLen == 0) paddedLen = AES_BLOCK_SIZE;

    // Allocate padded buffer
    uint8_t* padded = new uint8_t[paddedLen];
    uint8_t* output = new uint8_t[paddedLen];
    memset(padded, 0, paddedLen);
    memcpy(padded, plaintext, plaintextLen);

    mbedtls_aes_context ctx;
    mbedtls_aes_init(&ctx);

    int ret = mbedtls_aes_setkey_enc(&ctx, reinterpret_cast<const uint8_t*>(key), 128);
    if (ret != 0) {
        mbedtls_aes_free(&ctx);
        delete[] padded;
        delete[] output;
        lua_pushnil(L);
        lua_pushstring(L, "AES setkey failed");
        return 2;
    }

    // Encrypt block by block
    for (size_t i = 0; i < paddedLen; i += AES_BLOCK_SIZE) {
        ret = mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_ENCRYPT, padded + i, output + i);
        if (ret != 0) {
            mbedtls_aes_free(&ctx);
            delete[] padded;
            delete[] output;
            lua_pushnil(L);
            lua_pushstring(L, "AES encrypt failed");
            return 2;
        }
    }

    mbedtls_aes_free(&ctx);
    delete[] padded;

    lua_pushlstring(L, reinterpret_cast<char*>(output), paddedLen);
    delete[] output;
    return 1;
}

// @lua ez.crypto.aes128_ecb_decrypt(key, ciphertext) -> string
// @brief Decrypt data with AES-128-ECB
// @description Decrypts data encrypted with aes128_ecb_encrypt. The ciphertext must
// be a multiple of 16 bytes. The decrypted output includes zero padding bytes, so
// you may need to trim trailing zeros for text data.
// @param key 16-byte key (must match encryption key)
// @param ciphertext Data to decrypt (must be multiple of 16 bytes)
// @return Decrypted data as binary string (with padding zeros), or nil and error
// @example
// local key = ez.crypto.derive_channel_key("my secret")
// local encrypted = ez.crypto.aes128_ecb_encrypt(key, "hello")
// local decrypted = ez.crypto.aes128_ecb_decrypt(key, encrypted)
// print(decrypted:gsub("%z+$", ""))  -- Trim trailing zeros
// @end
LUA_FUNCTION(l_crypto_aes128_ecb_decrypt) {
    LUA_CHECK_ARGC(L, 2);

    size_t keyLen, ciphertextLen;
    const char* key = luaL_checklstring(L, 1, &keyLen);
    const char* ciphertext = luaL_checklstring(L, 2, &ciphertextLen);

    if (keyLen != 16) {
        lua_pushnil(L);
        lua_pushstring(L, "Key must be 16 bytes");
        return 2;
    }

    if (ciphertextLen == 0 || ciphertextLen % AES_BLOCK_SIZE != 0) {
        lua_pushnil(L);
        lua_pushstring(L, "Ciphertext must be multiple of 16 bytes");
        return 2;
    }

    uint8_t* output = new uint8_t[ciphertextLen];

    mbedtls_aes_context ctx;
    mbedtls_aes_init(&ctx);

    int ret = mbedtls_aes_setkey_dec(&ctx, reinterpret_cast<const uint8_t*>(key), 128);
    if (ret != 0) {
        mbedtls_aes_free(&ctx);
        delete[] output;
        lua_pushnil(L);
        lua_pushstring(L, "AES setkey failed");
        return 2;
    }

    // Decrypt block by block
    for (size_t i = 0; i < ciphertextLen; i += AES_BLOCK_SIZE) {
        ret = mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_DECRYPT,
                                     reinterpret_cast<const uint8_t*>(ciphertext) + i,
                                     output + i);
        if (ret != 0) {
            mbedtls_aes_free(&ctx);
            delete[] output;
            lua_pushnil(L);
            lua_pushstring(L, "AES decrypt failed");
            return 2;
        }
    }

    mbedtls_aes_free(&ctx);

    lua_pushlstring(L, reinterpret_cast<char*>(output), ciphertextLen);
    delete[] output;
    return 1;
}

// @lua ez.crypto.random_bytes(count) -> string
// @brief Generate cryptographically secure random bytes
// @description Generates cryptographically secure random bytes using the ESP32's
// hardware random number generator. Suitable for key generation, nonces, and
// other security-sensitive applications. Maximum 256 bytes per call.
// @param count Number of bytes to generate (1-256)
// @return Random bytes as binary string, or nil and error if count invalid
// @example
// local key = ez.crypto.random_bytes(16)  -- Generate 128-bit key
// local nonce = ez.crypto.random_bytes(12)  -- 96-bit nonce
// print("Key:", ez.crypto.bytes_to_hex(key))
// @end
LUA_FUNCTION(l_crypto_random_bytes) {
    LUA_CHECK_ARGC(L, 1);

    lua_Integer count = luaL_checkinteger(L, 1);
    if (count <= 0 || count > 256) {
        lua_pushnil(L);
        lua_pushstring(L, "Count must be 1-256");
        return 2;
    }

    uint8_t* buffer = new uint8_t[count];
    esp_fill_random(buffer, count);

    lua_pushlstring(L, reinterpret_cast<char*>(buffer), count);
    delete[] buffer;
    return 1;
}

// @lua ez.crypto.channel_hash(key) -> integer
// @brief Compute channel hash from key (SHA256(key)[0])
// @description Computes a single-byte channel identifier from a channel key. This
// is the first byte of SHA256(key) and is used in the MeshCore protocol to quickly
// filter packets by channel. Each channel has a unique hash that identifies it
// without revealing the encryption key.
// @param key 16-byte channel key
// @return Single byte hash as integer (0-255)
// @example
// local key = ez.crypto.public_channel_key()
// local hash = ez.crypto.channel_hash(key)
// print("Public channel hash:", hash)
// @end
LUA_FUNCTION(l_crypto_channel_hash) {
    LUA_CHECK_ARGC(L, 1);

    size_t keyLen;
    const char* key = luaL_checklstring(L, 1, &keyLen);

    uint8_t hash[32];
    mbedtls_sha256_context ctx;

    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    mbedtls_sha256_update(&ctx, reinterpret_cast<const uint8_t*>(key), keyLen);
    mbedtls_sha256_finish(&ctx, hash);
    mbedtls_sha256_free(&ctx);

    lua_pushinteger(L, hash[0]);
    return 1;
}

// @lua ez.crypto.derive_channel_key(input) -> string
// @brief Derive 16-byte channel key from password/name using SHA256
// @description Derives a 16-byte AES-128 key from a password or channel name by
// taking the first 16 bytes of SHA256(input). This allows users to join channels
// using a memorable password instead of raw key bytes. All devices with the same
// password will derive the same key.
// @param input Password or channel name string
// @return 16-byte key as binary string
// @example
// local key = ez.crypto.derive_channel_key("SecretChannel2024")
// print("Key:", ez.crypto.bytes_to_hex(key))
// local hash = ez.crypto.channel_hash(key)
// print("Channel hash:", hash)
// @end
LUA_FUNCTION(l_crypto_derive_channel_key) {
    LUA_CHECK_ARGC(L, 1);

    size_t inputLen;
    const char* input = luaL_checklstring(L, 1, &inputLen);

    uint8_t hash[32];
    mbedtls_sha256_context ctx;

    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    mbedtls_sha256_update(&ctx, reinterpret_cast<const uint8_t*>(input), inputLen);
    mbedtls_sha256_finish(&ctx, hash);
    mbedtls_sha256_free(&ctx);

    // Return first 16 bytes as AES-128 key
    lua_pushlstring(L, reinterpret_cast<char*>(hash), 16);
    return 1;
}

// @lua ez.crypto.public_channel_key() -> string
// @brief Get the well-known #Public channel key
// @description Returns the pre-defined key for the #Public channel. This is the
// default channel that all MeshCore devices join on startup. The key is well-known
// (8b3387e9c5cdea6ac9e5edbaa115cd72) so all devices can communicate without
// configuration. For private communication, use a custom channel with derive_channel_key.
// @return 16-byte key as binary string
// @example
// local public_key = ez.crypto.public_channel_key()
// print("Public key:", ez.crypto.bytes_to_hex(public_key))
// -- Output: 8b3387e9c5cdea6ac9e5edbaa115cd72
// @end
LUA_FUNCTION(l_crypto_public_channel_key) {
    // Well-known #Public channel key: 8b3387e9c5cdea6ac9e5edbaa115cd72
    static const uint8_t PUBLIC_KEY[16] = {
        0x8b, 0x33, 0x87, 0xe9, 0xc5, 0xcd, 0xea, 0x6a,
        0xc9, 0xe5, 0xed, 0xba, 0xa1, 0x15, 0xcd, 0x72
    };

    lua_pushlstring(L, reinterpret_cast<const char*>(PUBLIC_KEY), 16);
    return 1;
}

// @lua ez.crypto.bytes_to_hex(data) -> string
// @brief Convert binary data to hex string
// @description Converts binary data to a lowercase hexadecimal string representation.
// Each byte becomes two hex characters. Useful for displaying keys, hashes, and
// other binary data in a readable format.
// @param data Binary string
// @return Hex string (lowercase)
// @example
// local hash = ez.crypto.sha256("test")
// print(ez.crypto.bytes_to_hex(hash))
// -- Shows 64-character hex string
// @end
LUA_FUNCTION(l_crypto_bytes_to_hex) {
    LUA_CHECK_ARGC(L, 1);

    size_t dataLen;
    const char* data = luaL_checklstring(L, 1, &dataLen);

    char* hex = new char[dataLen * 2 + 1];
    for (size_t i = 0; i < dataLen; i++) {
        sprintf(hex + i * 2, "%02x", (uint8_t)data[i]);
    }
    hex[dataLen * 2] = '\0';

    lua_pushstring(L, hex);
    delete[] hex;
    return 1;
}

// @lua ez.crypto.hex_to_bytes(hex) -> string
// @brief Convert hex string to binary data
// @description Converts a hexadecimal string to binary data. Accepts both upper
// and lowercase hex characters. The input must have even length. Returns nil and
// error message if the string contains invalid characters or has odd length.
// @param hex Hex string (case-insensitive, must have even length)
// @return Binary string, or nil and error message on failure
// @example
// local key = ez.crypto.hex_to_bytes("8b3387e9c5cdea6ac9e5edbaa115cd72")
// print("Key length:", #key)  -- 16 bytes
// @end
LUA_FUNCTION(l_crypto_hex_to_bytes) {
    LUA_CHECK_ARGC(L, 1);

    size_t hexLen;
    const char* hex = luaL_checklstring(L, 1, &hexLen);

    if (hexLen % 2 != 0) {
        lua_pushnil(L);
        lua_pushstring(L, "Hex string must have even length");
        return 2;
    }

    size_t byteLen = hexLen / 2;
    uint8_t* bytes = new uint8_t[byteLen];

    for (size_t i = 0; i < byteLen; i++) {
        char high = hex[i * 2];
        char low = hex[i * 2 + 1];

        int highVal = (high >= '0' && high <= '9') ? high - '0' :
                      (high >= 'a' && high <= 'f') ? high - 'a' + 10 :
                      (high >= 'A' && high <= 'F') ? high - 'A' + 10 : -1;
        int lowVal = (low >= '0' && low <= '9') ? low - '0' :
                     (low >= 'a' && low <= 'f') ? low - 'a' + 10 :
                     (low >= 'A' && low <= 'F') ? low - 'A' + 10 : -1;

        if (highVal < 0 || lowVal < 0) {
            delete[] bytes;
            lua_pushnil(L);
            lua_pushstring(L, "Invalid hex character");
            return 2;
        }

        bytes[i] = (highVal << 4) | lowVal;
    }

    lua_pushlstring(L, reinterpret_cast<char*>(bytes), byteLen);
    delete[] bytes;
    return 1;
}

// @lua ez.crypto.base64_encode(data) -> string
// @brief Encode binary data to base64 string
// @description Encodes binary data to base64 format. Base64 represents binary data
// using only printable ASCII characters (A-Z, a-z, 0-9, +, /). The output is about
// 33% larger than the input. Useful for transmitting binary data in text formats.
// @param data Binary string to encode
// @return Base64 encoded string, or nil and error on failure
// @example
// local encoded = ez.crypto.base64_encode("Hello, World!")
// print(encoded)  -- "SGVsbG8sIFdvcmxkIQ=="
// @end
LUA_FUNCTION(l_crypto_base64_encode) {
    LUA_CHECK_ARGC(L, 1);

    size_t dataLen;
    const char* data = luaL_checklstring(L, 1, &dataLen);

    // Calculate output size (4 bytes per 3 input bytes, rounded up)
    size_t outLen = ((dataLen + 2) / 3) * 4 + 1;
    char* output = new char[outLen];
    size_t writtenLen = 0;

    int ret = mbedtls_base64_encode(
        reinterpret_cast<unsigned char*>(output), outLen,
        &writtenLen,
        reinterpret_cast<const unsigned char*>(data), dataLen);

    if (ret != 0) {
        delete[] output;
        lua_pushnil(L);
        lua_pushstring(L, "Base64 encode failed");
        return 2;
    }

    lua_pushlstring(L, output, writtenLen);
    delete[] output;
    return 1;
}

// @lua ez.crypto.base64_decode(encoded) -> string
// @brief Decode base64 string to binary data
// @description Decodes a base64 encoded string back to binary data. Returns nil
// and error message if the input contains invalid base64 characters or has
// incorrect padding.
// @param encoded Base64 encoded string
// @return Binary string, or nil and error on failure
// @example
// local decoded = ez.crypto.base64_decode("SGVsbG8sIFdvcmxkIQ==")
// print(decoded)  -- "Hello, World!"
// @end
LUA_FUNCTION(l_crypto_base64_decode) {
    LUA_CHECK_ARGC(L, 1);

    size_t encodedLen;
    const char* encoded = luaL_checklstring(L, 1, &encodedLen);

    // Output is at most 3/4 the size of input
    size_t outLen = (encodedLen * 3) / 4 + 1;
    unsigned char* output = new unsigned char[outLen];
    size_t writtenLen = 0;

    int ret = mbedtls_base64_decode(
        output, outLen, &writtenLen,
        reinterpret_cast<const unsigned char*>(encoded), encodedLen);

    if (ret != 0) {
        delete[] output;
        lua_pushnil(L);
        lua_pushstring(L, "Base64 decode failed");
        return 2;
    }

    lua_pushlstring(L, reinterpret_cast<char*>(output), writtenLen);
    delete[] output;
    return 1;
}

// Function table for ez.crypto
static const luaL_Reg crypto_funcs[] = {
    {"sha256",              l_crypto_sha256},
    {"sha512",              l_crypto_sha512},
    {"hmac_sha256",         l_crypto_hmac_sha256},
    {"aes128_ecb_encrypt",  l_crypto_aes128_ecb_encrypt},
    {"aes128_ecb_decrypt",  l_crypto_aes128_ecb_decrypt},
    {"random_bytes",        l_crypto_random_bytes},
    {"channel_hash",        l_crypto_channel_hash},
    {"derive_channel_key",  l_crypto_derive_channel_key},
    {"public_channel_key",  l_crypto_public_channel_key},
    {"bytes_to_hex",        l_crypto_bytes_to_hex},
    {"hex_to_bytes",        l_crypto_hex_to_bytes},
    {"base64_encode",       l_crypto_base64_encode},
    {"base64_decode",       l_crypto_base64_decode},
    {nullptr, nullptr}
};

// Register the crypto module
void registerCryptoModule(lua_State* L) {
    lua_register_module(L, "crypto", crypto_funcs);
    Serial.println("[LuaRuntime] Registered ez.crypto");
}
