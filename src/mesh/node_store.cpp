#include "node_store.h"
#include "meshcore.h"
#include "../hardware/sd_manager.h"

#include <Arduino.h>
#include <Preferences.h>
#include <SD.h>
#include <FS.h>

#include <algorithm>
#include <cstring>
#include <ctime>

namespace {

// time(NULL) returns seconds since 1970 from the system clock. Before
// NTP/GPS sync, the clock sits in 1970 (tm_year < 70 / 120). We treat
// "year >= 2020" as the threshold for a trustworthy unix time, matching
// l_system_get_time_unix in src/lua/bindings/system_bindings.cpp.
uint32_t currentUnixOrZero() {
    time_t now;
    time(&now);
    struct tm tinfo;
    gmtime_r(&now, &tinfo);
    if (tinfo.tm_year < 120) return 0;
    return static_cast<uint32_t>(now);
}

// Little-endian writers/readers. ESP32 is LE so memcpy would work, but
// going through these makes the on-disk format endian-independent
// should the codebase ever move.
void writeU16(std::vector<uint8_t>& buf, uint16_t v) {
    buf.push_back(v & 0xFF);
    buf.push_back((v >> 8) & 0xFF);
}
void writeU32(std::vector<uint8_t>& buf, uint32_t v) {
    buf.push_back(v & 0xFF);
    buf.push_back((v >> 8) & 0xFF);
    buf.push_back((v >> 16) & 0xFF);
    buf.push_back((v >> 24) & 0xFF);
}
void writeF32(std::vector<uint8_t>& buf, float f) {
    uint32_t u;
    std::memcpy(&u, &f, sizeof(u));
    writeU32(buf, u);
}

bool readU16(const uint8_t*& p, const uint8_t* end, uint16_t& out) {
    if (end - p < 2) return false;
    out = uint16_t(p[0]) | (uint16_t(p[1]) << 8);
    p += 2;
    return true;
}
bool readU32(const uint8_t*& p, const uint8_t* end, uint32_t& out) {
    if (end - p < 4) return false;
    out = uint32_t(p[0]) | (uint32_t(p[1]) << 8) |
          (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
    p += 4;
    return true;
}
bool readF32(const uint8_t*& p, const uint8_t* end, float& out) {
    uint32_t u;
    if (!readU32(p, end, u)) return false;
    std::memcpy(&out, &u, sizeof(out));
    return true;
}

}  // namespace

NodeStore::Backend NodeStore::chooseBackend() {
    // ensureMounted() is cheap when the card is already up; on a device
    // booted without SD it returns false on first call and we fall back
    // to NVS. The decision is re-made on every save/load to handle
    // late-insert (the SD takes precedence the moment it appears).
    return SDManager::ensureMounted() ? Backend::Sd : Backend::Nvs;
}

std::vector<uint8_t> NodeStore::serialize(const std::vector<NodeInfo>& nodes,
                                          size_t cap) {
    // Header: [magic:4][version:2][count:2]
    // Per node:
    //   [pathHash:1][role:1][flags:1][nameLen:1]
    //   [advertTimestamp:4][lastSeenUnix:4]
    //   [pubKey:32 if hasPublicKey, else absent]
    //   [lat:4][lon:4 if hasLocation, else absent]
    //   [name:nameLen]
    //
    // flags bit 0 = hasPublicKey, bit 1 = hasLocation. Variable-size
    // sections keyed off flags keep the per-node footprint small for
    // the common case (NVS-friendly).

    // Build a working copy of indices sorted newest-first by lastSeen
    // (local millis() observation time), so the truncation step keeps
    // the entries we heard most recently. Deliberately not sorted by
    // advertTimestamp: that field is peer-chosen and a node with a
    // future-dated or wrap-around ADVERT would always survive
    // truncation over genuinely-fresh local observations.
    std::vector<size_t> idx;
    idx.reserve(nodes.size());
    for (size_t i = 0; i < nodes.size(); ++i) idx.push_back(i);
    std::sort(idx.begin(), idx.end(),
              [&](size_t a, size_t b) {
                  return nodes[a].lastSeen > nodes[b].lastSeen;
              });
    if (idx.size() > cap) idx.resize(cap);

    std::vector<uint8_t> buf;
    buf.reserve(8 + idx.size() * 64);

    writeU32(buf, kMagic);
    writeU16(buf, kVersion);
    writeU16(buf, static_cast<uint16_t>(idx.size()));

    uint32_t nowUnix = currentUnixOrZero();

    for (size_t k : idx) {
        const NodeInfo& n = nodes[k];

        uint8_t flags = 0;
        if (n.hasPublicKey) flags |= 0x01;
        if (n.hasLocation)  flags |= 0x02;

        uint8_t nameLen = static_cast<uint8_t>(strnlen(n.name, MAX_NODE_NAME));

        // lastSeenUnix is derived from "how long ago lastSeen was" in
        // millis() and the current wall clock. If the wall clock is
        // unset, we still want a coherent ordering across this single
        // save batch, so use advertTimestamp as the fallback (it's the
        // best lower bound for "the node existed at unix t").
        uint32_t lastSeenUnix = 0;
        if (nowUnix > 0) {
            uint32_t ageMs = millis() - n.lastSeen;
            uint32_t ageSec = ageMs / 1000;
            lastSeenUnix = (nowUnix > ageSec) ? (nowUnix - ageSec) : 0;
        } else {
            lastSeenUnix = n.advertTimestamp;
        }

        buf.push_back(n.pathHash);
        buf.push_back(n.role);
        buf.push_back(flags);
        buf.push_back(nameLen);
        writeU32(buf, n.advertTimestamp);
        writeU32(buf, lastSeenUnix);
        if (n.hasPublicKey) {
            buf.insert(buf.end(), n.publicKey,
                       n.publicKey + ED25519_PUBLIC_KEY_SIZE);
        }
        if (n.hasLocation) {
            writeF32(buf, n.latitude);
            writeF32(buf, n.longitude);
        }
        if (nameLen > 0) {
            buf.insert(buf.end(),
                       reinterpret_cast<const uint8_t*>(n.name),
                       reinterpret_cast<const uint8_t*>(n.name) + nameLen);
        }
    }

    return buf;
}

bool NodeStore::deserialize(const uint8_t* data, size_t len,
                            std::vector<NodeInfo>& outNodes) {
    const uint8_t* p = data;
    const uint8_t* end = data + len;

    uint32_t magic = 0;
    uint16_t version = 0;
    uint16_t count = 0;
    if (!readU32(p, end, magic)) return false;
    if (magic != kMagic) return false;
    if (!readU16(p, end, version)) return false;
    if (version != kVersion) return false;
    if (!readU16(p, end, count)) return false;

    uint32_t nowUnix = currentUnixOrZero();
    uint32_t nowMs = millis();

    outNodes.clear();
    outNodes.reserve(count);

    for (uint16_t i = 0; i < count; ++i) {
        if (end - p < 12) return false;
        uint8_t pathHash = *p++;
        uint8_t role     = *p++;
        uint8_t flags    = *p++;
        uint8_t nameLen  = *p++;

        uint32_t advertTimestamp = 0;
        uint32_t lastSeenUnix = 0;
        if (!readU32(p, end, advertTimestamp)) return false;
        if (!readU32(p, end, lastSeenUnix)) return false;

        NodeInfo node{};
        node.pathHash = pathHash;
        node.role = role;
        node.advertTimestamp = advertTimestamp;
        node.hasPublicKey = (flags & 0x01) != 0;
        node.hasLocation  = (flags & 0x02) != 0;
        // Routing metrics describe the last packet, not the node;
        // explicitly zero them so callers don't see stale numbers
        // from before the reboot. The next ADVERT will refill them.
        node.lastRssi = 0.0f;
        node.lastSnr  = 0.0f;
        node.hopCount = 0;

        if (node.hasPublicKey) {
            if (end - p < (int)ED25519_PUBLIC_KEY_SIZE) return false;
            std::memcpy(node.publicKey, p, ED25519_PUBLIC_KEY_SIZE);
            p += ED25519_PUBLIC_KEY_SIZE;
        } else {
            std::memset(node.publicKey, 0, ED25519_PUBLIC_KEY_SIZE);
        }

        if (node.hasLocation) {
            if (!readF32(p, end, node.latitude)) return false;
            if (!readF32(p, end, node.longitude)) return false;
        } else {
            node.latitude = 0.0f;
            node.longitude = 0.0f;
        }

        if (end - p < nameLen) return false;
        size_t copy = nameLen;
        if (copy > MAX_NODE_NAME) copy = MAX_NODE_NAME;
        if (copy > 0) std::memcpy(node.name, p, copy);
        node.name[copy] = '\0';
        // Names originate in peer-sent ADVERTs and may contain bytes
        // outside printable ASCII. The on-device bitmap fonts only
        // render 0x20..0x7E; anything else shows up as a `[]` glyph
        // box on the Map screen / node browser. Replace at the
        // deserialise boundary so a hand-edited blob or an older-
        // firmware save can't poison the rendering pipeline. (The
        // same fix at the updateNode() seam would catch live ADVERTs
        // too -- out of scope for this change.)
        for (size_t i = 0; i < copy; i++) {
            uint8_t b = static_cast<uint8_t>(node.name[i]);
            if (b < 0x20 || b > 0x7E) node.name[i] = '?';
        }
        if (nameLen == 0) {
            // Synthesise a name from the path hash, matching the
            // updateNode() fallback so downstream code doesn't trip on
            // empty names.
            snprintf(node.name, MAX_NODE_NAME, "%02X", pathHash);
        }
        p += nameLen;

        // Aging: drop entries older than 7 days. Only enforceable when
        // the wall clock is trustworthy; if it isn't, keep everything
        // and let the next save (which will likely have a synced clock)
        // do the eviction.
        if (nowUnix > 0 && lastSeenUnix > 0 &&
            nowUnix > lastSeenUnix &&
            (nowUnix - lastSeenUnix) > kMaxAgeSeconds) {
            continue;
        }

        // Re-stamp lastSeen as a millis() value far enough in the past
        // to reflect the persisted unix age. Clamp at "0 millis() of
        // this boot" to avoid wrap-around or future-dated values.
        if (nowUnix > 0 && lastSeenUnix > 0 && lastSeenUnix <= nowUnix) {
            uint32_t ageSec = nowUnix - lastSeenUnix;
            uint64_t ageMs64 = uint64_t(ageSec) * 1000ULL;
            if (ageMs64 > nowMs) {
                node.lastSeen = 0;
            } else {
                node.lastSeen = nowMs - static_cast<uint32_t>(ageMs64);
            }
        } else {
            // No usable wall clock: push lastSeen to the start of this
            // boot. Age will then be reported as "uptime", which is the
            // best honest answer we can give.
            node.lastSeen = 0;
        }

        outNodes.push_back(node);
    }

    return true;
}

// -----------------------------------------------------------------------------
// SD backend
// -----------------------------------------------------------------------------

bool NodeStore::loadFromSd(std::vector<NodeInfo>& nodes) {
    SDManager::ScopedLock lk;
    if (!SD.exists(kSdPath)) return false;
    File f = SDManager::openWithRetry(&SD, kSdPath, FILE_READ);
    if (!f) return false;

    size_t sz = f.size();
    if (sz == 0 || sz > 64 * 1024) {  // sanity cap
        f.close();
        return false;
    }
    std::vector<uint8_t> buf(sz);
    size_t read = f.read(buf.data(), sz);
    f.close();
    if (read != sz) return false;

    return deserialize(buf.data(), sz, nodes);
}

bool NodeStore::saveToSd(const std::vector<NodeInfo>& nodes) {
    SDManager::ScopedLock lk;
    auto buf = serialize(nodes, kSdMaxNodes);

    // Write to a tmp file then rename to make the swap atomic. A
    // power loss mid-write only loses the *previous* save, never
    // corrupts the active blob.
    const char* tmpPath = "/sd/nodes.bin.tmp";
    File f = SDManager::openWithRetry(&SD, tmpPath, FILE_WRITE);
    if (!f) return false;
    size_t wrote = f.write(buf.data(), buf.size());
    f.close();
    if (wrote != buf.size()) {
        SD.remove(tmpPath);
        return false;
    }

    // SD.rename() on FAT cannot overwrite an existing file; remove the
    // target first, then rename the tmp into place.
    if (SD.exists(kSdPath)) SD.remove(kSdPath);
    if (!SD.rename(tmpPath, kSdPath)) {
        SD.remove(tmpPath);
        return false;
    }
    return true;
}

// -----------------------------------------------------------------------------
// NVS backend
// -----------------------------------------------------------------------------

bool NodeStore::loadFromNvs(std::vector<NodeInfo>& nodes) {
    Preferences prefs;
    if (!prefs.begin(kNvsNamespace, true)) return false;
    size_t sz = prefs.getBytesLength(kNvsKey);
    if (sz == 0) { prefs.end(); return false; }
    std::vector<uint8_t> buf(sz);
    size_t got = prefs.getBytes(kNvsKey, buf.data(), sz);
    prefs.end();
    if (got != sz) return false;
    return deserialize(buf.data(), sz, nodes);
}

bool NodeStore::saveToNvs(const std::vector<NodeInfo>& nodes) {
    auto buf = serialize(nodes, kNvsMaxNodes);
    Preferences prefs;
    if (!prefs.begin(kNvsNamespace, false)) return false;
    size_t wrote = prefs.putBytes(kNvsKey, buf.data(), buf.size());
    prefs.end();
    return wrote == buf.size();
}

// -----------------------------------------------------------------------------
// Public API
// -----------------------------------------------------------------------------

bool NodeStore::load(std::vector<NodeInfo>& nodes) {
    switch (chooseBackend()) {
        case Backend::Sd:
            if (loadFromSd(nodes)) return true;
            // SD present but no file (or corrupt) -- try NVS in case
            // the user moved from NVS-only to SD without copying.
            return loadFromNvs(nodes);
        case Backend::Nvs:
        default:
            return loadFromNvs(nodes);
    }
}

bool NodeStore::save(const std::vector<NodeInfo>& nodes) {
    switch (chooseBackend()) {
        case Backend::Sd:  return saveToSd(nodes);
        case Backend::Nvs:
        default:           return saveToNvs(nodes);
    }
}
