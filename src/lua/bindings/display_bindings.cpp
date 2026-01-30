// tdeck.display module bindings
// Provides display drawing functions and properties

#include "../lua_bindings.h"
#include "../../hardware/display.h"

// External reference to the global display instance
extern Display* display;

// @lua tdeck.display.clear()
// @brief Clear display buffer to black
LUA_FUNCTION(l_display_clear) {
    if (display) {
        display->clear();
    }
    return 0;
}

// @lua tdeck.display.flush()
// @brief Flush buffer to physical display
LUA_FUNCTION(l_display_flush) {
    if (display) {
        display->flush();
    }
    return 0;
}

// @lua tdeck.display.set_brightness(level)
// @brief Set backlight brightness
// @param level Brightness level (0-255)
LUA_FUNCTION(l_display_set_brightness) {
    LUA_CHECK_ARGC(L, 1);
    int level = luaL_checkinteger(L, 1);
    level = constrain(level, 0, 255);
    if (display) {
        display->setBrightness(level);
    }
    return 0;
}

// @lua tdeck.display.set_font_size(size)
// @brief Set font size
// @param size Font size string: "tiny", "small", "medium", or "large"
LUA_FUNCTION(l_display_set_font_size) {
    LUA_CHECK_ARGC(L, 1);
    const char* sizeStr = luaL_checkstring(L, 1);

    FontSize size = FontSize::MEDIUM;
    if (strcmp(sizeStr, "tiny") == 0) {
        size = FontSize::TINY;
    } else if (strcmp(sizeStr, "small") == 0) {
        size = FontSize::SMALL;
    } else if (strcmp(sizeStr, "large") == 0) {
        size = FontSize::LARGE;
    }

    if (display) {
        display->setFontSize(size);
    }
    return 0;
}

// @lua tdeck.display.draw_text(x, y, text, color)
// @brief Draw text at pixel coordinates
// @param x X position in pixels
// @param y Y position in pixels
// @param text Text string to draw
// @param color Text color (optional, defaults to TEXT)
LUA_FUNCTION(l_display_draw_text) {
    LUA_CHECK_ARGC_RANGE(L, 3, 4);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    const char* text = luaL_checkstring(L, 3);
    uint16_t color = luaL_optintegerdefault(L, 4, Colors::TEXT);

    if (display) {
        display->drawText(x, y, text, color);
    }
    return 0;
}

// @lua tdeck.display.draw_text_centered(y, text, color)
// @brief Draw horizontally centered text
// @param y Y position in pixels
// @param text Text string to draw
// @param color Text color (optional, defaults to TEXT)
LUA_FUNCTION(l_display_draw_text_centered) {
    LUA_CHECK_ARGC_RANGE(L, 2, 3);
    int y = luaL_checkinteger(L, 1);
    const char* text = luaL_checkstring(L, 2);
    uint16_t color = luaL_optintegerdefault(L, 3, Colors::TEXT);

    if (display) {
        display->drawTextCentered(y, text, color);
    }
    return 0;
}

// @lua tdeck.display.draw_char(x, y, char, color)
// @brief Draw a single character
// @param x X position in pixels
// @param y Y position in pixels
// @param char Character to draw (first char of string)
// @param color Character color (optional)
LUA_FUNCTION(l_display_draw_char) {
    LUA_CHECK_ARGC_RANGE(L, 3, 4);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    const char* str = luaL_checkstring(L, 3);
    uint16_t color = luaL_optintegerdefault(L, 4, Colors::TEXT);

    if (display && str[0] != '\0') {
        display->drawChar(x, y, str[0], color);
    }
    return 0;
}

// @lua tdeck.display.draw_box(x, y, w, h, title, border_color, title_color)
// @brief Draw bordered box with optional title
// @param x X position in character cells
// @param y Y position in character cells
// @param w Width in character cells
// @param h Height in character cells
// @param title Optional title string
// @param border_color Border color (optional)
// @param title_color Title color (optional)
LUA_FUNCTION(l_display_draw_box) {
    LUA_CHECK_ARGC_RANGE(L, 4, 7);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    int h = luaL_checkinteger(L, 4);
    const char* title = lua_isstring(L, 5) ? lua_tostring(L, 5) : nullptr;
    uint16_t borderColor = luaL_optintegerdefault(L, 6, Colors::BORDER);
    uint16_t titleColor = luaL_optintegerdefault(L, 7, Colors::HIGHLIGHT);

    if (display) {
        display->drawBox(x, y, w, h, title, borderColor, titleColor);
    }
    return 0;
}

