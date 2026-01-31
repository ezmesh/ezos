/**
 * Storage mock module
 * Uses localStorage for files and preferences
 * Binary files (like maps) are loaded on-demand using Range requests
 */

// Map of SD card paths to server paths
const SD_FILE_MAPPINGS = {
    '/sd/maps/world.tdmap': '../../tools/maps/world.tdmap',
};

// Binary file metadata cache (path -> { size, serverPath })
const binaryFileMeta = new Map();

// Small byte range cache to avoid repeated fetches (path -> Map(rangeKey -> Uint8Array))
const rangeCache = new Map();
const MAX_RANGE_CACHE_SIZE = 50;  // Max cached ranges per file
const MAX_CACHED_RANGE_SIZE = 100 * 1024;  // Only cache ranges up to 100KB

// Debug: expose cache for inspection
export function getBinaryCacheStatus() {
    const entries = [];
    for (const [path, meta] of binaryFileMeta.entries()) {
        const ranges = rangeCache.get(path);
        const cachedRanges = ranges ? ranges.size : 0;
        entries.push({ path, size: meta.size, cachedRanges });
    }
    return entries;
}

// Check if a path has a server mapping
function getServerPath(path) {
    return SD_FILE_MAPPINGS[path] || null;
}

// Initialize binary file metadata (just get sizes, don't load content)
export async function preloadBinaryFiles() {
    for (const [sdPath, serverPath] of Object.entries(SD_FILE_MAPPINGS)) {
        console.log(`[Storage] Checking ${sdPath} at ${serverPath}...`);
        try {
            // Use HEAD request to get file size without downloading content
            const response = await fetch(serverPath, { method: 'HEAD' });
            if (!response.ok) {
                console.warn(`[Storage] Failed to check ${serverPath}: ${response.status}`);
                continue;
            }
            const size = parseInt(response.headers.get('Content-Length') || '0', 10);
            binaryFileMeta.set(sdPath, { size, serverPath });
            console.log(`[Storage] Found ${sdPath}: ${(size / 1024 / 1024).toFixed(1)} MB (on-demand loading)`);
        } catch (e) {
            console.warn(`[Storage] Error checking ${serverPath}:`, e.message);
        }
    }
}

// Fetch a byte range from a file using synchronous XMLHttpRequest
// This blocks the main thread but is necessary because Wasmoon doesn't support async Promises
// Note: We use overrideMimeType to force binary interpretation since responseType='arraybuffer'
// is not allowed for synchronous XHR in modern browsers
function fetchRangeSync(serverPath, offset, len) {
    const rangeEnd = offset + len - 1;
    try {
        const xhr = new XMLHttpRequest();
        xhr.open('GET', serverPath, false);  // false = synchronous
        xhr.setRequestHeader('Range', `bytes=${offset}-${rangeEnd}`);
        // Use overrideMimeType to force binary string interpretation
        xhr.overrideMimeType('text/plain; charset=x-user-defined');
        xhr.send(null);

        if (xhr.status === 206 || xhr.status === 200) {
            const text = xhr.responseText;
            // Convert binary string to Uint8Array
            const bytes = new Uint8Array(text.length);
            for (let i = 0; i < text.length; i++) {
                bytes[i] = text.charCodeAt(i) & 0xFF;
            }
            if (xhr.status === 200) {
                // Server returned full file, slice it
                console.warn(`[Storage] Range request returned full file, slicing`);
                return bytes.slice(offset, offset + len);
            }
            return bytes;
        } else {
            console.error(`[Storage] Fetch failed: ${xhr.status}`);
            return null;
        }
    } catch (e) {
        console.error(`[Storage] Fetch error:`, e.message);
        return null;
    }
}

// Get a cached range or fetch it (synchronous)
function getCachedRange(sdPath, serverPath, offset, len) {
    // Initialize cache for this file if needed
    if (!rangeCache.has(sdPath)) {
        rangeCache.set(sdPath, new Map());
    }
    const cache = rangeCache.get(sdPath);

    // Check if we have this exact range cached
    const rangeKey = `${offset}:${len}`;
    if (cache.has(rangeKey)) {
        return cache.get(rangeKey);
    }

    // Fetch the range synchronously
    const data = fetchRangeSync(serverPath, offset, len);

    // Cache small ranges
    if (data && len <= MAX_CACHED_RANGE_SIZE) {
        // Evict old entries if cache is full
        if (cache.size >= MAX_RANGE_CACHE_SIZE) {
            const firstKey = cache.keys().next().value;
            cache.delete(firstKey);
        }
        cache.set(rangeKey, data);
    }

    return data;
}

export function createStorageModule() {
    const module = {
        // Read entire file
        read(path) {
            try {
                const cached = localStorage.getItem(`ez_file_${path}`);
                // Return undefined instead of null (Wasmoon handles undefined better)
                return cached === null ? undefined : cached;
            } catch (e) {
                return undefined;
            }
        },

        // Write entire file
        write(path, content) {
            try {
                localStorage.setItem(`ez_file_${path}`, content);
                return true;
            } catch (e) {
                return false;
            }
        },

        // Read bytes from file (returns array of byte values to avoid null-termination issues)
        // Wasmoon truncates strings at null bytes, so we return an array instead
        // Note: Returns undefined instead of null so Wasmoon converts to Lua nil properly
        // Uses synchronous XMLHttpRequest for Range requests (Wasmoon doesn't handle async Promises)
        read_bytes(path, offset, len) {
            // Check if this is a mapped binary file
            const meta = binaryFileMeta.get(path);
            if (meta) {
                // Fetch range synchronously
                const data = getCachedRange(path, meta.serverPath, offset, len);
                if (data) {
                    return Array.from(data);
                }
                return undefined;
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
            // Check binary file metadata first
            if (binaryFileMeta.has(path)) {
                return true;
            }
            try {
                const cached = localStorage.getItem(`ez_file_${path}`);
                return cached !== null;
            } catch (e) {
                return false;
            }
        },

        // Remove a file
        remove(path) {
            try {
                localStorage.removeItem(`ez_file_${path}`);
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
                const content = localStorage.getItem(`ez_file_${oldPath}`);
                if (content !== null) {
                    localStorage.setItem(`ez_file_${newPath}`, content);
                    localStorage.removeItem(`ez_file_${oldPath}`);
                    return true;
                }
                return false;
            } catch (e) {
                return false;
            }
        },

        // Get file size
        file_size(path) {
            // Check binary file metadata first
            const meta = binaryFileMeta.get(path);
            if (meta) {
                return meta.size;
            }
            try {
                const content = localStorage.getItem(`ez_file_${path}`);
                return content ? content.length : 0;
            } catch (e) {
                return 0;
            }
        },

        // Preferences using localStorage
        get_pref(key, defaultValue) {
            try {
                const value = localStorage.getItem(`ez_pref_${key}`);
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
                localStorage.setItem(`ez_pref_${key}`, JSON.stringify(value));
                return true;
            } catch (e) {
                return false;
            }
        },

        delete_pref(key) {
            try {
                localStorage.removeItem(`ez_pref_${key}`);
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
                    if (key.startsWith('ez_pref_')) {
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
