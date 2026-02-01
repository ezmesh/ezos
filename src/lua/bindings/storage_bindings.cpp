// ez.storage module bindings
// Provides file I/O for LittleFS and SD card

#include "../lua_bindings.h"
#include "../embedded_scripts.h"
#include "../../config.h"
#include <Arduino.h>
#include <LittleFS.h>
#include <SD.h>
#include <SPI.h>
#include <Preferences.h>
#include <ArduinoJson.h>

// @module ez.storage
// @brief File I/O for internal flash (LittleFS) and SD card
// @description
// Mount points:
//   /sd/  - SD card (removable, for maps, logs, large files)
//   /fs/  - LittleFS internal flash (for user data)
//   /img/ - Embedded scripts (read-only, compiled into firmware)
// Script loading uses /scripts/ paths with overlay: SD > FS > embedded.
// The /img/ mount point is for file browsing; internally maps to /scripts/.
// Also provides persistent key-value preferences stored in NVS flash.
// @end

// Storage state
static bool sdInitialized = false;
static Preferences prefs;
static bool prefsOpened = false;

// Mount point prefixes
static const char* MOUNT_SD = "/sd";
static const char* MOUNT_FS = "/fs";
static const char* MOUNT_IMG = "/img";

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

// Filesystem type enum
enum class FSType { SD_CARD, LITTLEFS, EMBEDDED, VIRTUAL_ROOT, INVALID };

// Helper to determine which filesystem to use based on path
// Returns filesystem type and adjusts path for the underlying FS
static FSType getFSType(const char* path, const char** adjustedPath) {
    // Virtual root - list mount points
    if (strcmp(path, "/") == 0) {
        *adjustedPath = "/";
        return FSType::VIRTUAL_ROOT;
    }

    // SD card: /sd or /sd/...
    if (strncmp(path, "/sd/", 4) == 0) {
        *adjustedPath = path + 3;  // Skip "/sd", keep leading "/"
        return FSType::SD_CARD;
    }
    if (strcmp(path, "/sd") == 0) {
        *adjustedPath = "/";
        return FSType::SD_CARD;
    }

    // LittleFS: /fs or /fs/...
    if (strncmp(path, "/fs/", 4) == 0) {
        *adjustedPath = path + 3;  // Skip "/fs", keep leading "/"
        return FSType::LITTLEFS;
    }
    if (strcmp(path, "/fs") == 0) {
        *adjustedPath = "/";
        return FSType::LITTLEFS;
    }

    // Embedded: /img or /img/...
    if (strncmp(path, "/img/", 5) == 0) {
        *adjustedPath = path + 4;  // Skip "/img", keep leading "/"
        return FSType::EMBEDDED;
    }
    if (strcmp(path, "/img") == 0) {
        *adjustedPath = "/";
        return FSType::EMBEDDED;
    }

    // Invalid path - doesn't start with a known mount point
    *adjustedPath = path;
    return FSType::INVALID;
}

// Legacy helper for backwards compatibility - returns fs::FS* for SD/LittleFS
static fs::FS* getFS(const char* path, const char** adjustedPath) {
    FSType type = getFSType(path, adjustedPath);

    if (type == FSType::SD_CARD) {
        if (!initSD()) {
            return nullptr;
        }
        return &SD;
    }

    if (type == FSType::LITTLEFS) {
        return &LittleFS;
    }

    // For embedded or invalid, return nullptr
    return nullptr;
}