// @lua tdeck.display.draw_hline(x, y, w, left_connect, right_connect, color)
// @brief Draw horizontal line with optional connectors
// @param x X position in character cells
// @param y Y position in character cells
// @param w Width in character cells
// @param left_connect Connect to left border (optional)
// @param right_connect Connect to right border (optional)
// @param color Line color (optional)
LUA_FUNCTION(l_display_draw_hline) {
    LUA_CHECK_ARGC_RANGE(L, 3, 6);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    bool leftConnect = lua_toboolean(L, 4);
    bool rightConnect = lua_toboolean(L, 5);
    uint16_t color = luaL_optintegerdefault(L, 6, Colors::BORDER);

    if (display) {
        display->drawHLine(x, y, w, leftConnect, rightConnect, color);
    }
    return 0;
}

// @lua tdeck.display.fill_rect(x, y, w, h, color)
// @brief Fill a rectangle with color
// @param x X position in pixels
// @param y Y position in pixels
// @param w Width in pixels
// @param h Height in pixels
// @param color Fill color (optional)
LUA_FUNCTION(l_display_fill_rect) {
    LUA_CHECK_ARGC_RANGE(L, 4, 5);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    int h = luaL_checkinteger(L, 4);
    uint16_t color = luaL_optintegerdefault(L, 5, Colors::FOREGROUND);

    if (display) {
        display->fillRect(x, y, w, h, color);
    }
    return 0;
}

// @lua tdeck.display.draw_rect(x, y, w, h, color)
// @brief Draw rectangle outline
// @param x X position in pixels
// @param y Y position in pixels
// @param w Width in pixels
// @param h Height in pixels
// @param color Outline color (optional)
LUA_FUNCTION(l_display_draw_rect) {
    LUA_CHECK_ARGC_RANGE(L, 4, 5);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    int h = luaL_checkinteger(L, 4);
    uint16_t color = luaL_optintegerdefault(L, 5, Colors::FOREGROUND);

    if (display) {
        display->drawRect(x, y, w, h, color);
    }
    return 0;
}

// @lua tdeck.display.draw_pixel(x, y, color)
// @brief Draw a single pixel
// @param x X position in pixels
// @param y Y position in pixels
// @param color Pixel color (optional)
LUA_FUNCTION(l_display_draw_pixel) {
    LUA_CHECK_ARGC_RANGE(L, 2, 3);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    uint16_t color = luaL_optintegerdefault(L, 3, Colors::FOREGROUND);

    if (display) {
        display->drawPixel(x, y, color);
    }
    return 0;
}

// @lua tdeck.display.draw_line(x1, y1, x2, y2, color)
// @brief Draw a line between two points
// @param x1 Start X position
// @param y1 Start Y position
// @param x2 End X position
// @param y2 End Y position
// @param color Line color (optional)
LUA_FUNCTION(l_display_draw_line) {
    LUA_CHECK_ARGC_RANGE(L, 4, 5);
    int x1 = luaL_checkinteger(L, 1);
    int y1 = luaL_checkinteger(L, 2);
    int x2 = luaL_checkinteger(L, 3);
    int y2 = luaL_checkinteger(L, 4);
    uint16_t color = luaL_optintegerdefault(L, 5, Colors::FOREGROUND);

    if (display) {
        display->drawLine(x1, y1, x2, y2, color);
    }
    return 0;
}

// @lua tdeck.display.draw_circle(x, y, r, color)
// @brief Draw circle outline
// @param x Center X position
// @param y Center Y position
// @param r Radius
// @param color Circle color (optional)
LUA_FUNCTION(l_display_draw_circle) {
    LUA_CHECK_ARGC_RANGE(L, 3, 4);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int r = luaL_checkinteger(L, 3);
    uint16_t color = luaL_optintegerdefault(L, 4, Colors::FOREGROUND);

    if (display) {
        display->drawCircle(x, y, r, color);
    }
    return 0;
}

// @lua tdeck.display.fill_circle(x, y, r, color)
// @brief Draw filled circle
// @param x Center X position
// @param y Center Y position
// @param r Radius
// @param color Fill color (optional)
LUA_FUNCTION(l_display_fill_circle) {
    LUA_CHECK_ARGC_RANGE(L, 3, 4);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int r = luaL_checkinteger(L, 3);
    uint16_t color = luaL_optintegerdefault(L, 4, Colors::FOREGROUND);

    if (display) {
        display->fillCircle(x, y, r, color);
    }
    return 0;
}

