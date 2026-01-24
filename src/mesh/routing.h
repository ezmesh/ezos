#pragma once

#include <cstdint>
#include <array>
#include "packet.h"
#include "../config.h"

// Router handles packet deduplication and rebroadcast decisions
// MeshCore uses path-based deduplication - if our hash is in the path, we've seen it
class Router {
public:
    Router();
    ~Router() = default;

    // Check if packet should be rebroadcast (flood routing)
    // Returns false if: our hash already in path, or max path length reached
    bool shouldRebroadcast(const MeshPacket& packet, uint8_t ourPathHash);

    // Calculate random rebroadcast delay to avoid collisions
    uint32_t getRebroadcastDelay() const;

    // Clear state
    void reset();

    // Statistics
    uint32_t getDuplicateCount() const { return _duplicateCount; }
    uint32_t getRebroadcastCount() const { return _rebroadcastCount; }

private:
    // Statistics
    uint32_t _duplicateCount = 0;
    uint32_t _rebroadcastCount = 0;
};