// @lua ez.storage.read_bytes(path, offset, length) -> string
// @brief Read bytes from file at specific offset (for random access)
// @description Reads a specific range of bytes from a file without loading the
// entire file into memory. Useful for reading headers, seeking within large files,
// or implementing file formats with random access. Maximum read size is 64KB.
// @param path File path (prefix /sd/ for SD card)
// @param offset Byte offset to start reading from (0-based)
// @param length Number of bytes to read (max 65536)
// @return Binary data as string, or nil with error message
// @example
// -- Read file header (first 16 bytes)
// local header = ez.storage.read_bytes("/sd/maps/tiles.bin", 0, 16)
// -- Read a specific tile from a map file
// local tile_offset = header_size + (tile_index * tile_size)
// local tile_data = ez.storage.read_bytes("/sd/maps/tiles.bin", tile_offset, 4096)
// @end
LUA_FUNCTION(l_storage_read_bytes) {
    LUA_CHECK_ARGC(L, 3);
    const char* path = luaL_checkstring(L, 1);
    lua_Integer offset = luaL_checkinteger(L, 2);
    lua_Integer length = luaL_checkinteger(L, 3);

    if (offset < 0 || length <= 0 || length > 65536) {
        lua_pushnil(L);
        lua_pushstring(L, "Invalid offset or length (max 64KB)");
        return 2;
    }

    const char* adjustedPath;
    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_pushnil(L);
        lua_pushstring(L, "SD card not available");
        return 2;
    }

    File file = fs->open(adjustedPath, "r");
    if (!file) {
        lua_pushnil(L);
        lua_pushstring(L, "File not found");
        return 2;
    }

    size_t fileSize = file.size();
    if ((size_t)offset >= fileSize) {
        file.close();
        lua_pushnil(L);
        lua_pushstring(L, "Offset beyond file end");
        return 2;
    }

    // Clamp length to available data
    size_t availableBytes = fileSize - offset;
    if ((size_t)length > availableBytes) {
        length = availableBytes;
    }

    char* buffer = (char*)malloc(length);
    if (!buffer) {
        file.close();
        lua_pushnil(L);
        lua_pushstring(L, "Out of memory");
        return 2;
    }

    file.seek(offset);
    size_t bytesRead = file.readBytes(buffer, length);
    file.close();

    if (bytesRead != (size_t)length) {
        free(buffer);
        lua_pushnil(L);
        lua_pushstring(L, "Read incomplete");
        return 2;
    }

    lua_pushlstring(L, buffer, length);
    free(buffer);
    return 1;
}

// @lua ez.storage.file_size(path) -> integer
// @brief Get file size in bytes
// @description Returns the size of a file in bytes. Useful for checking if a file
// is empty, allocating buffers, or calculating offsets for random access reads.
// @param path File path (prefix /sd/ for SD card)
// @return File size in bytes, or nil with error message if file not found
// @example
// local size = ez.storage.file_size("/config.json")
// if size then
//     print("Config file is", size, "bytes")
// end
// @end
LUA_FUNCTION(l_storage_file_size) {
    LUA_CHECK_ARGC(L, 1);
    const char* path = luaL_checkstring(L, 1);

    const char* adjustedPath;
    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_pushnil(L);
        lua_pushstring(L, "SD card not available");
        return 2;
    }

    File file = fs->open(adjustedPath, "r");
    if (!file) {
        lua_pushnil(L);
        lua_pushstring(L, "File not found");
        return 2;
    }

    size_t size = file.size();
    file.close();

    lua_pushinteger(L, size);
    return 1;
}

// @lua ez.storage.read_file(path) -> string
// @brief Read entire file contents
// @description Reads an entire file into memory and returns it as a string. Files
// up to 1MB are supported. For larger files or binary data, use read_bytes() for
// random access. Paths starting with /sd/ read from SD card, others from LittleFS.
// @param path File path (prefix /sd/ for SD card)
// @return File content as string, or nil with error message
// @example
// local content = ez.storage.read_file("/config.json")
// if content then
//     local config = ez.storage.json_decode(content)
// end
// @end
LUA_FUNCTION(l_storage_read_file) {
    LUA_CHECK_ARGC(L, 1);
    const char* path = luaL_checkstring(L, 1);

    const char* adjustedPath;
    FSType fsType = getFSType(path, &adjustedPath);

    // Handle embedded files (/img/... maps to /scripts/... in embedded)
    if (fsType == FSType::EMBEDDED) {
        // Map /img/... to /scripts/... for embedded lookup
        char embeddedPath[256];
        snprintf(embeddedPath, sizeof(embeddedPath), "/scripts%s", adjustedPath);

        size_t size = 0;
        const char* content = embedded_lua::get_script(embeddedPath, &size);
        if (content) {
            lua_pushlstring(L, content, size);
            return 1;
        }
        lua_pushnil(L);
        lua_pushstring(L, "Embedded file not found");
        return 2;
    }

    // Handle invalid paths
    if (fsType == FSType::INVALID || fsType == FSType::VIRTUAL_ROOT) {
        lua_pushnil(L);
        lua_pushstring(L, "Invalid path - use /sd/, /fs/, or /img/");
        return 2;
    }

    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_pushnil(L);
        lua_pushstring(L, "Filesystem not available");
        return 2;
    }

    File file = fs->open(adjustedPath, "r");
    if (!file) {
        lua_pushnil(L);
        lua_pushstring(L, "File not found");
        return 2;
    }

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

// @lua ez.storage.write_file(path, content) -> boolean
// @brief Write content to file (creates/overwrites)
// @description Creates a new file or overwrites an existing file with the given
// content. Parent directories must already exist. For binary data, pass a string
// with binary bytes. Use append_file() to add to existing file instead.
// @param path File path (prefix /sd/ for SD card)
// @param content Content to write (string, can be binary)
// @return true if successful, or false with error message
// @example
// local config = {brightness = 200, volume = 80}
// local json = ez.storage.json_encode(config)
// ez.storage.write_file("/config.json", json)
// @end
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

