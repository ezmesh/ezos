// ez.mesh module bindings
// Provides mesh networking functions

#include "../lua_bindings.h"
#include "../../mesh/meshcore.h"
#include "../../mesh/identity.h"
#include "bus_bindings.h"
#include <deque>

// External reference to the global mesh instance
extern MeshCore* mesh;

// Flag indicating whether mesh bus events are set up
static bool meshBusEventsEnabled = false;

// Helper: Convert public key bytes to hex string
static void pubKeyToHexStr(const uint8_t* pubKey, char* hexOut) {
    for (int i = 0; i < ED25519_PUBLIC_KEY_SIZE; i++) {
        sprintf(&hexOut[i * 2], "%02X", pubKey[i]);
    }
    hexOut[ED25519_PUBLIC_KEY_SIZE * 2] = '\0';
}

// Packet queue for polling-based access (avoids callback complexity)
struct QueuedPacket {
    uint8_t routeType;
    uint8_t payloadType;
    uint8_t version;
    std::vector<uint8_t> path;
    std::vector<uint8_t> payload;
    float rssi;
    float snr;
    uint32_t timestamp;
};
static std::deque<QueuedPacket> packetQueue;
static constexpr size_t MAX_PACKET_QUEUE = 32;
static bool packetQueueEnabled = false;

// @lua ez.mesh.is_initialized() -> boolean
// @brief Check if mesh networking is initialized
// @description Returns whether the MeshCore networking stack has been initialized
// and is ready to send/receive packets. Check this before calling other mesh functions.
// @return true if mesh is ready
// @example
// if ez.mesh.is_initialized() then
//     local nodes = ez.mesh.get_nodes()
// end
// @end
LUA_FUNCTION(l_mesh_is_initialized) {
    lua_pushboolean(L, mesh != nullptr);
    return 1;
}

// @lua ez.mesh.update()
// @brief Process incoming mesh packets
// @description Processes any pending radio packets, updates node discovery state,
// triggers callbacks for received messages, and handles packet rebroadcasting.
// Should be called frequently (at least every 50ms) for responsive mesh communication.
// @note Call this regularly in your main loop to receive messages
// @example
// -- In main loop
// ez.mesh.update()
// @end
LUA_FUNCTION(l_mesh_update) {
    if (mesh) {
        mesh->update();
    }
    return 0;
}

// @lua ez.mesh.get_node_id() -> string
// @brief Get this node's full ID
// @description Returns this node's unique identifier derived from its Ed25519 public key.
// The ID is the first 6 bytes of the SHA-256 hash of the public key, displayed as hex.
// @return 12-character hex string (6 bytes), or nil if mesh not initialized
// @example
// local id = ez.mesh.get_node_id()  -- e.g., "A1B2C3D4E5F6"
// @end
LUA_FUNCTION(l_mesh_get_node_id) {
    if (!mesh) {
        lua_pushnil(L);
        return 1;
    }

    char id[17];
    mesh->getIdentity().getFullId(id);
    lua_pushstring(L, id);
    return 1;
}

// @lua ez.mesh.get_short_id() -> string
// @brief Get this node's short ID
// @description Returns an abbreviated node identifier for display purposes. This is
// the first 3 bytes of the full node ID, providing a shorter but less unique identifier.
// @return 6-character hex string (3 bytes), or nil if mesh not initialized
// @example
// local short = ez.mesh.get_short_id()  -- e.g., "A1B2C3"
// @end
LUA_FUNCTION(l_mesh_get_short_id) {
    if (!mesh) {
        lua_pushnil(L);
        return 1;
    }

    char id[8];
    mesh->getIdentity().getShortId(id);
    lua_pushstring(L, id);
    return 1;
}

// @lua ez.mesh.get_node_name() -> string
// @brief Get this node's display name
// @description Returns the human-readable name configured for this node. This name
// is broadcast in ADVERT packets and displayed to other mesh users.
// @return Node name string, or nil if mesh not initialized
// @example
// local name = ez.mesh.get_node_name()  -- e.g., "Alice's T-Deck"
// @end
LUA_FUNCTION(l_mesh_get_node_name) {
    if (!mesh) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushstring(L, mesh->getIdentity().getNodeName());
    return 1;
}

// @lua ez.mesh.set_node_name(name) -> boolean
// @brief Set this node's display name
// @description Sets the human-readable name for this node. The name is stored in NVS
// and broadcast to other nodes in ADVERT packets. Limited to 32 characters.
// @param name New node name
// @return true if successful
// @example
// ez.mesh.set_node_name("Bob's T-Deck")
// @end
LUA_FUNCTION(l_mesh_set_node_name) {
    LUA_CHECK_ARGC(L, 1);
    const char* name = luaL_checkstring(L, 1);

    if (!mesh) {
        lua_pushboolean(L, false);
        return 1;
    }

    // Need non-const access to identity - cast away const
    Identity& identity = const_cast<Identity&>(mesh->getIdentity());
    bool ok = identity.setNodeName(name);
    lua_pushboolean(L, ok);
    return 1;
}

// Helper function to convert public key bytes to hex string (alias for compatibility)
#define pubKeyToHex pubKeyToHexStr

// @lua ez.mesh.get_nodes() -> table
// @brief Get list of discovered mesh nodes
// @description Returns an array of all nodes discovered via ADVERT packets. Each node
// table contains routing information, signal quality, and optional location data.
// Nodes are considered stale after ~5 minutes without a new ADVERT.
// @return Array of node tables with path_hash, name, rssi, snr, last_seen, hops, role, age_seconds, advert_timestamp, pub_key_hex (optional), has_location, lat, lon (if has_location)
// @example
// for _, node in ipairs(ez.mesh.get_nodes()) do
//     print(node.name, node.rssi .. "dBm", node.hops .. " hops")
// end
// @end
LUA_FUNCTION(l_mesh_get_nodes) {
    if (!mesh) {
        lua_newtable(L);
        return 1;
    }

    const auto& nodes = mesh->getNodes();
    lua_createtable(L, nodes.size(), 0);

    int idx = 1;
    for (const auto& node : nodes) {
        lua_newtable(L);

        lua_pushinteger(L, node.pathHash);
        lua_setfield(L, -2, "path_hash");

        lua_pushstring(L, node.name);
        lua_setfield(L, -2, "name");

        lua_pushnumber(L, node.lastRssi);
        lua_setfield(L, -2, "rssi");

        lua_pushnumber(L, node.lastSnr);
        lua_setfield(L, -2, "snr");

        lua_pushinteger(L, node.lastSeen);
        lua_setfield(L, -2, "last_seen");

        lua_pushinteger(L, node.hopCount);
        lua_setfield(L, -2, "hops");

        lua_pushinteger(L, node.role);
        lua_setfield(L, -2, "role");

        // Calculate age in seconds
        uint32_t age = (millis() - node.lastSeen) / 1000;
        lua_pushinteger(L, age);
        lua_setfield(L, -2, "age_seconds");

        // Unix timestamp from ADVERT packet (for time sync)
        lua_pushinteger(L, node.advertTimestamp);
        lua_setfield(L, -2, "advert_timestamp");

        // Public key as hex string (if available)
        if (node.hasPublicKey) {
            char hexKey[ED25519_PUBLIC_KEY_SIZE * 2 + 1];
            pubKeyToHex(node.publicKey, hexKey);
            lua_pushstring(L, hexKey);
            lua_setfield(L, -2, "pub_key_hex");
        }

        // Location (if available)
        lua_pushboolean(L, node.hasLocation);
        lua_setfield(L, -2, "has_location");
        if (node.hasLocation) {
            lua_pushnumber(L, node.latitude);
            lua_setfield(L, -2, "lat");
            lua_pushnumber(L, node.longitude);
            lua_setfield(L, -2, "lon");
        }

        lua_rawseti(L, -2, idx++);
    }

    return 1;
}

