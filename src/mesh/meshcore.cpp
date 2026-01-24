#include "meshcore.h"
#include <Arduino.h>
#include <Preferences.h>
#include <cstring>

// Rebroadcast delay range (ms)
constexpr uint32_t REBROADCAST_DELAY_MIN = 50;
constexpr uint32_t REBROADCAST_DELAY_MAX = 200;

// Announce interval (ms)
constexpr uint32_t ANNOUNCE_INTERVAL = 60000;

MeshCore::MeshCore(Radio& radio) : _radio(radio) {
}

// =============================================================================
// Channel Persistence
// =============================================================================

void MeshCore::saveChannels() {
    Preferences prefs;
    if (!prefs.begin("channels", false)) {
        Serial.println("Failed to open channels preferences");
        return;
    }

    int count = 0;
    for (const auto& ch : _channels) {
        if (ch.isJoined && !ch.isPublic()) {
            count++;
        }
    }

    prefs.putInt("count", count);

    int idx = 0;
    for (const auto& ch : _channels) {
        if (ch.isJoined && !ch.isPublic()) {
            char nameKey[16], encKey[16], keyKey[16];
            snprintf(nameKey, sizeof(nameKey), "name%d", idx);
            snprintf(encKey, sizeof(encKey), "enc%d", idx);
            snprintf(keyKey, sizeof(keyKey), "key%d", idx);

            prefs.putString(nameKey, ch.name);
            prefs.putBool(encKey, ch.isEncrypted);
            // Always save the key (even for name-derived channels)
            prefs.putBytes(keyKey, ch.key, CHANNEL_KEY_SIZE);
            idx++;
        }
    }

    prefs.end();
    Serial.printf("Saved %d channels to NVS\n", count);
}

void MeshCore::loadChannels() {
    Preferences prefs;
    if (!prefs.begin("channels", true)) {
        return;
    }

    int count = prefs.getInt("count", 0);
    Serial.printf("Loading %d saved channels\n", count);

    for (int i = 0; i < count; i++) {
        char nameKey[16], encKey[16], keyKey[16];
        snprintf(nameKey, sizeof(nameKey), "name%d", i);
        snprintf(encKey, sizeof(encKey), "enc%d", i);
        snprintf(keyKey, sizeof(keyKey), "key%d", i);

        String name = prefs.getString(nameKey, "");
        if (name.length() == 0) continue;

        Channel channel;
        strncpy(channel.name, name.c_str(), MAX_CHANNEL_NAME - 1);
        channel.name[MAX_CHANNEL_NAME - 1] = '\0';
        channel.isJoined = true;
        channel.isEncrypted = prefs.getBool(encKey, false);
        channel.lastActivity = millis();
        channel.unreadCount = 0;

        // Always load the key
        prefs.getBytes(keyKey, channel.key, CHANNEL_KEY_SIZE);

        _channels.push_back(channel);
        uint8_t keyHash = computeChannelHash(channel.key);
        Serial.printf("Loaded channel: %s (hash=%02X)%s\n", channel.name, keyHash,
                      channel.isEncrypted ? " (encrypted)" : "");
    }

    prefs.end();
}

// =============================================================================
// Initialization
// =============================================================================

bool MeshCore::init() {
    if (!_identity.init()) {
        Serial.println("Failed to initialize identity");
        return false;
    }

    char fullId[16];
    _identity.getFullId(fullId);
    Serial.printf("Node ID: %s\n", fullId);
    Serial.printf("Node Name: %s\n", _identity.getNodeName());

    // Clear any previously saved channels to ensure fresh key derivation
    {
        Preferences prefs;
        if (prefs.begin("channels", false)) {
            prefs.clear();
            prefs.end();
            Serial.println("Cleared saved channels");
        }
    }

    // Join the default public channel
    joinChannel("#Public");

    // Also join #test for compatibility with Ripple devices
    // (key derived from channel name produces hash 0xD9)
    joinChannel("#test");

    // Testing channel
    joinChannel("#xtr-test");

    Serial.printf("Total channels: %d\n", _channels.size());
    for (const auto& ch : _channels) {
        Serial.printf("  Channel %s: hash=%02X key=%02X%02X%02X%02X\n",
                      ch.name, computeChannelHash(ch.key),
                      ch.key[0], ch.key[1], ch.key[2], ch.key[3]);
    }

    // Announce ourselves
    sendAnnounce();

    return true;
}

