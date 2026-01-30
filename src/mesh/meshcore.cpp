#include "meshcore.h"
#include <Arduino.h>
#include <cstring>

// Rebroadcast delay range (ms)
constexpr uint32_t REBROADCAST_DELAY_MIN = 50;
constexpr uint32_t REBROADCAST_DELAY_MAX = 200;

// Default announce interval removed - now configurable via setAnnounceInterval()
// Default is 0 (disabled), can be set to: 1h, 4h, 8h, 12h, 24h via settings

MeshCore::MeshCore(Radio& radio) : _radio(radio) {
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

    // Channel management is now handled by Lua (scripts/services/channels.lua)
    // The Lua Channels service will call on_group_packet() to receive raw packets
    // and send_group_packet() to transmit encrypted messages

    // Note: Auto-advert is disabled by default. The user can enable periodic
    // announces via Settings > Radio > Auto Advert, or trigger manual announces
    // via tdeck.mesh.send_advert() from Lua.

    return true;
}

// =============================================================================
// Main Update Loop
// =============================================================================

void MeshCore::update() {
    // Process radio transmit queue (throttled)
    _radio.processQueue();

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

    // Periodic announce (if enabled)
    if (_announceInterval > 0) {
        uint32_t now = millis();
        if (now - _lastAnnounce >= _announceInterval) {
            _lastAnnounce = now;
            sendAnnounce();
        }
    }
}

// =============================================================================
// Packet Handling
// =============================================================================

void MeshCore::handlePacket(const uint8_t* data, size_t len, const RxMetadata& meta) {
    MeshPacket packet;

    size_t consumed = packet.deserialize(data, len);
    if (consumed == 0) {
        return;
    }

    if (!packet.isValid()) {
        return;
    }

    uint8_t myHash = _identity.getPathHash();
    uint8_t routeType = packet.getRouteType();

    // For FLOOD routing, check if we've already seen this packet (our hash in path)
    // For DIRECT routing, skip this check - destination hash IS in the path by design
    // This check can be disabled via settings for debugging
    if (_pathCheckEnabled) {
        if (routeType == RouteType::FLOOD || routeType == RouteType::TRANSPORT_FLOOD) {
            if (packet.isInPath(myHash)) {
                return;
            }
        }
    }

    uint8_t payloadType = packet.getPayloadType();

    // If Lua callback is registered, let it handle the packet first
    bool luaHandled = false;
    bool luaWantsRebroadcast = false;
    if (_onPacket) {
        ParsedPacket parsed;
        parsed.routeType = packet.getRouteType();
        parsed.payloadType = payloadType;
        parsed.version = packet.getVersion();
        parsed.pathLen = packet.pathLen;
        parsed.path = packet.path;
        parsed.payloadLen = packet.payloadLen;
        parsed.payload = packet.payload;
        parsed.rssi = meta.rssi;
        parsed.snr = meta.snr;
        parsed.timestamp = meta.timestamp;

        auto result = _onPacket(parsed);
        luaHandled = result.first;
        luaWantsRebroadcast = result.second;
    }

    // If Lua handled it completely, just do rebroadcast if requested
    if (luaHandled) {
        if (luaWantsRebroadcast && packet.getRouteType() == RouteType::FLOOD) {
            scheduleRebroadcast(packet);
        }
        return;
    }

    // C++ handling for packets Lua didn't handle
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

    // Rebroadcast if flood routing (C++ path)
    if (packet.getRouteType() == RouteType::FLOOD) {
        scheduleRebroadcast(packet);
    }
}

