// tdeck.storage module bindings
// Provides file I/O for LittleFS and SD card

#include "../lua_bindings.h"
#include "../../config.h"
#include <Arduino.h>
#include <LittleFS.h>
#include <SD.h>
#include <SPI.h>
#include <Preferences.h>

// Storage state
static bool sdInitialized = false;
static Preferences prefs;
static bool prefsOpened = false;

// Initialize SD card
static bool initSD() {
    if (sdInitialized) return true;

    SPI.begin(SD_SCLK, SD_MISO, SD_MOSI, SD_CS);
    if (SD.begin(SD_CS)) {
        sdInitialized = true;
        Serial.println("[Storage] SD card initialized");
        return true;
    }

    Serial.println("[Storage] SD card not available");
    return false;
}

// Ensure preferences are open
static void ensurePrefs() {
    if (!prefsOpened) {
        prefs.begin("lua_storage", false);
        prefsOpened = true;
    }
}

// Helper to determine which filesystem to use based on path
// Paths starting with "/sd/" use SD card, otherwise LittleFS
static fs::FS* getFS(const char* path, const char** adjustedPath) {
    if (strncmp(path, "/sd/", 4) == 0) {
        if (!initSD()) {
            return nullptr;
        }
        *adjustedPath = path + 3;  // Skip "/sd" prefix, keep leading "/"
        return &SD;
    }

    *adjustedPath = path;
    return &LittleFS;
}

// @lua tdeck.storage.read_file(path) -> string
// @brief Read entire file contents
// @param path File path (prefix /sd/ for SD card)
// @return File content or nil, error_message
LUA_FUNCTION(l_storage_read_file) {
    LUA_CHECK_ARGC(L, 1);
    const char* path = luaL_checkstring(L, 1);

    const char* adjustedPath;
    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_pushnil(L);
        lua_pushstring(L, "SD card not available");
        return 2;
    }

    // Debug: check if using LittleFS
    bool isLittleFS = (fs == &LittleFS);
    Serial.printf("[Storage] read_file: %s (using %s)\n", adjustedPath, isLittleFS ? "LittleFS" : "SD");

    File file = fs->open(adjustedPath, "r");
    if (!file) {
        Serial.printf("[Storage] Failed to open: %s\n", adjustedPath);
        lua_pushnil(L);
        lua_pushstring(L, "File not found");
        return 2;
    }
    Serial.printf("[Storage] Opened file, size: %d bytes\n", file.size());

    size_t size = file.size();
    if (size > 1024 * 1024) {  // 1MB limit
        file.close();
        lua_pushnil(L);
        lua_pushstring(L, "File too large");
        return 2;
    }

    char* buffer = (char*)malloc(size + 1);
    if (!buffer) {
        file.close();
        lua_pushnil(L);
        lua_pushstring(L, "Out of memory");
        return 2;
    }

    file.readBytes(buffer, size);
    buffer[size] = '\0';
    file.close();

    lua_pushlstring(L, buffer, size);
    free(buffer);
    return 1;
}

// @lua tdeck.storage.write_file(path, content) -> boolean
// @brief Write content to file (creates/overwrites)
// @param path File path
// @param content Content to write
// @return true if successful, or false with error
LUA_FUNCTION(l_storage_write_file) {
    LUA_CHECK_ARGC(L, 2);
    const char* path = luaL_checkstring(L, 1);
    size_t len;
    const char* content = luaL_checklstring(L, 2, &len);

    const char* adjustedPath;
    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "SD card not available");
        return 2;
    }

    File file = fs->open(adjustedPath, "w");
    if (!file) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "Cannot create file");
        return 2;
    }

    size_t written = file.write((const uint8_t*)content, len);
    file.close();

    if (written != len) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "Write incomplete");
        return 2;
    }

    lua_pushboolean(L, true);
    return 1;
}

// @lua tdeck.storage.append_file(path, content) -> boolean
// @brief Append content to file
// @param path File path
// @param content Content to append
// @return true if successful
LUA_FUNCTION(l_storage_append_file) {
    LUA_CHECK_ARGC(L, 2);
    const char* path = luaL_checkstring(L, 1);
    size_t len;
    const char* content = luaL_checklstring(L, 2, &len);

    const char* adjustedPath;
    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "SD card not available");
        return 2;
    }

    File file = fs->open(adjustedPath, "a");
    if (!file) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "Cannot open file");
        return 2;
    }

    size_t written = file.write((const uint8_t*)content, len);
    file.close();

    if (written != len) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "Write incomplete");
        return 2;
    }

    lua_pushboolean(L, true);
    return 1;
}

