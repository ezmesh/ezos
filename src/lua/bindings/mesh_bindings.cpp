// tdeck.mesh module bindings
// Provides mesh networking functions

#include "../lua_bindings.h"
#include "../../mesh/meshcore.h"
#include "../../mesh/identity.h"

// External reference to the global mesh instance
extern MeshCore* mesh;

// Callback references for Lua callbacks
static int nodeCallbackRef = LUA_NOREF;
static int groupPacketCallbackRef = LUA_NOREF;
static int packetCallbackRef = LUA_NOREF;
static lua_State* callbackState = nullptr;

// @lua tdeck.mesh.is_initialized() -> boolean
// @brief Check if mesh networking is initialized
// @return true if mesh is ready
LUA_FUNCTION(l_mesh_is_initialized) {
    lua_pushboolean(L, mesh != nullptr);
    return 1;
}

// @lua tdeck.mesh.update()
// @brief Process incoming mesh packets
// @note Call this regularly in your main loop to receive messages
LUA_FUNCTION(l_mesh_update) {
    if (mesh) {
        mesh->update();
    }
    return 0;
}

// @lua tdeck.mesh.get_node_id() -> string
// @brief Get this node's full ID
// @return 6-byte hex string
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

// @lua tdeck.mesh.get_short_id() -> string
// @brief Get this node's short ID
// @return 3-byte hex string (6 chars)
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

// @lua tdeck.mesh.get_node_name() -> string
// @brief Get this node's display name
// @return Node name string
LUA_FUNCTION(l_mesh_get_node_name) {
    if (!mesh) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushstring(L, mesh->getIdentity().getNodeName());
    return 1;
}

// @lua tdeck.mesh.set_node_name(name) -> boolean
// @brief Set this node's display name
// @param name New node name
// @return true if successful
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

// Helper function to convert public key bytes to hex string
static void pubKeyToHex(const uint8_t* pubKey, char* hexOut) {
    for (int i = 0; i < ED25519_PUBLIC_KEY_SIZE; i++) {
        sprintf(&hexOut[i * 2], "%02X", pubKey[i]);
    }
    hexOut[ED25519_PUBLIC_KEY_SIZE * 2] = '\0';
}

// @lua tdeck.mesh.get_nodes() -> table
// @brief Get list of discovered mesh nodes
// @return Array of node tables with path_hash, name, rssi, snr, last_seen, hops, pub_key_hex
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

        lua_rawseti(L, -2, idx++);
    }

    return 1;
}

// @lua tdeck.mesh.get_node_count() -> integer
// @brief Get number of known nodes
// @return Node count
LUA_FUNCTION(l_mesh_get_node_count) {
    int count = mesh ? mesh->getNodes().size() : 0;
    lua_pushinteger(L, count);
    return 1;
}

// @lua tdeck.mesh.send_announce() -> boolean
// @brief Broadcast node announcement
// @return true if sent successfully
LUA_FUNCTION(l_mesh_send_announce) {
    if (!mesh) {
        lua_pushboolean(L, false);
        return 1;
    }

    bool ok = mesh->sendAnnounce();
    lua_pushboolean(L, ok);
    return 1;
}

// @lua tdeck.mesh.get_tx_count() -> integer
// @brief Get total packets transmitted
// @return Transmit count
LUA_FUNCTION(l_mesh_get_tx_count) {
    uint32_t count = mesh ? mesh->getTxCount() : 0;
    lua_pushinteger(L, count);
    return 1;
}

// @lua tdeck.mesh.get_rx_count() -> integer
// @brief Get total packets received
// @return Receive count
LUA_FUNCTION(l_mesh_get_rx_count) {
    uint32_t count = mesh ? mesh->getRxCount() : 0;
    lua_pushinteger(L, count);
    return 1;
}