// @lua ez.storage.append_file(path, content) -> boolean
// @brief Append content to file
// @description Adds content to the end of an existing file, or creates the file
// if it doesn't exist. Useful for logging, collecting data, or building files
// incrementally.
// @param path File path (prefix /sd/ for SD card)
// @param content Content to append
// @return true if successful, or false with error message
// @example
// -- Append to log file
// local timestamp = os.date("%Y-%m-%d %H:%M:%S")
// ez.storage.append_file("/sd/log.txt", timestamp .. " System started\n")
// @end
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

// @lua ez.storage.exists(path) -> boolean
// @brief Check if file or directory exists
// @description Checks whether a file or directory exists at the given path.
// Use before reading to avoid errors, or before writing to check for existing files.
// @param path Path to check (prefix /sd/ for SD card)
// @return true if file or directory exists
// @example
// if ez.storage.exists("/config.json") then
//     local content = ez.storage.read_file("/config.json")
// else
//     print("Config not found, using defaults")
// end
// @end
LUA_FUNCTION(l_storage_exists) {
    LUA_CHECK_ARGC(L, 1);
    const char* path = luaL_checkstring(L, 1);

    const char* adjustedPath;
    FSType fsType = getFSType(path, &adjustedPath);

    // Virtual root always exists
    if (fsType == FSType::VIRTUAL_ROOT) {
        lua_pushboolean(L, true);
        return 1;
    }

    // Check embedded files (/img/... maps to /scripts/... in embedded)
    if (fsType == FSType::EMBEDDED) {
        // Map /img/... to /scripts/... for embedded lookup
        char embeddedPath[256];
        snprintf(embeddedPath, sizeof(embeddedPath), "/scripts%s", adjustedPath);
        size_t embeddedPathLen = strlen(embeddedPath);

        // Check if it's an embedded script
        const char* content = embedded_lua::get_script(embeddedPath, nullptr);
        if (content) {
            lua_pushboolean(L, true);
            return 1;
        }
        // Check if it's an embedded directory (has children)
        size_t count = embedded_lua::get_script_count();
        for (size_t i = 0; i < count; i++) {
            const char* scriptPath = embedded_lua::get_script_path(i);
            if (scriptPath && strncmp(scriptPath, embeddedPath, embeddedPathLen) == 0) {
                char nextChar = scriptPath[embeddedPathLen];
                if (nextChar == '/' || nextChar == '\0') {
                    lua_pushboolean(L, true);
                    return 1;
                }
            }
        }
        lua_pushboolean(L, false);
        return 1;
    }

    // Invalid path
    if (fsType == FSType::INVALID) {
        lua_pushboolean(L, false);
        return 1;
    }

    fs::FS* fs = getFS(path, &adjustedPath);
    if (!fs) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushboolean(L, fs->exists(adjustedPath));
    return 1;
}

// @lua ez.storage.remove(path) -> boolean
// @brief Delete a file
// @description Permanently deletes a file. Cannot be undone. For directories, use
// rmdir() instead (directory must be empty). Returns false if file doesn't exist
// or couldn't be deleted.
// @param path File path to delete (prefix /sd/ for SD card)
// @return true if file was deleted
// @example
// if ez.storage.remove("/sd/old_backup.json") then
//     print("Backup deleted")
// end
// @end
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

// @lua ez.storage.rename(old_path, new_path) -> boolean
// @brief Rename or move a file
// @description Renames a file or moves it to a different location within the same
// filesystem. Both paths must be on the same filesystem (both SD or both LittleFS).
// Can also be used to move files between directories.
// @param old_path Current file path
// @param new_path New file path
// @return true if renamed successfully
// @example
// -- Rename a file
// ez.storage.rename("/temp.txt", "/final.txt")
// -- Move to different directory
// ez.storage.rename("/downloads/file.txt", "/documents/file.txt")
// @end
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

// @lua ez.storage.mkdir(path) -> boolean
// @brief Create directory
// @description Creates a new directory. Parent directories must already exist.
// Returns false if directory already exists or creation failed.
// @param path Directory path to create (prefix /sd/ for SD card)
// @return true if directory was created
// @example
// ez.storage.mkdir("/sd/logs")
// ez.storage.mkdir("/sd/logs/2024")
// @end
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