// @lua ez.mesh.get_node_count() -> integer
// @brief Get number of known nodes
// @description Returns the count of nodes in the discovery table. This is faster
// than getting the full node list when you only need the count.
// @return Node count
// @example
// local count = ez.mesh.get_node_count()
// print("Discovered " .. count .. " nodes")
// @end
LUA_FUNCTION(l_mesh_get_node_count) {
    int count = mesh ? mesh->getNodes().size() : 0;
    lua_pushinteger(L, count);
    return 1;
}

// @lua ez.mesh.send_announce() -> boolean
// @brief Broadcast node announcement
// @description Sends an ADVERT packet containing this node's identity, name, role,
// and optional location. Other nodes use ADVERTs for discovery and routing.
// Announcements are flood-routed to reach all nodes in the mesh.
// @return true if sent successfully
// @example
// ez.mesh.send_announce()  -- Announce presence to mesh
// @end
LUA_FUNCTION(l_mesh_send_announce) {
    if (!mesh) {
        lua_pushboolean(L, false);
        return 1;
    }

    bool ok = mesh->sendAnnounce();
    lua_pushboolean(L, ok);
    return 1;
}

// @lua ez.mesh.get_tx_count() -> integer
// @brief Get total packets transmitted
// @description Returns the cumulative count of packets transmitted by this node
// since boot. Includes all packet types (ADVERTs, messages, rebroadcasts).
// @return Transmit count
// @example
// local tx = ez.mesh.get_tx_count()
// local rx = ez.mesh.get_rx_count()
// print("TX: " .. tx .. ", RX: " .. rx)
// @end
LUA_FUNCTION(l_mesh_get_tx_count) {
    uint32_t count = mesh ? mesh->getTxCount() : 0;
    lua_pushinteger(L, count);
    return 1;
}

// @lua ez.mesh.get_rx_count() -> integer
// @brief Get total packets received
// @description Returns the cumulative count of valid packets received by this node
// since boot. Only counts packets that passed CRC and basic validation.
// @return Receive count
// @example
// local rx = ez.mesh.get_rx_count()
// @end
LUA_FUNCTION(l_mesh_get_rx_count) {
    uint32_t count = mesh ? mesh->getRxCount() : 0;
    lua_pushinteger(L, count);
    return 1;
}

// Callback references for Lua callbacks (kept for backward compatibility)
static int nodeCallbackRef = LUA_NOREF;
static int groupPacketCallbackRef = LUA_NOREF;
static int packetCallbackRef = LUA_NOREF;
static lua_State* callbackState = nullptr;

// Helper: Push node info as Lua table onto stack and post to bus
static void pushNodeTable(lua_State* L, const NodeInfo& node) {
    lua_newtable(L);

    lua_pushinteger(L, node.pathHash);
    lua_setfield(L, -2, "path_hash");

    lua_pushstring(L, node.name);
    lua_setfield(L, -2, "name");

    lua_pushnumber(L, node.lastRssi);
    lua_setfield(L, -2, "rssi");

    lua_pushnumber(L, node.lastSnr);
    lua_setfield(L, -2, "snr");

    lua_pushinteger(L, node.role);
    lua_setfield(L, -2, "role");

    lua_pushinteger(L, node.advertTimestamp);
    lua_setfield(L, -2, "advert_timestamp");

    uint32_t age = (millis() - node.lastSeen) / 1000;
    lua_pushinteger(L, age);
    lua_setfield(L, -2, "age_seconds");

    lua_pushinteger(L, node.lastSeen);
    lua_setfield(L, -2, "last_seen");

    if (node.hasPublicKey) {
        char hexKey[ED25519_PUBLIC_KEY_SIZE * 2 + 1];
        pubKeyToHex(node.publicKey, hexKey);
        lua_pushstring(L, hexKey);
        lua_setfield(L, -2, "pub_key_hex");
    }

    lua_pushboolean(L, node.hasLocation);
    lua_setfield(L, -2, "has_location");
    if (node.hasLocation) {
        lua_pushnumber(L, node.latitude);
        lua_setfield(L, -2, "lat");
        lua_pushnumber(L, node.longitude);
        lua_setfield(L, -2, "lon");
    }
}

// Helper: Push group packet info as Lua table onto stack
static void pushGroupPacketTable(lua_State* L, uint8_t channelHash, const uint8_t* data, size_t dataLen,
                                  uint8_t senderHash, float rssi, float snr) {
    lua_newtable(L);

    lua_pushinteger(L, channelHash);
    lua_setfield(L, -2, "channel_hash");

    lua_pushlstring(L, reinterpret_cast<const char*>(data), dataLen);
    lua_setfield(L, -2, "data");

    lua_pushinteger(L, senderHash);
    lua_setfield(L, -2, "sender_hash");

    lua_pushnumber(L, rssi);
    lua_setfield(L, -2, "rssi");

    lua_pushnumber(L, snr);
    lua_setfield(L, -2, "snr");
}

// Helper: Push parsed packet info as Lua table onto stack
static void pushPacketTable(lua_State* L, const ParsedPacket& pkt) {
    lua_newtable(L);

    lua_pushinteger(L, pkt.routeType);
    lua_setfield(L, -2, "route_type");

    lua_pushinteger(L, pkt.payloadType);
    lua_setfield(L, -2, "payload_type");

    lua_pushinteger(L, pkt.version);
    lua_setfield(L, -2, "version");

    lua_pushlstring(L, reinterpret_cast<const char*>(pkt.path), pkt.pathLen);
    lua_setfield(L, -2, "path");

    lua_pushlstring(L, reinterpret_cast<const char*>(pkt.payload), pkt.payloadLen);
    lua_setfield(L, -2, "payload");

    lua_pushnumber(L, pkt.rssi);
    lua_setfield(L, -2, "rssi");

    lua_pushnumber(L, pkt.snr);
    lua_setfield(L, -2, "snr");

    lua_pushinteger(L, pkt.timestamp);
    lua_setfield(L, -2, "timestamp");
}