// @lua tdeck.display.draw_triangle(x1, y1, x2, y2, x3, y3, color)
// @brief Draw triangle outline
LUA_FUNCTION(l_display_draw_triangle) {
    LUA_CHECK_ARGC_RANGE(L, 6, 7);
    int x1 = luaL_checkinteger(L, 1);
    int y1 = luaL_checkinteger(L, 2);
    int x2 = luaL_checkinteger(L, 3);
    int y2 = luaL_checkinteger(L, 4);
    int x3 = luaL_checkinteger(L, 5);
    int y3 = luaL_checkinteger(L, 6);
    uint16_t color = luaL_optintegerdefault(L, 7, Colors::FOREGROUND);

    if (display) {
        display->drawTriangle(x1, y1, x2, y2, x3, y3, color);
    }
    return 0;
}

// @lua tdeck.display.fill_triangle(x1, y1, x2, y2, x3, y3, color)
// @brief Draw filled triangle
LUA_FUNCTION(l_display_fill_triangle) {
    LUA_CHECK_ARGC_RANGE(L, 6, 7);
    int x1 = luaL_checkinteger(L, 1);
    int y1 = luaL_checkinteger(L, 2);
    int x2 = luaL_checkinteger(L, 3);
    int y2 = luaL_checkinteger(L, 4);
    int x3 = luaL_checkinteger(L, 5);
    int y3 = luaL_checkinteger(L, 6);
    uint16_t color = luaL_optintegerdefault(L, 7, Colors::FOREGROUND);

    if (display) {
        display->fillTriangle(x1, y1, x2, y2, x3, y3, color);
    }
    return 0;
}

// @lua tdeck.display.draw_round_rect(x, y, w, h, r, color)
// @brief Draw rounded rectangle outline
LUA_FUNCTION(l_display_draw_round_rect) {
    LUA_CHECK_ARGC_RANGE(L, 5, 6);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    int h = luaL_checkinteger(L, 4);
    int r = luaL_checkinteger(L, 5);
    uint16_t color = luaL_optintegerdefault(L, 6, Colors::FOREGROUND);

    if (display) {
        display->drawRoundRect(x, y, w, h, r, color);
    }
    return 0;
}

// @lua tdeck.display.fill_round_rect(x, y, w, h, r, color)
// @brief Draw filled rounded rectangle
LUA_FUNCTION(l_display_fill_round_rect) {
    LUA_CHECK_ARGC_RANGE(L, 5, 6);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    int h = luaL_checkinteger(L, 4);
    int r = luaL_checkinteger(L, 5);
    uint16_t color = luaL_optintegerdefault(L, 6, Colors::FOREGROUND);

    if (display) {
        display->fillRoundRect(x, y, w, h, r, color);
    }
    return 0;
}

// @lua tdeck.display.draw_progress(x, y, w, h, progress, fg_color, bg_color)
// @brief Draw a progress bar
// @param x X position in pixels
// @param y Y position in pixels
// @param w Width in pixels
// @param h Height in pixels
// @param progress Progress value (0.0 to 1.0)
// @param fg_color Foreground color (optional)
// @param bg_color Background color (optional)
LUA_FUNCTION(l_display_draw_progress) {
    LUA_CHECK_ARGC_RANGE(L, 5, 7);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    int h = luaL_checkinteger(L, 4);
    float progress = luaL_checknumber(L, 5);
    uint16_t fgColor = luaL_optintegerdefault(L, 6, Colors::GREEN);
    uint16_t bgColor = luaL_optintegerdefault(L, 7, Colors::DARK_GRAY);

    progress = constrain(progress, 0.0f, 1.0f);

    if (display) {
        display->drawProgressBar(x, y, w, h, progress, fgColor, bgColor);
    }
    return 0;
}

// @lua tdeck.display.draw_battery(x, y, percent)
// @brief Draw battery indicator icon
// @param x X position in pixels
// @param y Y position in pixels
// @param percent Battery percentage (0-100)
LUA_FUNCTION(l_display_draw_battery) {
    LUA_CHECK_ARGC(L, 3);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int percent = luaL_checkinteger(L, 3);
    percent = constrain(percent, 0, 100);

    if (display) {
        display->drawBattery(x, y, percent);
    }
    return 0;
}

// @lua tdeck.display.draw_signal(x, y, bars)
// @brief Draw signal strength indicator
// @param x X position in pixels
// @param y Y position in pixels
// @param bars Signal strength (0-4 bars)
LUA_FUNCTION(l_display_draw_signal) {
    LUA_CHECK_ARGC(L, 3);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int bars = luaL_checkinteger(L, 3);
    bars = constrain(bars, 0, 4);

    if (display) {
        display->drawSignal(x, y, bars);
    }
    return 0;
}

// @lua tdeck.display.text_width(text) -> integer
// @brief Get pixel width of text string
// @param text Text string to measure
// @return Width in pixels
LUA_FUNCTION(l_display_text_width) {
    LUA_CHECK_ARGC(L, 1);
    const char* text = luaL_checkstring(L, 1);

    int width = 0;
    if (display) {
        width = display->textWidth(text);
    }
    lua_pushinteger(L, width);
    return 1;
}

