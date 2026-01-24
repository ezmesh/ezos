#pragma once

#include <cstdint>
#include <cstring>
#include <functional>
#include "packet.h"
#include "identity.h"

// Maximum channel name length (including # prefix and null terminator)
constexpr size_t MAX_CHANNEL_NAME = 32;

// Maximum channel message text length
constexpr size_t MAX_CHANNEL_TEXT = 100;

// MeshCore AES-128-ECB parameters
constexpr size_t CHANNEL_KEY_SIZE = 16;    // AES-128
constexpr size_t CHANNEL_MAC_SIZE = 2;     // Truncated HMAC
constexpr size_t CHANNEL_BLOCK_SIZE = 16;  // AES block size

// Default public channel key (well-known)
// Hex: 8b3387e9c5cdea6ac9e5edbaa115cd72
extern const uint8_t PUBLIC_CHANNEL_KEY[CHANNEL_KEY_SIZE];

// Channel structure for tracking joined channels
struct Channel {
    char name[MAX_CHANNEL_NAME];     // Channel name (e.g., "#Public", "#test")
    bool isJoined;                   // Whether we're actively participating
    bool isEncrypted;                // True if channel requires password/key
    uint8_t key[CHANNEL_KEY_SIZE];   // AES-256 key for encrypted channels
    uint32_t lastActivity;           // Timestamp of last message
    int unreadCount;                 // Number of unread messages

    Channel() {
        memset(name, 0, sizeof(name));
        isJoined = false;
        isEncrypted = false;
        memset(key, 0, sizeof(key));
        lastActivity = 0;
        unreadCount = 0;
    }

    // Check if channel name matches
    bool matches(const char* channelName) const {
        return strcmp(name, channelName) == 0;
    }

    // Check if this is the default public channel
    bool isPublic() const {
        return strcmp(name, "#Public") == 0;
    }
};

// Channel message structure for received/sent messages
struct ChannelMessage {
    char channel[MAX_CHANNEL_NAME];                 // Channel name
    uint8_t fromHash;                               // Sender's path hash
    uint8_t senderPubKey[ED25519_PUBLIC_KEY_SIZE];  // Sender's public key
    uint8_t signature[ED25519_SIGNATURE_SIZE];      // Ed25519 signature (if signed)
    char text[MAX_CHANNEL_TEXT + 1];                // Message text
    uint32_t timestamp;                             // When message was received
    uint32_t packetId;                              // Original packet ID for dedup
    bool isRead;                                    // Has user viewed this message
    bool verified;                                  // True if signature was verified
    bool isOurs;                                    // True if we sent this message

    ChannelMessage() {
        memset(channel, 0, sizeof(channel));
        fromHash = 0;
        memset(senderPubKey, 0, sizeof(senderPubKey));
        memset(signature, 0, sizeof(signature));
        memset(text, 0, sizeof(text));
        timestamp = 0;
        packetId = 0;
        isRead = false;
        verified = false;
        isOurs = false;
    }
};

// Callback type for channel message notifications
class ChannelMessage;
using ChannelMessageCallback = std::function<void(const ChannelMessage&)>;

// Get the default public channel key
const uint8_t* getPublicChannelKey();

// Compute channel hash from key (first byte of SHA256(key))
uint8_t computeChannelHash(const uint8_t* key);

// Derive channel key from password using SHA256 (first 16 bytes)
bool deriveChannelKey(const char* password, const char* channelName, uint8_t* keyOut);

// Encrypt message for channel using AES-128-ECB
// Input: [timestamp:4][flags:1][text]
// Output: [MAC:2][encrypted_blocks]
// Returns encrypted length, or 0 on error
size_t encryptChannelMessage(const uint8_t* key, const uint8_t* plaintext, size_t plaintextLen,
                              uint8_t* output, size_t outputMaxLen);

// Decrypt message from channel using AES-128-ECB
// Input: [MAC:2][encrypted_blocks]
// Output: [timestamp:4][flags:1][text]
// Returns decrypted length, or 0 on error (including MAC mismatch)
size_t decryptChannelMessage(const uint8_t* key, const uint8_t* input, size_t inputLen,
                              uint8_t* output, size_t outputMaxLen);

// Parse decrypted channel payload to extract text
// Input: [timestamp:4][flags:1][sender: text\0]
// Output: just the text portion (after ": ")
// Returns text length
size_t parseChannelPayload(const uint8_t* payload, size_t payloadLen,
                            char* textOut, size_t textMaxLen,
                            char* senderOut, size_t senderMaxLen);