// @lua ez.mesh.on_node_discovered(callback)
// @brief Set callback for node discovery (DEPRECATED - use bus.subscribe("mesh/node_discovered") instead)
// @description Registers a callback function invoked when a new node is discovered or
// an existing node sends a fresh ADVERT. Also posts to message bus "mesh/node_discovered".
// Pass nil to remove the callback.
// @param callback Function(node_table) called when node discovered
// @note node_table contains: path_hash, name, rssi, snr, role, advert_timestamp, age_seconds, pub_key_hex (if available)
// @example
// ez.mesh.on_node_discovered(function(node)
//     print("Found: " .. node.name)
// end)
// @end
LUA_FUNCTION(l_mesh_on_node_discovered) {
    LUA_CHECK_ARGC(L, 1);

    if (nodeCallbackRef != LUA_NOREF && callbackState) {
        luaL_unref(callbackState, LUA_REGISTRYINDEX, nodeCallbackRef);
    }

    if (lua_isfunction(L, 1)) {
        lua_pushvalue(L, 1);
        nodeCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX);
        callbackState = L;

        if (mesh) {
            mesh->setNodeCallback([](const NodeInfo& node) {
                // Call legacy callback if registered
                if (callbackState && nodeCallbackRef != LUA_NOREF) {
                    lua_rawgeti(callbackState, LUA_REGISTRYINDEX, nodeCallbackRef);
                    pushNodeTable(callbackState, node);

                    if (lua_pcall(callbackState, 1, 0, 0) != LUA_OK) {
                        Serial.printf("[Lua] Node callback error: %s\n",
                                     lua_tostring(callbackState, -1));
                        lua_pop(callbackState, 1);
                    }
                }

                // Post table to message bus with full node data
                NodeInfo nodeCopy = node;
                MessageBus::instance().postTable("mesh/node_discovered", [nodeCopy](lua_State* L) {
                    pushNodeTable(L, nodeCopy);
                });
            });
        }
    } else if (lua_isnil(L, 1)) {
        nodeCallbackRef = LUA_NOREF;
        if (mesh) {
            mesh->setNodeCallback(nullptr);
        }
    }

    return 0;
}

// @lua ez.mesh.on_group_packet(callback)
// @brief Set callback for raw group packets (DEPRECATED - use bus.subscribe("mesh/group_packet") instead)
// @description Registers a callback for receiving GRP_TXT and GRP_DATA packets.
// The callback receives pre-parsed group packet data including the encrypted payload.
// Also posts to message bus "mesh/group_packet". Pass nil to remove the callback.
// @param callback Function(packet_table) called with {channel_hash, data, sender_hash, rssi, snr}
// @note When this callback is set, Lua takes over channel handling
// @example
// ez.mesh.on_group_packet(function(pkt)
//     local decrypted = Channel.decrypt(pkt.channel_hash, pkt.data)
// end)
// @end
LUA_FUNCTION(l_mesh_on_group_packet) {
    LUA_CHECK_ARGC(L, 1);

    if (groupPacketCallbackRef != LUA_NOREF && callbackState) {
        luaL_unref(callbackState, LUA_REGISTRYINDEX, groupPacketCallbackRef);
    }

    if (lua_isfunction(L, 1)) {
        lua_pushvalue(L, 1);
        groupPacketCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX);
        callbackState = L;

        if (mesh) {
            mesh->setGroupPacketCallback([](uint8_t channelHash, const uint8_t* data, size_t dataLen,
                                           uint8_t senderHash, float rssi, float snr) {
                // Call legacy callback if registered
                if (callbackState && groupPacketCallbackRef != LUA_NOREF) {
                    lua_rawgeti(callbackState, LUA_REGISTRYINDEX, groupPacketCallbackRef);
                    pushGroupPacketTable(callbackState, channelHash, data, dataLen, senderHash, rssi, snr);

                    if (lua_pcall(callbackState, 1, 0, 0) != LUA_OK) {
                        Serial.printf("[Lua] Group packet callback error: %s\n",
                                     lua_tostring(callbackState, -1));
                        lua_pop(callbackState, 1);
                    }
                }

                // Post table to message bus with full packet data
                // Copy data since it won't survive beyond this callback
                std::vector<uint8_t> dataCopy(data, data + dataLen);
                MessageBus::instance().postTable("mesh/group_packet",
                    [channelHash, dataCopy, senderHash, rssi, snr](lua_State* L) {
                        pushGroupPacketTable(L, channelHash, dataCopy.data(), dataCopy.size(),
                                           senderHash, rssi, snr);
                    });
            });
        }
    } else if (lua_isnil(L, 1)) {
        groupPacketCallbackRef = LUA_NOREF;
        if (mesh) {
            mesh->setGroupPacketCallback(nullptr);
        }
    }

    return 0;
}

// @lua ez.mesh.send_group_packet(channel_hash, encrypted_data) -> boolean
// @brief Send raw encrypted group packet
// @description Sends a GRP_TXT packet to a channel. The data must already be encrypted
// with the channel key (use ez.crypto functions). The packet is flood-routed to reach
// all nodes subscribed to the channel.
// @param channel_hash Single byte channel identifier (first byte of channel key hash)
// @param encrypted_data Pre-encrypted payload (MAC + ciphertext)
// @return true if sent successfully
// @example
// local encrypted = Channel.encrypt("Hello everyone!")
// ez.mesh.send_group_packet(channel.hash, encrypted)
// @end
LUA_FUNCTION(l_mesh_send_group_packet) {
    LUA_CHECK_ARGC(L, 2);

    lua_Integer channelHash = luaL_checkinteger(L, 1);
    size_t dataLen;
    const char* data = luaL_checklstring(L, 2, &dataLen);

    if (!mesh) {
        lua_pushboolean(L, false);
        return 1;
    }

    bool ok = mesh->sendGroupPacket(static_cast<uint8_t>(channelHash),
                                     reinterpret_cast<const uint8_t*>(data), dataLen);
    lua_pushboolean(L, ok);
    return 1;
}