// =============================================================================
// Main Update Loop
// =============================================================================

void MeshCore::update() {
    // Check for incoming packets
    if (_radio.available()) {
        uint8_t buffer[MeshPacket::MAX_SIZE];
        RxMetadata meta;

        int len = _radio.receive(buffer, sizeof(buffer), meta);
        if (len > 0) {
            _rxCount++;
            handlePacket(buffer, len, meta);
        }
    }

    // Process pending rebroadcasts
    processRebroadcasts();

    // Periodic announce
    uint32_t now = millis();
    if (now - _lastAnnounce >= ANNOUNCE_INTERVAL) {
        _lastAnnounce = now;
        sendAnnounce();
    }
}

// =============================================================================
// Packet Handling
// =============================================================================

void MeshCore::handlePacket(const uint8_t* data, size_t len, const RxMetadata& meta) {
    MeshPacket packet;

    // Debug output
    Serial.printf("RX %zu bytes, RSSI:%.0f: ", len, meta.rssi);
    for (size_t i = 0; i < len && i < 16; i++) {
        Serial.printf("%02X ", data[i]);
    }
    Serial.println();

    size_t consumed = packet.deserialize(data, len);
    if (consumed == 0) {
        Serial.printf("Deserialize failed\n");
        return;
    }

    if (!packet.isValid()) {
        Serial.printf("Invalid packet: route=%d type=%d\n",
                      packet.getRouteType(), packet.getPayloadType());
        return;
    }

    // Check if we've already seen this packet (by checking if our hash is in path)
    uint8_t myHash = _identity.getPathHash();
    if (packet.isInPath(myHash)) {
        Serial.println("Already in path, ignoring");
        return;
    }

    // Handle based on payload type
    uint8_t payloadType = packet.getPayloadType();
    Serial.printf("Packet: route=%d type=%d pathLen=%d payloadLen=%d\n",
                  packet.getRouteType(), payloadType, packet.pathLen, packet.payloadLen);

    switch (payloadType) {
        case PayloadType::ADVERT:
            handleAdvertPacket(packet, meta);
            break;
        case PayloadType::TXT_MSG:
            handleTextPacket(packet, meta);
            break;
        case PayloadType::GRP_TXT:
            handleGroupTextPacket(packet, meta);
            break;
        case PayloadType::RESPONSE:
            // Response packets - dump for debugging
            Serial.printf("RESPONSE payload (%d bytes): ", packet.payloadLen);
            for (size_t i = 0; i < packet.payloadLen && i < 32; i++) {
                Serial.printf("%02X ", packet.payload[i]);
            }
            Serial.println();
            break;
        default:
            Serial.printf("Unhandled payload type: %d\n", payloadType);
            break;
    }

    // Rebroadcast if flood routing
    if (packet.getRouteType() == RouteType::FLOOD) {
        scheduleRebroadcast(packet);
    }
}

void MeshCore::handleAdvertPacket(const MeshPacket& packet, const RxMetadata& meta) {
    // ADVERT payload: [timestamp:4][pubkey:32][name:variable]
    if (packet.payloadLen < 4 + PUB_KEY_SIZE) {
        Serial.println("ADVERT payload too short");
        return;
    }

    // Extract timestamp (not used currently)
    // uint32_t timestamp = packet.payload[0] | (packet.payload[1] << 8) |
    //                      (packet.payload[2] << 16) | (packet.payload[3] << 24);

    // Extract public key
    const uint8_t* pubKey = packet.payload + 4;
    uint8_t pathHash = pubKey[0];

    // Extract name
    char name[MAX_NODE_NAME + 1];
    size_t nameLen = packet.payloadLen - 4 - PUB_KEY_SIZE;
    if (nameLen > MAX_NODE_NAME) nameLen = MAX_NODE_NAME;
    if (nameLen > 0) {
        memcpy(name, packet.payload + 4 + PUB_KEY_SIZE, nameLen);
    }
    name[nameLen] = '\0';

    // Update node info
    updateNode(pathHash, name, pubKey, meta, packet.pathLen);

    Serial.printf("ADVERT from %02X: %s\n", pathHash, name);
}

