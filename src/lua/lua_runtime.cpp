#include "lua_runtime.h"
#include "async.h"
#include "embedded_scripts.h"
#include "../config.h"
#include "../util/log.h"
#include <esp_heap_caps.h>
#include <LittleFS.h>
#include <SD.h>
#include <string>

// Include Lua headers
extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

// Forward declarations of module registration functions
void registerSystemModule(lua_State* L);
void registerDisplayModule(lua_State* L);
void registerKeyboardModule(lua_State* L);
// Phase 3 modules
void registerRadioModule(lua_State* L);
void registerMeshModule(lua_State* L);
void registerAudioModule(lua_State* L);
// Phase 4 modules
void registerStorageModule(lua_State* L);
void registerCryptoModule(lua_State* L);
// GPS module
#include "bindings/gps_bindings.h"
// WiFi module
void registerWifiModule(lua_State* L);
// Message bus module
#include "bindings/bus_bindings.h"

LuaRuntime& LuaRuntime::instance() {
    static LuaRuntime runtime;
    return runtime;
}

LuaRuntime::~LuaRuntime() {
    shutdown();
}

void* LuaRuntime::luaAlloc(void* ud, void* ptr, size_t osize, size_t nsize) {
    LuaRuntime* self = static_cast<LuaRuntime*>(ud);

    // Free operation
    if (nsize == 0) {
        if (ptr != nullptr) {
            self->_memoryUsed -= osize;
            heap_caps_free(ptr);
        }
        return nullptr;
    }

    // Allocation or reallocation - always prefer PSRAM
    void* newPtr = nullptr;

    // Try PSRAM first
    if (ptr == nullptr) {
        newPtr = heap_caps_malloc(nsize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    } else {
        newPtr = heap_caps_realloc(ptr, nsize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    }

    // Fall back to internal RAM only if PSRAM allocation failed
    if (newPtr == nullptr) {
        if (ptr == nullptr) {
            newPtr = heap_caps_malloc(nsize, MALLOC_CAP_8BIT);
        } else {
            newPtr = heap_caps_realloc(ptr, nsize, MALLOC_CAP_8BIT);
        }
    }

    if (newPtr != nullptr) {
        self->_memoryUsed = self->_memoryUsed - osize + nsize;
    }

    return newPtr;
}

int LuaRuntime::errorHandler(lua_State* L) {
    const char* msg = lua_tostring(L, 1);
    if (msg == nullptr) {
        msg = "(error object is not a string)";
    }

    // Add traceback
    luaL_traceback(L, L, msg, 1);
    return 1;
}

void LuaRuntime::reportError(const char* error) {
    // Store error message
    strncpy(_lastError, error, sizeof(_lastError) - 1);
    _lastError[sizeof(_lastError) - 1] = '\0';

    // Log to serial
    LOG("Lua Error", "%s", error);

    // Call error callback if set
    if (_errorCallback) {
        _errorCallback(error);
    }
}

bool LuaRuntime::init() {
    if (_state != nullptr) {
        LOG("LuaRuntime", "Already initialized");
        return true;
    }

    LOG("LuaRuntime", "Initializing...");

    // Create Lua state with custom allocator
    _state = lua_newstate(luaAlloc, this);
    if (_state == nullptr) {
        reportError("Failed to create Lua state");
        return false;
    }

    // Open standard libraries
    luaL_openlibs(_state);


    // Create the ez namespace
    createEzNamespace();

    // Register all hardware modules
    registerAllModules();

    // Initialize async I/O system (worker task on Core 0)
    if (!AsyncIO::instance().init(_state)) {
        LOG("LuaRuntime", "Warning: AsyncIO init failed");
    }

    LOG("LuaRuntime", "Initialized, memory: %u bytes", _memoryUsed);
    return true;
}

void LuaRuntime::shutdown() {
    if (_state != nullptr) {
        lua_close(_state);
        _state = nullptr;
        _memoryUsed = 0;
        LOG("LuaRuntime", "Shutdown complete");
    }
}

void LuaRuntime::createEzNamespace() {
    // Create the global 'ez' table
    lua_newtable(_state);
    lua_setglobal(_state, "ez");
}


void LuaRuntime::registerAllModules() {
    LOG("LuaRuntime", "Registering modules...");

    // Each module adds itself to the tdeck table
    registerSystemModule(_state);
    registerDisplayModule(_state);
    registerKeyboardModule(_state);

    // Phase 3 modules
    registerRadioModule(_state);
    registerMeshModule(_state);
    registerAudioModule(_state);

    // Phase 4 modules
    registerStorageModule(_state);
    registerCryptoModule(_state);

    // GPS module
    gps_bindings::registerBindings(_state);

    // Async I/O bindings (async_read, async_write, async_exists)
    AsyncIO::registerBindings(_state);

    // Message bus module
    registerBusModule(_state);

    // WiFi module
    registerWifiModule(_state);

    LOG("LuaRuntime", "Modules registered");
}

bool LuaRuntime::executeString(const char* script, const char* name) {
    if (_state == nullptr) {
        reportError("Lua not initialized");
        return false;
    }

    // Push error handler
    lua_pushcfunction(_state, errorHandler);
    int errfunc = lua_gettop(_state);

    // Load the script
    int status = luaL_loadbuffer(_state, script, strlen(script), name);
    if (status != LUA_OK) {
        const char* err = lua_tostring(_state, -1);
        reportError(err ? err : "Load error");
        lua_pop(_state, 2);  // error message and error handler
        return false;
    }

    // Execute with error handler
    status = lua_pcall(_state, 0, LUA_MULTRET, errfunc);
    if (status != LUA_OK) {
        const char* err = lua_tostring(_state, -1);
        reportError(err ? err : "Runtime error");
        lua_pop(_state, 2);  // error message and error handler
        return false;
    }

    lua_remove(_state, errfunc);  // Remove error handler
    return true;
}

bool LuaRuntime::executeFile(const char* path) {
    if (_state == nullptr) {
        reportError("Lua not initialized");
        return false;
    }

    // Try embedded scripts first
    size_t size = 0;
    const char* embedded = embedded_lua::get_script(path, &size);
    if (embedded != nullptr) {
        // Execute directly from embedded data (no allocation needed)
        return executeBuffer(embedded, size, path);
    }

    // Fallback to SD card for /scripts/ paths
    if (strncmp(path, "/scripts/", 9) == 0) {
        // Map /scripts/foo.lua to /sd/scripts/foo.lua
        char sdPath[128];
        snprintf(sdPath, sizeof(sdPath), "/sd%s", path);

        // Ensure SD is initialized
        if (!SD.begin(SD_CS)) {
            reportError("SD card not available");
            return false;
        }

        File file = SD.open(sdPath + 3, "r");  // Skip "/sd" prefix for SD.open
        if (!file) {
            char err[128];
            snprintf(err, sizeof(err), "Script not found: %s", path);
            reportError(err);
            return false;
        }

        size_t fileSize = file.size();
        char* buffer = (char*)heap_caps_malloc(fileSize + 1, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (!buffer) {
            file.close();
            reportError("Out of memory loading script");
            return false;
        }

        size_t bytesRead = file.read((uint8_t*)buffer, fileSize);
        file.close();
        buffer[bytesRead] = '\0';

        bool result = executeBuffer(buffer, bytesRead, path);
        heap_caps_free(buffer);
        return result;
    }

    // Script not found
    char err[128];
    snprintf(err, sizeof(err), "Script not found: %s", path);
    reportError(err);
    return false;
}

bool LuaRuntime::executeBuffer(const char* buffer, size_t size, const char* name) {
    if (_state == nullptr) {
        reportError("Lua not initialized");
        return false;
    }

    // Push error handler
    lua_pushcfunction(_state, errorHandler);
    int errfunc = lua_gettop(_state);

    // Load the script from buffer
    int status = luaL_loadbuffer(_state, buffer, size, name);
    if (status != LUA_OK) {
        const char* err = lua_tostring(_state, -1);
        reportError(err ? err : "Load error");
        lua_pop(_state, 2);  // error message and error handler
        return false;
    }

    // Execute with error handler
    status = lua_pcall(_state, 0, LUA_MULTRET, errfunc);
    if (status != LUA_OK) {
        const char* err = lua_tostring(_state, -1);
        reportError(err ? err : "Runtime error");
        lua_pop(_state, 2);  // error message and error handler
        return false;
    }

    lua_remove(_state, errfunc);  // Remove error handler
    return true;
}

bool LuaRuntime::callGlobalFunction(const char* name) {
    if (_state == nullptr) return false;

    // Push error handler
    lua_pushcfunction(_state, errorHandler);
    int errfunc = lua_gettop(_state);

    // Get the global function
    lua_getglobal(_state, name);
    if (!lua_isfunction(_state, -1)) {
        lua_pop(_state, 2);  // value and error handler
        return false;
    }

    // Call with no arguments
    int status = lua_pcall(_state, 0, 0, errfunc);
    if (status != LUA_OK) {
        const char* err = lua_tostring(_state, -1);
        reportError(err ? err : "Call error");
        lua_pop(_state, 2);
        return false;
    }

    lua_remove(_state, errfunc);
    return true;
}

bool LuaRuntime::callTableMethod(int tableRef, const char* method) {
    if (_state == nullptr) return false;

    // Push error handler
    lua_pushcfunction(_state, errorHandler);
    int errfunc = lua_gettop(_state);

    // Push the table from registry
    lua_rawgeti(_state, LUA_REGISTRYINDEX, tableRef);
    if (!lua_istable(_state, -1)) {
        lua_pop(_state, 2);
        return false;
    }

    // Get the method
    lua_getfield(_state, -1, method);
    if (!lua_isfunction(_state, -1)) {
        lua_pop(_state, 3);  // method, table, error handler
        return false;
    }

    // Push table as first argument (self)
    lua_pushvalue(_state, -2);

    // Call method(self)
    int status = lua_pcall(_state, 1, 0, errfunc);
    if (status != LUA_OK) {
        const char* err = lua_tostring(_state, -1);
        reportError(err ? err : "Method call error");
        lua_pop(_state, 3);
        return false;
    }

    lua_pop(_state, 1);  // table
    lua_remove(_state, errfunc);
    return true;
}

bool LuaRuntime::callTableMethod(int tableRef, const char* method, int arg1) {
    if (_state == nullptr) return false;

    // Push error handler
    lua_pushcfunction(_state, errorHandler);
    int errfunc = lua_gettop(_state);

    // Push the table from registry
    lua_rawgeti(_state, LUA_REGISTRYINDEX, tableRef);
    if (!lua_istable(_state, -1)) {
        lua_pop(_state, 2);
        return false;
    }

    // Get the method
    lua_getfield(_state, -1, method);
    if (!lua_isfunction(_state, -1)) {
        lua_pop(_state, 3);
        return false;
    }

    // Push table as first argument (self)
    lua_pushvalue(_state, -2);

    // Push additional argument
    lua_pushinteger(_state, arg1);

    // Call method(self, arg1)
    int status = lua_pcall(_state, 2, 0, errfunc);
    if (status != LUA_OK) {
        const char* err = lua_tostring(_state, -1);
        reportError(err ? err : "Method call error");
        lua_pop(_state, 3);
        return false;
    }

    lua_pop(_state, 1);  // table
    lua_remove(_state, errfunc);
    return true;
}

int LuaRuntime::createRef() {
    if (_state == nullptr) return LUA_NOREF;
    return luaL_ref(_state, LUA_REGISTRYINDEX);
}

void LuaRuntime::pushRef(int ref) {
    if (_state == nullptr || ref == LUA_NOREF) return;
    lua_rawgeti(_state, LUA_REGISTRYINDEX, ref);
}

void LuaRuntime::releaseRef(int ref) {
    if (_state == nullptr || ref == LUA_NOREF) return;
    luaL_unref(_state, LUA_REGISTRYINDEX, ref);
}

// Forward declaration for timer processing
extern void processLuaTimers();

void LuaRuntime::update() {
    if (_state == nullptr) return;

    // Process pending timers
    processLuaTimers();

    // Process async I/O completions (resumes waiting coroutines)
    AsyncIO::instance().update();

    // Process message bus (delivers queued messages to subscribers)
    MessageBus::instance().process(_state);

    // Note: GC is handled by Lua-side scheduler every 2 seconds
    // Running per-frame GC here was redundant (~100 calls/sec vs 0.5/sec)
}

bool LuaRuntime::reloadScripts() {
    if (_state == nullptr) {
        reportError("Lua not initialized");
        return false;
    }

    LOG("LuaRuntime", "Reloading scripts...");

    // Force garbage collection before reload
    collectGarbage();

    // Clear the package.loaded table to force re-require of modules
    lua_getglobal(_state, "package");
    if (lua_istable(_state, -1)) {
        lua_getfield(_state, -1, "loaded");
        if (lua_istable(_state, -1)) {
            // Iterate and clear non-standard modules
            lua_pushnil(_state);
            while (lua_next(_state, -2) != 0) {
                const char* key = lua_tostring(_state, -2);
                // Keep standard libraries, clear user scripts
                if (key && strncmp(key, "scripts/", 8) == 0) {
                    lua_pushnil(_state);
                    lua_setfield(_state, -4, key);
                }
                lua_pop(_state, 1);
            }
        }
        lua_pop(_state, 1);
    }
    lua_pop(_state, 1);

    LOG("LuaRuntime", "Scripts reloaded");
    return true;
}

bool LuaRuntime::reloadBootScript() {
    if (_state == nullptr) {
        reportError("Lua not initialized");
        return false;
    }

    LOG("LuaRuntime", "Reloading boot script...");

    // Clear cached modules
    reloadScripts();

    // Execute boot script again
    return executeFile("/scripts/boot.lua");
}

void LuaRuntime::collectGarbage() {
    if (_state == nullptr) return;

    size_t before = _memoryUsed;
    lua_gc(_state, LUA_GCCOLLECT, 0);
    size_t after = _memoryUsed;

    LOG("LuaRuntime", "GC: freed %u bytes (was %u, now %u)",
                  before - after, before, after);
}

void LuaRuntime::setGCPause(int pause) {
    if (_state == nullptr) return;
    lua_gc(_state, LUA_GCSETPAUSE, pause);
}

void LuaRuntime::setGCStepMul(int stepmul) {
    if (_state == nullptr) return;
    lua_gc(_state, LUA_GCSETSTEPMUL, stepmul);
}

bool LuaRuntime::isLowMemory() const {
    return getAvailableMemory() < 32768;  // Less than 32KB available
}

size_t LuaRuntime::getAvailableMemory() const {
    return heap_caps_get_free_size(MALLOC_CAP_8BIT);
}
