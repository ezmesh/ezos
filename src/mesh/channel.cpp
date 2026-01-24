#include "channel.h"
#include <Arduino.h>
#include <cstring>

// mbedTLS includes for AES and SHA256
#include "mbedtls/aes.h"
#include "mbedtls/md.h"
#include "mbedtls/sha256.h"

// Default public channel key (well-known across all MeshCore devices)
// Base64: izOH6cXN6mrJ5e25oRXNcg==
// Hex: 8b3387e9c5cdea6ac9e5edbaa115cd72
const uint8_t PUBLIC_CHANNEL_KEY[CHANNEL_KEY_SIZE] = {
    0x8b, 0x33, 0x87, 0xe9, 0xc5, 0xcd, 0xea, 0x6a,
    0xc9, 0xe5, 0xed, 0xba, 0xa1, 0x15, 0xcd, 0x72
};

const uint8_t* getPublicChannelKey() {
    return PUBLIC_CHANNEL_KEY;
}

// Compute channel hash from key (first byte of SHA256(key))
// Try multiple key sizes to find the right format
uint8_t computeChannelHash(const uint8_t* key) {
    uint8_t hash[32];
    mbedtls_sha256_context ctx;

    // Debug: try different key lengths and show all hashes
    Serial.print("Channel hash debug: ");

    // Try 1-byte key
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    mbedtls_sha256_update(&ctx, key, 1);
    mbedtls_sha256_finish(&ctx, hash);
    mbedtls_sha256_free(&ctx);
    Serial.printf("1B=%02X ", hash[0]);

    // Try 16-byte key
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    mbedtls_sha256_update(&ctx, key, 16);
    mbedtls_sha256_finish(&ctx, hash);
    mbedtls_sha256_free(&ctx);
    Serial.printf("16B=%02X ", hash[0]);

    // Try 32-byte key (padded with zeros)
    uint8_t key32[32];
    memcpy(key32, key, 16);
    memset(key32 + 16, 0, 16);
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    mbedtls_sha256_update(&ctx, key32, 32);
    mbedtls_sha256_finish(&ctx, hash);
    mbedtls_sha256_free(&ctx);
    Serial.printf("32B=%02X\n", hash[0]);

    // Return 16-byte version for now
    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    mbedtls_sha256_update(&ctx, key, CHANNEL_KEY_SIZE);
    mbedtls_sha256_finish(&ctx, hash);
    mbedtls_sha256_free(&ctx);
    return hash[0];
}

// Compute HMAC-SHA256 and return first 2 bytes as MAC
static bool computeMAC(const uint8_t* key, size_t keyLen,
                       const uint8_t* data, size_t dataLen,
                       uint8_t* macOut) {
    uint8_t fullMac[32];

    mbedtls_md_context_t ctx;
    mbedtls_md_init(&ctx);

    const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (!info) {
        mbedtls_md_free(&ctx);
        return false;
    }

    int ret = mbedtls_md_setup(&ctx, info, 1);  // 1 = use HMAC
    if (ret != 0) {
        mbedtls_md_free(&ctx);
        return false;
    }

    ret = mbedtls_md_hmac_starts(&ctx, key, keyLen);
    if (ret != 0) {
        mbedtls_md_free(&ctx);
        return false;
    }

    ret = mbedtls_md_hmac_update(&ctx, data, dataLen);
    if (ret != 0) {
        mbedtls_md_free(&ctx);
        return false;
    }

    ret = mbedtls_md_hmac_finish(&ctx, fullMac);
    mbedtls_md_free(&ctx);

    if (ret != 0) {
        return false;
    }

    // Truncate to 2 bytes
    macOut[0] = fullMac[0];
    macOut[1] = fullMac[1];
    return true;
}

