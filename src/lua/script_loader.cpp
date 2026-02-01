#include "script_loader.h"
#include "lua_runtime.h"
#include "../config.h"
#include "../util/log.h"
#include <LittleFS.h>
#include <SD.h>
#include <SPI.h>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

// Script search paths in priority order
static const char* SCRIPT_PATHS[] = {
    "/scripts/",      // SD card (will be prefixed with /sd)
    "/scripts/"       // LittleFS
};

ScriptLoader& ScriptLoader::instance() {
    static ScriptLoader loader;
    return loader;
}

bool ScriptLoader::init() {
    if (_initialized) return true;

    LOG("ScriptLoader", "Initializing...");

    // Try to initialize SD card
    SPI.begin(SD_SCLK, SD_MISO, SD_MOSI, SD_CS);
    if (SD.begin(SD_CS)) {
        _sdAvailable = true;
        LOG("ScriptLoader", "SD card available");

        // Check if scripts directory exists on SD
        if (SD.exists("/scripts")) {
            LOG("ScriptLoader", "Found /scripts on SD card");
        }
    } else {
        LOG("ScriptLoader", "SD card not available, using LittleFS only");
    }

    // Check LittleFS scripts directory
    if (LittleFS.exists("/scripts")) {
        LOG("ScriptLoader", "Found /scripts on LittleFS");
    }

    _initialized = true;
    return true;
}

bool ScriptLoader::fileExists(const char* path) {
    // Check if path starts with /sd/
    if (strncmp(path, "/sd/", 4) == 0) {
        if (!_sdAvailable) return false;
        return SD.exists(path + 3);  // Skip "/sd" prefix
    }

    return LittleFS.exists(path);
}

const char* ScriptLoader::findScript(const char* scriptName) {
    // Build full paths and check each location

    // 1. Check SD card first
    if (_sdAvailable) {
        snprintf(_pathBuffer, sizeof(_pathBuffer), "/scripts/%s.lua", scriptName);
        if (SD.exists(_pathBuffer)) {
            // Return with /sd prefix for consistency
            memmove(_pathBuffer + 3, _pathBuffer, strlen(_pathBuffer) + 1);
            memcpy(_pathBuffer, "/sd", 3);
            return _pathBuffer;
        }
    }

    // 2. Check LittleFS
    snprintf(_pathBuffer, sizeof(_pathBuffer), "/scripts/%s.lua", scriptName);
    if (LittleFS.exists(_pathBuffer)) {
        return _pathBuffer;
    }

    return nullptr;
}

bool ScriptLoader::scriptExists(const char* scriptName) {
    return findScript(scriptName) != nullptr;
}

bool ScriptLoader::loadFromPath(lua_State* L, const char* path) {
    File file;

    // Determine which filesystem to use
    if (strncmp(path, "/sd/", 4) == 0) {
        if (!_sdAvailable) {
            LOG("ScriptLoader", "SD not available for: %s", path);
            return false;
        }
        file = SD.open(path + 3, "r");  // Skip "/sd" prefix
    } else {
        file = LittleFS.open(path, "r");
    }

    if (!file) {
        LOG("ScriptLoader", "Cannot open: %s", path);
        return false;
    }

    // Read file content
    size_t size = file.size();
    if (size > 512 * 1024) {  // 512KB limit for scripts
        LOG("ScriptLoader", "Script too large: %s (%u bytes)", path, size);
        file.close();
        return false;
    }

    char* buffer = (char*)malloc(size + 1);
    if (!buffer) {
        LOG("ScriptLoader", "Out of memory loading: %s", path);
        file.close();
        return false;
    }

    file.readBytes(buffer, size);
    buffer[size] = '\0';
    file.close();

    LOG("ScriptLoader", "Loading: %s (%u bytes)", path, size);

    // Execute the script
    bool success = LuaRuntime::instance().executeString(buffer, path);
    free(buffer);

    return success;
}

bool ScriptLoader::loadScript(lua_State* L, const char* scriptName) {
    const char* path = findScript(scriptName);
    if (!path) {
        LOG("ScriptLoader", "Script not found: %s", scriptName);
        return false;
    }

    return loadFromPath(L, path);
}

bool ScriptLoader::loadBootScript(lua_State* L) {
    LOG("ScriptLoader", "Looking for boot script...");

    // Try to find and load boot.lua
    const char* bootPath = findScript("boot");
    if (bootPath) {
        LOG("ScriptLoader", "Found boot script at: %s", bootPath);
        return loadFromPath(L, bootPath);
    }

    // Try ui/boot as alternative
    bootPath = findScript("ui/boot");
    if (bootPath) {
        LOG("ScriptLoader", "Found boot script at: %s", bootPath);
        return loadFromPath(L, bootPath);
    }

    LOG("ScriptLoader", "No boot script found");
    return false;
}

bool ScriptLoader::reloadScripts(lua_State* L) {
    LOG("ScriptLoader", "Reloading scripts...");

    // Re-check SD card availability
    if (!_sdAvailable) {
        SPI.begin(SD_SCLK, SD_MISO, SD_MOSI, SD_CS);
        if (SD.begin(SD_CS)) {
            _sdAvailable = true;
            LOG("ScriptLoader", "SD card now available");
        }
    }

    // Reload boot script
    return loadBootScript(L);
}