// @lua ez.mesh.on_packet(callback)
// @brief Set callback for ALL incoming packets (DEPRECATED - use bus.subscribe("mesh/packet") instead)
// @description Registers a low-level callback for all received mesh packets before any
// processing. The callback can return (handled, rebroadcast) to control packet handling.
// Also posts to message bus "mesh/packet". Pass nil to remove the callback.
// @param callback Function(packet_table) returning handled, rebroadcast booleans
// @note packet_table contains: route_type, payload_type, version, path (binary), payload (binary), rssi, snr, timestamp
// @example
// ez.mesh.on_packet(function(pkt)
//     if pkt.payload_type == ez.mesh.PAYLOAD.ADVERT then
//         -- Handle ADVERT packet
//     end
//     return false, true  -- not handled, do rebroadcast
// end)
// @end
LUA_FUNCTION(l_mesh_on_packet) {
    LUA_CHECK_ARGC(L, 1);

    if (packetCallbackRef != LUA_NOREF && callbackState) {
        luaL_unref(callbackState, LUA_REGISTRYINDEX, packetCallbackRef);
    }

    if (lua_isfunction(L, 1)) {
        lua_pushvalue(L, 1);
        packetCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX);
        callbackState = L;

        if (mesh) {
            mesh->setPacketCallback([](const ParsedPacket& pkt) -> std::pair<bool, bool> {
                bool handled = false;
                bool rebroadcast = false;

                // Call legacy callback if registered
                if (callbackState && packetCallbackRef != LUA_NOREF) {
                    lua_rawgeti(callbackState, LUA_REGISTRYINDEX, packetCallbackRef);
                    pushPacketTable(callbackState, pkt);

                    if (lua_pcall(callbackState, 1, 2, 0) != LUA_OK) {
                        Serial.printf("[Lua] Packet callback error: %s\n",
                                     lua_tostring(callbackState, -1));
                        lua_pop(callbackState, 1);
                    } else {
                        rebroadcast = lua_toboolean(callbackState, -1);
                        handled = lua_toboolean(callbackState, -2);
                        lua_pop(callbackState, 2);
                    }
                }

                // Post table to message bus with full packet data
                // Copy path and payload since they won't survive beyond this callback
                std::vector<uint8_t> pathCopy(pkt.path, pkt.path + pkt.pathLen);
                std::vector<uint8_t> payloadCopy(pkt.payload, pkt.payload + pkt.payloadLen);
                uint8_t routeType = pkt.routeType;
                uint8_t payloadType = pkt.payloadType;
                uint8_t version = pkt.version;
                float rssi = pkt.rssi;
                float snr = pkt.snr;
                uint32_t timestamp = pkt.timestamp;

                MessageBus::instance().postTable("mesh/packet",
                    [routeType, payloadType, version, pathCopy, payloadCopy, rssi, snr, timestamp](lua_State* L) {
                        lua_newtable(L);

                        lua_pushinteger(L, routeType);
                        lua_setfield(L, -2, "route_type");

                        lua_pushinteger(L, payloadType);
                        lua_setfield(L, -2, "payload_type");

                        lua_pushinteger(L, version);
                        lua_setfield(L, -2, "version");

                        lua_pushlstring(L, reinterpret_cast<const char*>(pathCopy.data()), pathCopy.size());
                        lua_setfield(L, -2, "path");

                        lua_pushlstring(L, reinterpret_cast<const char*>(payloadCopy.data()), payloadCopy.size());
                        lua_setfield(L, -2, "payload");

                        lua_pushnumber(L, rssi);
                        lua_setfield(L, -2, "rssi");

                        lua_pushnumber(L, snr);
                        lua_setfield(L, -2, "snr");

                        lua_pushinteger(L, timestamp);
                        lua_setfield(L, -2, "timestamp");
                    });

                return {handled, rebroadcast};
            });
        }
    } else if (lua_isnil(L, 1)) {
        packetCallbackRef = LUA_NOREF;
        if (mesh) {
            mesh->setPacketCallback(nullptr);
        }
    }

    return 0;
}

// @lua ez.mesh.schedule_rebroadcast(data)
// @brief Schedule raw packet data for rebroadcast
// @description Queues a packet for rebroadcast to extend the mesh network range.
// The packet should be raw bytes from a previously received packet. Used when
// manually handling packets via on_packet callback.
// @param data Binary string of raw packet bytes
// @example
// ez.mesh.on_packet(function(pkt)
//     -- Manually rebroadcast after processing
//     ez.mesh.schedule_rebroadcast(raw_bytes)
// end)
// @end
LUA_FUNCTION(l_mesh_schedule_rebroadcast) {
    LUA_CHECK_ARGC(L, 1);

    size_t dataLen;
    const char* data = luaL_checklstring(L, 1, &dataLen);

    if (mesh) {
        mesh->scheduleRawRebroadcast(reinterpret_cast<const uint8_t*>(data), dataLen);
    }

    return 0;
}

// @lua ez.mesh.get_path_hash() -> integer
// @brief Get this node's path hash (first byte of public key)
// @description Returns this node's path hash, a single byte used in packet routing
// to identify the node in the path field. This is the first byte of the public key.
// @return Path hash as integer (0-255)
// @example
// local hash = ez.mesh.get_path_hash()  -- e.g., 0xA1 = 161
// @end
LUA_FUNCTION(l_mesh_get_path_hash) {
    if (!mesh) {
        lua_pushinteger(L, 0);
        return 1;
    }

    lua_pushinteger(L, mesh->getIdentity().getPathHash());
    return 1;
}

// @lua ez.mesh.get_public_key() -> string
// @brief Get this node's public key as binary string
// @description Returns this node's Ed25519 public key as a raw 32-byte binary string.
// Used for cryptographic operations like shared secret calculation and signature verification.
// @return 32-byte Ed25519 public key, or nil if mesh not initialized
// @example
// local pubkey = ez.mesh.get_public_key()
// local shared = ez.mesh.calc_shared_secret(other_pubkey)
// @end
LUA_FUNCTION(l_mesh_get_public_key) {
    if (!mesh) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushlstring(L, reinterpret_cast<const char*>(mesh->getIdentity().getPublicKey()),
                    ED25519_PUBLIC_KEY_SIZE);
    return 1;
}

// @lua ez.mesh.get_public_key_hex() -> string
// @brief Get this node's public key as hex string
// @description Returns this node's Ed25519 public key as a 64-character hexadecimal
// string for display or storage in text format.
// @return 64-character hex string, or nil if mesh not initialized
// @example
// local hex = ez.mesh.get_public_key_hex()
// print("Public key: " .. hex)
// @end
LUA_FUNCTION(l_mesh_get_public_key_hex) {
    if (!mesh) {
        lua_pushnil(L);
        return 1;
    }

    char hexKey[ED25519_PUBLIC_KEY_SIZE * 2 + 1];
    pubKeyToHex(mesh->getIdentity().getPublicKey(), hexKey);
    lua_pushstring(L, hexKey);
    return 1;
}

// @lua ez.mesh.ed25519_sign(data) -> signature
// @brief Sign data with this node's private key
// @description Creates an Ed25519 signature of the provided data using this node's
// private key. The signature can be verified by anyone with the public key.
// Used for message authentication and non-repudiation.
// @param data Binary string to sign
// @return 64-byte Ed25519 signature as binary string, or nil on error
// @example
// local message = "Hello, mesh!"
// local sig = ez.mesh.ed25519_sign(message)
// local pubkey = ez.mesh.get_public_key()
// assert(ez.mesh.ed25519_verify(message, sig, pubkey))
// @end
LUA_FUNCTION(l_mesh_ed25519_sign) {
    LUA_CHECK_ARGC(L, 1);

    size_t dataLen;
    const char* data = luaL_checklstring(L, 1, &dataLen);

    if (!mesh) {
        lua_pushnil(L);
        return 1;
    }

    uint8_t signature[ED25519_SIGNATURE_SIZE];
    bool ok = mesh->getIdentity().sign(reinterpret_cast<const uint8_t*>(data), dataLen, signature);

    if (!ok) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushlstring(L, reinterpret_cast<char*>(signature), ED25519_SIGNATURE_SIZE);
    return 1;
}