// @lua ez.storage.rmdir(path) -> boolean
// @brief Remove empty directory
// @description Removes an empty directory. The directory must be empty - remove
// all files and subdirectories first. Returns false if directory is not empty,
// doesn't exist, or couldn't be removed.
// @param path Directory path to remove (prefix /sd/ for SD card)
// @return true if directory was removed
// @example
// -- Remove directory contents first, then the directory
// for _, file in ipairs(ez.storage.list_dir("/sd/temp")) do
//     ez.storage.remove("/sd/temp/" .. file.name)
// end
// ez.storage.rmdir("/sd/temp")
// @end
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

// @lua ez.storage.list_dir(path) -> table
// @brief List directory contents
// @description Returns an array of all files and subdirectories in the given
// directory. Each entry is a table with name (string), is_dir (boolean), and
// size (integer, 0 for directories).
// @param path Directory path (default "/", prefix /sd/ for SD card)
// @return Array of tables with name, is_dir, size fields
// @example
// local files = ez.storage.list_dir("/sd/music")
// for _, file in ipairs(files) do
//     if file.is_dir then
//         print("[DIR]", file.name)
//     else
//         print(file.name, file.size, "bytes")
//     end
// end
// @end
// Helper to add a directory entry to the Lua table on the stack
static void addDirEntry(lua_State* L, int& idx, const char* name, bool isDir, size_t size, bool isEmbedded = false) {
    lua_newtable(L);

    lua_pushstring(L, name);
    lua_setfield(L, -2, "name");

    lua_pushboolean(L, isDir);
    lua_setfield(L, -2, "is_dir");

    lua_pushinteger(L, size);
    lua_setfield(L, -2, "size");

    if (isEmbedded) {
        lua_pushboolean(L, true);
        lua_setfield(L, -2, "is_embedded");
    }

    lua_rawseti(L, -2, idx++);
}

// Helper to list embedded files/directories at a given path
static void listEmbeddedDir(lua_State* L, const char* dirPath, int& idx) {
    size_t dirLen = strlen(dirPath);
    size_t count = embedded_lua::get_script_count();

    // Track which subdirectories we've already added
    char seenDirs[32][64];
    int seenCount = 0;

    for (size_t i = 0; i < count; i++) {
        const char* fullPath = embedded_lua::get_script_path(i);
        if (!fullPath) continue;

        // Check if path starts with dirPath
        if (strncmp(fullPath, dirPath, dirLen) != 0) continue;

        // Get the part after dirPath
        const char* remainder = fullPath + dirLen;
        if (remainder[0] == '/') remainder++;  // Skip leading slash
        if (remainder[0] == '\0') continue;    // Exact match, not a child

        // Check if it's a direct child or in a subdirectory
        const char* slash = strchr(remainder, '/');
        if (slash) {
            // It's in a subdirectory - extract dir name
            size_t nameLen = slash - remainder;
            if (nameLen >= 64) continue;

            char dirName[64];
            strncpy(dirName, remainder, nameLen);
            dirName[nameLen] = '\0';

            // Check if we've already added this directory
            bool seen = false;
            for (int j = 0; j < seenCount; j++) {
                if (strcmp(seenDirs[j], dirName) == 0) {
                    seen = true;
                    break;
                }
            }
            if (!seen && seenCount < 32) {
                strcpy(seenDirs[seenCount++], dirName);
                addDirEntry(L, idx, dirName, true, 0, true);
            }
        } else {
            // It's a direct file
            addDirEntry(L, idx, remainder, false, embedded_lua::get_script_size(i), true);
        }
    }
}

LUA_FUNCTION(l_storage_list_dir) {
    const char* path = lua_gettop(L) >= 1 ? luaL_checkstring(L, 1) : "/";

    const char* adjustedPath;
    FSType fsType = getFSType(path, &adjustedPath);

    lua_newtable(L);
    int idx = 1;

    // Handle virtual root - show mount points
    if (fsType == FSType::VIRTUAL_ROOT) {
        // Always show /sd and /fs mount points
        addDirEntry(L, idx, "sd", true, 0);
        addDirEntry(L, idx, "fs", true, 0);
        addDirEntry(L, idx, "img", true, 0);
        return 1;
    }

    // Handle embedded filesystem (/img/ maps to /scripts/ in embedded)
    if (fsType == FSType::EMBEDDED) {
        // Map /img/... to /scripts/... for embedded lookup
        char embeddedPath[256];
        if (strcmp(adjustedPath, "/") == 0) {
            // Root of /img/ shows contents of /scripts/
            strcpy(embeddedPath, "/scripts");
        } else {
            // /img/ui/screens -> /scripts/ui/screens
            snprintf(embeddedPath, sizeof(embeddedPath), "/scripts%s", adjustedPath);
        }
        listEmbeddedDir(L, embeddedPath, idx);
        return 1;
    }

    // Handle invalid paths
    if (fsType == FSType::INVALID) {
        return 1;  // Return empty table
    }

    // Handle SD card
    if (fsType == FSType::SD_CARD) {
        if (!initSD()) {
            return 1;
        }
        File dir = SD.open(adjustedPath);
        if (!dir || !dir.isDirectory()) {
            return 1;
        }

        File entry = dir.openNextFile();
        while (entry) {
            addDirEntry(L, idx, entry.name(), entry.isDirectory(), entry.size());
            entry = dir.openNextFile();
        }
        dir.close();
        return 1;
    }

    // Handle LittleFS
    if (fsType == FSType::LITTLEFS) {
        File dir = LittleFS.open(adjustedPath);
        if (!dir || !dir.isDirectory()) {
            return 1;
        }

        File entry = dir.openNextFile();
        while (entry) {
            addDirEntry(L, idx, entry.name(), entry.isDirectory(), entry.size());
            entry = dir.openNextFile();
        }
        dir.close();
        return 1;
    }

    return 1;
}