void MeshCore::handleTextPacket(const MeshPacket& packet, const RxMetadata& meta) {
    // Direct text message - not implemented yet for simplicity
    Serial.println("TXT_MSG received (not implemented)");
}

void MeshCore::handleGroupTextPacket(const MeshPacket& packet, const RxMetadata& meta) {
    // Debug: dump raw payload
    Serial.printf("GRP_TXT raw (%d bytes): ", packet.payloadLen);
    for (size_t i = 0; i < packet.payloadLen && i < 40; i++) {
        Serial.printf("%02X ", packet.payload[i]);
    }
    Serial.println();

    // Minimum: channel_hash(1) + MAC(2) + one AES block(16) = 19 bytes
    if (packet.payloadLen < 1 + CHANNEL_MAC_SIZE + CHANNEL_BLOCK_SIZE) {
        Serial.printf("GRP_TXT payload too short: %d < %d\n",
                      packet.payloadLen, 1 + CHANNEL_MAC_SIZE + CHANNEL_BLOCK_SIZE);
        return;
    }

    uint8_t channelIdx = packet.payload[0];
    const uint8_t* encryptedData = packet.payload + 1;  // MAC + ciphertext
    size_t encryptedLen = packet.payloadLen - 1;

    Serial.printf("GRP_TXT channelIdx=%02X encryptedLen=%d (MAC+cipher)\n", channelIdx, encryptedLen);
    Serial.printf("  MAC: %02X %02X, cipherLen=%d\n",
                  encryptedData[0], encryptedData[1], encryptedLen - 2);

    // Check if ciphertext length is block-aligned
    size_t cipherLen = encryptedLen - 2;
    if (cipherLen % 16 != 0) {
        Serial.printf("  WARNING: cipher length %d not multiple of 16!\n", cipherLen);
    }

    // Debug: show channel hashes we know
    Serial.printf("  Packet hash: %02X, our channels: ", channelIdx);
    for (const auto& ch : _channels) {
        if (ch.isJoined) {
            uint8_t h = computeChannelHash(ch.key);
            Serial.printf("%s=%02X ", ch.name, h);
        }
    }
    Serial.println();

    // Get sender from path (first byte is the originator)
    uint8_t senderHash = packet.pathLen > 0 ? packet.path[0] : 0;

    char text[MAX_CHANNEL_TEXT + 1];
    char senderName[32] = "";
    bool decrypted = false;
    const char* channelName = "#Public";  // Default

    // Try to decrypt with known channels
    uint8_t decryptedPayload[256];
    for (const auto& ch : _channels) {
        if (ch.isJoined) {
            // Debug: show channel key being tried
            uint8_t chHash = computeChannelHash(ch.key);
            Serial.printf("  Trying %s (keyHash=%02X): %02X%02X%02X%02X...\n",
                          ch.name, chHash, ch.key[0], ch.key[1], ch.key[2], ch.key[3]);

            size_t len = decryptChannelMessage(ch.key, encryptedData, encryptedLen,
                                                decryptedPayload, sizeof(decryptedPayload));
            if (len > 0) {
                // Debug: show raw decrypted bytes
                Serial.printf("  Decrypted %d bytes: ", len);
                for (size_t i = 0; i < len && i < 32; i++) {
                    Serial.printf("%02X ", decryptedPayload[i]);
                }
                Serial.println();
                // Parse the decrypted payload: [timestamp:4][flags:1][sender: text\0]
                size_t textLen = parseChannelPayload(decryptedPayload, len,
                                                      text, sizeof(text),
                                                      senderName, sizeof(senderName));
                if (textLen > 0) {
                    channelName = ch.name;
                    decrypted = true;
                    Serial.printf("Decrypted with %s from '%s': %s\n", ch.name, senderName, text);
                    break;
                } else {
                    // Payload parsed but no text extracted - show raw
                    memcpy(text, decryptedPayload + 5, len - 5);
                    text[len - 5] = '\0';
                    channelName = ch.name;
                    decrypted = true;
                    Serial.printf("Decrypted (raw) with %s: %s\n", ch.name, text);
                    break;
                }
            }
        }
    }

    if (!decrypted) {
        // Decryption failed with all known keys
        Serial.println("Could not decrypt with any known channel key");
        snprintf(text, sizeof(text), "[encrypted %d bytes]", (int)encryptedLen);
        decrypted = true;  // Still store the message placeholder
    }

    Serial.printf("GRP_TXT channel='%s' from=%02X: %s\n", channelName, senderHash, text);

    // Try to find channel by name, or use #Public as default
    Channel* ch = getChannel(channelName);
    if (!ch) {
        ch = getChannel("#Public");
    }

    if (ch && ch->isJoined) {
        ChannelMessage msg;
        strncpy(msg.channel, ch->name, MAX_CHANNEL_NAME - 1);
        msg.channel[MAX_CHANNEL_NAME - 1] = '\0';
        msg.fromHash = senderHash;
        memset(msg.senderPubKey, 0, ED25519_PUBLIC_KEY_SIZE);

        // If we got sender name from message, use that; otherwise use path hash
        if (strlen(senderName) > 0) {
            snprintf(msg.text, sizeof(msg.text), "%s: %s", senderName, text);
        } else {
            strncpy(msg.text, text, MAX_CHANNEL_TEXT);
        }
        msg.text[MAX_CHANNEL_TEXT] = '\0';

        msg.timestamp = meta.timestamp;
        msg.packetId = 0;
        msg.isRead = false;
        msg.verified = false;
        msg.isOurs = false;

        // Deduplication: check if we already have this message (same channel + text within 30 seconds)
        bool isDuplicate = false;
        for (const auto& existing : _channelMessages) {
            if (strcmp(existing.channel, msg.channel) == 0 &&
                strcmp(existing.text, msg.text) == 0 &&
                (msg.timestamp - existing.timestamp) < 30000) {
                isDuplicate = true;
                Serial.printf("Duplicate message ignored (from path %02X, already have from %02X)\n",
                              msg.fromHash, existing.fromHash);
                break;
            }
        }

        if (isDuplicate) {
            return;
        }

        _channelMessages.push_back(msg);
        ch->lastActivity = meta.timestamp;
        ch->unreadCount++;

        if (_onChannelMsg) {
            _onChannelMsg(msg);
        }
    }
}