bool deriveChannelKey(const char* password, const char* channelName, uint8_t* keyOut) {
    if (!channelName || !keyOut) {
        return false;
    }

    // For #Public (or "Public"), use the well-known key
    if (strcmp(channelName, "#Public") == 0 || strcmp(channelName, "Public") == 0) {
        memcpy(keyOut, PUBLIC_CHANNEL_KEY, CHANNEL_KEY_SIZE);
        Serial.println("Using default #Public key");

        // Debug: show what hash this key produces
        uint8_t testHash = computeChannelHash(keyOut);
        Serial.printf("  #Public key hash: %02X\n", testHash);
        return true;
    }

    // For channels without password, derive key from SHA256 of channel name
    // MeshCore uses: key = SHA256(channel_name)[0:16]
    uint8_t hash[32];
    mbedtls_sha256_context ctx;

    const char* deriveSrc = (password && strlen(password) > 0) ? password : channelName;

    mbedtls_sha256_init(&ctx);
    mbedtls_sha256_starts(&ctx, 0);
    mbedtls_sha256_update(&ctx, reinterpret_cast<const uint8_t*>(deriveSrc), strlen(deriveSrc));
    mbedtls_sha256_finish(&ctx, hash);
    mbedtls_sha256_free(&ctx);

    // Take first 16 bytes as AES-128 key
    memcpy(keyOut, hash, CHANNEL_KEY_SIZE);

    // Debug: show what hash this derived key produces
    uint8_t derivedHash = computeChannelHash(keyOut);
    Serial.printf("Channel '%s' key: %02X%02X%02X%02X... (hash=%02X) derived from '%s'\n",
                  channelName, keyOut[0], keyOut[1], keyOut[2], keyOut[3], derivedHash, deriveSrc);

    return true;
}

size_t encryptChannelMessage(const uint8_t* key, const uint8_t* plaintext, size_t plaintextLen,
                              uint8_t* output, size_t outputMaxLen) {
    // Round up to next block size
    size_t paddedLen = ((plaintextLen + CHANNEL_BLOCK_SIZE - 1) / CHANNEL_BLOCK_SIZE) * CHANNEL_BLOCK_SIZE;
    size_t requiredLen = CHANNEL_MAC_SIZE + paddedLen;

    if (outputMaxLen < requiredLen) {
        Serial.println("Output buffer too small for encrypted message");
        return 0;
    }

    // Prepare padded plaintext
    uint8_t padded[256];
    if (paddedLen > sizeof(padded)) {
        Serial.println("Message too long to encrypt");
        return 0;
    }
    memset(padded, 0, paddedLen);
    memcpy(padded, plaintext, plaintextLen);

    // Encrypt with AES-128-ECB
    mbedtls_aes_context ctx;
    mbedtls_aes_init(&ctx);

    int ret = mbedtls_aes_setkey_enc(&ctx, key, 128);
    if (ret != 0) {
        Serial.printf("AES setkey failed: %d\n", ret);
        mbedtls_aes_free(&ctx);
        return 0;
    }

    // Encrypt block by block (ECB mode)
    uint8_t* ciphertext = output + CHANNEL_MAC_SIZE;
    for (size_t i = 0; i < paddedLen; i += CHANNEL_BLOCK_SIZE) {
        ret = mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_ENCRYPT,
                                     padded + i, ciphertext + i);
        if (ret != 0) {
            Serial.printf("AES encrypt failed: %d\n", ret);
            mbedtls_aes_free(&ctx);
            return 0;
        }
    }

    mbedtls_aes_free(&ctx);

    // Build HMAC key: 16-byte channel key + 16 zero bytes = 32 bytes
    // (MeshCore uses this expanded key format for HMAC)
    uint8_t hmacKey[32];
    memcpy(hmacKey, key, CHANNEL_KEY_SIZE);
    memset(hmacKey + CHANNEL_KEY_SIZE, 0, 16);

    // Compute MAC over ciphertext using 32-byte expanded key
    if (!computeMAC(hmacKey, 32, ciphertext, paddedLen, output)) {
        Serial.println("MAC computation failed");
        return 0;
    }

    return requiredLen;
}

