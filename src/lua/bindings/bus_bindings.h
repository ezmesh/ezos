// tdeck.bus module bindings
// Global message bus for C++ and Lua communication

#pragma once

#include "../lua_bindings.h"
#include <functional>
#include <string>
#include <vector>
#include <deque>
#include <map>
#include <mutex>

// Forward declaration
void registerBusModule(lua_State* L);

// Subscription entry for Lua callbacks
struct LuaSubscription {
    int callbackRef;      // Reference to Lua callback function
    std::string topic;    // Topic pattern
    bool active;          // Whether subscription is active
};

// Subscription entry for C++ callbacks (receives lua_State to read table data)
struct CppSubscription {
    std::function<void(lua_State* L, const std::string& topic)> callback;
    std::string topic;
    bool active;
};

// Function type for building a Lua table from C++
// Called during message delivery with lua_State, should push one table onto stack
using TableBuilder = std::function<void(lua_State*)>;

// Queued message for deferred delivery
struct QueuedMessage {
    std::string topic;
    // For string data (legacy/simple events)
    std::string stringData;
    // For table data from C++ (builder creates table at delivery time)
    TableBuilder tableBuilder;
    // For table data from Lua (registry reference)
    int tableRef = LUA_NOREF;
    // Type flag
    enum class DataType { String, Table, TableBuilder } dataType = DataType::String;
};

// Global message bus singleton
// Enables pub/sub communication between C++ and Lua code
class MessageBus {
public:
    // Get singleton instance
    static MessageBus& instance();

    // Subscribe a Lua callback to a topic
    // Returns subscription ID (used for unsubscribe)
    // Callback signature: function(topic, data) where data is string or table
    int subscribe(lua_State* L, const char* topic, int callbackRef);

    // Unsubscribe by subscription ID
    // Returns true if subscription was found and removed
    bool unsubscribe(int subscriptionId);

    // Post a string message to a topic (legacy, for simple events)
    void post(const char* topic, const char* data);

    // Post a table message from C++ using a builder function
    // The builder is called during process() to create the Lua table
    void postTable(const char* topic, TableBuilder builder);

    // Post a table message from Lua (stores registry reference)
    void postLuaTable(lua_State* L, const char* topic, int tableRef);

    // Process pending messages (call from main loop)
    // Delivers all queued messages to subscribers
    void process(lua_State* L);

    // Subscribe a C++ callback to a topic
    // Callback receives lua_State with data on stack (string or table at index -1)
    int subscribeCpp(const char* topic, std::function<void(lua_State*, const std::string&)> callback);

    // Check if a topic has any active subscribers
    bool hasSubscribers(const char* topic) const;

    // Get number of pending messages in queue
    size_t getPendingCount() const;

    // Clear all subscriptions (useful for cleanup/reset)
    void clearAll(lua_State* L);

private:
    MessageBus() = default;
    ~MessageBus() = default;
    MessageBus(const MessageBus&) = delete;
    MessageBus& operator=(const MessageBus&) = delete;

    // Check if topic matches pattern (supports wildcards in future)
    bool topicMatches(const std::string& pattern, const std::string& topic) const;

    // Push message data onto Lua stack (string or table)
    void pushMessageData(lua_State* L, QueuedMessage& msg);

    // Subscription storage
    std::map<int, LuaSubscription> _luaSubscriptions;
    std::map<int, CppSubscription> _cppSubscriptions;
    int _nextSubscriptionId = 1;

    // Message queue for deferred delivery
    std::deque<QueuedMessage> _messageQueue;
    static constexpr size_t MAX_QUEUE_SIZE = 64;

    // Thread safety for FreeRTOS
    mutable std::mutex _mutex;

    // Cached lua state for C++ callbacks that need to post
    lua_State* _cachedState = nullptr;
};