// @lua ez.mesh.ed25519_verify(data, signature, pub_key) -> boolean
// @brief Verify an Ed25519 signature
// @description Verifies that an Ed25519 signature was created by the holder of the
// corresponding private key. Returns true only if the signature is valid for the
// given data and public key.
// @param data Binary string that was signed
// @param signature 64-byte Ed25519 signature
// @param pub_key 32-byte Ed25519 public key
// @return true if signature is valid
// @example
// local valid = ez.mesh.ed25519_verify(message, signature, sender_pubkey)
// if valid then
//     print("Message authenticated!")
// end
// @end
LUA_FUNCTION(l_mesh_ed25519_verify) {
    LUA_CHECK_ARGC(L, 3);

    size_t dataLen, sigLen, keyLen;
    const char* data = luaL_checklstring(L, 1, &dataLen);
    const char* signature = luaL_checklstring(L, 2, &sigLen);
    const char* pubKey = luaL_checklstring(L, 3, &keyLen);

    // Validate signature and key sizes
    if (sigLen != ED25519_SIGNATURE_SIZE || keyLen != ED25519_PUBLIC_KEY_SIZE) {
        lua_pushboolean(L, false);
        return 1;
    }

    bool valid = Identity::verify(
        reinterpret_cast<const uint8_t*>(data), dataLen,
        reinterpret_cast<const uint8_t*>(signature),
        reinterpret_cast<const uint8_t*>(pubKey)
    );

    lua_pushboolean(L, valid);
    return 1;
}

// @lua ez.mesh.calc_shared_secret(other_pub_key) -> string|nil
// @brief Calculate ECDH shared secret with another node
// @description Performs X25519 key exchange to derive a shared secret that only this
// node and the other party can compute. Used for end-to-end encryption of direct
// messages between two nodes.
// @param other_pub_key 32-byte Ed25519 public key of the other party
// @return 32-byte shared secret as binary string, or nil on error (with error message as second return)
// @example
// local secret = ez.mesh.calc_shared_secret(other_node.pub_key)
// local key = ez.crypto.sha256(secret):sub(1, 16)  -- Derive 128-bit key
// @end
LUA_FUNCTION(l_mesh_calc_shared_secret) {
    LUA_CHECK_ARGC(L, 1);

    size_t keyLen;
    const char* otherPubKey = luaL_checklstring(L, 1, &keyLen);

    if (keyLen != ED25519_PUBLIC_KEY_SIZE) {
        lua_pushnil(L);
        lua_pushstring(L, "Public key must be 32 bytes");
        return 2;
    }

    if (!mesh) {
        lua_pushnil(L);
        lua_pushstring(L, "Mesh not initialized");
        return 2;
    }

    uint8_t sharedSecret[32];
    bool ok = mesh->getIdentity().calcSharedSecret(
        reinterpret_cast<const uint8_t*>(otherPubKey),
        sharedSecret
    );

    if (!ok) {
        lua_pushnil(L);
        lua_pushstring(L, "Failed to calculate shared secret");
        return 2;
    }

    lua_pushlstring(L, reinterpret_cast<char*>(sharedSecret), 32);
    return 1;
}

// @lua ez.mesh.build_packet(route_type, payload_type, payload, path) -> string|nil
// @brief Build a raw mesh packet for transmission
// @description Constructs a serialized MeshCore packet from components. The packet
// includes header, path, and payload. Use ez.mesh.ROUTE and ez.mesh.PAYLOAD constants.
// @param route_type Route type constant (FLOOD=1, DIRECT=2)
// @param payload_type Payload type constant (ADVERT=4, GRP_TXT=5, etc.)
// @param payload Binary string payload (max 184 bytes)
// @param path Optional binary string of path hashes (default: empty)
// @return Serialized packet as binary string, or nil on error
// @example
// local pkt = ez.mesh.build_packet(
//     ez.mesh.ROUTE.FLOOD,
//     ez.mesh.PAYLOAD.GRP_TXT,
//     encrypted_message
// )
// ez.mesh.queue_send(pkt)
// @end
LUA_FUNCTION(l_mesh_build_packet) {
    int argc = lua_gettop(L);
    if (argc < 3) {
        return luaL_error(L, "build_packet requires at least 3 arguments");
    }

    lua_Integer routeType = luaL_checkinteger(L, 1);
    lua_Integer payloadType = luaL_checkinteger(L, 2);
    size_t payloadLen;
    const char* payload = luaL_checklstring(L, 3, &payloadLen);

    size_t pathLen = 0;
    const char* path = nullptr;
    if (argc >= 4 && !lua_isnil(L, 4)) {
        path = luaL_checklstring(L, 4, &pathLen);
    }

    if (payloadLen > MAX_PACKET_PAYLOAD) {
        lua_pushnil(L);
        return 1;
    }

    if (pathLen > MAX_PATH_SIZE) {
        lua_pushnil(L);
        return 1;
    }

    // Build packet
    MeshPacket pkt;
    pkt.clear();
    pkt.header = makeHeader(routeType, payloadType, PayloadVersion::V1);
    pkt.pathLen = pathLen;
    if (path && pathLen > 0) {
        memcpy(pkt.path, path, pathLen);
    }
    pkt.payloadLen = payloadLen;
    memcpy(pkt.payload, payload, payloadLen);

    // Serialize
    uint8_t buffer[MeshPacket::MAX_SIZE];
    size_t len = pkt.serialize(buffer, sizeof(buffer));
    if (len == 0) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushlstring(L, reinterpret_cast<char*>(buffer), len);
    return 1;
}

// @lua ez.mesh.parse_header(header_byte) -> route_type, payload_type, version
// @brief Parse a packet header byte into components
// @description Extracts the route type (bits 0-1), payload type (bits 2-5), and
// version (bits 6-7) from a MeshCore packet header byte.
// @param header_byte Single byte header value
// @return route_type, payload_type, version as integers
// @example
// local route, ptype, ver = ez.mesh.parse_header(pkt.header)
// if ptype == ez.mesh.PAYLOAD.ADVERT then
//     -- Handle ADVERT
// end
// @end
LUA_FUNCTION(l_mesh_parse_header) {
    LUA_CHECK_ARGC(L, 1);
    lua_Integer header = luaL_checkinteger(L, 1);

    lua_pushinteger(L, header & PH_ROUTE_MASK);
    lua_pushinteger(L, (header >> PH_TYPE_SHIFT) & PH_TYPE_MASK);
    lua_pushinteger(L, (header >> PH_VER_SHIFT) & PH_VER_MASK);
    return 3;
}