void MeshCore::handleAdvertPacket(const MeshPacket& packet, const RxMetadata& meta) {
    // MeshCore ADVERT payload format:
    // [pub_key:32][timestamp:4][signature:64][app_data:variable]
    // Minimum size: 32 + 4 + 64 = 100 bytes
    constexpr size_t ADVERT_HEADER_SIZE = PUB_KEY_SIZE + 4 + ED25519_SIGNATURE_SIZE;

    Serial.printf("ADVERT: payload %d bytes, dumping first 32: ", packet.payloadLen);
    for (size_t i = 0; i < 32 && i < packet.payloadLen; i++) {
        Serial.printf("%02X ", packet.payload[i]);
    }
    Serial.println();

    if (packet.payloadLen < ADVERT_HEADER_SIZE) {
        Serial.printf("ADVERT payload too short: %d bytes (need %d)\n",
                     packet.payloadLen, ADVERT_HEADER_SIZE);
        return;
    }

    size_t offset = 0;

    // Extract public key (offset 0, 32 bytes)
    const uint8_t* pubKey = packet.payload + offset;
    uint8_t pathHash = pubKey[0];
    offset += PUB_KEY_SIZE;

    // Extract timestamp (offset 32, 4 bytes)
    uint32_t timestamp;
    memcpy(&timestamp, packet.payload + offset, 4);
    offset += 4;

    Serial.printf("ADVERT: pathHash=%02X, timestamp=%u\n", pathHash, timestamp);

    // Extract signature (offset 36, 64 bytes)
    const uint8_t* signature = packet.payload + offset;
    offset += ED25519_SIGNATURE_SIZE;

    Serial.printf("ADVERT: sig[0..7]: %02X %02X %02X %02X %02X %02X %02X %02X\n",
                 signature[0], signature[1], signature[2], signature[3],
                 signature[4], signature[5], signature[6], signature[7]);

    // Extract app_data (offset 100, variable) - contains node name
    const uint8_t* appData = packet.payload + offset;
    size_t appDataLen = packet.payloadLen - offset;

    Serial.printf("ADVERT: appDataLen=%d, offset=%d\n", (int)appDataLen, (int)offset);
    if (appDataLen > 0) {
        Serial.printf("ADVERT: appData: ");
        for (size_t i = 0; i < appDataLen && i < 32; i++) {
            Serial.printf("%02X ", appData[i]);
        }
        Serial.println();
    }

    // Verify signature over (pub_key + timestamp + app_data)
    // This is the MeshCore reference format
    // Buffer must fit: pubkey(32) + timestamp(4) + appdata(up to 32) = 68 bytes max
    constexpr size_t MAX_ADVERT_DATA = 32;
    uint8_t signedMessage[PUB_KEY_SIZE + 4 + MAX_ADVERT_DATA];
    size_t msgLen = 0;
    memcpy(signedMessage + msgLen, pubKey, PUB_KEY_SIZE);
    msgLen += PUB_KEY_SIZE;
    memcpy(signedMessage + msgLen, &timestamp, 4);
    msgLen += 4;
    if (appDataLen > 0) {
        size_t copyLen = (appDataLen > MAX_ADVERT_DATA) ? MAX_ADVERT_DATA : appDataLen;
        memcpy(signedMessage + msgLen, appData, copyLen);
        msgLen += copyLen;
    }

    bool sigValid = Identity::verify(signedMessage, msgLen, signature, pubKey);

    // Parse role and name from app_data
    // Format: [flags:1][lat:4?][lon:4?][feat1:2?][feat2:2?][name:variable?]
    // Flags byte:
    //   bits 0-1: role (0x01=chat, 0x02=repeater, 0x03=room)
    //   bit 2 (0x04): sensor
    //   bit 4 (0x10): has location (8 bytes lat+lon follow)
    //   bit 5 (0x20): has feature1 (2 bytes follow)
    //   bit 6 (0x40): has feature2 (2 bytes follow)
    //   bit 7 (0x80): has name (at end)
    const uint8_t* nameData = nullptr;
    size_t nameLen = 0;
    uint8_t role = ROLE_UNKNOWN;
    bool hasLocation = false;
    float latitude = 0.0f;
    float longitude = 0.0f;

    if (appDataLen > 0) {
        uint8_t flags = appData[0];
        size_t dataOffset = 1;  // Skip flags byte

        // Parse role from bits 0-1
        uint8_t roleVal = flags & 0x03;
        switch (roleVal) {
            case 0x01: role = ROLE_CLIENT; break;
            case 0x02: role = ROLE_REPEATER; break;
            case 0x03: role = ROLE_ROUTER; break;
            default: role = ROLE_UNKNOWN; break;
        }
        // Check sensor bit
        if (flags & 0x04) {
            role = ROLE_SENSOR;
        }

        // Extract location if present (8 bytes: lat + lon as int32_le * 1,000,000)
        if ((flags & 0x10) && dataOffset + 8 <= appDataLen) {
            int32_t latRaw, lonRaw;
            memcpy(&latRaw, appData + dataOffset, 4);
            memcpy(&lonRaw, appData + dataOffset + 4, 4);
            latitude = latRaw / 1000000.0f;
            longitude = lonRaw / 1000000.0f;
            hasLocation = true;
            dataOffset += 8;
            Serial.printf("ADVERT: location=%.6f, %.6f\n", latitude, longitude);
        }
        // Skip optional feature1 (2 bytes)
        if (flags & 0x20) {
            dataOffset += 2;
        }
        // Skip optional feature2 (2 bytes)
        if (flags & 0x40) {
            dataOffset += 2;
        }

        // Extract name if present
        if ((flags & 0x80) && dataOffset < appDataLen) {
            nameData = appData + dataOffset;
            nameLen = appDataLen - dataOffset;
        }

        Serial.printf("ADVERT: flags=%02X role=%d hasLoc=%d hasName=%d nameOffset=%d\n",
                     flags, role, hasLocation ? 1 : 0, (flags & 0x80) ? 1 : 0, (int)dataOffset);
    }

    if (nameLen > MAX_NODE_NAME) nameLen = MAX_NODE_NAME;

    // Extract name
    char name[MAX_NODE_NAME + 1];
    if (nameLen > 0) {
        memcpy(name, nameData, nameLen);
    }
    name[nameLen] = '\0';

    const char* roleStr = "unknown";
    switch (role) {
        case ROLE_CLIENT: roleStr = "client"; break;
        case ROLE_REPEATER: roleStr = "repeater"; break;
        case ROLE_ROUTER: roleStr = "room"; break;
        case ROLE_SENSOR: roleStr = "sensor"; break;
    }

    if (!sigValid) {
        Serial.printf("ADVERT from %02X: %s [%s] (sig INVALID)\n", pathHash, name, roleStr);
        // Still add the node but could mark as unverified in the future
    } else {
        Serial.printf("ADVERT from %02X: %s [%s] (verified)\n", pathHash, name, roleStr);
    }

    // Update node info with role, ADVERT timestamp, and location
    updateNode(pathHash, name, pubKey, meta, packet.pathLen, role, timestamp, hasLocation, latitude, longitude);
}

