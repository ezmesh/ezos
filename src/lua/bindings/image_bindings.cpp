// ez.image bindings + sprite:encode_jpeg / encode_png method
// extensions.
//
// LovyanGFX bundles TJpgDec for JPEG *decoding* and lvgl_png for PNG
// decoding, but neither has an encoder. This file wires up
// bitbank2/JPEGENC + bitbank2/PNGenc so a sprite's pixel buffer can
// be turned into JPEG / PNG bytes -- needed by paint to save a
// canvas, by the wallpaper picker to accept user PNGs, and by any
// future export path (file manager, screenshot, etc.).
//
// Both libraries take an output buffer pre-allocated in caller
// memory and write directly into it. We size the buffer
// pessimistically (width * height * 4) so even a worst-case PNG
// fits, allocate from PSRAM (sprite buffers do too), and trim the
// returned Lua string to the encoder's reported size.

#include "image_bindings.h"
#include "../lua_bindings.h"
#include "../../hardware/display.h"

#include <Arduino.h>
#include <esp_heap_caps.h>
#include <string.h>

#include <JPEGENC.h>
#include <PNGenc.h>

#include <new>  // placement new for PSRAM-backed encoder objects.

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

// Allocate `size` bytes preferring PSRAM, falling back to internal
// heap. Both encoders carry tens of KiB of working state that's far
// too large for the loopTask stack (10 KiB), so they're constructed
// in PSRAM via placement new.
static void* allocPsram(size_t size) {
    void* p = heap_caps_malloc(size, MALLOC_CAP_SPIRAM);
    if (!p) p = malloc(size);
    return p;
}

#define SPRITE_METATABLE "ez.Sprite"

// Identical helper to display_bindings.cpp -- not exported there, so
// we duplicate the one-liner rather than refactor a header that's
// already settled.
static Sprite* checkSprite(lua_State* L, int idx) {
    Sprite** pp = (Sprite**)luaL_checkudata(L, idx, SPRITE_METATABLE);
    if (!pp || !*pp) {
        luaL_error(L, "invalid Sprite");
        return nullptr;
    }
    return *pp;
}

// ---------------------------------------------------------------------------
// JPEG encode
// ---------------------------------------------------------------------------
//
// JPEGENC consumes RGB565 in **little-endian** (host) byte order, but
// LovyanGFX stores the sprite buffer **big-endian** ("byte-swapped")
// so DMA can ship it straight to the panel without per-pixel work.
// We therefore allocate a temporary swapped copy and feed that to
// the encoder. The copy is in PSRAM since it can be up to 614 KiB
// for the largest 640x480 canvas.

// @module ez.image
// @brief Image encode + decode helpers (JPEG, PNG)