// @lua ez.storage.get_pref(key, default) -> string
// @brief Get preference value
// @description Retrieves a stored preference value from non-volatile storage (NVS).
// Preferences persist across reboots and are faster to access than files. Use for
// settings, calibration values, and other small key-value data.
// @param key Preference key (max 15 chars)
// @param default Default value if key not found (optional)
// @return Stored value as string, or default/nil if not found
// @example
// local brightness = ez.storage.get_pref("brightness", "200")
// local volume = ez.storage.get_pref("volume", "80")
// @end
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

    // Get the type of the stored preference and read accordingly
    PreferenceType type = prefs.getType(key);
    switch (type) {
        case PT_I8:
        case PT_U8:
        case PT_I16:
        case PT_U16:
        case PT_I32:
        case PT_U32:
        case PT_I64:
        case PT_U64:
            lua_pushinteger(L, prefs.getInt(key, 0));
            break;
        case PT_STR:
            lua_pushstring(L, prefs.getString(key, "").c_str());
            break;
        case PT_BLOB:
            // For blobs, try to read as string
            lua_pushstring(L, prefs.getString(key, "").c_str());
            break;
        default:
            // For bool and unknown types, try bool first then string
            // Note: ESP32 Preferences doesn't have PT_BOOL, bools are stored as U8
            {
                bool boolVal = prefs.getBool(key, false);
                lua_pushboolean(L, boolVal);
            }
            break;
    }
    return 1;
}

// @lua ez.storage.set_pref(key, value) -> boolean
// @brief Set preference value
// @description Stores a value in non-volatile storage (NVS). Values persist across
// reboots. Supports strings, integers, floats, and booleans. The key length is
// limited to 15 characters.
// @param key Preference key (max 15 chars)
// @param value Value to store (string, number, or boolean)
// @return true if saved successfully
// @example
// ez.storage.set_pref("brightness", 200)
// ez.storage.set_pref("username", "Alice")
// ez.storage.set_pref("gps_enabled", true)
// @end
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

// @lua ez.storage.remove_pref(key) -> boolean
// @brief Remove a preference
// @description Deletes a single preference from non-volatile storage. Use
// clear_prefs() to remove all preferences at once.
// @param key Preference key to remove
// @return true if preference was removed
// @example
// ez.storage.remove_pref("old_setting")
// @end
LUA_FUNCTION(l_storage_remove_pref) {
    LUA_CHECK_ARGC(L, 1);
    const char* key = luaL_checkstring(L, 1);

    ensurePrefs();
    lua_pushboolean(L, prefs.remove(key));
    return 1;
}

// @lua ez.storage.clear_prefs() -> boolean
// @brief Clear all preferences
// @description Removes all stored preferences from non-volatile storage. Use with
// caution - this resets all settings to defaults. Useful for factory reset
// functionality.
// @return true if all preferences were cleared
// @example
// -- Factory reset
// ez.storage.clear_prefs()
// print("All settings reset to defaults")
// @end
LUA_FUNCTION(l_storage_clear_prefs) {
    ensurePrefs();
    lua_pushboolean(L, prefs.clear());
    return 1;
}

// @lua ez.storage.is_sd_available() -> boolean
// @brief Check if SD card is mounted
// @description Checks if an SD card is inserted and accessible. The SD card is
// initialized on first access. Use this before attempting SD card operations
// to provide better error messages.
// @return true if SD card is available and mounted
// @example
// if ez.storage.is_sd_available() then
//     print("SD card ready")
// else
//     print("Please insert SD card")
// end
// @end
LUA_FUNCTION(l_storage_is_sd_available) {
    lua_pushboolean(L, initSD());
    return 1;
}