void MeshCore::handleTextPacket(const MeshPacket& packet, const RxMetadata& meta) {
    // Direct text message - handled by Lua DirectMessages service
}

void MeshCore::handleGroupTextPacket(const MeshPacket& packet, const RxMetadata& meta) {
    // Minimum: channel_hash(1) + MAC(2) + one AES block(16) = 19 bytes
    if (packet.payloadLen < 19) {
        Serial.printf("GRP_TXT payload too short: %d bytes\n", packet.payloadLen);
        return;
    }

    uint8_t channelIdx = packet.payload[0];
    const uint8_t* encryptedData = packet.payload + 1;  // MAC + ciphertext
    size_t encryptedLen = packet.payloadLen - 1;

    // Get sender from path (first byte is the originator)
    uint8_t senderHash = packet.pathLen > 0 ? packet.path[0] : 0;

    // Pass to Lua callback for decryption and handling
    if (_onGroupPacket) {
        _onGroupPacket(channelIdx, encryptedData, encryptedLen, senderHash, meta.rssi, meta.snr);
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
            // Use queued send for throttling (respects radio queue)
            RadioResult result = _radio.queueSend(it->data, it->len);
            if (result == RadioResult::OK) {
                _txCount++;
            }
            it = _pendingRebroadcasts.erase(it);
        } else {
            ++it;
        }
    }
}

void MeshCore::scheduleRawRebroadcast(const uint8_t* data, size_t len) {
    if (!data || len == 0 || len > MeshPacket::MAX_SIZE) {
        return;
    }

    PendingRebroadcast rb;
    memcpy(rb.data, data, len);
    rb.len = len;
    rb.sendAt = millis() + random(REBROADCAST_DELAY_MIN, REBROADCAST_DELAY_MAX);
    _pendingRebroadcasts.push_back(rb);
}

// =============================================================================
// Node Management
// =============================================================================