// @lua tdeck.display.rgb(r, g, b) -> integer
// @brief Convert RGB to RGB565 color value
// @param r Red component (0-255)
// @param g Green component (0-255)
// @param b Blue component (0-255)
// @return RGB565 color value
LUA_FUNCTION(l_display_rgb) {
    LUA_CHECK_ARGC(L, 3);
    int r = luaL_checkinteger(L, 1);
    int g = luaL_checkinteger(L, 2);
    int b = luaL_checkinteger(L, 3);

    r = constrain(r, 0, 255);
    g = constrain(g, 0, 255);
    b = constrain(b, 0, 255);

    // Convert to RGB565: RRRRRGGGGGGBBBBB
    uint16_t color = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
    lua_pushinteger(L, color);
    return 1;
}

// @lua tdeck.display.get_width() -> integer
// @brief Get display width
// @return Width in pixels
LUA_FUNCTION(l_display_get_width) {
    lua_pushinteger(L, display ? display->getWidth() : 320);
    return 1;
}

// @lua tdeck.display.get_height() -> integer
// @brief Get display height
// @return Height in pixels
LUA_FUNCTION(l_display_get_height) {
    lua_pushinteger(L, display ? display->getHeight() : 240);
    return 1;
}

// @lua tdeck.display.get_cols() -> integer
// @brief Get display columns
// @return Number of character columns
LUA_FUNCTION(l_display_get_cols) {
    lua_pushinteger(L, display ? display->getCols() : 40);
    return 1;
}

// @lua tdeck.display.get_rows() -> integer
// @brief Get display rows
// @return Number of character rows
LUA_FUNCTION(l_display_get_rows) {
    lua_pushinteger(L, display ? display->getRows() : 15);
    return 1;
}

// @lua tdeck.display.get_font_width() -> integer
// @brief Get font character width
// @return Character width in pixels
LUA_FUNCTION(l_display_get_font_width) {
    lua_pushinteger(L, display ? display->getFontWidth() : 8);
    return 1;
}

// @lua tdeck.display.get_font_height() -> integer
// @brief Get font character height
// @return Character height in pixels
LUA_FUNCTION(l_display_get_font_height) {
    lua_pushinteger(L, display ? display->getFontHeight() : 16);
    return 1;
}

// @lua tdeck.display.draw_bitmap(x, y, width, height, data)
// @brief Draw a bitmap image from raw RGB565 data
// @param x X position
// @param y Y position
// @param width Bitmap width in pixels
// @param height Bitmap height in pixels
// @param data Raw RGB565 pixel data (2 bytes per pixel, big-endian)
LUA_FUNCTION(l_display_draw_bitmap) {
    LUA_CHECK_ARGC(L, 5);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int width = luaL_checkinteger(L, 3);
    int height = luaL_checkinteger(L, 4);

    size_t dataLen;
    const char* data = luaL_checklstring(L, 5, &dataLen);

    size_t expectedLen = width * height * 2;  // 2 bytes per pixel for RGB565
    if (dataLen < expectedLen) {
        return luaL_error(L, "bitmap data too short: got %d, expected %d", dataLen, expectedLen);
    }

    if (display && width > 0 && height > 0) {
        display->drawBitmap(x, y, width, height, (const uint16_t*)data);
    }

    return 0;
}

// @lua tdeck.display.draw_bitmap_transparent(x, y, width, height, data, transparent_color)
// @brief Draw a bitmap with transparency
// @param x X position
// @param y Y position
// @param width Bitmap width in pixels
// @param height Bitmap height in pixels
// @param data Raw RGB565 pixel data
// @param transparent_color RGB565 color to treat as transparent
LUA_FUNCTION(l_display_draw_bitmap_transparent) {
    LUA_CHECK_ARGC(L, 6);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int width = luaL_checkinteger(L, 3);
    int height = luaL_checkinteger(L, 4);

    size_t dataLen;
    const char* data = luaL_checklstring(L, 5, &dataLen);
    uint16_t transparentColor = luaL_checkinteger(L, 6);

    size_t expectedLen = width * height * 2;
    if (dataLen < expectedLen) {
        return luaL_error(L, "bitmap data too short: got %d, expected %d", dataLen, expectedLen);
    }

    if (display && width > 0 && height > 0) {
        display->drawBitmapTransparent(x, y, width, height, (const uint16_t*)data, transparentColor);
    }

    return 0;
}

