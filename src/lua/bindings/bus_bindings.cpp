// ez.bus module bindings
// Global message bus for C++ and Lua communication

#include "bus_bindings.h"
#include <Arduino.h>

// @module ez.bus
// @brief Publish/subscribe message bus for decoupled communication
// @description
// Enables loose coupling between components through topic-based messaging.
// Any component can post messages to topics, and any component can subscribe
// to receive them. Messages are delivered synchronously during the next
// scheduler update. See the Message Bus tab for available system topics.
// @end

// Singleton instance
MessageBus& MessageBus::instance() {
    static MessageBus bus;
    return bus;
}

bool MessageBus::topicMatches(const std::string& pattern, const std::string& topic) const {
    // Exact match for now (wildcard support can be added later)
    return pattern == topic;
}

int MessageBus::subscribe(lua_State* L, const char* topic, int callbackRef) {
    std::lock_guard<std::mutex> lock(_mutex);

    int id = _nextSubscriptionId++;

    LuaSubscription sub;
    sub.callbackRef = callbackRef;
    sub.topic = topic;
    sub.active = true;

    _luaSubscriptions[id] = sub;
    _cachedState = L;

    Serial.printf("[MessageBus] Lua subscribe id=%d topic=%s\n", id, topic);
    return id;
}

bool MessageBus::unsubscribe(int subscriptionId) {
    std::lock_guard<std::mutex> lock(_mutex);

    // Check Lua subscriptions
    auto luaIt = _luaSubscriptions.find(subscriptionId);
    if (luaIt != _luaSubscriptions.end()) {
        luaIt->second.active = false;
        Serial.printf("[MessageBus] Unsubscribed id=%d\n", subscriptionId);
        return true;
    }

    // Check C++ subscriptions
    auto cppIt = _cppSubscriptions.find(subscriptionId);
    if (cppIt != _cppSubscriptions.end()) {
        cppIt->second.active = false;
        return true;
    }

    return false;
}

void MessageBus::post(const char* topic, const char* data) {
    std::lock_guard<std::mutex> lock(_mutex);

    if (_messageQueue.size() >= MAX_QUEUE_SIZE) {
        Serial.println("[MessageBus] Queue full, dropping message");
        return;
    }

    QueuedMessage msg;
    msg.topic = topic;
    msg.stringData = data ? data : "";
    msg.dataType = QueuedMessage::DataType::String;
    _messageQueue.push_back(std::move(msg));
}

void MessageBus::postTable(const char* topic, TableBuilder builder) {
    std::lock_guard<std::mutex> lock(_mutex);

    if (_messageQueue.size() >= MAX_QUEUE_SIZE) {
        Serial.println("[MessageBus] Queue full, dropping table message");
        return;
    }

    QueuedMessage msg;
    msg.topic = topic;
    msg.tableBuilder = std::move(builder);
    msg.dataType = QueuedMessage::DataType::TableBuilder;
    _messageQueue.push_back(std::move(msg));
}

void MessageBus::postLuaTable(lua_State* L, const char* topic, int tableRef) {
    std::lock_guard<std::mutex> lock(_mutex);

    if (_messageQueue.size() >= MAX_QUEUE_SIZE) {
        Serial.println("[MessageBus] Queue full, dropping Lua table message");
        // Release the reference since we're not using it
        luaL_unref(L, LUA_REGISTRYINDEX, tableRef);
        return;
    }

    QueuedMessage msg;
    msg.topic = topic;
    msg.tableRef = tableRef;
    msg.dataType = QueuedMessage::DataType::Table;
    _messageQueue.push_back(std::move(msg));
}

void MessageBus::pushMessageData(lua_State* L, QueuedMessage& msg) {
    switch (msg.dataType) {
        case QueuedMessage::DataType::String:
            lua_pushstring(L, msg.stringData.c_str());
            break;

        case QueuedMessage::DataType::TableBuilder:
            if (msg.tableBuilder) {
                msg.tableBuilder(L);
            } else {
                lua_newtable(L);  // Empty table as fallback
            }
            break;

        case QueuedMessage::DataType::Table:
            if (msg.tableRef != LUA_NOREF) {
                lua_rawgeti(L, LUA_REGISTRYINDEX, msg.tableRef);
            } else {
                lua_newtable(L);  // Empty table as fallback
            }
            break;
    }
}