void MeshCore::updateNode(uint8_t pathHash, const char* name, const uint8_t* publicKey,
                          const RxMetadata& meta, uint8_t hops, uint8_t role,
                          uint32_t advertTimestamp, bool hasLocation,
                          float latitude, float longitude) {
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
            // Update role if we got a valid one
            if (role != ROLE_UNKNOWN) {
                node.role = role;
            }
            // Store Unix timestamp from ADVERT if provided
            if (advertTimestamp > 0) {
                node.advertTimestamp = advertTimestamp;
            }
            // Update location if provided
            if (hasLocation) {
                node.hasLocation = true;
                node.latitude = latitude;
                node.longitude = longitude;
            }

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
    node.advertTimestamp = advertTimestamp;
    node.lastRssi = meta.rssi;
    node.lastSnr = meta.snr;
    node.hopCount = hops;
    node.role = role;
    node.hasLocation = hasLocation;
    node.latitude = latitude;
    node.longitude = longitude;

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

    // Use queued send for throttling
    RadioResult result = _radio.queueSend(buffer, len);
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

    // MeshCore ADVERT payload format:
    // [pub_key:32][timestamp:4][signature:64][app_data:variable]
    size_t offset = 0;

    // Public key (offset 0, 32 bytes)
    memcpy(packet.payload + offset, _identity.getPublicKey(), PUB_KEY_SIZE);
    offset += PUB_KEY_SIZE;

    // Timestamp (offset 32, 4 bytes) - use Unix time if available, else uptime
    uint32_t timestamp = millis() / 1000;
    memcpy(packet.payload + offset, &timestamp, 4);
    offset += 4;

    // Build app_data: [flags:1][name:variable]
    // Flags: 0x81 = has_name (0x80) + client role (0x01)
    constexpr size_t MAX_ADVERT_DATA = 32;
    uint8_t appData[MAX_ADVERT_DATA];
    size_t appDataLen = 0;

    // Flags byte: 0x81 = client (0x01) + has name (0x80)
    appData[appDataLen++] = 0x81;

    // Node name
    const char* name = _identity.getNodeName();
    size_t nameLen = strlen(name);
    if (nameLen > MAX_ADVERT_DATA - 1) nameLen = MAX_ADVERT_DATA - 1;
    memcpy(appData + appDataLen, name, nameLen);
    appDataLen += nameLen;

    // Build message to sign: pub_key + timestamp + app_data
    // This is the MeshCore reference format
    uint8_t signedMessage[PUB_KEY_SIZE + 4 + MAX_ADVERT_DATA];
    size_t msgLen = 0;
    memcpy(signedMessage + msgLen, _identity.getPublicKey(), PUB_KEY_SIZE);
    msgLen += PUB_KEY_SIZE;
    memcpy(signedMessage + msgLen, &timestamp, 4);
    msgLen += 4;
    memcpy(signedMessage + msgLen, appData, appDataLen);
    msgLen += appDataLen;

    // Generate signature (offset 36, 64 bytes)
    uint8_t signature[ED25519_SIGNATURE_SIZE];
    if (!_identity.sign(signedMessage, msgLen, signature)) {
        Serial.println("Failed to sign ADVERT");
        return false;
    }
    memcpy(packet.payload + offset, signature, ED25519_SIGNATURE_SIZE);
    offset += ED25519_SIGNATURE_SIZE;

    // App data (offset 100, variable)
    memcpy(packet.payload + offset, appData, appDataLen);
    offset += appDataLen;

    packet.payloadLen = offset;

    Serial.printf("Sending ADVERT (pathHash=%02X, name=%s, %d bytes)\n",
                  _identity.getPathHash(), name, (int)offset);
    return sendPacket(packet);
}

bool MeshCore::sendGroupPacket(uint8_t channelHash, const uint8_t* encryptedData, size_t dataLen) {
    if (!encryptedData || dataLen == 0) {
        return false;
    }

    // Build packet: [channel_hash:1][encrypted_data]
    MeshPacket packet;
    packet.clear();
    packet.header = makeHeader(RouteType::FLOOD, PayloadType::GRP_TXT, PayloadVersion::V1);

    if (1 + dataLen > MAX_PACKET_PAYLOAD) {
        Serial.println("sendGroupPacket: data too large");
        return false;
    }

    packet.payload[0] = channelHash;
    memcpy(packet.payload + 1, encryptedData, dataLen);
    packet.payloadLen = 1 + dataLen;

    Serial.printf("Sending raw GRP_TXT (hash=%02X, %d bytes)\n", channelHash, (int)dataLen);
    return sendPacket(packet);
}