// @lua tdeck.display.draw_indexed_bitmap(x, y, width, height, data, palette)
// @brief Draw a 3-bit indexed bitmap using a color palette
// @param x X position
// @param y Y position
// @param width Bitmap width in pixels
// @param height Bitmap height in pixels
// @param data Packed 3-bit pixel indices (8 pixels packed into 3 bytes)
// @param palette Table of 8 RGB565 color values
// @details
// The data format packs 8 pixels (3 bits each = 24 bits) into 3 bytes:
// Byte 0: [p0:2-0][p1:2-0][p2:1-0] (bits: p0=0-2, p1=3-5, p2_lo=6-7)
// Byte 1: [p2:2][p3:2-0][p4:2-0][p5:0] (bits: p2_hi=0, p3=1-3, p4=4-6, p5_lo=7)
// Byte 2: [p5:2-1][p6:2-0][p7:2-0] (bits: p5_hi=0-1, p6=2-4, p7=5-7)
// This is optimized for map tiles converted from grayscale with dithering.
// @example
// local palette = {0x0000, 0x2104, 0x4208, 0x630C, 0x8410, 0xC618, 0xE71C, 0xFFFF}
// display.draw_indexed_bitmap(0, 0, 256, 256, tile_data, palette)
// @end
LUA_FUNCTION(l_display_draw_indexed_bitmap) {
    LUA_CHECK_ARGC(L, 6);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int width = luaL_checkinteger(L, 3);
    int height = luaL_checkinteger(L, 4);

    size_t dataLen;
    const uint8_t* data = (const uint8_t*)luaL_checklstring(L, 5, &dataLen);

    // Get palette table (8 RGB565 colors)
    luaL_checktype(L, 6, LUA_TTABLE);
    uint16_t palette[8];
    for (int i = 0; i < 8; i++) {
        lua_rawgeti(L, 6, i + 1);  // Lua arrays are 1-indexed
        palette[i] = lua_tointeger(L, -1);
        lua_pop(L, 1);
    }

    // Calculate expected data length: 8 pixels per 3 bytes
    size_t totalPixels = width * height;
    size_t expectedLen = (totalPixels * 3 + 7) / 8;  // 3 bits per pixel, round up to bytes
    if (dataLen < expectedLen) {
        return luaL_error(L, "indexed bitmap data too short: got %d, expected %d", dataLen, expectedLen);
    }

    if (!display || width <= 0 || height <= 0) {
        return 0;
    }

    // Clip to screen bounds
    int screenW = display->getWidth();
    int screenH = display->getHeight();

    int startX = (x < 0) ? -x : 0;
    int startY = (y < 0) ? -y : 0;
    int endX = (x + width > screenW) ? screenW - x : width;
    int endY = (y + height > screenH) ? screenH - y : height;

    if (startX >= endX || startY >= endY) {
        return 0;  // Completely off-screen
    }

    int visibleWidth = endX - startX;
    int visibleHeight = endY - startY;

    // FAST PATH: If tile is fully visible and aligned, decode entire tile at once
    // This is the common case for map tiles
    if (startX == 0 && startY == 0 && endX == width && endY == height && width == 256 && height == 256) {
        // Allocate full tile buffer in PSRAM (256*256*2 = 128KB)
        uint16_t* tileBuffer = (uint16_t*)ps_malloc(256 * 256 * sizeof(uint16_t));
        if (tileBuffer) {
            // Optimized decode: process 8 pixels at a time from each 3-byte group
            // This eliminates per-pixel switch and byte fetch overhead
            uint16_t* outPtr = tileBuffer;
            const uint8_t* inPtr = data;
            size_t numGroups = (256 * 256) / 8;  // 8192 groups

            for (size_t g = 0; g < numGroups; g++) {
                uint8_t b0 = *inPtr++;
                uint8_t b1 = *inPtr++;
                uint8_t b2 = *inPtr++;

                // Unpack all 8 pixels at once (no switch, no conditionals)
                *outPtr++ = palette[b0 & 0x07];
                *outPtr++ = palette[(b0 >> 3) & 0x07];
                *outPtr++ = palette[((b0 >> 6) & 0x03) | ((b1 & 0x01) << 2)];
                *outPtr++ = palette[(b1 >> 1) & 0x07];
                *outPtr++ = palette[(b1 >> 4) & 0x07];
                *outPtr++ = palette[((b1 >> 7) & 0x01) | ((b2 & 0x03) << 1)];
                *outPtr++ = palette[(b2 >> 2) & 0x07];
                *outPtr++ = palette[(b2 >> 5) & 0x07];
            }

            // Push entire tile at once (single DMA transfer)
            display->drawBitmap(x, y, 256, 256, tileBuffer);
            free(tileBuffer);
            return 0;
        }
        // Fall through to row-by-row if PSRAM allocation fails
    }

    // SLOW PATH: Partial tile or non-standard size - process row by row
    uint16_t* lineBuffer = (uint16_t*)malloc(visibleWidth * sizeof(uint16_t));
    if (!lineBuffer) {
        return 0;  // Can't allocate, skip this tile
    }

    for (int row = startY; row < endY; row++) {
        int bufIdx = 0;
        int pixelIndex = row * width + startX;

        for (int col = startX; col < endX; col++, pixelIndex++) {
            int groupIndex = pixelIndex / 8;
            int pixelInGroup = pixelIndex % 8;
            int byteOffset = groupIndex * 3;

            uint8_t b0 = data[byteOffset];
            uint8_t b1 = data[byteOffset + 1];
            uint8_t b2 = data[byteOffset + 2];

            uint8_t paletteIndex;
            switch (pixelInGroup) {
                case 0: paletteIndex = b0 & 0x07; break;
                case 1: paletteIndex = (b0 >> 3) & 0x07; break;
                case 2: paletteIndex = ((b0 >> 6) & 0x03) | ((b1 & 0x01) << 2); break;
                case 3: paletteIndex = (b1 >> 1) & 0x07; break;
                case 4: paletteIndex = (b1 >> 4) & 0x07; break;
                case 5: paletteIndex = ((b1 >> 7) & 0x01) | ((b2 & 0x03) << 1); break;
                case 6: paletteIndex = (b2 >> 2) & 0x07; break;
                default: paletteIndex = (b2 >> 5) & 0x07; break;
            }
            lineBuffer[bufIdx++] = palette[paletteIndex];
        }

        display->drawBitmap(x + startX, y + row, visibleWidth, 1, lineBuffer);
    }

    free(lineBuffer);
    return 0;
}