// =============================================================================
// Rebroadcast
// =============================================================================

void MeshCore::scheduleRebroadcast(const MeshPacket& packet) {
    // Add our hash to path and rebroadcast
    MeshPacket rebroadcast = packet;

    if (!rebroadcast.addToPath(_identity.getPathHash())) {
        Serial.println("Path full, not rebroadcasting");
        return;
    }

    PendingRebroadcast rb;
    rb.len = rebroadcast.serialize(rb.data, sizeof(rb.data));
    if (rb.len == 0) {
        Serial.println("Failed to serialize for rebroadcast");
        return;
    }

    rb.sendAt = millis() + random(REBROADCAST_DELAY_MIN, REBROADCAST_DELAY_MAX);
    _pendingRebroadcasts.push_back(rb);
}

void MeshCore::processRebroadcasts() {
    uint32_t now = millis();

    auto it = _pendingRebroadcasts.begin();
    while (it != _pendingRebroadcasts.end()) {
        if (now >= it->sendAt) {
            _radio.send(it->data, it->len);
            _txCount++;
            it = _pendingRebroadcasts.erase(it);
        } else {
            ++it;
        }
    }
}

// =============================================================================
// Node Management
// =============================================================================

void MeshCore::updateNode(uint8_t pathHash, const char* name, const uint8_t* publicKey,
                          const RxMetadata& meta, uint8_t hops) {
    // Look for existing node
    for (auto& node : _nodes) {
        if (node.pathHash == pathHash) {
            if (name && strlen(name) > 0) {
                strncpy(node.name, name, MAX_NODE_NAME);
                node.name[MAX_NODE_NAME] = '\0';
            }
            if (publicKey) {
                memcpy(node.publicKey, publicKey, ED25519_PUBLIC_KEY_SIZE);
                node.hasPublicKey = true;
            }
            node.lastSeen = meta.timestamp;
            node.lastRssi = meta.rssi;
            node.lastSnr = meta.snr;
            node.hopCount = hops;

            if (_onNode) {
                _onNode(node);
            }
            return;
        }
    }

    // Add new node
    NodeInfo node;
    node.pathHash = pathHash;
    if (name && strlen(name) > 0) {
        strncpy(node.name, name, MAX_NODE_NAME);
    } else {
        snprintf(node.name, MAX_NODE_NAME, "%02X", pathHash);
    }
    node.name[MAX_NODE_NAME] = '\0';

    if (publicKey) {
        memcpy(node.publicKey, publicKey, ED25519_PUBLIC_KEY_SIZE);
        node.hasPublicKey = true;
    } else {
        memset(node.publicKey, 0, ED25519_PUBLIC_KEY_SIZE);
        node.hasPublicKey = false;
    }

    node.lastSeen = meta.timestamp;
    node.lastRssi = meta.rssi;
    node.lastSnr = meta.snr;
    node.hopCount = hops;

    _nodes.push_back(node);

    if (_onNode) {
        _onNode(node);
    }
}