// @lua ez.storage.get_sd_info() -> table
// @brief Get SD card info
// @description Returns information about the SD card including capacity, used
// space, and card type. Returns nil if SD card is not available.
// @return Table with total_bytes, used_bytes, free_bytes, card_type, or nil
// @example
// local info = ez.storage.get_sd_info()
// if info then
//     local free_mb = info.free_bytes / (1024 * 1024)
//     print(string.format("SD card: %.1f MB free", free_mb))
// end
// @end
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

// @lua ez.storage.get_flash_info() -> table
// @brief Get flash storage info
// @description Returns information about the LittleFS flash filesystem. This is
// the internal storage used for scripts, configuration, and small data files.
// Typically a few megabytes, shared with the firmware.
// @return Table with total_bytes, used_bytes, free_bytes
// @example
// local info = ez.storage.get_flash_info()
// local free_kb = info.free_bytes / 1024
// print(string.format("Flash: %.1f KB free", free_kb))
// @end
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

// Helper: Convert Lua value to JSON
static void luaToJson(lua_State* L, int idx, JsonVariant json);
static void luaTableToJson(lua_State* L, int idx, JsonVariant json) {
    // Check if array or object by looking at keys
    bool isArray = true;
    lua_Integer maxIdx = 0;

    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
        if (lua_type(L, -2) != LUA_TNUMBER || !lua_isinteger(L, -2)) {
            isArray = false;
            lua_pop(L, 2);
            break;
        }
        lua_Integer i = lua_tointeger(L, -2);
        if (i > maxIdx) maxIdx = i;
        lua_pop(L, 1);
    }

    if (isArray && maxIdx > 0) {
        JsonArray arr = json.to<JsonArray>();
        for (lua_Integer i = 1; i <= maxIdx; i++) {
            lua_rawgeti(L, idx, i);
            JsonVariant elem = arr.add<JsonVariant>();
            luaToJson(L, lua_gettop(L), elem);
            lua_pop(L, 1);
        }
    } else {
        JsonObject obj = json.to<JsonObject>();
        lua_pushnil(L);
        while (lua_next(L, idx) != 0) {
            const char* key = lua_tostring(L, -2);
            if (key) {
                JsonVariant val = obj[key].to<JsonVariant>();
                luaToJson(L, lua_gettop(L), val);
            }
            lua_pop(L, 1);
        }
    }
}

static void luaToJson(lua_State* L, int idx, JsonVariant json) {
    int absIdx = lua_absindex(L, idx);
    switch (lua_type(L, absIdx)) {
        case LUA_TNIL:
            json.set(nullptr);
            break;
        case LUA_TBOOLEAN:
            json.set(lua_toboolean(L, absIdx) != 0);
            break;
        case LUA_TNUMBER:
            if (lua_isinteger(L, absIdx)) {
                json.set(lua_tointeger(L, absIdx));
            } else {
                json.set(lua_tonumber(L, absIdx));
            }
            break;
        case LUA_TSTRING:
            json.set(lua_tostring(L, absIdx));
            break;
        case LUA_TTABLE:
            luaTableToJson(L, absIdx, json);
            break;
        default:
            json.set(nullptr);
            break;
    }
}

// Helper: Convert JSON to Lua value
static void jsonToLua(lua_State* L, JsonVariantConst json) {
    if (json.isNull()) {
        lua_pushnil(L);
    } else if (json.is<bool>()) {
        lua_pushboolean(L, json.as<bool>());
    } else if (json.is<long long>()) {
        lua_pushinteger(L, json.as<long long>());
    } else if (json.is<double>()) {
        lua_pushnumber(L, json.as<double>());
    } else if (json.is<const char*>()) {
        lua_pushstring(L, json.as<const char*>());
    } else if (json.is<JsonArrayConst>()) {
        JsonArrayConst arr = json.as<JsonArrayConst>();
        lua_createtable(L, arr.size(), 0);
        int i = 1;
        for (JsonVariantConst elem : arr) {
            jsonToLua(L, elem);
            lua_rawseti(L, -2, i++);
        }
    } else if (json.is<JsonObjectConst>()) {
        JsonObjectConst obj = json.as<JsonObjectConst>();
        lua_createtable(L, 0, obj.size());
        for (JsonPairConst kv : obj) {
            jsonToLua(L, kv.value());
            lua_setfield(L, -2, kv.key().c_str());
        }
    } else {
        lua_pushnil(L);
    }
}

