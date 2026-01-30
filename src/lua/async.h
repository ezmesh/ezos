#pragma once

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/queue.h>
#include "lua.hpp"

// Async I/O and compute system for Lua
// Runs operations on Core 0 so Lua on Core 1 isn't blocked
class AsyncIO {
public:
    static AsyncIO& instance();

    // Initialize (call once at startup after Lua is ready)
    bool init(lua_State* L);

    // Process completions (call every frame from main loop)
    void update();

    // Register Lua bindings
    static void registerBindings(lua_State* L);

    // Lua functions - File I/O
    static int l_async_read(lua_State* L);
    static int l_async_read_bytes(lua_State* L);
    static int l_async_write(lua_State* L);
    static int l_async_write_bytes(lua_State* L);
    static int l_async_append(lua_State* L);
    static int l_async_exists(lua_State* L);

    // Lua functions - JSON
    static int l_async_json_read(lua_State* L);
    static int l_async_json_write(lua_State* L);

    // Lua functions - Data processing
    static int l_async_rle_read(lua_State* L);
    static int l_async_rle_read_rgb565(lua_State* L);

    // Lua functions - Crypto
    static int l_async_aes_encrypt(lua_State* L);
    static int l_async_aes_decrypt(lua_State* L);
    static int l_async_hmac_sha256(lua_State* L);

private:
    AsyncIO() = default;

    enum class OpType : uint8_t {
        // File I/O
        READ,
        READ_BYTES,
        WRITE,
        WRITE_BYTES,
        APPEND,
        EXISTS,
        // JSON
        JSON_READ,
        JSON_WRITE,
        // Data processing
        RLE_READ,
        RLE_READ_RGB565,
        // Crypto
        AES_ENCRYPT,
        AES_DECRYPT,
        HMAC_SHA256,
    };

    // Max sizes
    static constexpr size_t MAX_PATH = 128;
    static constexpr size_t MAX_KEY = 32;
    static constexpr size_t MAX_JSON_DOC = 16384;

    struct Request {
        OpType type;
        int coroRef;
        char path[MAX_PATH];
        uint8_t* data;          // Input data (for write/crypto operations)
        size_t dataLen;
        size_t offset;          // File offset for READ_BYTES/WRITE_BYTES
        size_t length;          // Length for READ_BYTES/RLE_READ
        uint8_t key[MAX_KEY];   // Key for crypto operations
        size_t keyLen;
        uint16_t palette[8];    // RGB565 palette for RLE_READ_RGB565
    };

    struct Result {
        OpType type;
        int coroRef;
        uint8_t* data;          // Output data
        size_t len;
        bool success;
        char* jsonString;       // For JSON_READ result (parsed to Lua later)
    };

    lua_State* _mainState = nullptr;
    QueueHandle_t _requestQueue = nullptr;
    QueueHandle_t _resultQueue = nullptr;
    TaskHandle_t _workerTask = nullptr;

    static void workerTask(void* param);
    void processResults();

    // Helper functions for worker task
    static uint8_t* rleDecompress(const uint8_t* data, size_t len, size_t* outLen);
    static uint16_t* rleDecompressToRgb565(const uint8_t* data, size_t len,
                                            const uint16_t* palette, size_t* outLen);
    static uint8_t* aesEncrypt(const uint8_t* key, size_t keyLen,
                               const uint8_t* data, size_t dataLen, size_t* outLen);
    static uint8_t* aesDecrypt(const uint8_t* key, size_t keyLen,
                               const uint8_t* data, size_t dataLen, size_t* outLen);
    static uint8_t* hmacSha256(const uint8_t* key, size_t keyLen,
                               const uint8_t* data, size_t dataLen);
};