NodeInfo* MeshCore::findNodeByHash(uint8_t hash) {
    for (auto& node : _nodes) {
        if (node.pathHash == hash) {
            return &node;
        }
    }
    return nullptr;
}

const NodeInfo* MeshCore::findNodeByHash(uint8_t hash) const {
    for (const auto& node : _nodes) {
        if (node.pathHash == hash) {
            return &node;
        }
    }
    return nullptr;
}

NodeInfo* MeshCore::findNodeByPubKey(const uint8_t* pubKey) {
    for (auto& node : _nodes) {
        if (node.hasPublicKey && memcmp(node.publicKey, pubKey, ED25519_PUBLIC_KEY_SIZE) == 0) {
            return &node;
        }
    }
    return nullptr;
}

const NodeInfo* MeshCore::findNodeByPubKey(const uint8_t* pubKey) const {
    for (const auto& node : _nodes) {
        if (node.hasPublicKey && memcmp(node.publicKey, pubKey, ED25519_PUBLIC_KEY_SIZE) == 0) {
            return &node;
        }
    }
    return nullptr;
}

// =============================================================================
// Packet Sending
// =============================================================================

bool MeshCore::sendPacket(MeshPacket& packet) {
    // Add our hash to path
    packet.addToPath(_identity.getPathHash());

    uint8_t buffer[MeshPacket::MAX_SIZE];
    size_t len = packet.serialize(buffer, sizeof(buffer));

    if (len == 0) {
        return false;
    }

    RadioResult result = _radio.send(buffer, len);
    if (result == RadioResult::OK) {
        _txCount++;
        return true;
    }

    return false;
}

bool MeshCore::sendAnnounce() {
    MeshPacket packet;
    packet.clear();
    packet.header = makeHeader(RouteType::FLOOD, PayloadType::ADVERT, PayloadVersion::V1);

    // Build payload: [timestamp:4][pubkey:32][name:variable]
    size_t offset = 0;

    // Timestamp
    uint32_t timestamp = millis() / 1000;
    packet.payload[offset++] = timestamp & 0xFF;
    packet.payload[offset++] = (timestamp >> 8) & 0xFF;
    packet.payload[offset++] = (timestamp >> 16) & 0xFF;
    packet.payload[offset++] = (timestamp >> 24) & 0xFF;

    // Public key
    memcpy(packet.payload + offset, _identity.getPublicKey(), PUB_KEY_SIZE);
    offset += PUB_KEY_SIZE;

    // Node name
    const char* name = _identity.getNodeName();
    size_t nameLen = strlen(name);
    if (nameLen > MAX_NODE_NAME) nameLen = MAX_NODE_NAME;
    memcpy(packet.payload + offset, name, nameLen);
    offset += nameLen;

    packet.payloadLen = offset;

    Serial.printf("Sending ADVERT (pathHash=%02X, name=%s)\n",
                  _identity.getPathHash(), name);
    return sendPacket(packet);
}

