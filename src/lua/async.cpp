#include "async.h"
#include "embedded_lua_scripts.h"
#include <Arduino.h>
#include <SD.h>
#include <LittleFS.h>
#include <ArduinoJson.h>

// mbedTLS for crypto
#include "mbedtls/aes.h"
#include "mbedtls/md.h"
#include "mbedtls/sha256.h"

// Queue sizes
constexpr size_t QUEUE_SIZE = 8;
// Max file size for async read (512KB)
constexpr size_t MAX_FILE_SIZE = 512 * 1024;
// AES block size
constexpr size_t AES_BLOCK_SIZE = 16;

// Helper to determine which filesystem to use based on path
// Paths starting with "/sd/" use SD card, otherwise LittleFS
static fs::FS* getFS(const char* path, const char** adjustedPath) {
    if (strncmp(path, "/sd/", 4) == 0) {
        *adjustedPath = path + 3;  // Skip "/sd" prefix, keep leading "/"
        return &SD;
    }
    *adjustedPath = path;
    return &LittleFS;
}

AsyncIO& AsyncIO::instance() {
    static AsyncIO inst;
    return inst;
}

bool AsyncIO::init(lua_State* L) {
    _mainState = L;

    _requestQueue = xQueueCreate(QUEUE_SIZE, sizeof(Request));
    _resultQueue = xQueueCreate(QUEUE_SIZE, sizeof(Result));

    if (!_requestQueue || !_resultQueue) {
        Serial.println("[AsyncIO] Failed to create queues");
        return false;
    }

    // Worker task on Core 0 (Lua runs on Core 1)
    BaseType_t res = xTaskCreatePinnedToCore(
        workerTask, "async_io", 12288, this, 1, &_workerTask, 0
    );

    if (res != pdPASS) {
        Serial.println("[AsyncIO] Failed to create worker task");
        return false;
    }

    Serial.println("[AsyncIO] Initialized - worker on Core 0");
    return true;
}

// =============================================================================
// Helper Functions (run on worker task)
// =============================================================================

uint8_t* AsyncIO::rleDecompress(const uint8_t* data, size_t len, size_t* outLen) {
    // Single-pass RLE decompression with pre-allocated buffer
    // For map tiles, output is always 24576 bytes (256*256*3/8)
    // We allocate generously to handle any compressed data

    // Estimate max output size: worst case is no compression (1:1)
    // but RLE runs can expand, so use input * 256 as absolute max
    // In practice, map tiles decompress to ~24KB
    constexpr size_t MAP_TILE_SIZE = 256 * 256 * 3 / 8;  // 24576 bytes
    size_t maxOutput = (len < 1024) ? len * 256 : MAP_TILE_SIZE + 4096;

    // Allocate output buffer in PSRAM
    uint8_t* output = (uint8_t*)ps_malloc(maxOutput);
    if (!output) {
        output = (uint8_t*)malloc(maxOutput);
    }
    if (!output) {
        *outLen = 0;
        return nullptr;
    }

    // Single-pass decompress with memset optimization for runs
    size_t outIdx = 0;
    size_t i = 0;
    while (i < len && outIdx < maxOutput) {
        if (data[i] == 0xFF && i + 2 < len) {
            uint8_t count = data[i + 1];
            uint8_t value = data[i + 2];
            // Use memset for runs (faster than byte-by-byte loop)
            size_t runLen = (outIdx + count <= maxOutput) ? count : (maxOutput - outIdx);
            memset(output + outIdx, value, runLen);
            outIdx += runLen;
            i += 3;
        } else {
            output[outIdx++] = data[i++];
        }
    }

    *outLen = outIdx;
    return output;
}