// @lua tdeck.display.draw_indexed_bitmap_scaled(x, y, dest_w, dest_h, data, palette, src_x, src_y, src_w, src_h)
// @brief Draw a scaled portion of a 3-bit indexed bitmap
// @param x Destination X position
// @param y Destination Y position
// @param dest_w Destination width
// @param dest_h Destination height
// @param data Packed 3-bit pixel indices (256x256 source assumed)
// @param palette Table of 8 RGB565 color values
// @param src_x Source X offset in pixels
// @param src_y Source Y offset in pixels
// @param src_w Source width to sample
// @param src_h Source height to sample
// @details
// Used for map tile fallback rendering: shows a scaled-up portion of a parent tile
// while the higher-resolution child tile is loading from SD card.
// @end
LUA_FUNCTION(l_display_draw_indexed_bitmap_scaled) {
    LUA_CHECK_ARGC(L, 10);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int dest_w = luaL_checkinteger(L, 3);
    int dest_h = luaL_checkinteger(L, 4);

    size_t dataLen;
    const uint8_t* data = (const uint8_t*)luaL_checklstring(L, 5, &dataLen);

    // Get palette table
    luaL_checktype(L, 6, LUA_TTABLE);
    uint16_t palette[8];
    for (int i = 0; i < 8; i++) {
        lua_rawgeti(L, 6, i + 1);
        palette[i] = lua_tointeger(L, -1);
        lua_pop(L, 1);
    }

    int src_x = luaL_checkinteger(L, 7);
    int src_y = luaL_checkinteger(L, 8);
    int src_w = luaL_checkinteger(L, 9);
    int src_h = luaL_checkinteger(L, 10);

    if (!display || dest_w <= 0 || dest_h <= 0 || src_w <= 0 || src_h <= 0) {
        return 0;
    }

    // Source is 256x256 indexed bitmap
    const int SRC_SIZE = 256;

    // Clip destination to screen
    int screenW = display->getWidth();
    int screenH = display->getHeight();
    int endX = (x + dest_w > screenW) ? screenW : x + dest_w;
    int endY = (y + dest_h > screenH) ? screenH : y + dest_h;
    int startX = (x < 0) ? 0 : x;
    int startY = (y < 0) ? 0 : y;

    if (startX >= endX || startY >= endY) {
        return 0;
    }

    // Allocate line buffer
    int visibleWidth = endX - startX;
    uint16_t* lineBuffer = (uint16_t*)malloc(visibleWidth * sizeof(uint16_t));
    if (!lineBuffer) {
        return 0;
    }

    // Scale factors (fixed point, 8.8 format)
    int scaleX = (src_w << 8) / dest_w;
    int scaleY = (src_h << 8) / dest_h;

    // Helper lambda to get pixel at source coordinates
    auto getPixel = [&](int px, int py) -> uint16_t {
        if (px < 0 || px >= SRC_SIZE || py < 0 || py >= SRC_SIZE) {
            return palette[0];  // Default to first palette color
        }
        int pixelIndex = py * SRC_SIZE + px;
        int groupIndex = pixelIndex / 8;
        int pixelInGroup = pixelIndex % 8;
        int byteOffset = groupIndex * 3;

        if (byteOffset + 2 >= (int)dataLen) {
            return palette[0];
        }

        uint8_t b0 = data[byteOffset];
        uint8_t b1 = data[byteOffset + 1];
        uint8_t b2 = data[byteOffset + 2];

        uint8_t paletteIndex;
        switch (pixelInGroup) {
            case 0: paletteIndex = b0 & 0x07; break;
            case 1: paletteIndex = (b0 >> 3) & 0x07; break;
            case 2: paletteIndex = ((b0 >> 6) & 0x03) | ((b1 & 0x01) << 2); break;
            case 3: paletteIndex = (b1 >> 1) & 0x07; break;
            case 4: paletteIndex = (b1 >> 4) & 0x07; break;
            case 5: paletteIndex = ((b1 >> 7) & 0x01) | ((b2 & 0x03) << 1); break;
            case 6: paletteIndex = (b2 >> 2) & 0x07; break;
            default: paletteIndex = (b2 >> 5) & 0x07; break;
        }
        return palette[paletteIndex];
    };

    // Render each row
    for (int dy = startY; dy < endY; dy++) {
        int bufIdx = 0;
        // Map destination Y to source Y
        int srcY = src_y + (((dy - y) * scaleY) >> 8);

        for (int dx = startX; dx < endX; dx++) {
            // Map destination X to source X
            int srcX = src_x + (((dx - x) * scaleX) >> 8);
            lineBuffer[bufIdx++] = getPixel(srcX, srcY);
        }

        display->drawBitmap(startX, dy, visibleWidth, 1, lineBuffer);
    }

    free(lineBuffer);
    return 0;
}