// @lua tdeck.mesh.on_node_discovered(callback)
// @brief Set callback for node discovery
// @param callback Function(node_table) called when node discovered
// @note node_table contains: path_hash, name, rssi, snr, role, advert_timestamp, age_seconds, pub_key_hex (if available)
LUA_FUNCTION(l_mesh_on_node_discovered) {
    LUA_CHECK_ARGC(L, 1);

    // Release old callback if any
    if (nodeCallbackRef != LUA_NOREF && callbackState) {
        luaL_unref(callbackState, LUA_REGISTRYINDEX, nodeCallbackRef);
    }

    if (lua_isfunction(L, 1)) {
        lua_pushvalue(L, 1);
        nodeCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX);
        callbackState = L;

        // Set up the C++ callback to call Lua
        if (mesh) {
            mesh->setNodeCallback([](const NodeInfo& node) {
                if (callbackState && nodeCallbackRef != LUA_NOREF) {
                    lua_rawgeti(callbackState, LUA_REGISTRYINDEX, nodeCallbackRef);

                    // Push node as table with full information
                    lua_newtable(callbackState);

                    lua_pushinteger(callbackState, node.pathHash);
                    lua_setfield(callbackState, -2, "path_hash");

                    lua_pushstring(callbackState, node.name);
                    lua_setfield(callbackState, -2, "name");

                    lua_pushnumber(callbackState, node.lastRssi);
                    lua_setfield(callbackState, -2, "rssi");

                    lua_pushnumber(callbackState, node.lastSnr);
                    lua_setfield(callbackState, -2, "snr");

                    lua_pushinteger(callbackState, node.role);
                    lua_setfield(callbackState, -2, "role");

                    lua_pushinteger(callbackState, node.advertTimestamp);
                    lua_setfield(callbackState, -2, "advert_timestamp");

                    // Calculate age in seconds
                    uint32_t age = (millis() - node.lastSeen) / 1000;
                    lua_pushinteger(callbackState, age);
                    lua_setfield(callbackState, -2, "age_seconds");

                    lua_pushinteger(callbackState, node.lastSeen);
                    lua_setfield(callbackState, -2, "last_seen");

                    // Public key as hex string (if available)
                    if (node.hasPublicKey) {
                        char hexKey[ED25519_PUBLIC_KEY_SIZE * 2 + 1];
                        pubKeyToHex(node.publicKey, hexKey);
                        lua_pushstring(callbackState, hexKey);
                        lua_setfield(callbackState, -2, "pub_key_hex");
                    }

                    if (lua_pcall(callbackState, 1, 0, 0) != LUA_OK) {
                        Serial.printf("[Lua] Node callback error: %s\n",
                                     lua_tostring(callbackState, -1));
                        lua_pop(callbackState, 1);
                    }
                }
            });
        }
    } else if (lua_isnil(L, 1)) {
        // Clear callback
        nodeCallbackRef = LUA_NOREF;
        if (mesh) {
            mesh->setNodeCallback(nullptr);
        }
    }

    return 0;
}

// @lua tdeck.mesh.on_group_packet(callback)
// @brief Set callback for raw group packets (before C++ decryption)
// @param callback Function(packet_table) called with {channel_hash, data, sender_hash, rssi, snr}
// @note When this callback is set, Lua takes over channel handling
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
                if (callbackState && groupPacketCallbackRef != LUA_NOREF) {
                    lua_rawgeti(callbackState, LUA_REGISTRYINDEX, groupPacketCallbackRef);

                    // Create packet table
                    lua_newtable(callbackState);

                    lua_pushinteger(callbackState, channelHash);
                    lua_setfield(callbackState, -2, "channel_hash");

                    // Pass raw encrypted data as binary string
                    lua_pushlstring(callbackState, reinterpret_cast<const char*>(data), dataLen);
                    lua_setfield(callbackState, -2, "data");

                    lua_pushinteger(callbackState, senderHash);
                    lua_setfield(callbackState, -2, "sender_hash");

                    lua_pushnumber(callbackState, rssi);
                    lua_setfield(callbackState, -2, "rssi");

                    lua_pushnumber(callbackState, snr);
                    lua_setfield(callbackState, -2, "snr");

                    if (lua_pcall(callbackState, 1, 0, 0) != LUA_OK) {
                        Serial.printf("[Lua] Group packet callback error: %s\n",
                                     lua_tostring(callbackState, -1));
                        lua_pop(callbackState, 1);
                    }
                }
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

// @lua tdeck.mesh.send_group_packet(channel_hash, encrypted_data) -> boolean
// @brief Send raw encrypted group packet
// @param channel_hash Single byte channel identifier
// @param encrypted_data Pre-encrypted payload (MAC + ciphertext)
// @return true if sent successfully
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

