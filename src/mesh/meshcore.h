#pragma once

#include <functional>
#include <vector>
#include "../hardware/radio.h"
#include "packet.h"
#include "identity.h"

// Node role constants (matches MeshCore ADV_TYPE values)
enum NodeRole : uint8_t {
    ROLE_UNKNOWN = 0,
    ROLE_CLIENT = 1,    // ADV_TYPE_CHAT (0x81)
    ROLE_REPEATER = 2,  // ADV_TYPE_REPEATER (0x82)
    ROLE_ROUTER = 3,    // ADV_TYPE_ROOM (0x83)
    ROLE_SENSOR = 4,    // ADV_TYPE_SENSOR (0x84)
    ROLE_GATEWAY = 5
};

// MeshCore ADV_TYPE values in app_data first byte
constexpr uint8_t ADV_TYPE_CHAT = 0x81;
constexpr uint8_t ADV_TYPE_REPEATER = 0x82;
constexpr uint8_t ADV_TYPE_ROOM = 0x83;
constexpr uint8_t ADV_TYPE_SENSOR = 0x84;

// Known node information
struct NodeInfo {
    uint8_t pathHash;                            // 1-byte path hash (first byte of pubkey)
    char name[MAX_NODE_NAME + 1];
    uint8_t publicKey[ED25519_PUBLIC_KEY_SIZE];  // Node's public key
    bool hasPublicKey;                           // True if we've received their public key
    uint32_t lastSeen;                           // millis() timestamp
    uint32_t advertTimestamp;                    // Unix timestamp from ADVERT packet
    float lastRssi;
    float lastSnr;
    uint8_t hopCount;                            // Hops to reach this node
    uint8_t role;                                // Node role (client, repeater, etc.)
};

// Received direct message
struct Message {
    uint8_t fromHash;                            // Sender's path hash
    uint8_t fromPubKey[ED25519_PUBLIC_KEY_SIZE]; // Sender's public key
    char text[MAX_PACKET_PAYLOAD + 1];
    uint32_t timestamp;
    bool isRead;
};

// Parsed packet info passed to Lua
struct ParsedPacket {
    uint8_t routeType;      // FLOOD, DIRECT, etc.
    uint8_t payloadType;    // ADVERT, GRP_TXT, TXT_MSG, etc.
    uint8_t version;
    uint8_t pathLen;
    const uint8_t* path;    // Path hashes (first is originator)
    uint16_t payloadLen;
    const uint8_t* payload; // Raw payload bytes
    float rssi;
    float snr;
    uint32_t timestamp;
};

// Callback types
using MessageCallback = std::function<void(const Message&)>;
using NodeCallback = std::function<void(const NodeInfo&)>;
// Raw group packet callback for Lua - receives encrypted data before decryption
using GroupPacketCallback = std::function<void(uint8_t channelHash, const uint8_t* data, size_t dataLen,
                                                uint8_t senderHash, float rssi, float snr)>;
// Generic packet callback - returns true if Lua handled it (skip C++ handling),
// second bool is whether to rebroadcast
using PacketCallback = std::function<std::pair<bool, bool>(const ParsedPacket& packet)>;

// Main MeshCore protocol handler
class MeshCore {
public:
    MeshCore(Radio& radio);
    ~MeshCore() = default;

    // Initialize the mesh protocol
    bool init();

    // Call in loop - processes radio RX/TX
    void update();

    // Send node announcement
    bool sendAnnounce();

    // Send raw group packet (for Lua channel handling)
    bool sendGroupPacket(uint8_t channelHash, const uint8_t* encryptedData, size_t dataLen);

    // Set callbacks for incoming messages and node discovery
    void setMessageCallback(MessageCallback cb) { _onMessage = cb; }
    void setNodeCallback(NodeCallback cb) { _onNode = cb; }
    void setGroupPacketCallback(GroupPacketCallback cb) { _onGroupPacket = cb; }
    void setPacketCallback(PacketCallback cb) { _onPacket = cb; }

    // Schedule a raw packet for rebroadcast (called from Lua)
    void scheduleRawRebroadcast(const uint8_t* data, size_t len);

    // Get known nodes
    const std::vector<NodeInfo>& getNodes() const { return _nodes; }

    // Get our identity
    const Identity& getIdentity() const { return _identity; }

    // Get radio instance
    Radio* getRadio() { return &_radio; }
    const Radio* getRadio() const { return &_radio; }

    // Get statistics
    uint32_t getTxCount() const { return _txCount; }
    uint32_t getRxCount() const { return _rxCount; }
    uint32_t getPacketsSent() const { return _txCount; }
    uint32_t getPacketsReceived() const { return _rxCount; }

private:
    Radio& _radio;
    Identity _identity;

    std::vector<NodeInfo> _nodes;
    std::vector<Message> _messages;

    MessageCallback _onMessage;
    NodeCallback _onNode;
    GroupPacketCallback _onGroupPacket;
    PacketCallback _onPacket;

    uint32_t _txCount = 0;
    uint32_t _rxCount = 0;
    uint32_t _lastAnnounce = 0;

    // Pending rebroadcast
    struct PendingRebroadcast {
        uint8_t data[MeshPacket::MAX_SIZE];
        size_t len;
        uint32_t sendAt;
    };
    std::vector<PendingRebroadcast> _pendingRebroadcasts;

    // Process received packet
    void handlePacket(const uint8_t* data, size_t len, const RxMetadata& meta);

    // Handle specific payload types
    void handleAdvertPacket(const MeshPacket& packet, const RxMetadata& meta);
    void handleTextPacket(const MeshPacket& packet, const RxMetadata& meta);
    void handleGroupTextPacket(const MeshPacket& packet, const RxMetadata& meta);

    // Schedule packet for rebroadcast (flood routing)
    void scheduleRebroadcast(const MeshPacket& packet);

    // Process pending rebroadcasts
    void processRebroadcasts();

    // Update or add node info
    void updateNode(uint8_t pathHash, const char* name, const uint8_t* publicKey,
                   const RxMetadata& meta, uint8_t hops, uint8_t role = ROLE_UNKNOWN,
                   uint32_t advertTimestamp = 0);

    // Find node by path hash
    NodeInfo* findNodeByHash(uint8_t hash);
    const NodeInfo* findNodeByHash(uint8_t hash) const;

    // Find node by public key
    NodeInfo* findNodeByPubKey(const uint8_t* pubKey);
    const NodeInfo* findNodeByPubKey(const uint8_t* pubKey) const;

    // Send raw packet
    bool sendPacket(MeshPacket& packet);
};