bool MeshCore::sendChannelMessage(const char* channel, const char* text) {
    if (!channel || !text || strlen(text) == 0) {
        return false;
    }

    Channel* ch = getChannel(channel);
    if (!ch || !ch->isJoined) {
        Serial.printf("Not in channel: %s\n", channel);
        return false;
    }

    // Build plaintext payload: [timestamp:4][flags:1][sender_name: message\0]
    uint8_t plaintext[200];
    size_t plaintextLen = 0;

    // Timestamp (4 bytes, little-endian)
    uint32_t timestamp = millis() / 1000;  // seconds
    plaintext[plaintextLen++] = (timestamp >> 0) & 0xFF;
    plaintext[plaintextLen++] = (timestamp >> 8) & 0xFF;
    plaintext[plaintextLen++] = (timestamp >> 16) & 0xFF;
    plaintext[plaintextLen++] = (timestamp >> 24) & 0xFF;

    // Flags (1 byte)
    plaintext[plaintextLen++] = 0x00;

    // Sender name + ": " + message + null terminator
    const char* nodeName = _identity.getNodeName();
    size_t nameLen = strlen(nodeName);
    size_t textLen = strlen(text);
    size_t maxMsgLen = sizeof(plaintext) - plaintextLen - nameLen - 3;  // ": " + \0
    if (textLen > maxMsgLen) textLen = maxMsgLen;

    memcpy(plaintext + plaintextLen, nodeName, nameLen);
    plaintextLen += nameLen;
    plaintext[plaintextLen++] = ':';
    plaintext[plaintextLen++] = ' ';
    memcpy(plaintext + plaintextLen, text, textLen);
    plaintextLen += textLen;
    plaintext[plaintextLen++] = '\0';

    // Encrypt the payload
    uint8_t encrypted[220];
    size_t encryptedLen = encryptChannelMessage(ch->key, plaintext, plaintextLen,
                                                  encrypted, sizeof(encrypted));
    if (encryptedLen == 0) {
        Serial.println("Failed to encrypt channel message");
        return false;
    }

    // Build packet: [channel_hash:1][MAC:2][ciphertext]
    MeshPacket packet;
    packet.clear();
    packet.header = makeHeader(RouteType::FLOOD, PayloadType::GRP_TXT, PayloadVersion::V1);

    size_t offset = 0;
    packet.payload[offset++] = computeChannelHash(ch->key);
    memcpy(packet.payload + offset, encrypted, encryptedLen);
    offset += encryptedLen;

    packet.payloadLen = offset;

    // Store our own message locally
    ChannelMessage msg;
    strncpy(msg.channel, channel, MAX_CHANNEL_NAME - 1);
    msg.channel[MAX_CHANNEL_NAME - 1] = '\0';
    msg.fromHash = _identity.getPathHash();
    memcpy(msg.senderPubKey, _identity.getPublicKey(), ED25519_PUBLIC_KEY_SIZE);
    snprintf(msg.text, MAX_CHANNEL_TEXT + 1, "%s: %s", nodeName, text);
    msg.timestamp = millis();
    msg.packetId = 0;
    msg.isRead = true;
    msg.verified = true;
    msg.isOurs = true;
    _channelMessages.push_back(msg);

    ch->lastActivity = msg.timestamp;

    Serial.printf("Sending GRP_TXT to %s (hash=%02X, %d bytes encrypted): %s\n",
                  channel, computeChannelHash(ch->key), (int)encryptedLen, text);
    return sendPacket(packet);
}

// =============================================================================
// Channel Management
// =============================================================================

