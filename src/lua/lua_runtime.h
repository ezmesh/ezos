#pragma once

#include <Arduino.h>
#include <functional>

// Forward declarations to avoid including full Lua headers everywhere
struct lua_State;

// Callback types for Lua events
using LuaErrorCallback = std::function<void(const char* error)>;

// Lua runtime manager - singleton for managing the Lua state
class LuaRuntime {
public:
    // Get singleton instance
    static LuaRuntime& instance();

    // Prevent copying
    LuaRuntime(const LuaRuntime&) = delete;
    LuaRuntime& operator=(const LuaRuntime&) = delete;

    // Initialize the Lua runtime with PSRAM-backed memory
    bool init();

    // Shutdown and cleanup
    void shutdown();

    // Check if initialized
    bool isInitialized() const { return _state != nullptr; }

    // Get the raw Lua state (for advanced usage)
    lua_State* getState() { return _state; }

    // Load and execute a script from string
    bool executeString(const char* script, const char* name = "chunk");

    // Load and execute a script file from LittleFS
    bool executeFile(const char* path);

    // Call a global Lua function with no arguments
    bool callGlobalFunction(const char* name);

    // Call a method on a Lua table (e.g., screen:render())
    // tableRef is a registry reference to the table
    bool callTableMethod(int tableRef, const char* method);
    bool callTableMethod(int tableRef, const char* method, int arg1);

    // Create a reference to the value on top of the stack
    int createRef();

    // Push a referenced value onto the stack
    void pushRef(int ref);

    // Release a reference
    void releaseRef(int ref);

    // Register all tdeck.* modules
    void registerAllModules();

    // Get memory usage info
    size_t getMemoryUsed() const { return _memoryUsed; }

    // Error handling
    void setErrorCallback(LuaErrorCallback callback) { _errorCallback = callback; }
    const char* getLastError() const { return _lastError; }

    // Process pending timers and coroutines (call from main loop)
    void update();

    // Hot reload support
    bool reloadScripts();
    bool reloadBootScript();

    // Garbage collection control
    void collectGarbage();
    void setGCPause(int pause);
    void setGCStepMul(int stepmul);

    // Memory pressure handling
    bool isLowMemory() const;
    size_t getAvailableMemory() const;

private:
    LuaRuntime() = default;
    ~LuaRuntime();

    lua_State* _state = nullptr;
    size_t _memoryUsed = 0;
    char _lastError[256] = {0};
    LuaErrorCallback _errorCallback = nullptr;

    // Custom allocator for PSRAM support
    static void* luaAlloc(void* ud, void* ptr, size_t osize, size_t nsize);

    // Error handler for protected calls
    static int errorHandler(lua_State* L);

    // Report error to callback and serial
    void reportError(const char* error);

    // Create the tdeck global table
    void createTdeckNamespace();
};

// Convenience macro to get the Lua state
#define LUA_STATE LuaRuntime::instance().getState()
