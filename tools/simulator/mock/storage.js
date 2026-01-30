/**
 * Storage mock module
 * Uses IndexedDB for files and localStorage for preferences
 */

// IndexedDB setup
const DB_NAME = 'tdeck-simulator';
const DB_VERSION = 1;
const STORE_NAME = 'files';

let db = null;

async function initDB() {
    if (db) return db;

    return new Promise((resolve, reject) => {
        const request = indexedDB.open(DB_NAME, DB_VERSION);

        request.onerror = () => reject(request.error);

        request.onsuccess = () => {
            db = request.result;
            resolve(db);
        };

        request.onupgradeneeded = (event) => {
            const database = event.target.result;
            if (!database.objectStoreNames.contains(STORE_NAME)) {
                database.createObjectStore(STORE_NAME);
            }
        };
    });
}

// Initialize DB on module load
initDB().catch(console.error);

async function idbGet(key) {
    await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction([STORE_NAME], 'readonly');
        const store = transaction.objectStore(STORE_NAME);
        const request = store.get(key);

        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve(request.result);
    });
}

async function idbSet(key, value) {
    await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction([STORE_NAME], 'readwrite');
        const store = transaction.objectStore(STORE_NAME);
        const request = store.put(value, key);

        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve();
    });
}

async function idbDelete(key) {
    await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction([STORE_NAME], 'readwrite');
        const store = transaction.objectStore(STORE_NAME);
        const request = store.delete(key);

        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve();
    });
}

async function idbKeys() {
    await initDB();
    return new Promise((resolve, reject) => {
        const transaction = db.transaction([STORE_NAME], 'readonly');
        const store = transaction.objectStore(STORE_NAME);
        const request = store.getAllKeys();

        request.onerror = () => reject(request.error);
        request.onsuccess = () => resolve(request.result);
    });
}

export function createStorageModule() {
    const module = {
        // Read entire file (sync version for Lua compatibility)
        read(path) {
            // For simulator, return from localStorage or null
            try {
                const cached = localStorage.getItem(`tdeck_file_${path}`);
                return cached;
            } catch (e) {
                return null;
            }
        },

        // Write entire file (sync version for Lua compatibility)
        write(path, content) {
            try {
                localStorage.setItem(`tdeck_file_${path}`, content);
                return true;
            } catch (e) {
                return false;
            }
        },

        // Read bytes from file (sync version)
        read_bytes(path, offset, len) {
            const content = module.read(path);
            if (content) {
                return content.substring(offset, offset + len);
            }
            return null;
        },

        // Read entire file (async version)
        async read_file(path) {
            try {
                // Check IndexedDB first
                const cached = await idbGet(path);
                if (cached !== undefined) {
                    return cached;
                }

                // Try fetching from data directory
                if (path.startsWith('/sd/')) {
                    const relativePath = path.substring(4);
                    const response = await fetch(`../../data/${relativePath}`);
                    if (response.ok) {
                        return await response.text();
                    }
                }

                return null;
            } catch (e) {
                console.error('read_file error:', e);
                return null;
            }
        },

        // Write file
        async write_file(path, content) {
            try {
                await idbSet(path, content);
                return true;
            } catch (e) {
                console.error('write_file error:', e);
                return false;
            }
        },

        // Append to file
        async append_file(path, content) {
            try {
                const existing = await idbGet(path) || '';
                await idbSet(path, existing + content);
                return true;
            } catch (e) {
                console.error('append_file error:', e);
                return false;
            }
        },

        // Check if file exists
        async exists(path) {
            try {
                const cached = await idbGet(path);
                if (cached !== undefined) return true;

                // Try fetching from data directory
                if (path.startsWith('/sd/')) {
                    const relativePath = path.substring(4);
                    const response = await fetch(`../../data/${relativePath}`, { method: 'HEAD' });
                    return response.ok;
                }

                return false;
            } catch (e) {
                return false;
            }
        },

        // Delete file
        async delete_file(path) {
            try {
                await idbDelete(path);
                return true;
            } catch (e) {
                console.error('delete_file error:', e);
                return false;
            }
        },

        // List directory contents
        async list_dir(path) {
            try {
                const allKeys = await idbKeys();
                const prefix = path.endsWith('/') ? path : path + '/';
                const files = [];

                for (const key of allKeys) {
                    if (key.startsWith(prefix)) {
                        const relativePath = key.substring(prefix.length);
                        const parts = relativePath.split('/');
                        if (parts.length === 1) {
                            files.push({
                                name: parts[0],
                                is_dir: false,
                                size: 0,
                            });
                        } else {
                            // Directory
                            const dirName = parts[0];
                            if (!files.find(f => f.name === dirName)) {
                                files.push({
                                    name: dirName,
                                    is_dir: true,
                                    size: 0,
                                });
                            }
                        }
                    }
                }

                return files;
            } catch (e) {
                console.error('list_dir error:', e);
                return [];
            }
        },

        // Create directory (no-op in browser)
        mkdir(path) {
            return true;
        },

        // Remove directory
        async rmdir(path) {
            try {
                const allKeys = await idbKeys();
                const prefix = path.endsWith('/') ? path : path + '/';

                for (const key of allKeys) {
                    if (key.startsWith(prefix)) {
                        await idbDelete(key);
                    }
                }
                return true;
            } catch (e) {
                console.error('rmdir error:', e);
                return false;
            }
        },

        // Get file size
        async file_size(path) {
            try {
                const content = await idbGet(path);
                if (content !== undefined) {
                    return typeof content === 'string' ? content.length : 0;
                }
                return 0;
            } catch (e) {
                return 0;
            }
        },

        // Preferences using localStorage
        get_pref(key, defaultValue = null) {
            try {
                const value = localStorage.getItem(`tdeck_pref_${key}`);
                if (value === null) return defaultValue;
                // Try to parse as JSON for booleans/numbers
                try {
                    return JSON.parse(value);
                } catch {
                    return value;
                }
            } catch (e) {
                return defaultValue;
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
                total: 4 * 1024 * 1024,
                used: 1 * 1024 * 1024,
                free: 3 * 1024 * 1024,
            };
        },

        get_sd_info() {
            return {
                total: 16 * 1024 * 1024 * 1024,
                used: 6 * 1024 * 1024 * 1024,
                free: 10 * 1024 * 1024 * 1024,
            };
        },
    };

    return module;
}