// Decompress RLE data and convert to RGB565
// Two-step: decompress RLE first, then convert 3-bit indexed to RGB565
// Output: 256*256*2 = 131072 bytes for a full map tile
uint16_t* AsyncIO::rleDecompressToRgb565(const uint8_t* data, size_t len,
                                          const uint16_t* palette, size_t* outLen) {
    // Step 1: Decompress RLE to get indexed data
    size_t indexedLen;
    uint8_t* indexed = rleDecompress(data, len, &indexedLen);
    if (!indexed) {
        Serial.println("[AsyncIO] RLE decompress failed in RGB565");
        *outLen = 0;
        return nullptr;
    }

    // Expected size for 256x256 tile with 3-bit indexed (8 pixels per 3 bytes)
    constexpr size_t EXPECTED_INDEXED = 256 * 256 * 3 / 8;  // 24576 bytes
    if (indexedLen < EXPECTED_INDEXED) {
        Serial.printf("[AsyncIO] Indexed data too short: %d < %d\n", indexedLen, EXPECTED_INDEXED);
        free(indexed);
        *outLen = 0;
        return nullptr;
    }

    // Step 2: Allocate RGB565 output buffer
    constexpr size_t TILE_PIXELS = 256 * 256;
    constexpr size_t RGB565_SIZE = TILE_PIXELS * sizeof(uint16_t);

    uint16_t* output = (uint16_t*)ps_malloc(RGB565_SIZE);
    if (!output) {
        output = (uint16_t*)malloc(RGB565_SIZE);
    }
    if (!output) {
        Serial.println("[AsyncIO] RGB565 buffer alloc failed");
        free(indexed);
        *outLen = 0;
        return nullptr;
    }

    // Step 3: Convert 3-bit indexed to RGB565
    // Process 8 pixels (3 bytes) at a time
    uint16_t* outPtr = output;
    const uint8_t* inPtr = indexed;
    size_t numGroups = TILE_PIXELS / 8;  // 8192 groups

    for (size_t g = 0; g < numGroups; g++) {
        uint8_t b0 = *inPtr++;
        uint8_t b1 = *inPtr++;
        uint8_t b2 = *inPtr++;

        // Unpack 8 pixels from 3 bytes
        *outPtr++ = palette[b0 & 0x07];
        *outPtr++ = palette[(b0 >> 3) & 0x07];
        *outPtr++ = palette[((b0 >> 6) & 0x03) | ((b1 & 0x01) << 2)];
        *outPtr++ = palette[(b1 >> 1) & 0x07];
        *outPtr++ = palette[(b1 >> 4) & 0x07];
        *outPtr++ = palette[((b1 >> 7) & 0x01) | ((b2 & 0x03) << 1)];
        *outPtr++ = palette[(b2 >> 2) & 0x07];
        *outPtr++ = palette[(b2 >> 5) & 0x07];
    }

    free(indexed);
    *outLen = RGB565_SIZE;
    return output;
}

uint8_t* AsyncIO::aesEncrypt(const uint8_t* key, size_t keyLen,
                             const uint8_t* data, size_t dataLen, size_t* outLen) {
    if (keyLen != 16) {
        *outLen = 0;
        return nullptr;
    }

    // Pad to block boundary
    size_t paddedLen = ((dataLen + AES_BLOCK_SIZE - 1) / AES_BLOCK_SIZE) * AES_BLOCK_SIZE;
    if (paddedLen == 0) paddedLen = AES_BLOCK_SIZE;

    uint8_t* padded = (uint8_t*)malloc(paddedLen);
    uint8_t* output = (uint8_t*)ps_malloc(paddedLen);
    if (!output) output = (uint8_t*)malloc(paddedLen);

    if (!padded || !output) {
        free(padded);
        free(output);
        *outLen = 0;
        return nullptr;
    }

    memset(padded, 0, paddedLen);
    memcpy(padded, data, dataLen);

    mbedtls_aes_context ctx;
    mbedtls_aes_init(&ctx);

    int ret = mbedtls_aes_setkey_enc(&ctx, key, 128);
    if (ret != 0) {
        mbedtls_aes_free(&ctx);
        free(padded);
        free(output);
        *outLen = 0;
        return nullptr;
    }

    // Encrypt block by block
    for (size_t i = 0; i < paddedLen; i += AES_BLOCK_SIZE) {
        ret = mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_ENCRYPT, padded + i, output + i);
        if (ret != 0) {
            mbedtls_aes_free(&ctx);
            free(padded);
            free(output);
            *outLen = 0;
            return nullptr;
        }
    }

    mbedtls_aes_free(&ctx);
    free(padded);

    *outLen = paddedLen;
    return output;
}

