// tdeck.mesh module bindings
// Provides mesh networking functions

#include "../lua_bindings.h"
#include "../../mesh/meshcore.h"
#include "../../mesh/identity.h"

// External reference to the global mesh instance
extern MeshCore* mesh;

// Callback references for Lua callbacks
static int nodeCallbackRef = LUA_NOREF;
static int channelMsgCallbackRef = LUA_NOREF;
static lua_State* callbackState = nullptr;

// @lua tdeck.mesh.is_initialized() -> boolean
// @brief Check if mesh networking is initialized
// @return true if mesh is ready
LUA_FUNCTION(l_mesh_is_initialized) {
    lua_pushboolean(L, mesh != nullptr);
    return 1;
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

// @lua tdeck.mesh.get_nodes() -> table
// @brief Get list of discovered mesh nodes
// @return Array of node tables with path_hash, name, rssi, snr, last_seen, hops
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

        // Calculate age in seconds
        uint32_t age = (millis() - node.lastSeen) / 1000;
        lua_pushinteger(L, age);
        lua_setfield(L, -2, "age_seconds");

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

// @lua tdeck.mesh.join_channel(name, password) -> boolean
// @brief Join or create a channel
// @param name Channel name
// @param password Optional password for encryption
// @return true if successful
LUA_FUNCTION(l_mesh_join_channel) {
    LUA_CHECK_ARGC_RANGE(L, 1, 2);
    const char* name = luaL_checkstring(L, 1);
    const char* password = lua_isstring(L, 2) ? lua_tostring(L, 2) : nullptr;

    if (!mesh) {
        lua_pushboolean(L, false);
        return 1;
    }

    bool ok = mesh->joinChannel(name, password);
    lua_pushboolean(L, ok);
    return 1;
}

// @lua tdeck.mesh.leave_channel(name) -> boolean
// @brief Leave a channel
// @param name Channel name to leave
// @return true if successful
LUA_FUNCTION(l_mesh_leave_channel) {
    LUA_CHECK_ARGC(L, 1);
    const char* name = luaL_checkstring(L, 1);

    if (!mesh) {
        lua_pushboolean(L, false);
        return 1;
    }

    bool ok = mesh->leaveChannel(name);
    lua_pushboolean(L, ok);
    return 1;
}

// @lua tdeck.mesh.is_in_channel(name) -> boolean
// @brief Check if joined to channel
// @param name Channel name
// @return true if member of channel
LUA_FUNCTION(l_mesh_is_in_channel) {
    LUA_CHECK_ARGC(L, 1);
    const char* name = luaL_checkstring(L, 1);

    bool inChannel = mesh && mesh->isInChannel(name);
    lua_pushboolean(L, inChannel);
    return 1;
}

// @lua tdeck.mesh.get_channels() -> table
// @brief Get list of known channels
// @return Array of channel tables with name, is_joined, is_encrypted
LUA_FUNCTION(l_mesh_get_channels) {
    if (!mesh) {
        lua_newtable(L);
        return 1;
    }

    const auto& channels = mesh->getChannels();
    lua_createtable(L, channels.size(), 0);

    int idx = 1;
    for (const auto& ch : channels) {
        lua_newtable(L);

        lua_pushstring(L, ch.name);
        lua_setfield(L, -2, "name");

        lua_pushboolean(L, ch.isJoined);
        lua_setfield(L, -2, "is_joined");

        lua_pushboolean(L, ch.isEncrypted);
        lua_setfield(L, -2, "is_encrypted");

        lua_pushinteger(L, ch.unreadCount);
        lua_setfield(L, -2, "unread_count");

        lua_pushinteger(L, ch.lastActivity);
        lua_setfield(L, -2, "last_activity");

        lua_rawseti(L, -2, idx++);
    }

    return 1;
}

// @lua tdeck.mesh.send_channel_message(channel, text) -> boolean
// @brief Send message to a channel
// @param channel Channel name
// @param text Message text
// @return true if sent successfully
LUA_FUNCTION(l_mesh_send_channel_message) {
    LUA_CHECK_ARGC(L, 2);
    const char* channel = luaL_checkstring(L, 1);
    const char* text = luaL_checkstring(L, 2);

    if (!mesh) {
        lua_pushboolean(L, false);
        return 1;
    }

    bool ok = mesh->sendChannelMessage(channel, text);
    lua_pushboolean(L, ok);
    return 1;
}

// @lua tdeck.mesh.get_channel_messages(channel) -> table
// @brief Get messages for a channel
// @param channel Optional channel filter
// @return Array of message tables
LUA_FUNCTION(l_mesh_get_channel_messages) {
    const char* channelFilter = nullptr;
    if (lua_gettop(L) >= 1 && lua_isstring(L, 1)) {
        channelFilter = lua_tostring(L, 1);
    }

    if (!mesh) {
        lua_newtable(L);
        return 1;
    }

    const auto& messages = mesh->getChannelMessages();
    lua_newtable(L);

    int idx = 1;
    for (const auto& msg : messages) {
        // Filter by channel if specified
        if (channelFilter && strcmp(msg.channel, channelFilter) != 0) {
            continue;
        }

        lua_newtable(L);

        lua_pushstring(L, msg.channel);
        lua_setfield(L, -2, "channel");

        lua_pushinteger(L, msg.fromHash);
        lua_setfield(L, -2, "from_hash");

        lua_pushstring(L, msg.text);
        lua_setfield(L, -2, "text");

        lua_pushinteger(L, msg.timestamp);
        lua_setfield(L, -2, "timestamp");

        lua_pushboolean(L, msg.isRead);
        lua_setfield(L, -2, "is_read");

        lua_pushboolean(L, msg.verified);
        lua_setfield(L, -2, "verified");

        lua_pushboolean(L, msg.isOurs);
        lua_setfield(L, -2, "is_ours");

        lua_rawseti(L, -2, idx++);
    }

    return 1;
}

// @lua tdeck.mesh.mark_channel_read(channel)
// @brief Mark channel messages as read
// @param channel Channel name
LUA_FUNCTION(l_mesh_mark_channel_read) {
    LUA_CHECK_ARGC(L, 1);
    const char* channel = luaL_checkstring(L, 1);

    if (mesh) {
        mesh->markChannelMessagesRead(channel);
    }
    return 0;
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

                    // Push node as table
                    lua_newtable(callbackState);
                    lua_pushinteger(callbackState, node.pathHash);
                    lua_setfield(callbackState, -2, "path_hash");
                    lua_pushstring(callbackState, node.name);
                    lua_setfield(callbackState, -2, "name");
                    lua_pushnumber(callbackState, node.lastRssi);
                    lua_setfield(callbackState, -2, "rssi");
                    lua_pushnumber(callbackState, node.lastSnr);
                    lua_setfield(callbackState, -2, "snr");

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

// @lua tdeck.mesh.on_channel_message(callback)
// @brief Set callback for incoming channel messages
// @param callback Function(message_table) called on new message
LUA_FUNCTION(l_mesh_on_channel_message) {
    LUA_CHECK_ARGC(L, 1);

    if (channelMsgCallbackRef != LUA_NOREF && callbackState) {
        luaL_unref(callbackState, LUA_REGISTRYINDEX, channelMsgCallbackRef);
    }

    if (lua_isfunction(L, 1)) {
        lua_pushvalue(L, 1);
        channelMsgCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX);
        callbackState = L;

        if (mesh) {
            mesh->setChannelCallback([](const ChannelMessage& msg) {
                if (callbackState && channelMsgCallbackRef != LUA_NOREF) {
                    lua_rawgeti(callbackState, LUA_REGISTRYINDEX, channelMsgCallbackRef);

                    lua_newtable(callbackState);
                    lua_pushstring(callbackState, msg.channel);
                    lua_setfield(callbackState, -2, "channel");
                    lua_pushstring(callbackState, msg.text);
                    lua_setfield(callbackState, -2, "text");
                    lua_pushinteger(callbackState, msg.fromHash);
                    lua_setfield(callbackState, -2, "from_hash");
                    lua_pushboolean(callbackState, msg.isOurs);
                    lua_setfield(callbackState, -2, "is_ours");

                    if (lua_pcall(callbackState, 1, 0, 0) != LUA_OK) {
                        Serial.printf("[Lua] Channel msg callback error: %s\n",
                                     lua_tostring(callbackState, -1));
                        lua_pop(callbackState, 1);
                    }
                }
            });
        }
    } else if (lua_isnil(L, 1)) {
        channelMsgCallbackRef = LUA_NOREF;
        if (mesh) {
            mesh->setChannelCallback(nullptr);
        }
    }

    return 0;
}

// Function table for tdeck.mesh
static const luaL_Reg mesh_funcs[] = {
    {"is_initialized",       l_mesh_is_initialized},
    {"get_node_id",          l_mesh_get_node_id},
    {"get_short_id",         l_mesh_get_short_id},
    {"get_node_name",        l_mesh_get_node_name},
    {"set_node_name",        l_mesh_set_node_name},
    {"get_nodes",            l_mesh_get_nodes},
    {"get_node_count",       l_mesh_get_node_count},
    {"join_channel",         l_mesh_join_channel},
    {"leave_channel",        l_mesh_leave_channel},
    {"is_in_channel",        l_mesh_is_in_channel},
    {"get_channels",         l_mesh_get_channels},
    {"send_channel_message", l_mesh_send_channel_message},
    {"get_channel_messages", l_mesh_get_channel_messages},
    {"mark_channel_read",    l_mesh_mark_channel_read},
    {"send_announce",        l_mesh_send_announce},
    {"get_tx_count",         l_mesh_get_tx_count},
    {"get_rx_count",         l_mesh_get_rx_count},
    {"on_node_discovered",   l_mesh_on_node_discovered},
    {"on_channel_message",   l_mesh_on_channel_message},
    {nullptr, nullptr}
};

// Register the mesh module
void registerMeshModule(lua_State* L) {
    lua_register_module(L, "mesh", mesh_funcs);
    Serial.println("[LuaRuntime] Registered tdeck.mesh");
}