// @lua sprite:encode_jpeg([quality]) -> string | nil, error_msg
// @brief Encode the sprite as a JPEG byte string
// @description Returns the JPEG bytes ready to write to a file or
// push over the bus. `quality` is one of 0..3 mapping to BEST,
// HIGH, MED, LOW (default HIGH = 1). Subsampling is 4:2:0 for
// quality MED/LOW (smaller files) and 4:4:4 for HIGH/BEST (better
// colour reproduction at the cost of size). Errors return nil + a
// short reason string.
// @example
// local jpeg = sprite:encode_jpeg(1)
// ez.storage.write_file("/sd/snap.jpg", jpeg)
LUA_FUNCTION(l_sprite_encode_jpeg) {
    Sprite* sprite = checkSprite(L, 1);
    if (!sprite) return 0;
    int quality = luaL_optinteger(L, 2, JPEGE_Q_HIGH);
    if (quality < JPEGE_Q_BEST || quality > JPEGE_Q_LOW) {
        quality = JPEGE_Q_HIGH;
    }
    // 4:2:0 chroma subsampling halves both axes -> ~half the
    // bandwidth of 4:4:4. Pick it automatically for the lower-
    // quality settings where the visible difference is small.
    uint8_t subsample = (quality >= JPEGE_Q_MED)
        ? JPEGE_SUBSAMPLE_420 : JPEGE_SUBSAMPLE_444;

    int w = sprite->width();
    int h = sprite->height();
    if (w <= 0 || h <= 0) {
        lua_pushnil(L);
        lua_pushstring(L, "sprite has no pixels");
        return 2;
    }

    const uint8_t* lgfxBuf = sprite->rawBuffer();
    if (!lgfxBuf) {
        lua_pushnil(L);
        lua_pushstring(L, "sprite buffer not available");
        return 2;
    }

    // Byte-swap the RGB565 buffer into a fresh PSRAM copy so the
    // encoder sees host-order pixels. We can't swap in place
    // because the live sprite is shipping bytes to the panel.
    size_t pxBytes = (size_t)w * h * 2;
    uint16_t* swapped = (uint16_t*)heap_caps_malloc(pxBytes, MALLOC_CAP_SPIRAM);
    if (!swapped) swapped = (uint16_t*)malloc(pxBytes);
    if (!swapped) {
        lua_pushnil(L);
        lua_pushstring(L, "psram alloc failed (swap buffer)");
        return 2;
    }
    const uint16_t* src = (const uint16_t*)lgfxBuf;
    int npx = w * h;
    for (int i = 0; i < npx; ++i) {
        uint16_t v = src[i];
        swapped[i] = (uint16_t)((v >> 8) | (v << 8));
    }

    // Output buffer. JPEG is almost always smaller than the raw
    // pixel data; w*h*2 is a safe ceiling that handles even the
    // worst-case high-quality + 444 subsample output.
    int outCap = w * h * 2 + 4096;
    uint8_t* outBuf = (uint8_t*)heap_caps_malloc(outCap, MALLOC_CAP_SPIRAM);
    if (!outBuf) outBuf = (uint8_t*)malloc(outCap);
    if (!outBuf) {
        free(swapped);
        lua_pushnil(L);
        lua_pushstring(L, "psram alloc failed (output buffer)");
        return 2;
    }

    // Heap-allocate the encoder. Even though JPEGENC's working set
    // (~3 KiB) fits on the stack, we keep both paths consistent and
    // free the loopTask stack to handle deeper Lua call chains
    // upstream of encode_jpeg.
    void* jpeMem = allocPsram(sizeof(JPEGENC));
    if (!jpeMem) {
        free(swapped);
        free(outBuf);
        lua_pushnil(L);
        lua_pushstring(L, "psram alloc failed (encoder)");
        return 2;
    }
    JPEGENC* jpe = new (jpeMem) JPEGENC();

    JPEGENCODE jpeenc;
    int rc = jpe->open(outBuf, outCap);
    if (rc == JPEGE_SUCCESS) {
        rc = jpe->encodeBegin(&jpeenc, w, h,
            JPEGE_PIXEL_RGB565, subsample, (uint8_t)quality);
    }
    if (rc == JPEGE_SUCCESS) {
        rc = jpe->addFrame(&jpeenc, (uint8_t*)swapped, w * 2);
    }
    int finalSize = jpe->close();
    jpe->~JPEGENC();
    free(jpeMem);

    free(swapped);
    if (rc != JPEGE_SUCCESS || finalSize <= 0) {
        free(outBuf);
        lua_pushnil(L);
        lua_pushfstring(L, "encode failed (rc=%d, size=%d)", rc, finalSize);
        return 2;
    }

    lua_pushlstring(L, (const char*)outBuf, finalSize);
    free(outBuf);
    return 1;
}

// ---------------------------------------------------------------------------
// PNG encode
// ---------------------------------------------------------------------------
//
// PNGenc has a built-in addRGB565Line(pixels, tempLine, bBigEndian)
// which handles the LGFX byte-swapped layout for us when bBigEndian
// is true. It needs a temp scratch line of width * 3 bytes (RGB888
// expansion) -- we allocate one once and reuse for every row.