uint8_t* AsyncIO::aesDecrypt(const uint8_t* key, size_t keyLen,
                             const uint8_t* data, size_t dataLen, size_t* outLen) {
    if (keyLen != 16 || dataLen == 0 || dataLen % AES_BLOCK_SIZE != 0) {
        *outLen = 0;
        return nullptr;
    }

    uint8_t* output = (uint8_t*)ps_malloc(dataLen);
    if (!output) output = (uint8_t*)malloc(dataLen);

    if (!output) {
        *outLen = 0;
        return nullptr;
    }

    mbedtls_aes_context ctx;
    mbedtls_aes_init(&ctx);

    int ret = mbedtls_aes_setkey_dec(&ctx, key, 128);
    if (ret != 0) {
        mbedtls_aes_free(&ctx);
        free(output);
        *outLen = 0;
        return nullptr;
    }

    // Decrypt block by block
    for (size_t i = 0; i < dataLen; i += AES_BLOCK_SIZE) {
        ret = mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_DECRYPT, data + i, output + i);
        if (ret != 0) {
            mbedtls_aes_free(&ctx);
            free(output);
            *outLen = 0;
            return nullptr;
        }
    }

    mbedtls_aes_free(&ctx);

    *outLen = dataLen;
    return output;
}

uint8_t* AsyncIO::hmacSha256(const uint8_t* key, size_t keyLen,
                             const uint8_t* data, size_t dataLen) {
    uint8_t* mac = (uint8_t*)malloc(32);
    if (!mac) return nullptr;

    mbedtls_md_context_t ctx;
    mbedtls_md_init(&ctx);

    const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (!info) {
        mbedtls_md_free(&ctx);
        free(mac);
        return nullptr;
    }

    int ret = mbedtls_md_setup(&ctx, info, 1);  // 1 = use HMAC
    if (ret != 0) {
        mbedtls_md_free(&ctx);
        free(mac);
        return nullptr;
    }

    ret = mbedtls_md_hmac_starts(&ctx, key, keyLen);
    if (ret != 0) {
        mbedtls_md_free(&ctx);
        free(mac);
        return nullptr;
    }

    ret = mbedtls_md_hmac_update(&ctx, data, dataLen);
    if (ret != 0) {
        mbedtls_md_free(&ctx);
        free(mac);
        return nullptr;
    }

    ret = mbedtls_md_hmac_finish(&ctx, mac);
    mbedtls_md_free(&ctx);

    if (ret != 0) {
        free(mac);
        return nullptr;
    }

    return mac;
}

// =============================================================================
// Worker Task
// =============================================================================