void MessageBus::process(lua_State* L) {
    // Take a snapshot of messages to process (avoid holding lock during callbacks)
    std::vector<QueuedMessage> toProcess;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        toProcess.reserve(_messageQueue.size());
        while (!_messageQueue.empty()) {
            toProcess.push_back(std::move(_messageQueue.front()));
            _messageQueue.pop_front();
        }
        _cachedState = L;
    }

    if (toProcess.empty()) return;

    // Process each message
    for (auto& msg : toProcess) {
        // Collect matching subscriptions (avoid holding lock during callbacks)
        std::vector<std::pair<int, int>> luaCallbacks;
        std::vector<std::pair<int, std::function<void(lua_State*, const std::string&)>>> cppCallbacks;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            for (auto& [id, sub] : _luaSubscriptions) {
                if (sub.active && topicMatches(sub.topic, msg.topic)) {
                    luaCallbacks.push_back({id, sub.callbackRef});
                }
            }
            for (auto& [id, sub] : _cppSubscriptions) {
                if (sub.active && topicMatches(sub.topic, msg.topic)) {
                    cppCallbacks.push_back({id, sub.callback});
                }
            }
        }

        // Deliver to C++ subscribers first
        for (const auto& [id, callback] : cppCallbacks) {
            pushMessageData(L, msg);  // Push data onto stack
            callback(L, msg.topic);   // Callback reads from stack
            lua_pop(L, 1);            // Pop data
        }

        // Deliver to Lua subscribers
        for (const auto& [id, callbackRef] : luaCallbacks) {
            // Get callback function from registry
            lua_rawgeti(L, LUA_REGISTRYINDEX, callbackRef);

            if (lua_isfunction(L, -1)) {
                // Push arguments: topic, data (string or table)
                lua_pushstring(L, msg.topic.c_str());
                pushMessageData(L, msg);

                // Call callback(topic, data)
                if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
                    Serial.printf("[MessageBus] Callback error: %s\n",
                                 lua_tostring(L, -1));
                    lua_pop(L, 1);
                }
            } else {
                lua_pop(L, 1);
            }
        }

        // Release Lua table reference after all deliveries
        if (msg.dataType == QueuedMessage::DataType::Table && msg.tableRef != LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX, msg.tableRef);
        }
    }
}

int MessageBus::subscribeCpp(const char* topic, std::function<void(lua_State*, const std::string&)> callback) {
    std::lock_guard<std::mutex> lock(_mutex);

    int id = _nextSubscriptionId++;

    CppSubscription sub;
    sub.callback = std::move(callback);
    sub.topic = topic;
    sub.active = true;

    _cppSubscriptions[id] = std::move(sub);

    Serial.printf("[MessageBus] C++ subscribe id=%d topic=%s\n", id, topic);
    return id;
}

bool MessageBus::hasSubscribers(const char* topic) const {
    std::lock_guard<std::mutex> lock(_mutex);

    std::string topicStr(topic);

    for (const auto& [id, sub] : _luaSubscriptions) {
        if (sub.active && topicMatches(sub.topic, topicStr)) {
            return true;
        }
    }

    for (const auto& [id, sub] : _cppSubscriptions) {
        if (sub.active && topicMatches(sub.topic, topicStr)) {
            return true;
        }
    }

    return false;
}

size_t MessageBus::getPendingCount() const {
    std::lock_guard<std::mutex> lock(_mutex);
    return _messageQueue.size();
}

void MessageBus::clearAll(lua_State* L) {
    std::lock_guard<std::mutex> lock(_mutex);

    // Release Lua callback references
    for (auto& [id, sub] : _luaSubscriptions) {
        if (sub.callbackRef != LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX, sub.callbackRef);
        }
    }

    // Release any pending Lua table references
    for (auto& msg : _messageQueue) {
        if (msg.dataType == QueuedMessage::DataType::Table && msg.tableRef != LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX, msg.tableRef);
        }
    }

    _luaSubscriptions.clear();
    _cppSubscriptions.clear();
    _messageQueue.clear();

    Serial.println("[MessageBus] Cleared all subscriptions");
}

// =============================================================================
// Lua Bindings
// =============================================================================

// @lua ez.bus.subscribe(topic, callback) -> subscription_id
// @brief Subscribe to a topic with a callback function
// @description The message bus provides pub/sub communication between Lua scripts
// and C++ code. Topics are strings like "screen/pushed" or "mesh/message". When a
// message is posted to a topic, all subscribers receive it with the topic name and
// data payload. Keep the returned subscription ID to unsubscribe later.
// @param topic Topic string to subscribe to
// @param callback Function(topic, data) called when message received
// @return Subscription ID for use with unsubscribe
// @example
// local sub_id = ez.bus.subscribe("mesh/message", function(topic, data)
//     print("Received:", data.text, "from", data.sender)
// end)
// @end
LUA_FUNCTION(l_bus_subscribe) {
    LUA_CHECK_ARGC(L, 2);

    const char* topic = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);

    // Create reference to callback
    lua_pushvalue(L, 2);
    int callbackRef = luaL_ref(L, LUA_REGISTRYINDEX);

    int subId = MessageBus::instance().subscribe(L, topic, callbackRef);

    lua_pushinteger(L, subId);
    return 1;
}