// @lua ez.storage.json_encode(value) -> string
// @brief Encode Lua value to JSON string
// @description Converts a Lua value to a JSON string. Supports tables (converted
// to arrays or objects), strings, numbers, booleans, and nil. Nested tables are
// supported. Useful for saving configuration or sending data over network.
// @param value Lua table, string, number, boolean, or nil
// @return JSON string
// @example
// local data = {
//     name = "Alice",
//     scores = {95, 87, 92},
//     settings = {sound = true, level = 5}
// }
// local json = ez.storage.json_encode(data)
// ez.storage.write_file("/save.json", json)
// @end
LUA_FUNCTION(l_storage_json_encode) {
    LUA_CHECK_ARGC(L, 1);

    JsonDocument doc;
    JsonVariant root = doc.to<JsonVariant>();
    luaToJson(L, 1, root);

    String output;
    serializeJson(doc, output);
    lua_pushstring(L, output.c_str());
    return 1;
}

// @lua ez.storage.json_decode(json_string) -> value
// @brief Decode JSON string to Lua value
// @description Parses a JSON string and returns the corresponding Lua value.
// JSON objects become Lua tables, arrays become indexed tables, and primitives
// become their Lua equivalents. Returns nil with error message on parse failure.
// @param json_string JSON string to parse
// @return Lua value (table, string, number, boolean, or nil), or nil with error
// @example
// local json = ez.storage.read_file("/config.json")
// local config, err = ez.storage.json_decode(json)
// if config then
//     print("Username:", config.username)
// else
//     print("Parse error:", err)
// end
// @end
LUA_FUNCTION(l_storage_json_decode) {
    LUA_CHECK_ARGC(L, 1);
    const char* json = luaL_checkstring(L, 1);

    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, json);

    if (err) {
        lua_pushnil(L);
        lua_pushstring(L, err.c_str());
        return 2;
    }

    jsonToLua(L, doc.as<JsonVariantConst>());
    return 1;
}

// @lua ez.storage.copy_file(src, dst) -> boolean
// @brief Copy a file from source to destination
// @description Copies a file from source to destination. Can copy between different
// filesystems (e.g., from LittleFS to SD card or vice versa). The destination file
// is overwritten if it exists. Uses 512-byte chunks to minimize memory usage.
// @param src Source file path (prefix /sd/ for SD card)
// @param dst Destination file path (prefix /sd/ for SD card)
// @return true if copy was successful
// @example
// -- Backup config to SD card
// ez.storage.copy_file("/config.json", "/sd/backup/config.json")
// -- Copy from SD to flash
// ez.storage.copy_file("/sd/assets/image.bin", "/cache/image.bin")
// @end
LUA_FUNCTION(l_storage_copy_file) {
    LUA_CHECK_ARGC(L, 2);
    const char* src = luaL_checkstring(L, 1);
    const char* dst = luaL_checkstring(L, 2);

    const char* srcPath;
    const char* dstPath;
    fs::FS* srcFs = getFS(src, &srcPath);
    fs::FS* dstFs = getFS(dst, &dstPath);

    if (!srcFs || !dstFs) {
        lua_pushboolean(L, false);
        return 1;
    }

    File srcFile = srcFs->open(srcPath, "r");
    if (!srcFile) {
        lua_pushboolean(L, false);
        return 1;
    }

    File dstFile = dstFs->open(dstPath, "w");
    if (!dstFile) {
        srcFile.close();
        lua_pushboolean(L, false);
        return 1;
    }

    // Copy in chunks
    uint8_t buffer[512];
    size_t bytesRead;
    bool success = true;

    while ((bytesRead = srcFile.read(buffer, sizeof(buffer))) > 0) {
        if (dstFile.write(buffer, bytesRead) != bytesRead) {
            success = false;
            break;
        }
    }

    srcFile.close();
    dstFile.close();

    lua_pushboolean(L, success);
    return 1;
}

// @lua ez.storage.get_free_space(path) -> integer
// @brief Get free space on filesystem in bytes
// @description Returns the available free space on the specified filesystem.
// Use before writing large files to ensure sufficient space. Returns 0 if the
// filesystem is not available.
// @param path Path to check ("/sd/" for SD card, otherwise LittleFS), default "/sd/"
// @return Free space in bytes, or 0 on error
// @example
// local sd_free = ez.storage.get_free_space("/sd/")
// local flash_free = ez.storage.get_free_space("/")
// print(string.format("SD: %d MB, Flash: %d KB free",
//     sd_free / (1024*1024), flash_free / 1024))
// @end
LUA_FUNCTION(l_storage_get_free_space) {
    const char* path = luaL_optstring(L, 1, "/sd/");

    if (strncmp(path, "/sd/", 4) == 0 || strcmp(path, "/sd") == 0) {
        if (!initSD()) {
            lua_pushinteger(L, 0);
            return 1;
        }
        uint64_t freeSpace = SD.totalBytes() - SD.usedBytes();
        lua_pushinteger(L, (lua_Integer)freeSpace);
    } else {
        size_t totalBytes = LittleFS.totalBytes();
        size_t usedBytes = LittleFS.usedBytes();
        lua_pushinteger(L, (lua_Integer)(totalBytes - usedBytes));
    }
    return 1;
}

