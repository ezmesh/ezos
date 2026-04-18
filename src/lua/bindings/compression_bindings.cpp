// ez.compression module bindings
// Zlib / raw-deflate decompression backed by the ESP32 ROM's miniz (tinfl).
// Used primarily by services.map_archive to decode tile bytes, but kept as a
// general-purpose module so any Lua code can unpack compressed blobs.

#include "../lua_bindings.h"
#include <Arduino.h>

// ROM miniz header. MINIZ_NO_ZLIB_APIS is set in the ROM build, so only the
// low-level tinfl_* API is available — which is exactly what we need.
#include "rom/miniz.h"

// Pulled from the ROM header, redeclared here so this file compiles even
// when the ROM header's flag macros are name-mangled by the toolchain.
#ifndef TINFL_FLAG_PARSE_ZLIB_HEADER
#define TINFL_FLAG_PARSE_ZLIB_HEADER 1
#endif

// ez.compression.inflate(data, out_size [, raw]) -> string | nil, error
// @brief Decompress zlib- or raw-deflate-encoded bytes.
// @description
//   Out-size must be the exact uncompressed length (no growth allowed). For
//   map tiles this is always 24576 bytes (256*256*3/8). The third argument
//   defaults to false, meaning the input carries a zlib wrapper (RFC 1950);
//   pass true for raw DEFLATE streams (RFC 1951).
//   On failure returns nil plus an error string.
// @param data Binary string: compressed input.
// @param out_size Expected decompressed size in bytes.
// @param raw Optional boolean; true = raw deflate, false/nil = zlib.
// @return Decompressed binary string, or nil plus an error string.
// @example
//   local raw = ez.compression.inflate(compressed, 24576)
//   if not raw then error("decompress failed: " .. tostring(err)) end
// @end
LUA_FUNCTION(l_compression_inflate) {
    int argc = lua_gettop(L);
    if (argc < 2) {
        return luaL_error(L, "inflate(data, out_size [, raw]) requires at least 2 arguments");
    }

    size_t inLen = 0;
    const char* inData = luaL_checklstring(L, 1, &inLen);
    lua_Integer outSize = luaL_checkinteger(L, 2);
    bool raw = (argc >= 3) && lua_toboolean(L, 3);

    if (outSize <= 0 || outSize > 1024 * 1024) {
        lua_pushnil(L);
        lua_pushfstring(L, "invalid out_size %d", (int)outSize);
        return 2;
    }

    // Prefer PSRAM for the output buffer — tile payloads are large (24 KB)
    // and called many times per frame, so we don't want them on the small
    // DRAM heap. Fall back to regular malloc on non-PSRAM parts.
    uint8_t* outBuf = (uint8_t*)heap_caps_malloc(outSize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (outBuf == nullptr) {
        outBuf = (uint8_t*)malloc(outSize);
    }
    if (outBuf == nullptr) {
        lua_pushnil(L);
        lua_pushstring(L, "out-of-memory");
        return 2;
    }

    int flags = raw ? 0 : TINFL_FLAG_PARSE_ZLIB_HEADER;
    size_t decoded = tinfl_decompress_mem_to_mem(
        outBuf, (size_t)outSize,
        inData, inLen,
        flags);

    if (decoded == TINFL_DECOMPRESS_MEM_TO_MEM_FAILED) {
        free(outBuf);
        lua_pushnil(L);
        lua_pushstring(L, "inflate failed");
        return 2;
    }

    lua_pushlstring(L, (const char*)outBuf, decoded);
    free(outBuf);
    return 1;
}

static const luaL_Reg compression_funcs[] = {
    {"inflate", l_compression_inflate},
    {nullptr,   nullptr},
};

void registerCompressionModule(lua_State* L) {
    lua_register_module(L, "compression", compression_funcs);
    Serial.println("[LuaRuntime] Registered ez.compression");
}