// @lua ez.bus.unsubscribe(subscription_id) -> boolean
// @brief Unsubscribe from a topic
// @description Removes a subscription created with subscribe(). Always unsubscribe
// when a screen exits or a service shuts down to prevent memory leaks and stale
// callbacks. Returns false if the subscription ID was not found.
// @param subscription_id ID returned from subscribe()
// @return true if subscription was found and removed
// @example
// function MyScreen:on_exit()
//     if self.sub_id then
//         ez.bus.unsubscribe(self.sub_id)
//     end
// end
// @end
LUA_FUNCTION(l_bus_unsubscribe) {
    LUA_CHECK_ARGC(L, 1);

    int subId = luaL_checkinteger(L, 1);

    // Get callback ref before unsubscribing so we can release it
    bool found = MessageBus::instance().unsubscribe(subId);

    lua_pushboolean(L, found);
    return 1;
}

// @lua ez.bus.post(topic, data)
// @brief Post a message to a topic
// @description Sends a message to all subscribers of the given topic. The data can
// be a string or a table. Messages are queued and delivered on the next main loop
// iteration, so posting is non-blocking. Use consistent topic naming like
// "module/event" (e.g., "screen/pushed", "mesh/node_discovered").
// @param topic Topic string to post to
// @param data Message data (string or table)
// @example
// -- Post a string message
// ez.bus.post("status/update", "connected")
// -- Post a table with structured data
// ez.bus.post("chat/message", {sender = "Alice", text = "Hello!"})
// @end
LUA_FUNCTION(l_bus_post) {
    LUA_CHECK_ARGC(L, 2);

    const char* topic = luaL_checkstring(L, 1);

    // Check if data is a table or string
    if (lua_istable(L, 2)) {
        // Copy the table to registry so it survives until delivery
        lua_pushvalue(L, 2);
        int tableRef = luaL_ref(L, LUA_REGISTRYINDEX);
        MessageBus::instance().postLuaTable(L, topic, tableRef);
    } else {
        // Treat as string (nil becomes empty string)
        const char* data = lua_isnil(L, 2) ? "" : luaL_checkstring(L, 2);
        MessageBus::instance().post(topic, data);
    }

    return 0;
}

// @lua ez.bus.has_subscribers(topic) -> boolean
// @brief Check if a topic has any active subscribers
// @description Useful for avoiding expensive work when no one is listening. For
// example, skip serializing debug data if no debug panel is subscribed.
// @param topic Topic string to check
// @return true if one or more subscribers exist
// @example
// if ez.bus.has_subscribers("debug/memory") then
//     ez.bus.post("debug/memory", {heap = ez.system.get_free_heap()})
// end
// @end
LUA_FUNCTION(l_bus_has_subscribers) {
    LUA_CHECK_ARGC(L, 1);

    const char* topic = luaL_checkstring(L, 1);

    lua_pushboolean(L, MessageBus::instance().hasSubscribers(topic));
    return 1;
}

// @lua ez.bus.pending_count() -> integer
// @brief Get number of messages waiting in queue
// @description Returns the number of messages posted but not yet delivered to
// subscribers. Messages are delivered during the main loop, so this count is
// typically 0 or low. A high count might indicate subscribers are slow.
// @return Number of pending messages
// @example
// local pending = ez.bus.pending_count()
// if pending > 10 then
//     print("Warning: message queue backing up")
// end
// @end
LUA_FUNCTION(l_bus_pending_count) {
    lua_pushinteger(L, MessageBus::instance().getPendingCount());
    return 1;
}

// Function table for ez.bus
static const luaL_Reg bus_funcs[] = {
    {"subscribe",       l_bus_subscribe},
    {"unsubscribe",     l_bus_unsubscribe},
    {"post",            l_bus_post},
    {"has_subscribers", l_bus_has_subscribers},
    {"pending_count",   l_bus_pending_count},
    {nullptr, nullptr}
};

// Built-in C++ echo handler for testing
static int echoSubscriptionId = 0;

static void setupBuiltinHandlers() {
    // Echo handler: messages to "bus/ping" are echoed back on "bus/echo"
    echoSubscriptionId = MessageBus::instance().subscribeCpp("bus/ping",
        [](lua_State* L, const std::string& topic) {
            // Data is on top of stack - for echo we just convert to string
            const char* data = "";
            if (lua_isstring(L, -1)) {
                data = lua_tostring(L, -1);
            }
            MessageBus::instance().post("bus/echo", data);
        });
}

// Register the bus module
void registerBusModule(lua_State* L) {
    lua_register_module(L, "bus", bus_funcs);

    // Set up built-in C++ handlers
    setupBuiltinHandlers();

    Serial.println("[LuaRuntime] Registered ez.bus");
}
