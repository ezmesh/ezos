#pragma once

#include <Arduino.h>

extern "C" {
#include <lua.h>
}

// Script loading priority:
// 1. SD Card: /sd/scripts/
// 2. Internal Flash: /scripts/ (LittleFS)
// 3. Embedded in firmware (fallback)

class ScriptLoader {
public:
    static ScriptLoader& instance();

    // Initialize the script loader (call after LittleFS.begin())
    bool init();

    // Load and execute a script by name (without .lua extension)
    // Searches in priority order: SD -> LittleFS -> embedded
    bool loadScript(lua_State* L, const char* scriptName);

    // Load the boot script (scripts/boot.lua)
    bool loadBootScript(lua_State* L);

    // Check if a script exists (in any location)
    bool scriptExists(const char* scriptName);

    // Get the full path where a script was found
    // Returns nullptr if not found
    const char* findScript(const char* scriptName);

    // Reload all scripts (for hot reload)
    bool reloadScripts(lua_State* L);

    // Check if SD card scripts are available
    bool hasSDScripts() const { return _sdAvailable; }

private:
    ScriptLoader() = default;
    ~ScriptLoader() = default;

    ScriptLoader(const ScriptLoader&) = delete;
    ScriptLoader& operator=(const ScriptLoader&) = delete;

    bool loadFromPath(lua_State* L, const char* path);
    bool fileExists(const char* path);

    bool _initialized = false;
    bool _sdAvailable = false;
    char _pathBuffer[128];
};