// @lua tdeck.mesh.on_packet(callback)
// @brief Set callback for ALL incoming packets (called before C++ handling)
// @param callback Function(packet_table) returning handled, rebroadcast booleans
// @note packet_table contains: route_type, payload_type, version, path (binary), payload (binary), rssi, snr, timestamp
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
                if (!callbackState || packetCallbackRef == LUA_NOREF) {
                    return {false, false};
                }

                lua_rawgeti(callbackState, LUA_REGISTRYINDEX, packetCallbackRef);

                // Create packet table
                lua_newtable(callbackState);

                lua_pushinteger(callbackState, pkt.routeType);
                lua_setfield(callbackState, -2, "route_type");

                lua_pushinteger(callbackState, pkt.payloadType);
                lua_setfield(callbackState, -2, "payload_type");

                lua_pushinteger(callbackState, pkt.version);
                lua_setfield(callbackState, -2, "version");

                // Path as binary string
                lua_pushlstring(callbackState, reinterpret_cast<const char*>(pkt.path), pkt.pathLen);
                lua_setfield(callbackState, -2, "path");

                // Payload as binary string
                lua_pushlstring(callbackState, reinterpret_cast<const char*>(pkt.payload), pkt.payloadLen);
                lua_setfield(callbackState, -2, "payload");

                lua_pushnumber(callbackState, pkt.rssi);
                lua_setfield(callbackState, -2, "rssi");

                lua_pushnumber(callbackState, pkt.snr);
                lua_setfield(callbackState, -2, "snr");

                lua_pushinteger(callbackState, pkt.timestamp);
                lua_setfield(callbackState, -2, "timestamp");

                // Call with 1 argument, expect 2 return values
                if (lua_pcall(callbackState, 1, 2, 0) != LUA_OK) {
                    Serial.printf("[Lua] Packet callback error: %s\n",
                                 lua_tostring(callbackState, -1));
                    lua_pop(callbackState, 1);
                    return {false, false};
                }

                // Get return values: handled, rebroadcast
                bool rebroadcast = lua_toboolean(callbackState, -1);
                bool handled = lua_toboolean(callbackState, -2);
                lua_pop(callbackState, 2);

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

// @lua tdeck.mesh.schedule_rebroadcast(data)
// @brief Schedule raw packet data for rebroadcast
// @param data Binary string of raw packet bytes
LUA_FUNCTION(l_mesh_schedule_rebroadcast) {
    LUA_CHECK_ARGC(L, 1);

    size_t dataLen;
    const char* data = luaL_checklstring(L, 1, &dataLen);

    if (mesh) {
        mesh->scheduleRawRebroadcast(reinterpret_cast<const uint8_t*>(data), dataLen);
    }

    return 0;
}

// @lua tdeck.mesh.get_path_hash() -> integer
// @brief Get this node's path hash (first byte of public key)
// @return Path hash as integer (0-255)
LUA_FUNCTION(l_mesh_get_path_hash) {
    if (!mesh) {
        lua_pushinteger(L, 0);
        return 1;
    }

    lua_pushinteger(L, mesh->getIdentity().getPathHash());
    return 1;
}

// @lua tdeck.mesh.get_public_key() -> string
// @brief Get this node's public key as binary string
// @return 32-byte Ed25519 public key
LUA_FUNCTION(l_mesh_get_public_key) {
    if (!mesh) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushlstring(L, reinterpret_cast<const char*>(mesh->getIdentity().getPublicKey()),
                    ED25519_PUBLIC_KEY_SIZE);
    return 1;
}

// @lua tdeck.mesh.build_packet(route_type, payload_type, payload, path) -> string|nil
// @brief Build a raw mesh packet for transmission
// @param route_type Route type constant (FLOOD=1, DIRECT=2)
// @param payload_type Payload type constant (ADVERT=4, GRP_TXT=5, etc.)
// @param payload Binary string payload
// @param path Optional binary string of path hashes (default: empty)
// @return Serialized packet as binary string, or nil on error
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

// @lua tdeck.mesh.parse_header(header_byte) -> route_type, payload_type, version
// @brief Parse a packet header byte into components
// @param header_byte Single byte header value
// @return route_type, payload_type, version as integers
LUA_FUNCTION(l_mesh_parse_header) {
    LUA_CHECK_ARGC(L, 1);
    lua_Integer header = luaL_checkinteger(L, 1);

    lua_pushinteger(L, header & PH_ROUTE_MASK);
    lua_pushinteger(L, (header >> PH_TYPE_SHIFT) & PH_TYPE_MASK);
    lua_pushinteger(L, (header >> PH_VER_SHIFT) & PH_VER_MASK);
    return 3;
}

// @lua tdeck.mesh.make_header(route_type, payload_type, version) -> integer
// @brief Create a packet header byte from components
// @param route_type Route type constant
// @param payload_type Payload type constant
// @param version Optional version (default: 0)
// @return Header byte as integer
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

// @lua tdeck.mesh.send_raw(data) -> boolean
// @brief Send raw packet data directly via radio
// @param data Binary string of serialized packet
// @return true if sent successfully
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

// Function table for tdeck.mesh
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
    {"build_packet",         l_mesh_build_packet},
    {"parse_header",         l_mesh_parse_header},
    {"make_header",          l_mesh_make_header},
    {"send_raw",             l_mesh_send_raw},
    {nullptr, nullptr}
};

// Register the mesh module
void registerMeshModule(lua_State* L) {
    lua_register_module(L, "mesh", mesh_funcs);

    // Register route type constants
    lua_getglobal(L, "tdeck");
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

    Serial.println("[LuaRuntime] Registered tdeck.mesh");
}