// @lua ez.mesh.make_header(route_type, payload_type, version) -> integer
// @brief Create a packet header byte from components
// @description Constructs a MeshCore packet header byte from route type, payload type,
// and version fields. Use ez.mesh.ROUTE and ez.mesh.PAYLOAD constants.
// @param route_type Route type constant
// @param payload_type Payload type constant
// @param version Optional version (default: 0)
// @return Header byte as integer
// @example
// local header = ez.mesh.make_header(ez.mesh.ROUTE.FLOOD, ez.mesh.PAYLOAD.GRP_TXT)
// @end
LUA_FUNCTION(l_mesh_make_header) {
    int argc = lua_gettop(L);
    if (argc < 2) {
        return luaL_error(L, "make_header requires at least 2 arguments");
    }

    lua_Integer route = luaL_checkinteger(L, 1);
    lua_Integer type = luaL_checkinteger(L, 2);
    lua_Integer version = (argc >= 3) ? luaL_checkinteger(L, 3) : 0;

    lua_pushinteger(L, makeHeader(route, type, version));
    return 1;
}

// @lua ez.mesh.send_raw(data) -> boolean
// @brief Send raw packet data directly via radio (bypasses queue, immediate)
// @description Transmits a packet immediately without queueing or throttling.
// Blocks until transmission completes. Use queue_send() for non-blocking throttled
// transmission in most cases.
// @param data Binary string of serialized packet
// @return true if sent successfully
// @example
// local pkt = ez.mesh.build_packet(ez.mesh.ROUTE.FLOOD, ez.mesh.PAYLOAD.GRP_TXT, data)
// ez.mesh.send_raw(pkt)  -- Immediate transmission
// @end
LUA_FUNCTION(l_mesh_send_raw) {
    LUA_CHECK_ARGC(L, 1);

    size_t dataLen;
    const char* data = luaL_checklstring(L, 1, &dataLen);

    if (!mesh) {
        lua_pushboolean(L, false);
        return 1;
    }

    Radio* radio = mesh->getRadio();
    if (!radio) {
        lua_pushboolean(L, false);
        return 1;
    }

    RadioResult result = radio->send(reinterpret_cast<const uint8_t*>(data), dataLen);
    lua_pushboolean(L, result == RadioResult::OK);
    return 1;
}

// @lua ez.mesh.queue_send(data) -> boolean
// @brief Queue packet for transmission (throttled, non-blocking)
// @description Adds a packet to the transmit queue for throttled sending. Returns
// immediately without blocking. Packets are sent at the throttle interval to avoid
// flooding the radio channel. Preferred over send_raw() for most uses.
// @param data Binary string of serialized packet
// @return true if queued successfully, false if queue full or error
// @example
// local pkt = ez.mesh.build_packet(ez.mesh.ROUTE.FLOOD, ez.mesh.PAYLOAD.GRP_TXT, data)
// if ez.mesh.queue_send(pkt) then
//     print("Message queued")
// end
// @end
LUA_FUNCTION(l_mesh_queue_send) {
    LUA_CHECK_ARGC(L, 1);

    size_t dataLen;
    const char* data = luaL_checklstring(L, 1, &dataLen);

    if (!mesh) {
        lua_pushboolean(L, false);
        return 1;
    }

    Radio* radio = mesh->getRadio();
    if (!radio) {
        lua_pushboolean(L, false);
        return 1;
    }

    RadioResult result = radio->queueSend(reinterpret_cast<const uint8_t*>(data), dataLen);
    lua_pushboolean(L, result == RadioResult::OK);
    return 1;
}

// @lua ez.mesh.get_tx_queue_size() -> integer
// @brief Get number of packets waiting in transmit queue
// @description Returns the current number of packets in the transmit queue waiting
// to be sent. Check this to avoid queueing more packets when the queue is full.
// @return Queue size
// @example
// local pending = ez.mesh.get_tx_queue_size()
// print(pending .. " packets pending")
// @end
LUA_FUNCTION(l_mesh_get_tx_queue_size) {
    if (!mesh) {
        lua_pushinteger(L, 0);
        return 1;
    }

    Radio* radio = mesh->getRadio();
    lua_pushinteger(L, radio ? radio->getQueueSize() : 0);
    return 1;
}

// @lua ez.mesh.get_tx_queue_capacity() -> integer
// @brief Get maximum transmit queue capacity
// @description Returns the maximum number of packets the transmit queue can hold.
// @return Max queue size
// @example
// local cap = ez.mesh.get_tx_queue_capacity()  -- e.g., 16
// @end
LUA_FUNCTION(l_mesh_get_tx_queue_capacity) {
    if (!mesh) {
        lua_pushinteger(L, 0);
        return 1;
    }

    Radio* radio = mesh->getRadio();
    lua_pushinteger(L, radio ? radio->getQueueCapacity() : 0);
    return 1;
}

// @lua ez.mesh.is_tx_queue_full() -> boolean
// @brief Check if transmit queue is full
// @description Returns true if the transmit queue cannot accept more packets.
// Check this before calling queue_send() to avoid failed queuing.
// @return true if queue is full
// @example
// if not ez.mesh.is_tx_queue_full() then
//     ez.mesh.queue_send(packet)
// end
// @end
LUA_FUNCTION(l_mesh_is_tx_queue_full) {
    if (!mesh) {
        lua_pushboolean(L, true);
        return 1;
    }

    Radio* radio = mesh->getRadio();
    lua_pushboolean(L, radio ? radio->isQueueFull() : true);
    return 1;
}

// @lua ez.mesh.clear_tx_queue()
// @brief Clear all packets from transmit queue
// @description Removes all pending packets from the transmit queue. Use when you
// need to cancel queued transmissions, such as when changing channels.
// @example
// ez.mesh.clear_tx_queue()  -- Cancel all pending transmissions
// @end
LUA_FUNCTION(l_mesh_clear_tx_queue) {
    if (mesh) {
        Radio* radio = mesh->getRadio();
        if (radio) {
            radio->clearQueue();
        }
    }
    return 0;
}

// @lua ez.mesh.set_tx_throttle(ms)
// @brief Set minimum interval between transmissions
// @description Sets the minimum time between queued packet transmissions. Higher
// values reduce channel congestion but increase latency. Default is 100ms.
// @param ms Milliseconds between transmissions (default 100)
// @example
// ez.mesh.set_tx_throttle(200)  -- Slower, less channel usage
// ez.mesh.set_tx_throttle(50)   -- Faster, more responsive
// @end
LUA_FUNCTION(l_mesh_set_tx_throttle) {
    LUA_CHECK_ARGC(L, 1);
    uint32_t ms = luaL_checkinteger(L, 1);

    if (mesh) {
        Radio* radio = mesh->getRadio();
        if (radio) {
            radio->setThrottleInterval(ms);
        }
    }
    return 0;
}

// @lua ez.mesh.get_tx_throttle() -> integer
// @brief Get current throttle interval
// @description Returns the current minimum interval between queued packet transmissions.
// @return Milliseconds between transmissions
// @example
// local interval = ez.mesh.get_tx_throttle()  -- e.g., 100
// @end
LUA_FUNCTION(l_mesh_get_tx_throttle) {
    if (!mesh) {
        lua_pushinteger(L, 0);
        return 1;
    }

    Radio* radio = mesh->getRadio();
    lua_pushinteger(L, radio ? radio->getThrottleInterval() : 0);
    return 1;
}

// =============================================================================
// Packet Queue (polling-based API - safer than callbacks)
// =============================================================================