// @lua tdeck.display.draw_bitmap_1bit(x, y, width, height, data, scale, color)
// @brief Draw a 1-bit bitmap with scaling and colorization
// @param x X position
// @param y Y position
// @param width Bitmap width in pixels (original size)
// @param height Bitmap height in pixels (original size)
// @param data Packed 1-bit data (MSB first, row by row)
// @param scale Scale factor (1, 2, 3, etc.) - optional, default 1
// @param color RGB565 color for "on" pixels - optional, default WHITE
// @example
// -- 8x8 icon (8 bytes), scaled 3x, cyan color
// display.draw_bitmap_1bit(10, 10, 8, 8, icon_data, 3, colors.CYAN)
// @end
LUA_FUNCTION(l_display_draw_bitmap_1bit) {
    LUA_CHECK_ARGC_RANGE(L, 5, 7);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int width = luaL_checkinteger(L, 3);
    int height = luaL_checkinteger(L, 4);

    size_t dataLen;
    const uint8_t* data = (const uint8_t*)luaL_checklstring(L, 5, &dataLen);
    int scale = luaL_optinteger(L, 6, 1);
    uint16_t color = luaL_optintegerdefault(L, 7, Colors::WHITE);

    // Calculate expected data length (bits rounded up to bytes)
    size_t expectedLen = (width * height + 7) / 8;
    if (dataLen < expectedLen) {
        return luaL_error(L, "bitmap data too short: got %d, expected %d", dataLen, expectedLen);
    }

    if (!display || width <= 0 || height <= 0 || scale <= 0) {
        return 0;
    }

    // Draw the 1-bit bitmap with scaling
    int bitIndex = 0;
    for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
            // Get bit value (MSB first)
            int byteIndex = bitIndex / 8;
            int bitOffset = 7 - (bitIndex % 8);
            bool pixel = (data[byteIndex] >> bitOffset) & 1;
            bitIndex++;

            if (pixel) {
                // Draw scaled pixel
                int px = x + col * scale;
                int py = y + row * scale;
                if (scale == 1) {
                    display->drawPixel(px, py, color);
                } else {
                    display->fillRect(px, py, scale, scale, color);
                }
            }
        }
    }

    return 0;
}

