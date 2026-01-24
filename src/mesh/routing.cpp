#include "routing.h"
#include <Arduino.h>

Router::Router() {
    reset();
}

bool Router::shouldRebroadcast(const MeshPacket& packet, uint8_t ourPathHash) {
    // Only FLOOD packets should be rebroadcast
    uint8_t routeType = packet.getRouteType();
    if (routeType != RouteType::FLOOD && routeType != RouteType::TRANSPORT_FLOOD) {
        return false;
    }

    // If our hash is already in the path, we've seen this packet (don't rebroadcast)
    if (packet.isInPath(ourPathHash)) {
        _duplicateCount++;
        return false;
    }

    // Check if path would exceed maximum length
    if (packet.pathLen >= MAX_PATH_SIZE - 1) {
        return false;
    }

    _rebroadcastCount++;
    return true;
}

uint32_t Router::getRebroadcastDelay() const {
    // Random delay between min and max to avoid collisions
    return random(MESHCORE_REBROADCAST_DELAY_MIN, MESHCORE_REBROADCAST_DELAY_MAX);
}

void Router::reset() {
    _duplicateCount = 0;
    _rebroadcastCount = 0;
}