void AsyncIO::workerTask(void* param) {
    AsyncIO* self = static_cast<AsyncIO*>(param);
    Request req;

    while (true) {
        if (xQueueReceive(self->_requestQueue, &req, portMAX_DELAY) == pdTRUE) {
            Result result;
            result.type = req.type;
            result.coroRef = req.coroRef;
            result.data = nullptr;
            result.len = 0;
            result.success = false;
            result.jsonString = nullptr;

            // Get the appropriate filesystem based on path
            const char* adjustedPath;
            fs::FS* fs = getFS(req.path, &adjustedPath);

            switch (req.type) {
                case OpType::READ: {
                    File f = fs->open(adjustedPath, FILE_READ);
                    if (f) {
                        size_t size = f.size();
                        if (size > 0 && size <= MAX_FILE_SIZE) {
                            result.data = (uint8_t*)ps_malloc(size);
                            if (!result.data) {
                                result.data = (uint8_t*)malloc(size);
                            }
                            if (result.data) {
                                result.len = f.read(result.data, size);
                                result.success = (result.len == size);
                                if (!result.success) {
                                    free(result.data);
                                    result.data = nullptr;
                                    result.len = 0;
                                }
                            }
                        }
                        f.close();
                    }
                    break;
                }

                case OpType::READ_BYTES: {
                    File f = fs->open(adjustedPath, FILE_READ);
                    if (f) {
                        size_t fileSize = f.size();
                        if (req.offset < fileSize && req.length > 0) {
                            size_t actualLen = req.length;
                            if (req.offset + actualLen > fileSize) {
                                actualLen = fileSize - req.offset;
                            }
                            result.data = (uint8_t*)ps_malloc(actualLen);
                            if (!result.data) {
                                result.data = (uint8_t*)malloc(actualLen);
                            }
                            if (result.data) {
                                f.seek(req.offset);
                                result.len = f.read(result.data, actualLen);
                                result.success = (result.len == actualLen);
                                if (!result.success) {
                                    free(result.data);
                                    result.data = nullptr;
                                    result.len = 0;
                                }
                            }
                        }
                        f.close();
                    }
                    break;
                }

                case OpType::WRITE: {
                    if (req.data && req.dataLen > 0) {
                        File f = fs->open(adjustedPath, FILE_WRITE);
                        if (f) {
                            size_t written = f.write(req.data, req.dataLen);
                            result.success = (written == req.dataLen);
                            result.len = written;
                            f.close();
                        }
                        free(req.data);
                    }
                    break;
                }

                case OpType::WRITE_BYTES: {
                    if (req.data && req.dataLen > 0) {
                        // Open in read+write mode to preserve existing content
                        File f = fs->open(adjustedPath, "r+");
                        if (!f) {
                            // File doesn't exist, create it
                            f = fs->open(adjustedPath, FILE_WRITE);
                        }
                        if (f) {
                            f.seek(req.offset);
                            size_t written = f.write(req.data, req.dataLen);
                            result.success = (written == req.dataLen);
                            result.len = written;
                            f.close();
                        }
                        free(req.data);
                    }
                    break;
                }

                case OpType::APPEND: {
                    if (req.data && req.dataLen > 0) {
                        File f = fs->open(adjustedPath, FILE_APPEND);
                        if (f) {
                            size_t written = f.write(req.data, req.dataLen);
                            result.success = (written == req.dataLen);
                            result.len = written;
                            f.close();
                        }
                        free(req.data);
                    }
                    break;
                }

                case OpType::EXISTS: {
                    result.success = fs->exists(adjustedPath);
                    break;
                }

                case OpType::JSON_READ: {
                    File f = fs->open(adjustedPath, FILE_READ);
                    if (f) {
                        size_t size = f.size();
                        if (size > 0 && size <= MAX_JSON_DOC) {
                            char* content = (char*)malloc(size + 1);
                            if (content) {
                                size_t readLen = f.read((uint8_t*)content, size);
                                content[readLen] = '\0';
                                // Store raw JSON string - will be parsed in main thread
                                result.jsonString = content;
                                result.success = true;
                            }
                        }
                        f.close();
                    }
                    break;
                }

                case OpType::JSON_WRITE: {
                    if (req.data && req.dataLen > 0) {
                        File f = fs->open(adjustedPath, FILE_WRITE);
                        if (f) {
                            // Data is already JSON string from Lua
                            size_t written = f.write(req.data, req.dataLen);
                            result.success = (written == req.dataLen);
                            f.close();
                        }
                        free(req.data);
                    }
                    break;
                }

                case OpType::RLE_READ: {
                    File f = fs->open(adjustedPath, FILE_READ);
                    if (f) {
                        size_t fileSize = f.size();
                        if (req.offset < fileSize && req.length > 0) {
                            size_t actualLen = req.length;
                            if (req.offset + actualLen > fileSize) {
                                actualLen = fileSize - req.offset;
                            }
                            uint8_t* compressed = (uint8_t*)malloc(actualLen);
                            if (compressed) {
                                f.seek(req.offset);
                                size_t readLen = f.read(compressed, actualLen);
                                if (readLen == actualLen) {
                                    // Decompress in worker thread
                                    size_t decompLen;
                                    result.data = rleDecompress(compressed, actualLen, &decompLen);
                                    if (result.data) {
                                        result.len = decompLen;
                                        result.success = true;
                                    }
                                }
                                free(compressed);
                            }
                        }
                        f.close();
                    }
                    break;
                }

                case OpType::RLE_READ_RGB565: {
                    File f = fs->open(adjustedPath, FILE_READ);
                    if (f) {
                        size_t fileSize = f.size();
                        if (req.offset < fileSize && req.length > 0) {
                            size_t actualLen = req.length;
                            if (req.offset + actualLen > fileSize) {
                                actualLen = fileSize - req.offset;
                            }
                            uint8_t* compressed = (uint8_t*)malloc(actualLen);
                            if (compressed) {
                                f.seek(req.offset);
                                size_t readLen = f.read(compressed, actualLen);
                                if (readLen == actualLen) {
                                    // Decompress and convert to RGB565 in one pass
                                    size_t rgb565Len;
                                    result.data = (uint8_t*)rleDecompressToRgb565(
                                        compressed, actualLen, req.palette, &rgb565Len);
                                    if (result.data) {
                                        result.len = rgb565Len;
                                        result.success = true;
                                        Serial.printf("[AsyncIO] RGB565 tile: in=%d out=%d\n", actualLen, rgb565Len);
                                    } else {
                                        Serial.println("[AsyncIO] RGB565 conversion failed");
                                    }
                                } else {
                                    Serial.printf("[AsyncIO] RGB565 read mismatch: %d vs %d\n", readLen, actualLen);
                                }
                                free(compressed);
                            } else {
                                Serial.println("[AsyncIO] RGB565 malloc failed");
                            }
                        }
                        f.close();
                    } else {
                        Serial.printf("[AsyncIO] RGB565 file open failed: %s\n", adjustedPath);
                    }
                    break;
                }

                case OpType::AES_ENCRYPT: {
                    if (req.data && req.dataLen > 0 && req.keyLen == 16) {
                        size_t outLen;
                        result.data = aesEncrypt(req.key, req.keyLen, req.data, req.dataLen, &outLen);
                        if (result.data) {
                            result.len = outLen;
                            result.success = true;
                        }
                        free(req.data);
                    }
                    break;
                }

                case OpType::AES_DECRYPT: {
                    if (req.data && req.dataLen > 0 && req.keyLen == 16) {
                        size_t outLen;
                        result.data = aesDecrypt(req.key, req.keyLen, req.data, req.dataLen, &outLen);
                        if (result.data) {
                            result.len = outLen;
                            result.success = true;
                        }
                        free(req.data);
                    }
                    break;
                }

                case OpType::HMAC_SHA256: {
                    if (req.data && req.dataLen > 0 && req.keyLen > 0) {
                        result.data = hmacSha256(req.key, req.keyLen, req.data, req.dataLen);
                        if (result.data) {
                            result.len = 32;  // SHA256 output is always 32 bytes
                            result.success = true;
                        }
                        free(req.data);
                    }
                    break;
                }
            }

            xQueueSend(self->_resultQueue, &result, portMAX_DELAY);
        }
    }
}