// @lua tdeck.storage.exists(path) -> boolean
// @brief Check if file or directory exists
// @param path Path to check
// @return true if exists
LUA_FUNCTION(l_storage_exists) {
    LUA_CHECK_ARGC(L, 1);
    const char* path = luaL_checkstring(L, 1);

    const char* adjustedPath;
    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushboolean(L, fs->exists(adjustedPath));
    return 1;
}

// @lua tdeck.storage.remove(path) -> boolean
// @brief Delete a file
// @param path File path to delete
// @return true if deleted
LUA_FUNCTION(l_storage_remove) {
    LUA_CHECK_ARGC(L, 1);
    const char* path = luaL_checkstring(L, 1);

    const char* adjustedPath;
    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushboolean(L, fs->remove(adjustedPath));
    return 1;
}

// @lua tdeck.storage.rename(old_path, new_path) -> boolean
// @brief Rename or move a file
// @param old_path Current path
// @param new_path New path
// @return true if renamed
LUA_FUNCTION(l_storage_rename) {
    LUA_CHECK_ARGC(L, 2);
    const char* oldPath = luaL_checkstring(L, 1);
    const char* newPath = luaL_checkstring(L, 2);

    const char* adjustedOld;
    const char* adjustedNew;
    fs::FS* fsOld = getFS(oldPath, &adjustedOld);
    fs::FS* fsNew = getFS(newPath, &adjustedNew);

    if (!fsOld || !fsNew || fsOld != fsNew) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushboolean(L, fsOld->rename(adjustedOld, adjustedNew));
    return 1;
}

// @lua tdeck.storage.mkdir(path) -> boolean
// @brief Create directory
// @param path Directory path
// @return true if created
LUA_FUNCTION(l_storage_mkdir) {
    LUA_CHECK_ARGC(L, 1);
    const char* path = luaL_checkstring(L, 1);

    const char* adjustedPath;
    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushboolean(L, fs->mkdir(adjustedPath));
    return 1;
}

// @lua tdeck.storage.rmdir(path) -> boolean
// @brief Remove empty directory
// @param path Directory path
// @return true if removed
LUA_FUNCTION(l_storage_rmdir) {
    LUA_CHECK_ARGC(L, 1);
    const char* path = luaL_checkstring(L, 1);

    const char* adjustedPath;
    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushboolean(L, fs->rmdir(adjustedPath));
    return 1;
}

// @lua tdeck.storage.list_dir(path) -> table
// @brief List directory contents
// @param path Directory path (default "/")
// @return Array of tables with name, is_dir, size
LUA_FUNCTION(l_storage_list_dir) {
    const char* path = lua_gettop(L) >= 1 ? luaL_checkstring(L, 1) : "/";

    const char* adjustedPath;
    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_newtable(L);
        return 1;
    }

    File dir = fs->open(adjustedPath);
    if (!dir || !dir.isDirectory()) {
        lua_newtable(L);
        return 1;
    }

    lua_newtable(L);
    int idx = 1;

    File entry = dir.openNextFile();
    while (entry) {
        lua_newtable(L);

        lua_pushstring(L, entry.name());
        lua_setfield(L, -2, "name");

        lua_pushboolean(L, entry.isDirectory());
        lua_setfield(L, -2, "is_dir");

        lua_pushinteger(L, entry.size());
        lua_setfield(L, -2, "size");

        lua_rawseti(L, -2, idx++);
        entry = dir.openNextFile();
    }

    dir.close();
    return 1;
}

// @lua tdeck.storage.get_pref(key, default) -> string
// @brief Get preference value
// @param key Preference key
// @param default Default value if not found
// @return Stored value or default
LUA_FUNCTION(l_storage_get_pref) {
    LUA_CHECK_ARGC_RANGE(L, 1, 2);
    const char* key = luaL_checkstring(L, 1);

    ensurePrefs();

    if (!prefs.isKey(key)) {
        if (lua_gettop(L) >= 2) {
            lua_pushvalue(L, 2);  // Return default
        } else {
            lua_pushnil(L);
        }
        return 1;
    }

    // Try to determine type and return appropriate value
    // Preferences stores type info, but we'll store as string for simplicity
    String value = prefs.getString(key, "");
    lua_pushstring(L, value.c_str());
    return 1;
}