bool MeshCore::joinChannel(const char* name, const char* password) {
    Serial.printf("joinChannel('%s', '%s')\n", name ? name : "null", password ? password : "null");

    if (!name || strlen(name) == 0) {
        Serial.println("  -> rejected: empty name");
        return false;
    }

    char channelName[MAX_CHANNEL_NAME];
    if (name[0] != '#') {
        snprintf(channelName, sizeof(channelName), "#%s", name);
    } else {
        strncpy(channelName, name, MAX_CHANNEL_NAME - 1);
        channelName[MAX_CHANNEL_NAME - 1] = '\0';
    }

    // Check if already exists
    for (auto& ch : _channels) {
        if (ch.matches(channelName)) {
            // Re-derive key if it's all zeros (wasn't properly loaded)
            bool keyEmpty = true;
            for (int i = 0; i < CHANNEL_KEY_SIZE; i++) {
                if (ch.key[i] != 0) { keyEmpty = false; break; }
            }
            if (keyEmpty) {
                const char* keyPassword = (password && strlen(password) > 0) ? password : channelName;
                deriveChannelKey(keyPassword, channelName, ch.key);
                Serial.printf("Re-derived key for %s (hash=%02X)\n", channelName, computeChannelHash(ch.key));
            }
            if (!ch.isJoined) {
                ch.isJoined = true;
                Serial.printf("Rejoined channel: %s\n", channelName);
            }
            return true;
        }
    }

    // Create new channel
    Channel channel;
    strncpy(channel.name, channelName, MAX_CHANNEL_NAME - 1);
    channel.name[MAX_CHANNEL_NAME - 1] = '\0';
    channel.isJoined = true;
    channel.lastActivity = millis();
    channel.unreadCount = 0;

    // MeshCore encrypts ALL channels - derive key from password or channel name
    const char* keyPassword = (password && strlen(password) > 0) ? password : channelName;
    if (deriveChannelKey(keyPassword, channelName, channel.key)) {
        channel.isEncrypted = (password && strlen(password) > 0);  // Mark as "private" if password provided
        uint8_t keyHash = computeChannelHash(channel.key);
        Serial.printf("Joined channel: %s (hash=%02X, key=%02X%02X%02X%02X...)\n",
                      channelName, keyHash, channel.key[0], channel.key[1], channel.key[2], channel.key[3]);
    } else {
        Serial.println("Failed to derive channel key");
        return false;
    }

    _channels.push_back(channel);

    // Debug: verify key was stored correctly
    Channel& stored = _channels.back();
    Serial.printf("  Stored %s key: %02X%02X%02X%02X (hash=%02X)\n",
                  stored.name, stored.key[0], stored.key[1], stored.key[2], stored.key[3],
                  computeChannelHash(stored.key));

    if (!channel.isPublic()) {
        saveChannels();
    }

    return true;
}

bool MeshCore::leaveChannel(const char* name) {
    for (auto it = _channels.begin(); it != _channels.end(); ++it) {
        if (it->matches(name)) {
            it->isJoined = false;
            Serial.printf("Left channel: %s\n", name);
            saveChannels();
            return true;
        }
    }
    return false;
}

bool MeshCore::isInChannel(const char* name) const {
    for (const auto& ch : _channels) {
        if (ch.matches(name) && ch.isJoined) {
            return true;
        }
    }
    return false;
}

Channel* MeshCore::getChannel(const char* name) {
    for (auto& ch : _channels) {
        if (ch.matches(name)) {
            return &ch;
        }
    }
    return nullptr;
}

const Channel* MeshCore::getChannel(const char* name) const {
    for (const auto& ch : _channels) {
        if (ch.matches(name)) {
            return &ch;
        }
    }
    return nullptr;
}

void MeshCore::markChannelMessagesRead(const char* channel) {
    for (auto& msg : _channelMessages) {
        if (strcmp(msg.channel, channel) == 0) {
            msg.isRead = true;
        }
    }

    Channel* ch = getChannel(channel);
    if (ch) {
        ch->unreadCount = 0;
    }
}
