#pragma once

#include <functional>
#include <vector>
#include "../hardware/radio.h"
#include "packet.h"
#include "identity.h"
#include "channel.h"

// Known node information
struct NodeInfo {
    uint8_t pathHash;                            // 1-byte path hash (first byte of pubkey)
    char name[MAX_NODE_NAME + 1];
    uint8_t publicKey[ED25519_PUBLIC_KEY_SIZE];  // Node's public key
    bool hasPublicKey;                           // True if we've received their public key
    uint32_t lastSeen;                           // millis() timestamp
    float lastRssi;
    float lastSnr;
    uint8_t hopCount;                            // Hops to reach this node
};

// Received direct message
struct Message {
    uint8_t fromHash;                            // Sender's path hash
    uint8_t fromPubKey[ED25519_PUBLIC_KEY_SIZE]; // Sender's public key
    char text[MAX_PACKET_PAYLOAD + 1];
    uint32_t timestamp;
    bool isRead;
};

// Callback types
using MessageCallback = std::function<void(const Message&)>;
using NodeCallback = std::function<void(const NodeInfo&)>;
using ChannelMsgCallback = std::function<void(const ChannelMessage&)>;

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

    // Send a message to a channel (group)
    bool sendChannelMessage(const char* channel, const char* text);

    // Set callbacks for incoming messages and node discovery
    void setMessageCallback(MessageCallback cb) { _onMessage = cb; }
    void setNodeCallback(NodeCallback cb) { _onNode = cb; }
    void setChannelCallback(ChannelMsgCallback cb) { _onChannelMsg = cb; }

    // Get known nodes
    const std::vector<NodeInfo>& getNodes() const { return _nodes; }

    // Channel management
    const std::vector<Channel>& getChannels() const { return _channels; }
    const std::vector<ChannelMessage>& getChannelMessages() const { return _channelMessages; }

    // Join a channel (optionally with password for encrypted channels)
    bool joinChannel(const char* name, const char* password = nullptr);

    // Leave a channel
    bool leaveChannel(const char* name);

    // Check if we're in a channel
    bool isInChannel(const char* name) const;

    // Get channel by name (returns nullptr if not found)
    Channel* getChannel(const char* name);
    const Channel* getChannel(const char* name) const;

    // Mark channel messages as read
    void markChannelMessagesRead(const char* channel);

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
    std::vector<Channel> _channels;
    std::vector<ChannelMessage> _channelMessages;

    MessageCallback _onMessage;
    NodeCallback _onNode;
    ChannelMsgCallback _onChannelMsg;

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
                   const RxMetadata& meta, uint8_t hops);

    // Find node by path hash
    NodeInfo* findNodeByHash(uint8_t hash);
    const NodeInfo* findNodeByHash(uint8_t hash) const;

    // Find node by public key
    NodeInfo* findNodeByPubKey(const uint8_t* pubKey);
    const NodeInfo* findNodeByPubKey(const uint8_t* pubKey) const;

    // Send raw packet
    bool sendPacket(MeshPacket& packet);

    // Channel persistence
    void saveChannels();
    void loadChannels();
};