// @lua ez.mesh.enable_packet_queue(enabled)
// @brief Enable or disable packet queuing for polling
// @description When enabled, incoming packets are added to an internal queue instead
// of triggering callbacks. Use has_packets() and pop_packet() to process them.
// This polling-based API is safer than callbacks and works well with coroutines.
// @param enabled Boolean to enable/disable
// @note When enabled, incoming packets are queued instead of using callbacks
// @example
// ez.mesh.enable_packet_queue(true)
// -- In main loop:
// while ez.mesh.has_packets() do
//     local pkt = ez.mesh.pop_packet()
//     process_packet(pkt)
// end
// @end
LUA_FUNCTION(l_mesh_enable_packet_queue) {
    LUA_CHECK_ARGC(L, 1);
    bool enable = lua_toboolean(L, 1);

    if (enable && !packetQueueEnabled) {
        // Enable: set up internal callback that queues packets
        packetQueueEnabled = true;
        packetQueue.clear();

        if (mesh) {
            mesh->setPacketCallback([](const ParsedPacket& pkt) -> std::pair<bool, bool> {
                // Queue the packet (copy data since pkt pointers are temporary)
                if (packetQueue.size() < MAX_PACKET_QUEUE) {
                    QueuedPacket qp;
                    qp.routeType = pkt.routeType;
                    qp.payloadType = pkt.payloadType;
                    qp.version = pkt.version;
                    qp.path.assign(pkt.path, pkt.path + pkt.pathLen);
                    qp.payload.assign(pkt.payload, pkt.payload + pkt.payloadLen);
                    qp.rssi = pkt.rssi;
                    qp.snr = pkt.snr;
                    qp.timestamp = pkt.timestamp;
                    packetQueue.push_back(std::move(qp));
                }
                // Don't handle in C++, don't rebroadcast (Lua will decide)
                return {false, false};
            });
        }
    } else if (!enable && packetQueueEnabled) {
        // Disable: clear callback and queue
        packetQueueEnabled = false;
        packetQueue.clear();
        if (mesh) {
            mesh->setPacketCallback(nullptr);
        }
    }

    return 0;
}

// @lua ez.mesh.has_packets() -> boolean
// @brief Check if packets are available in the queue
// @description Returns true if there are packets waiting in the receive queue.
// Only works when packet queuing is enabled via enable_packet_queue(true).
// @return true if one or more packets are queued
// @example
// if ez.mesh.has_packets() then
//     local pkt = ez.mesh.pop_packet()
// end
// @end
LUA_FUNCTION(l_mesh_has_packets) {
    lua_pushboolean(L, !packetQueue.empty());
    return 1;
}

// @lua ez.mesh.packet_count() -> integer
// @brief Get number of packets in queue
// @description Returns the current number of packets waiting in the receive queue.
// @return Number of queued packets
// @example
// local count = ez.mesh.packet_count()
// print(count .. " packets waiting")
// @end
LUA_FUNCTION(l_mesh_packet_count) {
    lua_pushinteger(L, packetQueue.size());
    return 1;
}

// @lua ez.mesh.pop_packet() -> table|nil
// @brief Get and remove the next packet from queue
// @description Removes and returns the oldest packet from the receive queue.
// Returns nil if the queue is empty. The packet table contains route_type,
// payload_type, version, path, payload, rssi, snr, and timestamp fields.
// @return Packet table or nil if queue is empty
// @example
// local pkt = ez.mesh.pop_packet()
// if pkt then
//     print("Received:", pkt.payload_type, pkt.rssi .. "dBm")
// end
// @end
LUA_FUNCTION(l_mesh_pop_packet) {
    if (packetQueue.empty()) {
        lua_pushnil(L);
        return 1;
    }

    // Get front packet
    QueuedPacket& pkt = packetQueue.front();

    // Create packet table
    lua_newtable(L);

    lua_pushinteger(L, pkt.routeType);
    lua_setfield(L, -2, "route_type");

    lua_pushinteger(L, pkt.payloadType);
    lua_setfield(L, -2, "payload_type");

    lua_pushinteger(L, pkt.version);
    lua_setfield(L, -2, "version");

    lua_pushlstring(L, reinterpret_cast<const char*>(pkt.path.data()), pkt.path.size());
    lua_setfield(L, -2, "path");

    lua_pushlstring(L, reinterpret_cast<const char*>(pkt.payload.data()), pkt.payload.size());
    lua_setfield(L, -2, "payload");

    lua_pushnumber(L, pkt.rssi);
    lua_setfield(L, -2, "rssi");

    lua_pushnumber(L, pkt.snr);
    lua_setfield(L, -2, "snr");

    lua_pushinteger(L, pkt.timestamp);
    lua_setfield(L, -2, "timestamp");

    // Remove from queue
    packetQueue.pop_front();

    return 1;
}

// @lua ez.mesh.clear_packet_queue()
// @brief Clear all packets from the queue
// @description Removes all packets from the receive queue without processing them.
// Use when switching contexts or resetting the receiver state.
// @example
// ez.mesh.clear_packet_queue()  -- Discard unprocessed packets
// @end
LUA_FUNCTION(l_mesh_clear_packet_queue) {
    packetQueue.clear();
    return 0;
}

// @lua ez.mesh.set_path_check(enabled)
// @brief Enable or disable path check for flood routing
// @description Controls whether the mesh rejects packets that already contain this
// node's path hash (indicating the packet has already passed through). Enabled by
// default to prevent routing loops. Disable only for debugging.
// @param enabled Boolean - when true, packets with our hash in path are skipped
// @note Disabling this can help debug packet delivery issues but may cause loops
// @example
// ez.mesh.set_path_check(false)  -- Disable for debugging
// @end
LUA_FUNCTION(l_mesh_set_path_check) {
    LUA_CHECK_ARGC(L, 1);
    bool enabled = lua_toboolean(L, 1);

    if (mesh) {
        mesh->setPathCheckEnabled(enabled);
    }

    return 0;
}

// @lua ez.mesh.get_path_check() -> boolean
// @brief Get current path check setting
// @description Returns whether path loop detection is enabled.
// @return true if path check is enabled
// @example
// local enabled = ez.mesh.get_path_check()
// @end
LUA_FUNCTION(l_mesh_get_path_check) {
    bool enabled = mesh ? mesh->isPathCheckEnabled() : true;
    lua_pushboolean(L, enabled);
    return 1;
}

// @lua ez.mesh.set_announce_interval(ms)
// @brief Set auto-announce interval in milliseconds (0 = disabled)
// @description Configures automatic ADVERT transmission at a regular interval.
// Set to 0 to disable auto-announce and rely on manual send_announce() calls.
// Typical values are 60000-300000 (1-5 minutes).
// @param ms Integer - interval in milliseconds (0 to disable)
// @example
// ez.mesh.set_announce_interval(120000)  -- Announce every 2 minutes
// ez.mesh.set_announce_interval(0)       -- Disable auto-announce
// @end
LUA_FUNCTION(l_mesh_set_announce_interval) {
    LUA_CHECK_ARGC(L, 1);
    uint32_t ms = (uint32_t)luaL_checkinteger(L, 1);

    if (mesh) {
        mesh->setAnnounceInterval(ms);
        Serial.printf("[Mesh] Auto-announce interval set to %lu ms\n", ms);
    }

    return 0;
}