void AsyncIO::update() {
    processResults();
}

void AsyncIO::processResults() {
    Result result;

    while (xQueueReceive(_resultQueue, &result, 0) == pdTRUE) {
        if (result.coroRef == LUA_NOREF) {
            if (result.data) free(result.data);
            if (result.jsonString) free(result.jsonString);
            continue;
        }

        // Get coroutine
        lua_rawgeti(_mainState, LUA_REGISTRYINDEX, result.coroRef);
        lua_State* co = lua_tothread(_mainState, -1);
        lua_pop(_mainState, 1);

        if (co) {
            // Push result based on operation type
            switch (result.type) {
                case OpType::READ:
                case OpType::READ_BYTES:
                case OpType::RLE_READ:
                case OpType::RLE_READ_RGB565:
                case OpType::AES_ENCRYPT:
                case OpType::AES_DECRYPT:
                case OpType::HMAC_SHA256:
                    if (result.success && result.data) {
                        lua_pushlstring(co, (const char*)result.data, result.len);
                    } else {
                        lua_pushnil(co);
                    }
                    break;

                case OpType::WRITE:
                case OpType::WRITE_BYTES:
                case OpType::APPEND:
                case OpType::EXISTS:
                case OpType::JSON_WRITE:
                    lua_pushboolean(co, result.success);
                    break;

                case OpType::JSON_READ:
                    if (result.success && result.jsonString) {
                        // Parse JSON string to Lua table
                        JsonDocument doc;
                        DeserializationError err = deserializeJson(doc, result.jsonString);
                        if (err) {
                            lua_pushnil(co);
                        } else {
                            // Convert JSON to Lua (recursive helper needed)
                            // For simplicity, push raw string - Lua can use json_decode
                            lua_pushstring(co, result.jsonString);
                        }
                    } else {
                        lua_pushnil(co);
                    }
                    break;
            }

            // Lua 5.4 lua_resume requires nresults output parameter
            int nresults = 0;
            int status = lua_resume(co, _mainState, 1, &nresults);
            if (status != LUA_OK && status != LUA_YIELD) {
                const char* errMsg = lua_tostring(co, -1);
                Serial.printf("[AsyncIO] Coroutine error: %s\n", errMsg);

                // Call global show_error function to display error screen
                lua_getglobal(_mainState, "show_error");
                if (lua_isfunction(_mainState, -1)) {
                    lua_pushstring(_mainState, errMsg ? errMsg : "Unknown coroutine error");
                    lua_pushstring(_mainState, "coroutine");
                    if (lua_pcall(_mainState, 2, 0, 0) != LUA_OK) {
                        Serial.printf("[AsyncIO] Failed to show error: %s\n", lua_tostring(_mainState, -1));
                        lua_pop(_mainState, 1);
                    }
                } else {
                    lua_pop(_mainState, 1);
                }

                lua_pop(co, 1);
            }
        }

        luaL_unref(_mainState, LUA_REGISTRYINDEX, result.coroRef);
        if (result.data) free(result.data);
        if (result.jsonString) free(result.jsonString);
    }
}