size_t decryptChannelMessage(const uint8_t* key, const uint8_t* input, size_t inputLen,
                              uint8_t* output, size_t outputMaxLen) {
    // Input format: [MAC:2][encrypted_blocks]
    if (inputLen < CHANNEL_MAC_SIZE + 1) {
        Serial.printf("Encrypted message too short: %d bytes\n", inputLen);
        return 0;
    }

    size_t ciphertextLen = inputLen - CHANNEL_MAC_SIZE;

    // For ECB mode, we need block-aligned data
    // If not aligned, round up and we'll handle extra zeros after decryption
    size_t alignedLen = ((ciphertextLen + CHANNEL_BLOCK_SIZE - 1) / CHANNEL_BLOCK_SIZE) * CHANNEL_BLOCK_SIZE;

    if (outputMaxLen < alignedLen) {
        Serial.println("Output buffer too small for decrypted message");
        return 0;
    }

    const uint8_t* mac = input;
    const uint8_t* ciphertext = input + CHANNEL_MAC_SIZE;

    // Build HMAC key: 16-byte channel key + 16 zero bytes = 32 bytes
    // (MeshCore uses this expanded key format for HMAC)
    uint8_t hmacKey[32];
    memcpy(hmacKey, key, CHANNEL_KEY_SIZE);
    memset(hmacKey + CHANNEL_KEY_SIZE, 0, 16);

    // Verify MAC using the 32-byte expanded key
    uint8_t computedMac[2];
    if (!computeMAC(hmacKey, 32, ciphertext, ciphertextLen, computedMac)) {
        Serial.println("MAC computation failed during verify");
        return 0;
    }

    if (mac[0] != computedMac[0] || mac[1] != computedMac[1]) {
        // Try with just the 16-byte key (fallback)
        if (!computeMAC(key, CHANNEL_KEY_SIZE, ciphertext, ciphertextLen, computedMac)) {
            Serial.println("MAC computation failed (fallback)");
            return 0;
        }
        if (mac[0] != computedMac[0] || mac[1] != computedMac[1]) {
            Serial.printf("MAC mismatch: got %02X%02X, expected %02X%02X\n",
                          mac[0], mac[1], computedMac[0], computedMac[1]);
            return 0;
        }
    }

    Serial.println("MAC verified OK");

    // If ciphertext is not block-aligned, we can't decrypt it properly with ECB
    // This would indicate a protocol mismatch
    if (ciphertextLen % CHANNEL_BLOCK_SIZE != 0) {
        Serial.printf("Warning: ciphertext not block-aligned: %d bytes\n", ciphertextLen);
        // Still try - maybe it's CTR mode or different format
        // For now, just return 0 to indicate failure
        return 0;
    }

    // Decrypt with AES-128-ECB
    mbedtls_aes_context ctx;
    mbedtls_aes_init(&ctx);

    int ret = mbedtls_aes_setkey_dec(&ctx, key, 128);
    if (ret != 0) {
        Serial.printf("AES setkey failed: %d\n", ret);
        mbedtls_aes_free(&ctx);
        return 0;
    }

    // Decrypt block by block (ECB mode)
    for (size_t i = 0; i < ciphertextLen; i += CHANNEL_BLOCK_SIZE) {
        ret = mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_DECRYPT,
                                     ciphertext + i, output + i);
        if (ret != 0) {
            Serial.printf("AES decrypt failed: %d\n", ret);
            mbedtls_aes_free(&ctx);
            return 0;
        }
    }

    mbedtls_aes_free(&ctx);

    // Find actual length by looking for null terminator or trailing zeros
    size_t actualLen = ciphertextLen;
    while (actualLen > 0 && output[actualLen - 1] == 0) {
        actualLen--;
    }

    return actualLen;
}

size_t parseChannelPayload(const uint8_t* payload, size_t payloadLen,
                            char* textOut, size_t textMaxLen,
                            char* senderOut, size_t senderMaxLen) {
    // Payload format: [timestamp:4][flags:1][sender: text\0]
    if (payloadLen < 6) {
        return 0;
    }

    // Skip timestamp (4 bytes) and flags (1 byte)
    const char* content = reinterpret_cast<const char*>(payload + 5);
    size_t contentLen = payloadLen - 5;

    // Find the ": " separator between sender name and message
    const char* separator = strstr(content, ": ");

    if (separator && senderOut && senderMaxLen > 0) {
        size_t senderLen = separator - content;
        if (senderLen >= senderMaxLen) senderLen = senderMaxLen - 1;
        memcpy(senderOut, content, senderLen);
        senderOut[senderLen] = '\0';

        // Text starts after ": "
        const char* text = separator + 2;
        size_t textLen = contentLen - (text - content);
        if (textLen >= textMaxLen) textLen = textMaxLen - 1;
        memcpy(textOut, text, textLen);
        textOut[textLen] = '\0';
        return textLen;
    }

    // No separator found - use whole content as text
    if (textOut && textMaxLen > 0) {
        size_t textLen = contentLen;
        if (textLen >= textMaxLen) textLen = textMaxLen - 1;
        memcpy(textOut, content, textLen);
        textOut[textLen] = '\0';
        return textLen;
    }

    return 0;
}
