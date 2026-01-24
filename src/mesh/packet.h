#pragma once

#include <cstdint>
#include <cstddef>
#include "../config.h"

// MeshCore protocol constants
constexpr size_t MAX_PATH_SIZE = 64;
constexpr size_t MAX_PACKET_PAYLOAD = 184;
constexpr size_t PATH_HASH_SIZE = 1;      // 1-byte node hash in paths
constexpr size_t PUB_KEY_SIZE = 32;       // Ed25519 public key size

// Route types (bits 0-1 of header)
namespace RouteType {
    constexpr uint8_t TRANSPORT_FLOOD = 0x00;
    constexpr uint8_t FLOOD = 0x01;
    constexpr uint8_t DIRECT = 0x02;
    constexpr uint8_t TRANSPORT_DIRECT = 0x03;
}

// Payload types (bits 2-5 of header)
namespace PayloadType {
    constexpr uint8_t REQ = 0x00;
    constexpr uint8_t RESPONSE = 0x01;
    constexpr uint8_t TXT_MSG = 0x02;
    constexpr uint8_t ACK = 0x03;
    constexpr uint8_t ADVERT = 0x04;
    constexpr uint8_t GRP_TXT = 0x05;      // Group/channel text message
    constexpr uint8_t GRP_DATA = 0x06;     // Group/channel data
    constexpr uint8_t ANON_REQ = 0x07;
    constexpr uint8_t PATH = 0x08;
    constexpr uint8_t TRACE = 0x09;
    constexpr uint8_t MULTIPART = 0x0A;
    constexpr uint8_t CONTROL = 0x0B;
    constexpr uint8_t RAW_CUSTOM = 0x0F;
}

// Payload versions (bits 6-7 of header)
namespace PayloadVersion {
    constexpr uint8_t V1 = 0x00;
    constexpr uint8_t V2 = 0x01;
    constexpr uint8_t V3 = 0x02;
    constexpr uint8_t V4 = 0x03;
}

// Header bit masks and shifts
constexpr uint8_t PH_ROUTE_MASK = 0x03;
constexpr uint8_t PH_TYPE_SHIFT = 2;
constexpr uint8_t PH_TYPE_MASK = 0x0F;
constexpr uint8_t PH_VER_SHIFT = 6;
constexpr uint8_t PH_VER_MASK = 0x03;

// Build header byte from components
inline uint8_t makeHeader(uint8_t route, uint8_t type, uint8_t version = PayloadVersion::V1) {
    return (route & PH_ROUTE_MASK) |
           ((type & PH_TYPE_MASK) << PH_TYPE_SHIFT) |
           ((version & PH_VER_MASK) << PH_VER_SHIFT);
}

// MeshCore packet structure
// Wire format: [Header(1)] [TransportCodes(4)?] [PathLen(1)] [Path(var)] [Payload(var)]
struct MeshPacket {
    uint8_t header;                          // Route + Type + Version
    uint16_t transportCodes[2];              // Optional transport codes
    uint8_t pathLen;                         // Length of path
    uint8_t path[MAX_PATH_SIZE];             // Node hashes for routing
    uint16_t payloadLen;                     // Payload length
    uint8_t payload[MAX_PACKET_PAYLOAD];     // Message payload

    // Maximum total packet size
    static constexpr size_t MAX_SIZE = 1 + 4 + 1 + MAX_PATH_SIZE + MAX_PACKET_PAYLOAD;

    // Extract header components
    uint8_t getRouteType() const { return header & PH_ROUTE_MASK; }
    uint8_t getPayloadType() const { return (header >> PH_TYPE_SHIFT) & PH_TYPE_MASK; }
    uint8_t getVersion() const { return (header >> PH_VER_SHIFT) & PH_VER_MASK; }

    // Set header components
    void setRouteType(uint8_t route) {
        header = (header & ~PH_ROUTE_MASK) | (route & PH_ROUTE_MASK);
    }
    void setPayloadType(uint8_t type) {
        header = (header & ~(PH_TYPE_MASK << PH_TYPE_SHIFT)) | ((type & PH_TYPE_MASK) << PH_TYPE_SHIFT);
    }
    void setVersion(uint8_t ver) {
        header = (header & ~(PH_VER_MASK << PH_VER_SHIFT)) | ((ver & PH_VER_MASK) << PH_VER_SHIFT);
    }

    // Check if transport codes are present
    bool hasTransportCodes() const {
        uint8_t rt = getRouteType();
        return rt == RouteType::TRANSPORT_FLOOD || rt == RouteType::TRANSPORT_DIRECT;
    }

    // Serialize packet to buffer (returns total size, 0 on error)
    size_t serialize(uint8_t* buffer, size_t maxLen) const;

    // Deserialize packet from buffer (returns bytes consumed, 0 on error)
    size_t deserialize(const uint8_t* buffer, size_t len);

    // Check if packet is valid
    bool isValid() const;

    // Clear/initialize packet
    void clear();

    // Add a node hash to the path (for flood routing)
    bool addToPath(uint8_t nodeHash);

    // Check if a node hash is already in the path
    bool isInPath(uint8_t nodeHash) const;
};