// @lua ez.storage.list_embedded(prefix) -> table
// @brief List embedded script paths
// @description Returns a list of all embedded Lua scripts. These are scripts
// compiled into the firmware and cannot be modified. Optionally filter by prefix
// to list only scripts in a subdirectory (e.g., "/scripts/ui/screens").
// @param prefix Optional path prefix filter (default: list all)
// @return Array of tables with path, size, and is_embedded fields
// @example
// local scripts = ez.storage.list_embedded("/scripts/ui/screens")
// for _, script in ipairs(scripts) do
//     print(script.path, script.size, "bytes")
// end
// @end
LUA_FUNCTION(l_storage_list_embedded) {
    const char* prefix = luaL_optstring(L, 1, "");
    size_t prefixLen = strlen(prefix);

    lua_newtable(L);
    int idx = 1;

    size_t count = embedded_lua::get_script_count();
    for (size_t i = 0; i < count; i++) {
        const char* path = embedded_lua::get_script_path(i);
        if (!path) continue;

        // Filter by prefix if provided
        if (prefixLen > 0 && strncmp(path, prefix, prefixLen) != 0) {
            continue;
        }

        lua_newtable(L);

        lua_pushstring(L, path);
        lua_setfield(L, -2, "path");

        lua_pushinteger(L, embedded_lua::get_script_size(i));
        lua_setfield(L, -2, "size");

        lua_pushboolean(L, true);
        lua_setfield(L, -2, "is_embedded");

        lua_rawseti(L, -2, idx++);
    }

    return 1;
}

// @lua ez.storage.read_embedded(path) -> string
// @brief Read embedded script content
// @description Reads the content of an embedded Lua script. These scripts are
// compiled into firmware and are read-only. Use list_embedded() to discover
// available embedded scripts.
// @param path Full path of the embedded script (e.g., "/scripts/boot.lua")
// @return Script content as string, or nil if not found
// @example
// local content = ez.storage.read_embedded("/scripts/boot.lua")
// if content then
//     print("Boot script is", #content, "bytes")
// end
// @end
LUA_FUNCTION(l_storage_read_embedded) {
    LUA_CHECK_ARGC(L, 1);
    const char* path = luaL_checkstring(L, 1);

    size_t size = 0;
    const char* content = embedded_lua::get_script(path, &size);

    if (!content) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushlstring(L, content, size);
    return 1;
}

// @lua ez.storage.is_embedded(path) -> boolean
// @brief Check if a path is an embedded script
// @description Returns true if the given path corresponds to an embedded Lua script.
// Useful for determining if a file is read-only (embedded) or editable (on SD/flash).
// @param path Path to check
// @return true if path is an embedded script
// @example
// if ez.storage.is_embedded("/scripts/boot.lua") then
//     print("This is a read-only embedded script")
// end
// @end
LUA_FUNCTION(l_storage_is_embedded) {
    LUA_CHECK_ARGC(L, 1);
    const char* path = luaL_checkstring(L, 1);

    const char* content = embedded_lua::get_script(path, nullptr);
    lua_pushboolean(L, content != nullptr);
    return 1;
}

// Function table for ez.storage
static const luaL_Reg storage_funcs[] = {
    {"read_file",       l_storage_read_file},
    {"read_bytes",      l_storage_read_bytes},
    {"file_size",       l_storage_file_size},
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
    {"json_encode",     l_storage_json_encode},
    {"json_decode",     l_storage_json_decode},
    {"copy_file",       l_storage_copy_file},
    {"get_free_space",  l_storage_get_free_space},
    // Embedded script functions
    {"list_embedded",   l_storage_list_embedded},
    {"read_embedded",   l_storage_read_embedded},
    {"is_embedded",     l_storage_is_embedded},
    // Aliases for shorter names
    {"read",            l_storage_read_file},
    {"write",           l_storage_write_file},
    {nullptr, nullptr}
};

// Register the storage module
void registerStorageModule(lua_State* L) {
    lua_register_module(L, "storage", storage_funcs);
    Serial.println("[LuaRuntime] Registered ez.storage");
}