// @lua ez.mesh.get_announce_interval() -> integer
// @brief Get current auto-announce interval
// @description Returns the current auto-announce interval setting.
// @return Interval in milliseconds (0 = disabled)
// @example
// local interval = ez.mesh.get_announce_interval()
// if interval == 0 then
//     print("Auto-announce disabled")
// end
// @end
LUA_FUNCTION(l_mesh_get_announce_interval) {
    uint32_t ms = mesh ? mesh->getAnnounceInterval() : 0;
    lua_pushinteger(L, ms);
    return 1;
}

// Function table for ez.mesh
static const luaL_Reg mesh_funcs[] = {
    {"is_initialized",       l_mesh_is_initialized},
    {"update",               l_mesh_update},
    {"get_node_id",          l_mesh_get_node_id},
    {"get_short_id",         l_mesh_get_short_id},
    {"get_node_name",        l_mesh_get_node_name},
    {"set_node_name",        l_mesh_set_node_name},
    {"get_nodes",            l_mesh_get_nodes},
    {"get_node_count",       l_mesh_get_node_count},
    {"send_announce",        l_mesh_send_announce},
    {"get_tx_count",         l_mesh_get_tx_count},
    {"get_rx_count",         l_mesh_get_rx_count},
    {"on_node_discovered",   l_mesh_on_node_discovered},
    {"on_group_packet",      l_mesh_on_group_packet},
    {"send_group_packet",    l_mesh_send_group_packet},
    {"on_packet",            l_mesh_on_packet},
    {"schedule_rebroadcast", l_mesh_schedule_rebroadcast},
    {"get_path_hash",        l_mesh_get_path_hash},
    {"get_public_key",       l_mesh_get_public_key},
    {"get_public_key_hex",   l_mesh_get_public_key_hex},
    {"ed25519_sign",         l_mesh_ed25519_sign},
    {"ed25519_verify",       l_mesh_ed25519_verify},
    {"calc_shared_secret",   l_mesh_calc_shared_secret},
    {"build_packet",         l_mesh_build_packet},
    {"parse_header",         l_mesh_parse_header},
    {"make_header",          l_mesh_make_header},
    {"send_raw",             l_mesh_send_raw},
    // Transmit queue (throttled sending)
    {"queue_send",           l_mesh_queue_send},
    {"get_tx_queue_size",    l_mesh_get_tx_queue_size},
    {"get_tx_queue_capacity", l_mesh_get_tx_queue_capacity},
    {"is_tx_queue_full",     l_mesh_is_tx_queue_full},
    {"clear_tx_queue",       l_mesh_clear_tx_queue},
    {"set_tx_throttle",      l_mesh_set_tx_throttle},
    {"get_tx_throttle",      l_mesh_get_tx_throttle},
    // Packet queue (polling-based API for RX)
    {"enable_packet_queue",  l_mesh_enable_packet_queue},
    {"has_packets",          l_mesh_has_packets},
    {"packet_count",         l_mesh_packet_count},
    {"pop_packet",           l_mesh_pop_packet},
    {"clear_packet_queue",   l_mesh_clear_packet_queue},
    // Path check setting
    {"set_path_check",       l_mesh_set_path_check},
    {"get_path_check",       l_mesh_get_path_check},
    // Auto-announce interval setting
    {"set_announce_interval", l_mesh_set_announce_interval},
    {"get_announce_interval", l_mesh_get_announce_interval},
    {nullptr, nullptr}
};

// Register the mesh module
void registerMeshModule(lua_State* L) {
    lua_register_module(L, "mesh", mesh_funcs);

    // Register route type constants
    lua_getglobal(L, "ez");
    lua_getfield(L, -1, "mesh");

    // Route types
    lua_newtable(L);
    lua_pushinteger(L, RouteType::TRANSPORT_FLOOD);
    lua_setfield(L, -2, "TRANSPORT_FLOOD");
    lua_pushinteger(L, RouteType::FLOOD);
    lua_setfield(L, -2, "FLOOD");
    lua_pushinteger(L, RouteType::DIRECT);
    lua_setfield(L, -2, "DIRECT");
    lua_pushinteger(L, RouteType::TRANSPORT_DIRECT);
    lua_setfield(L, -2, "TRANSPORT_DIRECT");
    lua_setfield(L, -2, "ROUTE");

    // Payload types
    lua_newtable(L);
    lua_pushinteger(L, PayloadType::REQ);
    lua_setfield(L, -2, "REQ");
    lua_pushinteger(L, PayloadType::RESPONSE);
    lua_setfield(L, -2, "RESPONSE");
    lua_pushinteger(L, PayloadType::TXT_MSG);
    lua_setfield(L, -2, "TXT_MSG");
    lua_pushinteger(L, PayloadType::ACK);
    lua_setfield(L, -2, "ACK");
    lua_pushinteger(L, PayloadType::ADVERT);
    lua_setfield(L, -2, "ADVERT");
    lua_pushinteger(L, PayloadType::GRP_TXT);
    lua_setfield(L, -2, "GRP_TXT");
    lua_pushinteger(L, PayloadType::GRP_DATA);
    lua_setfield(L, -2, "GRP_DATA");
    lua_pushinteger(L, PayloadType::ANON_REQ);
    lua_setfield(L, -2, "ANON_REQ");
    lua_pushinteger(L, PayloadType::PATH);
    lua_setfield(L, -2, "PATH");
    lua_pushinteger(L, PayloadType::TRACE);
    lua_setfield(L, -2, "TRACE");
    lua_pushinteger(L, PayloadType::MULTIPART);
    lua_setfield(L, -2, "MULTIPART");
    lua_pushinteger(L, PayloadType::CONTROL);
    lua_setfield(L, -2, "CONTROL");
    lua_pushinteger(L, PayloadType::RAW_CUSTOM);
    lua_setfield(L, -2, "RAW_CUSTOM");
    lua_setfield(L, -2, "PAYLOAD");

    // Node role constants
    lua_newtable(L);
    lua_pushinteger(L, ROLE_UNKNOWN);
    lua_setfield(L, -2, "UNKNOWN");
    lua_pushinteger(L, ROLE_CLIENT);
    lua_setfield(L, -2, "CLIENT");
    lua_pushinteger(L, ROLE_REPEATER);
    lua_setfield(L, -2, "REPEATER");
    lua_pushinteger(L, ROLE_ROUTER);
    lua_setfield(L, -2, "ROUTER");
    lua_pushinteger(L, ROLE_GATEWAY);
    lua_setfield(L, -2, "GATEWAY");
    lua_setfield(L, -2, "ROLE");

    lua_pop(L, 2);  // Pop mesh and tdeck

    Serial.println("[LuaRuntime] Registered ez.mesh");
}
