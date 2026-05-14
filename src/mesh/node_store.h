// Persistence layer for the MeshCore known-nodes table.
//
// The MeshCore in-memory _nodes vector lives only for the current boot.
// Without persistence, a cold boot starts with an empty list and the
// Map screen / "browse nodes" UI shows only the local marker until the
// next ADVERT round (which on a quiet mesh can be 15+ minutes per peer).
//
// NodeStore writes the list to /sd/nodes.bin (SD) or NVS blob (fallback
// when no SD is present), debounced by the caller, with a 7-day age cap
// matching STALE_HIDE_AGE in lua/screens/tools/map.lua.
//
// Persisted fields are intentionally a subset of NodeInfo: routing
// metrics (lastRssi/lastSnr/hopCount) describe the most recent received
// packet, not the node, so reloading them across a reboot would just be
// stale noise. They are re-derived from the next ADVERT instead.
#pragma once

#include <vector>
#include <cstdint>

struct NodeInfo;

class NodeStore {
public:
    // SD path (preferred). Survives NVS factory-reset and scales further.
    static constexpr const char* kSdPath = "/sd/nodes.bin";

    // NVS fallback location -- single blob in the existing "meshcore"
    // namespace so factory reset wipes it alongside the identity keys.
    static constexpr const char* kNvsNamespace = "meshcore";
    static constexpr const char* kNvsKey = "nodes";

    // 7 days, matches STALE_HIDE_AGE in lua/screens/tools/map.lua.
    static constexpr uint32_t kMaxAgeSeconds = 7 * 24 * 60 * 60;

    // Storage caps. SD has room for many more, but 128 covers the
    // realistic radius for a single radio and keeps the blob small
    // enough to write atomically. NVS is intentionally tighter because
    // every save rewrites the whole blob and NVS wear-levels per entry.
    static constexpr size_t kSdMaxNodes = 128;
    static constexpr size_t kNvsMaxNodes = 64;

    // File format magic + version. Bump version on any layout change so
    // older firmware loading a newer blob fails fast rather than
    // misinterpreting fields.
    static constexpr uint32_t kMagic = 0x534E5A45;  // 'EZNS'
    static constexpr uint16_t kVersion = 1;

    NodeStore() = default;

    // Populate `nodes` from disk. Aging (>7d) is dropped at load time.
    // `lastSeen` is re-stamped relative to the current millis() so age
    // calculations downstream stay sane; if the device clock is not yet
    // synced (time(NULL) returns < 2020), the persisted lastSeenUnix is
    // trusted as-is and lastSeen is pushed maximally into the past.
    // Returns true on a successful load (even if zero nodes), false if
    // no store exists or the file is corrupt.
    bool load(std::vector<NodeInfo>& nodes);

    // Write the current node list. Returns false on I/O failure.
    // If the list exceeds the active backend's cap, the oldest entries
    // by lastSeenUnix are evicted from the *written* set; the in-memory
    // vector is left untouched (the caller may choose to prune it).
    bool save(const std::vector<NodeInfo>& nodes);

private:
    // Which backend save()/load() last picked. Set by chooseBackend().
    enum class Backend { Sd, Nvs };

    static Backend chooseBackend();

    static bool loadFromSd(std::vector<NodeInfo>& nodes);
    static bool loadFromNvs(std::vector<NodeInfo>& nodes);
    static bool saveToSd(const std::vector<NodeInfo>& nodes);
    static bool saveToNvs(const std::vector<NodeInfo>& nodes);

    // Shared (de)serialisation: writes/reads the binary format into a
    // contiguous byte buffer so both backends can reuse the same layout.
    static std::vector<uint8_t> serialize(const std::vector<NodeInfo>& nodes,
                                          size_t cap);
    static bool deserialize(const uint8_t* data, size_t len,
                            std::vector<NodeInfo>& outNodes);
};
