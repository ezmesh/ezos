// tdeck.display module bindings
// Provides display drawing functions and properties

#include "../lua_bindings.h"
#include "../../hardware/display.h"
#include "../../tui/theme.h"

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
// @param size Font size string: "small", "medium", or "large"
LUA_FUNCTION(l_display_set_font_size) {
    LUA_CHECK_ARGC(L, 1);
    const char* sizeStr = luaL_checkstring(L, 1);

    FontSize size = FontSize::MEDIUM;
    if (strcmp(sizeStr, "small") == 0) {
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