// Function table for tdeck.display
static const luaL_Reg display_funcs[] = {
    {"clear",             l_display_clear},
    {"flush",             l_display_flush},
    {"set_brightness",    l_display_set_brightness},
    {"set_font_size",     l_display_set_font_size},
    {"draw_text",         l_display_draw_text},
    {"draw_text_centered", l_display_draw_text_centered},
    {"draw_char",         l_display_draw_char},
    {"draw_box",          l_display_draw_box},
    {"draw_hline",        l_display_draw_hline},
    {"fill_rect",         l_display_fill_rect},
    {"draw_rect",         l_display_draw_rect},
    {"draw_pixel",        l_display_draw_pixel},
    {"draw_line",         l_display_draw_line},
    {"draw_circle",       l_display_draw_circle},
    {"fill_circle",       l_display_fill_circle},
    {"draw_triangle",     l_display_draw_triangle},
    {"fill_triangle",     l_display_fill_triangle},
    {"draw_round_rect",   l_display_draw_round_rect},
    {"fill_round_rect",   l_display_fill_round_rect},
    {"draw_progress",     l_display_draw_progress},
    {"draw_battery",      l_display_draw_battery},
    {"draw_signal",       l_display_draw_signal},
    {"text_width",        l_display_text_width},
    {"rgb",               l_display_rgb},
    {"get_width",         l_display_get_width},
    {"get_height",        l_display_get_height},
    {"get_cols",          l_display_get_cols},
    {"get_rows",          l_display_get_rows},
    {"get_font_width",    l_display_get_font_width},
    {"get_font_height",   l_display_get_font_height},
    {"draw_bitmap",       l_display_draw_bitmap},
    {"draw_bitmap_transparent", l_display_draw_bitmap_transparent},
    {"draw_bitmap_1bit",  l_display_draw_bitmap_1bit},
    {"draw_indexed_bitmap", l_display_draw_indexed_bitmap},
    {"draw_indexed_bitmap_scaled", l_display_draw_indexed_bitmap_scaled},
    {nullptr, nullptr}
};

// Register the display module
void registerDisplayModule(lua_State* L) {
    // Register main functions
    lua_register_module(L, "display", display_funcs);

    // Add color constants as tdeck.display.colors subtable
    lua_getglobal(L, "tdeck");
    lua_getfield(L, -1, "display");

    // Create colors subtable
    lua_newtable(L);

    // Add all color constants
    lua_set_const_int(L, "BLACK",       Colors::BLACK);
    lua_set_const_int(L, "WHITE",       Colors::WHITE);
    lua_set_const_int(L, "GREEN",       Colors::GREEN);
    lua_set_const_int(L, "DARK_GREEN",  Colors::DARK_GREEN);
    lua_set_const_int(L, "CYAN",        Colors::CYAN);
    lua_set_const_int(L, "RED",         Colors::RED);
    lua_set_const_int(L, "YELLOW",      Colors::YELLOW);
    lua_set_const_int(L, "ORANGE",      Colors::ORANGE);
    lua_set_const_int(L, "BLUE",        Colors::BLUE);
    lua_set_const_int(L, "GRAY",        Colors::GRAY);
    lua_set_const_int(L, "DARK_GRAY",   Colors::DARK_GRAY);
    lua_set_const_int(L, "LIGHT_GRAY",  Colors::LIGHT_GRAY);

    // Theme colors
    lua_set_const_int(L, "BACKGROUND",  Colors::BACKGROUND);
    lua_set_const_int(L, "FOREGROUND",  Colors::FOREGROUND);
    lua_set_const_int(L, "HIGHLIGHT",   Colors::HIGHLIGHT);
    lua_set_const_int(L, "BORDER",      Colors::BORDER);
    lua_set_const_int(L, "TEXT",        Colors::TEXT);
    lua_set_const_int(L, "TEXT_DIM",    Colors::TEXT_DIM);
    lua_set_const_int(L, "SELECTION",   Colors::SELECTION);
    lua_set_const_int(L, "ERROR",       Colors::ERROR);
    lua_set_const_int(L, "WARNING",     Colors::WARNING);
    lua_set_const_int(L, "SUCCESS",     Colors::SUCCESS);

    // Set colors table on display module
    lua_setfield(L, -2, "colors");

    // Add dimension properties (read-only convenience)
    if (display) {
        lua_set_const_int(L, "width",       display->getWidth());
        lua_set_const_int(L, "height",      display->getHeight());
        lua_set_const_int(L, "cols",        display->getCols());
        lua_set_const_int(L, "rows",        display->getRows());
        lua_set_const_int(L, "font_width",  display->getFontWidth());
        lua_set_const_int(L, "font_height", display->getFontHeight());
    } else {
        // Defaults if display not yet initialized
        lua_set_const_int(L, "width",       320);
        lua_set_const_int(L, "height",      240);
        lua_set_const_int(L, "cols",        40);
        lua_set_const_int(L, "rows",        15);
        lua_set_const_int(L, "font_width",  8);
        lua_set_const_int(L, "font_height", 16);
    }

    // Pop display table and tdeck table
    lua_pop(L, 2);

    Serial.println("[LuaRuntime] Registered tdeck.display");
}
