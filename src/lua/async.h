#pragma once

#include <functional>

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

    // Install the callback that does X25519 ECDH. Called on the worker
    // thread, so the handler must be thread-safe with respect to its
    // captures (the typical implementation reads an immutable private
    // key out of the mesh identity, which is set once at boot).
    // Signature: bool(const uint8_t peer_pubkey[32], uint8_t out_secret[32])
    using X25519Handler = std::function<bool(const uint8_t*, uint8_t*)>;
    static void setX25519Handler(X25519Handler handler);

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
    static int l_async_x25519_shared_secret(lua_State* L);

    // Cross-module entry point: queue an HTTP request to be processed
    // on the worker thread. The opaque pointer is forwarded verbatim to
    // the registered HTTP processor (see setHttpProcessor). The caller
    // (http_bindings) retains ownership; the processor is responsible
    // for freeing the request after it produces a response.
    // Returns false if the queue was full -- caller must clean up.
    bool queueHttpRequest(void* requestPtr, int coroRef);

    // Install the function that the worker calls to process an
    // HTTP_FETCH op. http_bindings registers this at boot. Signature:
    //   void(*)(void* requestPtr, int coroRef)
    // The processor runs on the worker thread (Core 0); it must not
    // touch the Lua state directly. It typically deposits a response
    // struct on http_bindings' own response queue, which is drained by
    // http_bindings::update() on the Lua thread.
    using HttpProcessor = void (*)(void* requestPtr, int coroRef);
    static void setHttpProcessor(HttpProcessor fn);

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
        X25519_SHARED_SECRET,
        // HTTP -- the request struct is opaque to AsyncIO. http_bindings
        // hands us a pointer (req.data) to a heap-allocated HttpRequest
        // and provides the actual processing routine. We reuse this
        // worker thread rather than spawning a second one because
        // internal DRAM is too tight to afford a separate task stack.
        HTTP_FETCH,
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
