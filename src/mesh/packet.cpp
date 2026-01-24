#include "packet.h"
#include <cstring>
#include <Arduino.h>

void MeshPacket::clear() {
    header = 0;
    transportCodes[0] = 0;
    transportCodes[1] = 0;
    pathLen = 0;
    memset(path, 0, sizeof(path));
    payloadLen = 0;
    memset(payload, 0, sizeof(payload));
}

size_t MeshPacket::serialize(uint8_t* buffer, size_t maxLen) const {
    size_t offset = 0;

    // Header byte
    if (offset >= maxLen) return 0;
    buffer[offset++] = header;

    // Transport codes (optional, 4 bytes if present)
    if (hasTransportCodes()) {
        if (offset + 4 > maxLen) return 0;
        buffer[offset++] = transportCodes[0] & 0xFF;
        buffer[offset++] = (transportCodes[0] >> 8) & 0xFF;
        buffer[offset++] = transportCodes[1] & 0xFF;
        buffer[offset++] = (transportCodes[1] >> 8) & 0xFF;
    }

    // Path length (1 byte)
    if (offset >= maxLen) return 0;
    buffer[offset++] = pathLen;

    // Path data
    if (pathLen > 0) {
        if (offset + pathLen > maxLen) return 0;
        memcpy(buffer + offset, path, pathLen);
        offset += pathLen;
    }

    // Payload data
    if (payloadLen > 0) {
        if (offset + payloadLen > maxLen) return 0;
        memcpy(buffer + offset, payload, payloadLen);
        offset += payloadLen;
    }

    return offset;
}

size_t MeshPacket::deserialize(const uint8_t* buffer, size_t len) {
    if (len < 2) {
        return 0;  // Minimum: header + path_len
    }

    clear();
    size_t offset = 0;

    // Header byte
    header = buffer[offset++];

    // Transport codes (optional)
    if (hasTransportCodes()) {
        if (offset + 4 > len) return 0;
        transportCodes[0] = buffer[offset] | (buffer[offset + 1] << 8);
        offset += 2;
        transportCodes[1] = buffer[offset] | (buffer[offset + 1] << 8);
        offset += 2;
    }

    // Path length
    if (offset >= len) return 0;
    pathLen = buffer[offset++];

    // Validate path length
    if (pathLen > MAX_PATH_SIZE) {
        Serial.printf("Path too long: %d > %d\n", pathLen, MAX_PATH_SIZE);
        return 0;
    }

    // Path data
    if (pathLen > 0) {
        if (offset + pathLen > len) return 0;
        memcpy(path, buffer + offset, pathLen);
        offset += pathLen;
    }

    // Remaining bytes are payload
    payloadLen = len - offset;
    if (payloadLen > MAX_PACKET_PAYLOAD) {
        Serial.printf("Payload too long: %d > %d\n", payloadLen, MAX_PACKET_PAYLOAD);
        return 0;
    }

    if (payloadLen > 0) {
        memcpy(payload, buffer + offset, payloadLen);
        offset += payloadLen;
    }

    return offset;
}

bool MeshPacket::isValid() const {
    // Check route type is valid
    uint8_t rt = getRouteType();
    if (rt > RouteType::TRANSPORT_DIRECT) return false;

    // Check payload type is valid (0x00-0x0F)
    uint8_t pt = getPayloadType();
    if (pt > 0x0F) return false;

    // Check path length
    if (pathLen > MAX_PATH_SIZE) return false;

    // Check payload length
    if (payloadLen > MAX_PACKET_PAYLOAD) return false;

    return true;
}

bool MeshPacket::addToPath(uint8_t nodeHash) {
    if (pathLen >= MAX_PATH_SIZE) {
        return false;
    }
    path[pathLen++] = nodeHash;
    return true;
}

bool MeshPacket::isInPath(uint8_t nodeHash) const {
    for (size_t i = 0; i < pathLen; i++) {
        if (path[i] == nodeHash) {
            return true;
        }
    }
    return false;
}
