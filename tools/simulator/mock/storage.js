/**
 * Storage mock module
 * Uses localStorage for files and preferences
 * Binary files (like maps) are preloaded into memory during initialization
 */

// Map of SD card paths to server paths
const SD_FILE_MAPPINGS = {
    '/sd/maps/world.tdmap': '../../tools/maps/world.tdmap',
};

// Binary file cache (path -> Uint8Array)
const binaryFileCache = new Map();

// Debug: expose cache for inspection
export function getBinaryCacheStatus() {
    const entries = [];
    for (const [path, data] of binaryFileCache.entries()) {
        entries.push({ path, size: data.length });
    }
    return entries;
}

// Check if a path has a server mapping
function getServerPath(path) {
    return SD_FILE_MAPPINGS[path] || null;
}

// Preload binary files into memory
export async function preloadBinaryFiles() {
    for (const [sdPath, serverPath] of Object.entries(SD_FILE_MAPPINGS)) {
        console.log(`[Storage] Loading ${sdPath} from ${serverPath}...`);
        try {
            const response = await fetch(serverPath);
            if (!response.ok) {
                console.warn(`[Storage] Failed to fetch ${serverPath}: ${response.status}`);
                continue;
            }
            const buffer = await response.arrayBuffer();
            const data = new Uint8Array(buffer);
            binaryFileCache.set(sdPath, data);
            console.log(`[Storage] Loaded ${sdPath}: ${(data.length / 1024 / 1024).toFixed(1)} MB`);
        } catch (e) {
            console.warn(`[Storage] Error loading ${serverPath}:`, e.message);
        }
    }
}

export function createStorageModule() {
    const module = {
        // Read entire file
        read(path) {
            try {
                const cached = localStorage.getItem(`tdeck_file_${path}`);
                // Return undefined instead of null (Wasmoon handles undefined better)
                return cached === null ? undefined : cached;
            } catch (e) {
                return undefined;
            }
        },

        // Write entire file
        write(path, content) {
            try {
                localStorage.setItem(`tdeck_file_${path}`, content);
                return true;
            } catch (e) {
                return false;
            }
        },

        // Read bytes from file (returns array of byte values to avoid null-termination issues)
        // Wasmoon truncates strings at null bytes, so we return an array instead
        // Note: Returns undefined instead of null so Wasmoon converts to Lua nil properly
        read_bytes(path, offset, len) {
            // Check binary file cache first
            const binaryData = binaryFileCache.get(path);
            if (binaryData) {
                // Return slice as array of byte values (avoids null-termination issue)
                const end = Math.min(offset + len, binaryData.length);
                const slice = binaryData.slice(offset, end);
                return Array.from(slice);
            }
            // Fall back to localStorage (returns string, convert to byte array)
            const content = module.read(path);
            if (content) {
                const str = content.substring(offset, offset + len);
                const result = [];
                for (let i = 0; i < str.length; i++) {
                    result.push(str.charCodeAt(i));
                }
                return result;
            }
            return undefined;
        },

        // Check if file exists
        exists(path) {
            // Check binary file cache first
            if (binaryFileCache.has(path)) {
                return true;
            }
            try {
                const cached = localStorage.getItem(`tdeck_file_${path}`);
                return cached !== null;
            } catch (e) {
                return false;
            }
        },

        // Remove a file
        remove(path) {
            try {
                localStorage.removeItem(`tdeck_file_${path}`);
                return true;
            } catch (e) {
                return false;
            }
        },

        // List directory contents (returns empty array in simulator)
        list_dir(path) {
            // In browser simulator, return empty array
            return [];
        },

        // Create directory (no-op in browser)
        mkdir(path) {
            return true;
        },

        // Remove directory (no-op in browser)
        rmdir(path) {
            return true;
        },

        // Check if SD card is available (always true in simulator)
        is_sd_available() {
            return true;
        },

        // Rename/move a file
        rename(oldPath, newPath) {
            try {
                const content = localStorage.getItem(`tdeck_file_${oldPath}`);
                if (content !== null) {
                    localStorage.setItem(`tdeck_file_${newPath}`, content);
                    localStorage.removeItem(`tdeck_file_${oldPath}`);
                    return true;
                }
                return false;
            } catch (e) {
                return false;
            }
        },

        // Get file size
        file_size(path) {
            // Check binary file cache first
            const binaryData = binaryFileCache.get(path);
            if (binaryData) {
                return binaryData.length;
            }
            try {
                const content = localStorage.getItem(`tdeck_file_${path}`);
                return content ? content.length : 0;
            } catch (e) {
                return 0;
            }
        },

        // Preferences using localStorage
        get_pref(key, defaultValue) {
            try {
                const value = localStorage.getItem(`tdeck_pref_${key}`);
                if (value === null) {
                    // Return undefined (becomes nil in Lua) if no default, otherwise return default
                    // But if defaultValue is null (from Lua nil), return undefined
                    return defaultValue === null ? undefined : defaultValue;
                }
                // Try to parse as JSON for booleans/numbers
                try {
                    return JSON.parse(value);
                } catch {
                    return value;
                }
            } catch (e) {
                return defaultValue === null ? undefined : defaultValue;
            }
        },

        set_pref(key, value) {
            try {
                localStorage.setItem(`tdeck_pref_${key}`, JSON.stringify(value));
                return true;
            } catch (e) {
                return false;
            }
        },

        delete_pref(key) {
            try {
                localStorage.removeItem(`tdeck_pref_${key}`);
                return true;
            } catch (e) {
                return false;
            }
        },

        // Alias for API compatibility
        remove_pref(key) {
            return module.delete_pref(key);
        },

        // Clear all preferences
        clear_prefs() {
            try {
                const keys = Object.keys(localStorage);
                for (const key of keys) {
                    if (key.startsWith('tdeck_pref_')) {
                        localStorage.removeItem(key);
                    }
                }
                return true;
            } catch (e) {
                return false;
            }
        },

        // JSON encoding/decoding
        json_encode(value) {
            try {
                return JSON.stringify(value);
            } catch (e) {
                return null;
            }
        },

        json_decode(str) {
            try {
                return JSON.parse(str);
            } catch (e) {
                return null;
            }
        },

        // Get total/free space (mock values)
        get_total_space() {
            return 16 * 1024 * 1024 * 1024; // 16GB
        },

        get_free_space() {
            return 10 * 1024 * 1024 * 1024; // 10GB
        },

        // Flash/SD info (mock)
        get_flash_info() {
            return {
                total_bytes: 4 * 1024 * 1024,
                used_bytes: 1 * 1024 * 1024,
                free_bytes: 3 * 1024 * 1024,
            };
        },

        get_sd_info() {
            return {
                total_bytes: 16 * 1024 * 1024 * 1024,
                used_bytes: 6 * 1024 * 1024 * 1024,
                free_bytes: 10 * 1024 * 1024 * 1024,
            };
        },
    };

    return module;
}