// @lua sprite:encode_png([compression]) -> string | nil, error_msg
// @brief Encode the sprite as a PNG byte string
// @description Lossless. `compression` is 0..9 (default 6). Higher
// values are smaller but slower (level 9 on a 640x480 sprite is
// roughly 2-3x the time of level 1). The resulting bytes are a
// standard PNG file and can be opened by any image viewer.
// @example
// local png = sprite:encode_png(6)
// ez.storage.write_file("/sd/snap.png", png)
LUA_FUNCTION(l_sprite_encode_png) {
    Sprite* sprite = checkSprite(L, 1);
    if (!sprite) return 0;
    int compression = luaL_optinteger(L, 2, 6);
    if (compression < 0) compression = 0;
    if (compression > 9) compression = 9;

    int w = sprite->width();
    int h = sprite->height();
    if (w <= 0 || h <= 0) {
        lua_pushnil(L);
        lua_pushstring(L, "sprite has no pixels");
        return 2;
    }
    const uint8_t* lgfxBuf = sprite->rawBuffer();
    if (!lgfxBuf) {
        lua_pushnil(L);
        lua_pushstring(L, "sprite buffer not available");
        return 2;
    }

    // Output buffer. Worst case for an uncompressible PNG is a few
    // bytes per pixel of expansion above raw RGB888; 4 bpp is a
    // generous ceiling that always fits.
    size_t outCap = (size_t)w * h * 4 + 8192;
    uint8_t* outBuf = (uint8_t*)heap_caps_malloc(outCap, MALLOC_CAP_SPIRAM);
    if (!outBuf) outBuf = (uint8_t*)malloc(outCap);
    if (!outBuf) {
        lua_pushnil(L);
        lua_pushstring(L, "psram alloc failed (output buffer)");
        return 2;
    }

    // Per-line scratch for the RGB565->RGB888 expansion. PNGenc
    // writes into this buffer before deflate, so it has to live for
    // the duration of the encode -- one alloc, reused per row.
    uint8_t* tempLine = (uint8_t*)heap_caps_malloc(w * 3, MALLOC_CAP_SPIRAM);
    if (!tempLine) tempLine = (uint8_t*)malloc(w * 3);
    if (!tempLine) {
        free(outBuf);
        lua_pushnil(L);
        lua_pushstring(L, "psram alloc failed (line buffer)");
        return 2;
    }

    // PNGENC has a ~44 KiB internal struct (deflate working set,
    // line buffers, file buffer). Putting that on the loopTask's
    // 10 KiB stack overflows immediately and crashes the device on
    // the first call -- always heap-construct it in PSRAM.
    void* pngMem = allocPsram(sizeof(PNGENC));
    if (!pngMem) {
        free(tempLine);
        free(outBuf);
        lua_pushnil(L);
        lua_pushstring(L, "psram alloc failed (encoder)");
        return 2;
    }
    PNGENC* png = new (pngMem) PNGENC();

    int rc = png->open(outBuf, outCap);
    if (rc == PNG_SUCCESS) {
        rc = png->encodeBegin(w, h, PNG_PIXEL_TRUECOLOR, 8, NULL,
                              (uint8_t)compression);
    }
    if (rc == PNG_SUCCESS) {
        // bBigEndian = true matches LovyanGFX's byte-swapped buffer
        // layout, so we don't need to copy + swap like the JPEG
        // path does.
        const uint16_t* src = (const uint16_t*)lgfxBuf;
        for (int y = 0; y < h && rc == PNG_SUCCESS; ++y) {
            rc = png->addRGB565Line(
                (uint16_t*)(src + y * w), tempLine, true);
        }
    }
    int finalSize = png->close();
    png->~PNGENC();
    free(pngMem);

    free(tempLine);
    if (rc != PNG_SUCCESS || finalSize <= 0) {
        free(outBuf);
        lua_pushnil(L);
        lua_pushfstring(L, "encode failed (rc=%d, size=%d)", rc, finalSize);
        return 2;
    }

    lua_pushlstring(L, (const char*)outBuf, finalSize);
    free(outBuf);
    return 1;
}

// ---------------------------------------------------------------------------
// Header peek helpers
// ---------------------------------------------------------------------------
//
// Both formats encode dimensions in their first few hundred bytes so
// callers can size a sprite before decoding. The peek functions skip
// the full decode (which would also alloc + write a sprite) and
// just return (w, h).