// =============================================================================
// Lua Bindings
// =============================================================================

// async_read(path) - yields coroutine, resumes with data or nil
// For embedded scripts, returns data directly without async I/O
int AsyncIO::l_async_read(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    // Check for embedded scripts first (returns instantly for /scripts/ paths)
    size_t embeddedSize = 0;
    const char* embedded = embedded_lua::get_script(path, &embeddedSize);
    if (embedded != nullptr) {
        // Return embedded content directly - no async needed
        lua_pushlstring(L, embedded, embeddedSize);
        return 1;
    }

    // Not an embedded script - use async I/O for SD card files
    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    Request req = {};
    req.type = OpType::READ;
    req.coroRef = coroRef;
    strncpy(req.path, path, MAX_PATH - 1);

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_read_bytes(path, offset, len) - yields coroutine, resumes with data or nil
int AsyncIO::l_async_read_bytes(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    lua_Integer offset = luaL_checkinteger(L, 2);
    lua_Integer len = luaL_checkinteger(L, 3);

    if (offset < 0 || len <= 0) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    Request req = {};
    req.type = OpType::READ_BYTES;
    req.coroRef = coroRef;
    strncpy(req.path, path, MAX_PATH - 1);
    req.offset = (size_t)offset;
    req.length = (size_t)len;

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_write(path, data) - yields coroutine, resumes with true/false
int AsyncIO::l_async_write(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    size_t dataLen;
    const char* data = luaL_checklstring(L, 2, &dataLen);

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    uint8_t* dataCopy = (uint8_t*)malloc(dataLen);
    if (!dataCopy) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "out of memory");
    }
    memcpy(dataCopy, data, dataLen);

    Request req = {};
    req.type = OpType::WRITE;
    req.coroRef = coroRef;
    strncpy(req.path, path, MAX_PATH - 1);
    req.data = dataCopy;
    req.dataLen = dataLen;

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        free(dataCopy);
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_write_bytes(path, offset, data) - yields coroutine, resumes with true/false
int AsyncIO::l_async_write_bytes(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    lua_Integer offset = luaL_checkinteger(L, 2);
    size_t dataLen;
    const char* data = luaL_checklstring(L, 3, &dataLen);

    if (offset < 0) {
        lua_pushboolean(L, false);
        return 1;
    }

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    uint8_t* dataCopy = (uint8_t*)malloc(dataLen);
    if (!dataCopy) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "out of memory");
    }
    memcpy(dataCopy, data, dataLen);

    Request req = {};
    req.type = OpType::WRITE_BYTES;
    req.coroRef = coroRef;
    strncpy(req.path, path, MAX_PATH - 1);
    req.data = dataCopy;
    req.dataLen = dataLen;
    req.offset = (size_t)offset;

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        free(dataCopy);
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_append(path, data) - yields coroutine, resumes with true/false
int AsyncIO::l_async_append(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    size_t dataLen;
    const char* data = luaL_checklstring(L, 2, &dataLen);

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    uint8_t* dataCopy = (uint8_t*)malloc(dataLen);
    if (!dataCopy) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "out of memory");
    }
    memcpy(dataCopy, data, dataLen);

    Request req = {};
    req.type = OpType::APPEND;
    req.coroRef = coroRef;
    strncpy(req.path, path, MAX_PATH - 1);
    req.data = dataCopy;
    req.dataLen = dataLen;

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        free(dataCopy);
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_exists(path) - yields coroutine, resumes with true/false
int AsyncIO::l_async_exists(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    Request req = {};
    req.type = OpType::EXISTS;
    req.coroRef = coroRef;
    strncpy(req.path, path, MAX_PATH - 1);

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_json_read(path) - yields coroutine, resumes with JSON string or nil
int AsyncIO::l_async_json_read(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    Request req = {};
    req.type = OpType::JSON_READ;
    req.coroRef = coroRef;
    strncpy(req.path, path, MAX_PATH - 1);

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_json_write(path, json_string) - yields coroutine, resumes with true/false
int AsyncIO::l_async_json_write(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    size_t jsonLen;
    const char* jsonStr = luaL_checklstring(L, 2, &jsonLen);

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    uint8_t* dataCopy = (uint8_t*)malloc(jsonLen);
    if (!dataCopy) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "out of memory");
    }
    memcpy(dataCopy, jsonStr, jsonLen);

    Request req = {};
    req.type = OpType::JSON_WRITE;
    req.coroRef = coroRef;
    strncpy(req.path, path, MAX_PATH - 1);
    req.data = dataCopy;
    req.dataLen = jsonLen;

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        free(dataCopy);
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_rle_read(path, offset, len) - yields coroutine, resumes with decompressed data or nil
int AsyncIO::l_async_rle_read(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    lua_Integer offset = luaL_checkinteger(L, 2);
    lua_Integer len = luaL_checkinteger(L, 3);

    if (offset < 0 || len <= 0) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    Request req = {};
    req.type = OpType::RLE_READ;
    req.coroRef = coroRef;
    strncpy(req.path, path, MAX_PATH - 1);
    req.offset = (size_t)offset;
    req.length = (size_t)len;

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_rle_read_rgb565(path, offset, len, palette) - yields, resumes with RGB565 data
// Combines RLE decompression and 3-bit to RGB565 conversion in one async operation
// Returns 128KB of RGB565 data ready for draw_bitmap
int AsyncIO::l_async_rle_read_rgb565(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    lua_Integer offset = luaL_checkinteger(L, 2);
    lua_Integer len = luaL_checkinteger(L, 3);
    luaL_checktype(L, 4, LUA_TTABLE);

    if (offset < 0 || len <= 0) {
        lua_pushnil(L);
        return 1;
    }

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    Request req = {};
    req.type = OpType::RLE_READ_RGB565;
    req.coroRef = coroRef;
    strncpy(req.path, path, MAX_PATH - 1);
    req.offset = (size_t)offset;
    req.length = (size_t)len;

    // Copy palette from Lua table (8 RGB565 values, 1-indexed in Lua)
    for (int i = 0; i < 8; i++) {
        lua_rawgeti(L, 4, i + 1);
        req.palette[i] = (uint16_t)lua_tointeger(L, -1);
        lua_pop(L, 1);
    }

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_aes_encrypt(key, plaintext) - yields coroutine, resumes with ciphertext or nil
int AsyncIO::l_async_aes_encrypt(lua_State* L) {
    size_t keyLen, dataLen;
    const char* key = luaL_checklstring(L, 1, &keyLen);
    const char* data = luaL_checklstring(L, 2, &dataLen);

    if (keyLen != 16) {
        lua_pushnil(L);
        lua_pushstring(L, "Key must be 16 bytes");
        return 2;
    }

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    uint8_t* dataCopy = (uint8_t*)malloc(dataLen);
    if (!dataCopy) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "out of memory");
    }
    memcpy(dataCopy, data, dataLen);

    Request req = {};
    req.type = OpType::AES_ENCRYPT;
    req.coroRef = coroRef;
    req.data = dataCopy;
    req.dataLen = dataLen;
    memcpy(req.key, key, keyLen);
    req.keyLen = keyLen;

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        free(dataCopy);
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_aes_decrypt(key, ciphertext) - yields coroutine, resumes with plaintext or nil
int AsyncIO::l_async_aes_decrypt(lua_State* L) {
    size_t keyLen, dataLen;
    const char* key = luaL_checklstring(L, 1, &keyLen);
    const char* data = luaL_checklstring(L, 2, &dataLen);

    if (keyLen != 16) {
        lua_pushnil(L);
        lua_pushstring(L, "Key must be 16 bytes");
        return 2;
    }

    if (dataLen == 0 || dataLen % 16 != 0) {
        lua_pushnil(L);
        lua_pushstring(L, "Ciphertext must be multiple of 16 bytes");
        return 2;
    }

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    uint8_t* dataCopy = (uint8_t*)malloc(dataLen);
    if (!dataCopy) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "out of memory");
    }
    memcpy(dataCopy, data, dataLen);

    Request req = {};
    req.type = OpType::AES_DECRYPT;
    req.coroRef = coroRef;
    req.data = dataCopy;
    req.dataLen = dataLen;
    memcpy(req.key, key, keyLen);
    req.keyLen = keyLen;

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        free(dataCopy);
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

// async_hmac_sha256(key, data) - yields coroutine, resumes with 32-byte MAC or nil
int AsyncIO::l_async_hmac_sha256(lua_State* L) {
    size_t keyLen, dataLen;
    const char* key = luaL_checklstring(L, 1, &keyLen);
    const char* data = luaL_checklstring(L, 2, &dataLen);

    if (keyLen > MAX_KEY) {
        lua_pushnil(L);
        lua_pushstring(L, "Key too long");
        return 2;
    }

    lua_pushthread(L);
    int coroRef = luaL_ref(L, LUA_REGISTRYINDEX);

    uint8_t* dataCopy = (uint8_t*)malloc(dataLen);
    if (!dataCopy) {
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "out of memory");
    }
    memcpy(dataCopy, data, dataLen);

    Request req = {};
    req.type = OpType::HMAC_SHA256;
    req.coroRef = coroRef;
    req.data = dataCopy;
    req.dataLen = dataLen;
    memcpy(req.key, key, keyLen);
    req.keyLen = keyLen;

    if (xQueueSend(AsyncIO::instance()._requestQueue, &req, 0) != pdTRUE) {
        free(dataCopy);
        luaL_unref(L, LUA_REGISTRYINDEX, coroRef);
        return luaL_error(L, "async queue full");
    }

    return lua_yield(L, 0);
}

void AsyncIO::registerBindings(lua_State* L) {
    // File I/O
    lua_register(L, "async_read", l_async_read);
    lua_register(L, "async_read_bytes", l_async_read_bytes);
    lua_register(L, "async_write", l_async_write);
    lua_register(L, "async_write_bytes", l_async_write_bytes);
    lua_register(L, "async_append", l_async_append);
    lua_register(L, "async_exists", l_async_exists);

    // JSON
    lua_register(L, "async_json_read", l_async_json_read);
    lua_register(L, "async_json_write", l_async_json_write);

    // Data processing
    lua_register(L, "async_rle_read", l_async_rle_read);
    lua_register(L, "async_rle_read_rgb565", l_async_rle_read_rgb565);

    // Crypto
    lua_register(L, "async_aes_encrypt", l_async_aes_encrypt);
    lua_register(L, "async_aes_decrypt", l_async_aes_decrypt);
    lua_register(L, "async_hmac_sha256", l_async_hmac_sha256);

    Serial.println("[AsyncIO] Registered Lua bindings");
}