// @lua tdeck.storage.set_pref(key, value) -> boolean
// @brief Set preference value
// @param key Preference key
// @param value Value to store
// @return true if saved successfully
LUA_FUNCTION(l_storage_set_pref) {
    LUA_CHECK_ARGC(L, 2);
    const char* key = luaL_checkstring(L, 1);

    ensurePrefs();

    bool ok = false;
    if (lua_isstring(L, 2)) {
        ok = prefs.putString(key, lua_tostring(L, 2)) > 0;
    } else if (lua_isinteger(L, 2)) {
        ok = prefs.putInt(key, lua_tointeger(L, 2)) > 0;
    } else if (lua_isnumber(L, 2)) {
        ok = prefs.putFloat(key, lua_tonumber(L, 2)) > 0;
    } else if (lua_isboolean(L, 2)) {
        ok = prefs.putBool(key, lua_toboolean(L, 2)) > 0;
    } else {
        // Convert to string
        ok = prefs.putString(key, luaL_tolstring(L, 2, nullptr)) > 0;
        lua_pop(L, 1);
    }

    lua_pushboolean(L, ok);
    return 1;
}

// @lua tdeck.storage.remove_pref(key) -> boolean
// @brief Remove a preference
// @param key Preference key to remove
// @return true if removed
LUA_FUNCTION(l_storage_remove_pref) {
    LUA_CHECK_ARGC(L, 1);
    const char* key = luaL_checkstring(L, 1);

    ensurePrefs();
    lua_pushboolean(L, prefs.remove(key));
    return 1;
}

// @lua tdeck.storage.clear_prefs() -> boolean
// @brief Clear all preferences
// @return true if cleared
LUA_FUNCTION(l_storage_clear_prefs) {
    ensurePrefs();
    lua_pushboolean(L, prefs.clear());
    return 1;
}

// @lua tdeck.storage.is_sd_available() -> boolean
// @brief Check if SD card is mounted
// @return true if SD card available
LUA_FUNCTION(l_storage_is_sd_available) {
    lua_pushboolean(L, initSD());
    return 1;
}

// @lua tdeck.storage.get_sd_info() -> table
// @brief Get SD card info
// @return Table with total_bytes, used_bytes, free_bytes or nil
LUA_FUNCTION(l_storage_get_sd_info) {
    if (!initSD()) {
        lua_pushnil(L);
        return 1;
    }

    lua_newtable(L);

    lua_pushinteger(L, SD.totalBytes());
    lua_setfield(L, -2, "total_bytes");

    lua_pushinteger(L, SD.usedBytes());
    lua_setfield(L, -2, "used_bytes");

    lua_pushinteger(L, SD.totalBytes() - SD.usedBytes());
    lua_setfield(L, -2, "free_bytes");

    lua_pushinteger(L, SD.cardType());
    lua_setfield(L, -2, "card_type");

    return 1;
}

// @lua tdeck.storage.get_flash_info() -> table
// @brief Get flash storage info
// @return Table with total_bytes, used_bytes, free_bytes
LUA_FUNCTION(l_storage_get_flash_info) {
    lua_newtable(L);

    lua_pushinteger(L, LittleFS.totalBytes());
    lua_setfield(L, -2, "total_bytes");

    lua_pushinteger(L, LittleFS.usedBytes());
    lua_setfield(L, -2, "used_bytes");

    lua_pushinteger(L, LittleFS.totalBytes() - LittleFS.usedBytes());
    lua_setfield(L, -2, "free_bytes");

    return 1;
}

// Function table for tdeck.storage
static const luaL_Reg storage_funcs[] = {
    {"read_file",       l_storage_read_file},
    {"write_file",      l_storage_write_file},
    {"append_file",     l_storage_append_file},
    {"exists",          l_storage_exists},
    {"remove",          l_storage_remove},
    {"rename",          l_storage_rename},
    {"mkdir",           l_storage_mkdir},
    {"rmdir",           l_storage_rmdir},
    {"list_dir",        l_storage_list_dir},
    {"get_pref",        l_storage_get_pref},
    {"set_pref",        l_storage_set_pref},
    {"remove_pref",     l_storage_remove_pref},
    {"clear_prefs",     l_storage_clear_prefs},
    {"is_sd_available", l_storage_is_sd_available},
    {"get_sd_info",     l_storage_get_sd_info},
    {"get_flash_info",  l_storage_get_flash_info},
    {nullptr, nullptr}
};

// Register the storage module
void registerStorageModule(lua_State* L) {
    lua_register_module(L, "storage", storage_funcs);
    Serial.println("[LuaRuntime] Registered tdeck.storage");
}