// @lua ez.image.jpeg_size(bytes) -> w, h | nil
// @brief Read the dimensions from a JPEG header without decoding
// @description Walks the JPEG marker stream looking for the SOF0
// (0xFFC0) or SOF2 (0xFFC2) marker; the next two big-endian u16s
// after the marker length are height + width respectively. Returns
// nil if the input isn't a valid JPEG or no SOF marker is found.
LUA_FUNCTION(l_image_jpeg_size) {
    size_t len;
    const uint8_t* data = (const uint8_t*)luaL_checklstring(L, 1, &len);
    if (len < 4 || data[0] != 0xFF || data[1] != 0xD8) {
        lua_pushnil(L);
        return 1;
    }
    size_t i = 2;
    while (i + 9 < len) {
        if (data[i] != 0xFF) break;
        // Skip 0xFF padding bytes and SOI/EOI markers.
        while (i < len && data[i] == 0xFF) i++;
        if (i >= len) break;
        uint8_t marker = data[i++];
        // Standalone markers (no length): 0xD0..0xD7, 0x01.
        if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
        if (i + 1 >= len) break;
        uint16_t segLen = ((uint16_t)data[i] << 8) | data[i + 1];
        if (segLen < 2 || i + segLen > len) break;
        // SOF0 (baseline) = 0xC0; SOF2 (progressive) = 0xC2; both
        // store [precision:1][height:2][width:2] right after the
        // length field.
        if (marker == 0xC0 || marker == 0xC2) {
            if (i + 6 > len) break;
            uint16_t height = ((uint16_t)data[i + 3] << 8) | data[i + 4];
            uint16_t width  = ((uint16_t)data[i + 5] << 8) | data[i + 6];
            lua_pushinteger(L, width);
            lua_pushinteger(L, height);
            return 2;
        }
        i += segLen;
    }
    lua_pushnil(L);
    return 1;
}

// @lua ez.image.png_size(bytes) -> w, h | nil
// @brief Read the dimensions from a PNG IHDR chunk
// @description PNGs always start with the 8-byte signature followed
// by an IHDR chunk; bytes [16..19] are width and [20..23] are
// height, both big-endian uint32. Returns nil if the input doesn't
// match the PNG signature.
LUA_FUNCTION(l_image_png_size) {
    size_t len;
    const uint8_t* data = (const uint8_t*)luaL_checklstring(L, 1, &len);
    static const uint8_t SIG[8] =
        { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (len < 24 || memcmp(data, SIG, 8) != 0) {
        lua_pushnil(L);
        return 1;
    }
    uint32_t width  = ((uint32_t)data[16] << 24) | ((uint32_t)data[17] << 16)
                    | ((uint32_t)data[18] << 8)  | (uint32_t)data[19];
    uint32_t height = ((uint32_t)data[20] << 24) | ((uint32_t)data[21] << 16)
                    | ((uint32_t)data[22] << 8)  | (uint32_t)data[23];
    lua_pushinteger(L, (lua_Integer)width);
    lua_pushinteger(L, (lua_Integer)height);
    return 2;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

namespace image_bindings {

void registerBindings(lua_State* L) {
    // Add encode_jpeg / encode_png to the existing Sprite metatable.
    // The display bindings register the metatable + base methods at
    // boot before us; we just append.
    luaL_getmetatable(L, SPRITE_METATABLE);
    if (!lua_isnil(L, -1)) {
        // The metatable has an __index that points back at itself
        // (typical "class table" pattern), so adding methods to the
        // metatable directly makes them callable as sprite:method().
        lua_pushcfunction(L, l_sprite_encode_jpeg);
        lua_setfield(L, -2, "encode_jpeg");
        lua_pushcfunction(L, l_sprite_encode_png);
        lua_setfield(L, -2, "encode_png");
    }
    lua_pop(L, 1);

    // ez.image module table for the format-detection helpers.
    static const luaL_Reg image_funcs[] = {
        { "jpeg_size", l_image_jpeg_size },
        { "png_size",  l_image_png_size  },
        { nullptr, nullptr }
    };
    lua_register_module(L, "image", image_funcs);
    Serial.println("[LuaRuntime] Registered ez.image");
}

}  // namespace image_bindings
