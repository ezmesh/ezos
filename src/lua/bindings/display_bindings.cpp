// ez.display module bindings
// Provides display drawing functions and properties

#include "../lua_bindings.h"
#include "../../hardware/display.h"

// @module ez.display
// @brief 2D drawing primitives and text rendering for the 320x240 LCD
// @description
// All drawing operations write to a double-buffered framebuffer in PSRAM.
// Call flush() once per frame to transfer the buffer to the physical display
// via DMA. Drawing functions use pixel coordinates (0,0 at top-left) and
// RGB565 color format. Use rgb(r,g,b) to convert from 8-bit RGB values.
// @end

// External reference to the global display instance
extern Display* display;

// =============================================================================
// Bus Message Topics (display/theme module)
// =============================================================================

// @bus theme/wallpaper
// @brief Posted when the wallpaper is changed
// @payload string Wallpaper name (e.g., "clouds", "mountains", "none")
// @description
// Fired when ThemeManager.set_wallpaper() is called. Screens can
// subscribe to update their rendering if they display the wallpaper.
// @example
// ez.bus.subscribe("theme/wallpaper", function(name)
//     print("Wallpaper changed to: " .. name)
// end)
// @end

// @bus theme/icons
// @brief Posted when the icon pack is changed
// @payload string Icon pack name
// @description
// Fired when ThemeManager.set_icon_pack() is called. Components
// displaying icons should refresh their cached icon references.
// @example
// ez.bus.subscribe("theme/icons", function(pack)
//     self:reload_icons()
// end)
// @end

// @bus theme/colors
// @brief Posted when the color scheme is changed
// @payload string Color scheme name
// @description
// Fired when ThemeManager.set_colors() is called. UI components
// should refresh their color values.
// @example
// ez.bus.subscribe("theme/colors", function(scheme)
//     self.bg_color = ThemeManager.colors.background
// end)
// @end

// =============================================================================

// @lua ez.display.clear()
// @brief Clear display buffer to black
// @description Fills the entire display buffer with black (0x0000). This does not
// immediately update the physical screen - call flush() to push changes to the display.
// Typically called at the start of each render cycle before drawing new content.
// @example
// ez.display.clear()
// ez.display.draw_text(10, 10, "Hello", colors.WHITE)
// ez.display.flush()
// @end
LUA_FUNCTION(l_display_clear) {
    if (display) {
        display->clear();
    }
    return 0;
}

// @lua ez.display.flush()
// @brief Flush buffer to physical display
// @description Transfers the internal frame buffer to the physical LCD via DMA.
// Call this after all drawing operations are complete for the current frame.
// The T-Deck uses a 320x240 RGB565 display with hardware-accelerated transfers.
// @example
// ez.display.clear()
// ez.display.draw_text(10, 10, "Frame complete", colors.GREEN)
// ez.display.flush()  -- Push to screen
// @end
LUA_FUNCTION(l_display_flush) {
    if (display) {
        display->flush();
    }
    return 0;
}

// @lua ez.display.set_brightness(level)
// @brief Set backlight brightness
// @description Controls the LCD backlight PWM level. Lower values save battery but
// reduce visibility. The setting persists until changed. Use 0 to turn off the
// backlight completely (screen will appear black but is still rendering).
// @param level Brightness level (0-255)
// @example
// ez.display.set_brightness(200)  -- Bright, good for indoor use
// ez.display.set_brightness(50)   -- Dim, saves battery
// ez.display.set_brightness(0)    -- Backlight off
// @end
LUA_FUNCTION(l_display_set_brightness) {
    LUA_CHECK_ARGC(L, 1);
    int level = luaL_checkinteger(L, 1);
    level = constrain(level, 0, 255);
    if (display) {
        display->setBrightness(level);
    }
    return 0;
}

// @lua ez.display.set_font_size(size)
// @brief Set font size
// @description Changes the current font size used by all text drawing functions.
// The font size affects text_width(), get_font_width(), and get_font_height() return values.
// Available sizes: tiny (6px), small (8px), medium (12px), large (16px).
// @param size Font size string: "tiny", "small", "medium", or "large"
// @example
// ez.display.set_font_size("large")
// ez.display.draw_text(10, 10, "Big Title", colors.WHITE)
// ez.display.set_font_size("small")
// ez.display.draw_text(10, 30, "Small details", colors.GRAY)
// @end
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

// @lua ez.display.draw_text(x, y, text, color)
// @brief Draw text at pixel coordinates
// @description Renders a text string at the specified pixel position using the current
// font size. The position specifies the top-left corner of the first character.
// Supports UTF-8 encoded strings including special characters.
// @param x X position in pixels
// @param y Y position in pixels
// @param text Text string to draw
// @param color Text color (optional, defaults to TEXT)
// @example
// ez.display.draw_text(10, 20, "Hello World", colors.WHITE)
// ez.display.draw_text(10, 40, "Status: OK", colors.GREEN)
// @end
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

// @lua ez.display.draw_text_bg(x, y, text, fg_color, bg_color, padding)
// @brief Draw text with a background rectangle
// @description Draws text with a solid background rectangle for better readability
// over complex backgrounds like images or maps. The background rectangle is sized
// automatically based on text dimensions plus the specified padding.
// @param x X position in pixels
// @param y Y position in pixels
// @param text Text string to draw
// @param fg_color Text color
// @param bg_color Background color
// @param padding Padding around text (optional, defaults to 1)
// @example
// -- Label with dark background for contrast
// ez.display.draw_text_bg(50, 100, "GPS: Locked", colors.GREEN, colors.BLACK, 2)
// @end
LUA_FUNCTION(l_display_draw_text_bg) {
    LUA_CHECK_ARGC_RANGE(L, 5, 6);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    const char* text = luaL_checkstring(L, 3);
    uint16_t fg_color = luaL_checkinteger(L, 4);
    uint16_t bg_color = luaL_checkinteger(L, 5);
    int padding = luaL_optinteger(L, 6, 1);

    if (display) {
        int tw = display->textWidth(text);
        int fontHeight = display->getFontHeight();
        // Draw background rectangle
        display->fillRect(x - padding, y - padding,
                         tw + padding * 2, fontHeight + padding * 2,
                         bg_color);
        // Draw text on top
        display->drawText(x, y, text, fg_color);
    }
    return 0;
}

// @lua ez.display.draw_text_shadow(x, y, text, fg_color, shadow_color, offset)
// @brief Draw text with a shadow offset
// @description Draws text with a drop shadow effect by rendering the text twice:
// first at an offset position in the shadow color, then at the original position
// in the foreground color. Creates a pseudo-3D effect that improves readability.
// @param x X position in pixels
// @param y Y position in pixels
// @param text Text string to draw
// @param fg_color Text color
// @param shadow_color Shadow color (optional, defaults to black)
// @param offset Shadow offset in pixels (optional, defaults to 1)
// @example
// -- Title with drop shadow
// ez.display.draw_text_shadow(20, 10, "ezOS", colors.WHITE, colors.DARK_GRAY, 2)
// @end
LUA_FUNCTION(l_display_draw_text_shadow) {
    LUA_CHECK_ARGC_RANGE(L, 4, 6);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    const char* text = luaL_checkstring(L, 3);
    uint16_t fg_color = luaL_checkinteger(L, 4);
    uint16_t shadow_color = luaL_optinteger(L, 5, 0x0000);  // Default black
    int offset = luaL_optinteger(L, 6, 1);

    if (display) {
        // Draw shadow (offset down and right)
        display->drawText(x + offset, y + offset, text, shadow_color);
        // Draw text on top
        display->drawText(x, y, text, fg_color);
    }
    return 0;
}

// @lua ez.display.draw_text_centered(y, text, color)
// @brief Draw horizontally centered text
// @description Draws text centered horizontally on the display. The text width is
// calculated automatically and the X position is computed to center the string.
// Useful for titles, headings, and status messages.
// @param y Y position in pixels
// @param text Text string to draw
// @param color Text color (optional, defaults to TEXT)
// @example
// ez.display.draw_text_centered(10, "Settings", colors.WHITE)
// ez.display.draw_text_centered(120, "No messages", colors.GRAY)
// @end
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

// @lua ez.display.draw_char(x, y, char, color)
// @brief Draw a single character
// @description Draws a single character at the specified position. Only the first
// character of the provided string is rendered. More efficient than draw_text()
// when you only need one character, such as for custom cursors or icon fonts.
// @param x X position in pixels
// @param y Y position in pixels
// @param char Character to draw (first char of string)
// @param color Character color (optional)
// @example
// ez.display.draw_char(100, 100, ">", colors.GREEN)  -- Cursor
// ez.display.draw_char(50, 50, "X", colors.RED)      -- Close icon
// @end
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

// @lua ez.display.draw_box(x, y, w, h, title, border_color, title_color)
// @brief Draw bordered box with optional title
// @description Draws a box using box-drawing characters (single-line borders) with
// an optional title in the top border. Coordinates are in character cells, not pixels.
// Used for creating dialog boxes, menus, and panels in text-mode UIs.
// @param x X position in character cells
// @param y Y position in character cells
// @param w Width in character cells
// @param h Height in character cells
// @param title Optional title string
// @param border_color Border color (optional)
// @param title_color Title color (optional)
// @example
// -- Dialog box with title
// ez.display.draw_box(5, 3, 30, 10, "Confirm", colors.BORDER, colors.HIGHLIGHT)
// @end
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

// @lua ez.display.draw_hline(x, y, w, left_connect, right_connect, color)
// @brief Draw horizontal line with optional connectors
// @description Draws a horizontal line using box-drawing characters with optional
// T-junction connectors at the ends for connecting to vertical borders. Coordinates
// are in character cells. Used for dividers within boxes or between sections.
// @param x X position in character cells
// @param y Y position in character cells
// @param w Width in character cells
// @param left_connect Connect to left border (optional)
// @param right_connect Connect to right border (optional)
// @param color Line color (optional)
// @example
// -- Horizontal divider inside a box (connected on both sides)
// ez.display.draw_hline(5, 6, 30, true, true, colors.BORDER)
// @end
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

// @lua ez.display.fill_rect(x, y, w, h, color)
// @brief Fill a rectangle with color
// @description Draws a solid filled rectangle. One of the most commonly used
// drawing primitives for backgrounds, buttons, selection highlights, and clearing
// specific screen regions. Coordinates can extend off-screen (clipped automatically).
// @param x X position in pixels
// @param y Y position in pixels
// @param w Width in pixels
// @param h Height in pixels
// @param color Fill color (optional)
// @example
// -- Selection highlight
// ez.display.fill_rect(0, 50, 320, 20, colors.SELECTION)
// -- Button background
// ez.display.fill_rect(100, 200, 120, 30, colors.BLUE)
// @end
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

// @lua ez.display.draw_rect(x, y, w, h, color)
// @brief Draw rectangle outline
// @description Draws a 1-pixel wide rectangle outline (not filled). Useful for
// borders, focus indicators, and bounding boxes. The outline is drawn inside the
// specified dimensions.
// @param x X position in pixels
// @param y Y position in pixels
// @param w Width in pixels
// @param h Height in pixels
// @param color Outline color (optional)
// @example
// -- Focus border around selected item
// ez.display.draw_rect(10, 50, 300, 25, colors.HIGHLIGHT)
// @end
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

// @lua ez.display.fill_rect_dithered(x, y, w, h, color, density)
// @brief Fill a rectangle with dithered pattern (simulates transparency)
// @description Fills a rectangle with a dithered pattern to simulate semi-transparency
// on hardware that doesn't support alpha blending. At 50% density, creates a checkerboard
// pattern. Lower density = fewer pixels filled. Useful for overlays and shadows.
// @param x X position in pixels
// @param y Y position in pixels
// @param w Width in pixels
// @param h Height in pixels
// @param color Fill color
// @param density Percentage of pixels filled (0-100, default 50 for checkerboard)
// @example
// -- Semi-transparent overlay
// ez.display.fill_rect_dithered(0, 0, 320, 240, colors.BLACK, 50)
// -- Light shadow effect
// ez.display.fill_rect_dithered(5, 5, 100, 50, colors.BLACK, 25)
// @end
LUA_FUNCTION(l_display_fill_rect_dithered) {
    LUA_CHECK_ARGC_RANGE(L, 5, 6);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    int h = luaL_checkinteger(L, 4);
    uint16_t color = luaL_checkinteger(L, 5);
    int density = luaL_optinteger(L, 6, 50);

    if (display) {
        display->fillRectDithered(x, y, w, h, color, density);
    }
    return 0;
}

// @lua ez.display.fill_rect_hlines(x, y, w, h, color, spacing)
// @brief Fill a rectangle with horizontal line pattern
// @description Fills a rectangle with horizontal scan lines at regular intervals.
// Creates a striped pattern that can simulate CRT effects, partial fills, or
// decorative backgrounds. Spacing of 2 fills every other row (50% fill).
// @param x X position in pixels
// @param y Y position in pixels
// @param w Width in pixels
// @param h Height in pixels
// @param color Fill color
// @param spacing Line spacing (2 = 50%, 3 = 33%, etc., default 2)
// @example
// -- Retro scanline effect
// ez.display.fill_rect_hlines(0, 0, 320, 240, colors.BLACK, 2)
// @end
LUA_FUNCTION(l_display_fill_rect_hlines) {
    LUA_CHECK_ARGC_RANGE(L, 5, 6);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    int h = luaL_checkinteger(L, 4);
    uint16_t color = luaL_checkinteger(L, 5);
    int spacing = luaL_optinteger(L, 6, 2);

    if (display) {
        display->fillRectHLines(x, y, w, h, color, spacing);
    }
    return 0;
}

// @lua ez.display.fill_rect_vlines(x, y, w, h, color, spacing)
// @brief Fill a rectangle with vertical line pattern
// @description Fills a rectangle with vertical lines at regular intervals.
// Creates a vertical striped pattern. Spacing of 2 fills every other column (50% fill).
// @param x X position in pixels
// @param y Y position in pixels
// @param w Width in pixels
// @param h Height in pixels
// @param color Fill color
// @param spacing Line spacing (2 = 50%, 3 = 33%, etc., default 2)
// @example
// -- Vertical stripe pattern
// ez.display.fill_rect_vlines(10, 10, 100, 100, colors.BLUE, 3)
// @end
LUA_FUNCTION(l_display_fill_rect_vlines) {
    LUA_CHECK_ARGC_RANGE(L, 5, 6);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    int h = luaL_checkinteger(L, 4);
    uint16_t color = luaL_checkinteger(L, 5);
    int spacing = luaL_optinteger(L, 6, 2);

    if (display) {
        display->fillRectVLines(x, y, w, h, color, spacing);
    }
    return 0;
}

// @lua ez.display.draw_pixel(x, y, color)
// @brief Draw a single pixel
// @description Sets a single pixel in the frame buffer. While simple, this is the
// slowest way to draw - prefer fill_rect or other primitives when possible.
// Useful for plotting graphs, custom patterns, or debugging.
// @param x X position in pixels
// @param y Y position in pixels
// @param color Pixel color (optional)
// @example
// -- Plot a point
// ez.display.draw_pixel(160, 120, colors.RED)
// @end
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

// @lua ez.display.draw_line(x1, y1, x2, y2, color)
// @brief Draw a line between two points
// @description Draws a 1-pixel wide line using Bresenham's algorithm. Supports any
// angle including diagonal lines. Coordinates can extend off-screen and will be
// clipped appropriately.
// @param x1 Start X position
// @param y1 Start Y position
// @param x2 End X position
// @param y2 End Y position
// @param color Line color (optional)
// @example
// -- Diagonal line
// ez.display.draw_line(0, 0, 319, 239, colors.WHITE)
// -- Horizontal separator
// ez.display.draw_line(10, 100, 310, 100, colors.GRAY)
// @end
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

// @lua ez.display.draw_circle(x, y, r, color)
// @brief Draw circle outline
// @description Draws a 1-pixel wide circle outline using the midpoint circle algorithm.
// The center point and radius define the circle. Partially off-screen circles are
// clipped correctly.
// @param x Center X position
// @param y Center Y position
// @param r Radius
// @param color Circle color (optional)
// @example
// -- Ring around a point
// ez.display.draw_circle(160, 120, 50, colors.CYAN)
// @end
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

// @lua ez.display.fill_circle(x, y, r, color)
// @brief Draw filled circle
// @description Draws a solid filled circle. Useful for indicators, buttons, or markers.
// @param x Center X position
// @param y Center Y position
// @param r Radius
// @param color Fill color (optional)
// @example
// -- Status indicator dot
// ez.display.fill_circle(300, 10, 5, colors.GREEN)
// @end
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

// @lua ez.display.draw_triangle(x1, y1, x2, y2, x3, y3, color)
// @brief Draw triangle outline
// @description Draws a triangle outline by connecting three vertices with lines.
// Vertices can be specified in any order. Useful for arrows, pointers, and icons.
// @param x1 First vertex X
// @param y1 First vertex Y
// @param x2 Second vertex X
// @param y2 Second vertex Y
// @param x3 Third vertex X
// @param y3 Third vertex Y
// @param color Outline color (optional)
// @example
// -- Arrow pointing right
// ez.display.draw_triangle(100, 110, 100, 130, 120, 120, colors.WHITE)
// @end
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

// @lua ez.display.fill_triangle(x1, y1, x2, y2, x3, y3, color)
// @brief Draw filled triangle
// @description Draws a solid filled triangle. The fill uses scan-line rasterization.
// Useful for filled arrows, play buttons, and decorative elements.
// @param x1 First vertex X
// @param y1 First vertex Y
// @param x2 Second vertex X
// @param y2 Second vertex Y
// @param x3 Third vertex X
// @param y3 Third vertex Y
// @param color Fill color (optional)
// @example
// -- Play button triangle
// ez.display.fill_triangle(130, 100, 130, 140, 170, 120, colors.GREEN)
// @end
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

// @lua ez.display.draw_round_rect(x, y, w, h, r, color)
// @brief Draw rounded rectangle outline
// @description Draws a rectangle outline with rounded corners. The corner radius
// should be less than half the smaller dimension. Commonly used for modern UI elements.
// @param x X position
// @param y Y position
// @param w Width
// @param h Height
// @param r Corner radius
// @param color Outline color (optional)
// @example
// -- Rounded button outline
// ez.display.draw_round_rect(100, 180, 120, 40, 8, colors.WHITE)
// @end
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

// @lua ez.display.fill_round_rect(x, y, w, h, r, color)
// @brief Draw filled rounded rectangle
// @description Draws a solid filled rectangle with rounded corners. Commonly used
// for buttons, cards, and modern UI panels.
// @param x X position
// @param y Y position
// @param w Width
// @param h Height
// @param r Corner radius
// @param color Fill color (optional)
// @example
// -- Button background
// ez.display.fill_round_rect(100, 180, 120, 40, 8, colors.BLUE)
// ez.display.draw_text(130, 190, "OK", colors.WHITE)
// @end
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

// @lua ez.display.draw_progress(x, y, w, h, progress, fg_color, bg_color)
// @brief Draw a progress bar
// @description Draws a horizontal progress bar with a background track and filled
// portion. The progress value is clamped to 0.0-1.0 range. Useful for loading
// indicators, file transfers, or any percentage-based visualization.
// @param x X position in pixels
// @param y Y position in pixels
// @param w Width in pixels
// @param h Height in pixels
// @param progress Progress value (0.0 to 1.0)
// @param fg_color Foreground color (optional)
// @param bg_color Background color (optional)
// @example
// -- Download progress at 75%
// ez.display.draw_progress(20, 150, 280, 12, 0.75, colors.GREEN, colors.DARK_GRAY)
// @end
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

// @lua ez.display.draw_battery(x, y, percent)
// @brief Draw battery indicator icon
// @description Draws a battery icon with fill level corresponding to the percentage.
// The icon is color-coded: green for high charge, yellow for medium, red for low.
// Typically used in status bars.
// @param x X position in pixels
// @param y Y position in pixels
// @param percent Battery percentage (0-100)
// @example
// local battery = ez.system.get_battery()
// ez.display.draw_battery(290, 2, battery.percent)
// @end
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

// @lua ez.display.draw_signal(x, y, bars)
// @brief Draw signal strength indicator
// @description Draws a signal strength icon with 0-4 ascending bars, similar to
// mobile phone signal indicators. Used to show radio or mesh network signal quality.
// @param x X position in pixels
// @param y Y position in pixels
// @param bars Signal strength (0-4 bars)
// @example
// -- Strong signal
// ez.display.draw_signal(270, 2, 4)
// -- Weak signal
// ez.display.draw_signal(270, 2, 1)
// @end
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

// @lua ez.display.text_width(text) -> integer
// @brief Get pixel width of text string
// @description Calculates the width in pixels that the given text would occupy when
// rendered with the current font size. Essential for text alignment, centering,
// truncation, and layout calculations.
// @param text Text string to measure
// @return Width in pixels
// @example
// local text = "Hello World"
// local width = ez.display.text_width(text)
// local x = (320 - width) / 2  -- Center on 320px display
// ez.display.draw_text(x, 100, text, colors.WHITE)
// @end
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

// @lua ez.display.rgb(r, g, b) -> integer
// @brief Convert RGB to RGB565 color value
// @description Converts 8-bit RGB components to the 16-bit RGB565 format used by
// the display. RGB565 packs red (5 bits), green (6 bits), and blue (5 bits) into
// a single 16-bit value. Some color precision is lost in this conversion.
// @param r Red component (0-255)
// @param g Green component (0-255)
// @param b Blue component (0-255)
// @return RGB565 color value
// @example
// local purple = ez.display.rgb(128, 0, 255)
// local orange = ez.display.rgb(255, 165, 0)
// ez.display.fill_rect(10, 10, 50, 50, purple)
// @end
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

// @lua ez.display.get_width() -> integer
// @brief Get display width
// @description Returns the display width in pixels. The T-Deck has a 320x240 IPS LCD.
// Use this for portable layouts that adapt to different display sizes.
// @return Width in pixels
// @example
// local w = ez.display.get_width()  -- Returns 320
// @end
LUA_FUNCTION(l_display_get_width) {
    lua_pushinteger(L, display ? display->getWidth() : 320);
    return 1;
}

// @lua ez.display.get_height() -> integer
// @brief Get display height
// @description Returns the display height in pixels. The T-Deck has a 320x240 IPS LCD.
// @return Height in pixels
// @example
// local h = ez.display.get_height()  -- Returns 240
// @end
LUA_FUNCTION(l_display_get_height) {
    lua_pushinteger(L, display ? display->getHeight() : 240);
    return 1;
}

// @lua ez.display.get_cols() -> integer
// @brief Get display columns
// @description Returns the number of character columns based on current font size.
// Used for text-mode layouts where positioning is in character cells rather than pixels.
// @return Number of character columns
// @example
// local cols = ez.display.get_cols()  -- e.g., 40 with 8px font
// @end
LUA_FUNCTION(l_display_get_cols) {
    lua_pushinteger(L, display ? display->getCols() : 40);
    return 1;
}

// @lua ez.display.get_rows() -> integer
// @brief Get display rows
// @description Returns the number of character rows based on current font size.
// Used for text-mode layouts where positioning is in character cells.
// @return Number of character rows
// @example
// local rows = ez.display.get_rows()  -- e.g., 15 with 16px font
// @end
LUA_FUNCTION(l_display_get_rows) {
    lua_pushinteger(L, display ? display->getRows() : 15);
    return 1;
}

// @lua ez.display.get_font_width() -> integer
// @brief Get font character width
// @description Returns the width in pixels of a single character in the current font.
// Monospace fonts have uniform character width. Useful for calculating text positioning.
// @return Character width in pixels
// @example
// local fw = ez.display.get_font_width()  -- e.g., 8 for medium font
// local x = 10 + 5 * fw  -- Position after 5 characters
// @end
LUA_FUNCTION(l_display_get_font_width) {
    lua_pushinteger(L, display ? display->getFontWidth() : 8);
    return 1;
}

// @lua ez.display.get_font_height() -> integer
// @brief Get font character height
// @description Returns the height in pixels of a character cell in the current font.
// This is the line height including spacing. Useful for calculating vertical layout.
// @return Character height in pixels
// @example
// local fh = ez.display.get_font_height()  -- e.g., 16 for medium font
// for i, line in ipairs(lines) do
//     ez.display.draw_text(10, 10 + (i-1) * fh, line, colors.WHITE)
// end
// @end
LUA_FUNCTION(l_display_get_font_height) {
    lua_pushinteger(L, display ? display->getFontHeight() : 16);
    return 1;
}

// @lua ez.display.draw_bitmap(x, y, width, height, data)
// @brief Draw a bitmap image from raw RGB565 data
// @description Draws an uncompressed bitmap from raw RGB565 pixel data. Each pixel
// is 2 bytes in big-endian format. The data length must be exactly width*height*2
// bytes. This is the fastest bitmap draw method but uses the most memory.
// @param x X position
// @param y Y position
// @param width Bitmap width in pixels
// @param height Bitmap height in pixels
// @param data Raw RGB565 pixel data (2 bytes per pixel, big-endian)
// @example
// local data = ez.storage.read_bytes("/icons/logo.raw")
// ez.display.draw_bitmap(100, 50, 64, 64, data)
// @end
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

// @lua ez.display.draw_bitmap_transparent(x, y, width, height, data, transparent_color)
// @brief Draw a bitmap with transparency
// @description Draws a bitmap where pixels matching the transparent color are skipped,
// allowing the background to show through. This is a simple color-key transparency
// (not alpha blending). Commonly used for sprites and icons.
// @param x X position
// @param y Y position
// @param width Bitmap width in pixels
// @param height Bitmap height in pixels
// @param data Raw RGB565 pixel data
// @param transparent_color RGB565 color to treat as transparent
// @example
// local data = ez.storage.read_bytes("/sprites/player.raw")
// -- Treat magenta (0xF81F) as transparent
// ez.display.draw_bitmap_transparent(100, 100, 32, 32, data, 0xF81F)
// @end
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

// @lua ez.display.draw_indexed_bitmap(x, y, width, height, data, palette)
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

// @lua ez.display.draw_indexed_bitmap_scaled(x, y, dest_w, dest_h, data, palette, src_x, src_y, src_w, src_h)
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

// @lua ez.display.save_screenshot(path) -> boolean
// @brief Save current display contents as BMP screenshot to SD card
// @param path File path on SD card (e.g., "/screenshots/screen_001.bmp")
// @return true if saved successfully, false on error
// @example
// local ok = display.save_screenshot("/screenshots/capture.bmp")
// @end
LUA_FUNCTION(l_display_save_screenshot) {
    LUA_CHECK_ARGC(L, 1);
    const char* path = luaL_checkstring(L, 1);

    if (!display) {
        lua_pushboolean(L, false);
        return 1;
    }

    bool ok = display->saveScreenshot(path);
    lua_pushboolean(L, ok);
    return 1;
}

// @lua ez.display.draw_bitmap_1bit(x, y, width, height, data, scale, color)
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

// ============================================================================
// Sprite userdata bindings
// ============================================================================

#define SPRITE_METATABLE "ez.Sprite"

// Helper to get Sprite* from userdata
static Sprite* checkSprite(lua_State* L, int idx) {
    Sprite** pp = (Sprite**)luaL_checkudata(L, idx, SPRITE_METATABLE);
    if (!pp || !*pp) {
        luaL_error(L, "invalid Sprite");
        return nullptr;
    }
    return *pp;
}

// @module sprite
// @brief Off-screen drawing surface for compositing and overlays
// @description
// Sprites are off-screen RGB565 buffers allocated in PSRAM. Create with
// ez.display.create_sprite(w,h), draw to them using the same primitives as
// the display, then push() to composite onto the screen with optional alpha.
// Useful for UI overlays, menus, and cached graphics. Call destroy() when done.
// @end

// @lua sprite:clear(color)
// @brief Clear sprite to a color
// @description Fills the entire sprite buffer with the specified color. Call this
// before drawing new content to reset the sprite. Often used with the transparent
// color to create a clean slate for layered composition.
// @param color Fill color (optional, defaults to black)
// @example
// sprite:clear(0x0000)  -- Clear to black
// sprite:clear(0xF81F)  -- Clear to magenta (for transparency)
// @end
LUA_FUNCTION(l_sprite_clear) {
    Sprite* sprite = checkSprite(L, 1);
    uint16_t color = luaL_optinteger(L, 2, 0x0000);
    if (sprite) sprite->clear(color);
    return 0;
}

// @lua sprite:set_transparent_color(color)
// @brief Set the color treated as transparent when pushing
// @description Sets the color key used for transparency when calling push(). Pixels
// matching this color will not be drawn, allowing the background to show through.
// Common choices are magenta (0xF81F) or black (0x0000).
// @param color RGB565 color to treat as transparent
// @example
// sprite:set_transparent_color(0xF81F)  -- Magenta = transparent
// @end
LUA_FUNCTION(l_sprite_set_transparent_color) {
    Sprite* sprite = checkSprite(L, 1);
    uint16_t color = luaL_checkinteger(L, 2);
    if (sprite) sprite->setTransparentColor(color);
    return 0;
}

// @lua sprite:fill_rect(x, y, w, h, color)
// @brief Fill a rectangle in the sprite
// @description Draws a solid filled rectangle within the sprite buffer.
// @param x X position relative to sprite
// @param y Y position relative to sprite
// @param w Width in pixels
// @param h Height in pixels
// @param color Fill color
// @example
// sprite:fill_rect(0, 0, 100, 50, colors.BLUE)
// @end
LUA_FUNCTION(l_sprite_fill_rect) {
    Sprite* sprite = checkSprite(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    int w = luaL_checkinteger(L, 4);
    int h = luaL_checkinteger(L, 5);
    uint16_t color = luaL_checkinteger(L, 6);
    if (sprite) sprite->fillRect(x, y, w, h, color);
    return 0;
}

// @lua sprite:draw_rect(x, y, w, h, color)
// @brief Draw a rectangle outline in the sprite
// @description Draws a 1-pixel wide rectangle outline within the sprite buffer.
// @param x X position relative to sprite
// @param y Y position relative to sprite
// @param w Width in pixels
// @param h Height in pixels
// @param color Outline color
// @example
// sprite:draw_rect(5, 5, 90, 40, colors.WHITE)
// @end
LUA_FUNCTION(l_sprite_draw_rect) {
    Sprite* sprite = checkSprite(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    int w = luaL_checkinteger(L, 4);
    int h = luaL_checkinteger(L, 5);
    uint16_t color = luaL_checkinteger(L, 6);
    if (sprite) sprite->drawRect(x, y, w, h, color);
    return 0;
}

// @lua sprite:fill_round_rect(x, y, w, h, r, color)
// @brief Draw a filled rounded rectangle in the sprite
// @description Draws a solid rectangle with rounded corners within the sprite buffer.
// @param x X position
// @param y Y position
// @param w Width
// @param h Height
// @param r Corner radius
// @param color Fill color
// @example
// sprite:fill_round_rect(10, 10, 80, 30, 5, colors.GREEN)
// @end
LUA_FUNCTION(l_sprite_fill_round_rect) {
    Sprite* sprite = checkSprite(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    int w = luaL_checkinteger(L, 4);
    int h = luaL_checkinteger(L, 5);
    int r = luaL_checkinteger(L, 6);
    uint16_t color = luaL_checkinteger(L, 7);
    if (sprite) sprite->fillRoundRect(x, y, w, h, r, color);
    return 0;
}

// @lua sprite:draw_round_rect(x, y, w, h, r, color)
// @brief Draw a rounded rectangle outline in the sprite
// @description Draws a rectangle outline with rounded corners within the sprite buffer.
// @param x X position
// @param y Y position
// @param w Width
// @param h Height
// @param r Corner radius
// @param color Outline color
// @example
// sprite:draw_round_rect(10, 10, 80, 30, 5, colors.WHITE)
// @end
LUA_FUNCTION(l_sprite_draw_round_rect) {
    Sprite* sprite = checkSprite(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    int w = luaL_checkinteger(L, 4);
    int h = luaL_checkinteger(L, 5);
    int r = luaL_checkinteger(L, 6);
    uint16_t color = luaL_checkinteger(L, 7);
    if (sprite) sprite->drawRoundRect(x, y, w, h, r, color);
    return 0;
}

// @lua sprite:draw_text(x, y, text, color)
// @brief Draw text in the sprite
// @description Renders text at the specified position within the sprite buffer.
// Uses the current global font size setting.
// @param x X position
// @param y Y position
// @param text Text string to draw
// @param color Text color
// @example
// sprite:draw_text(10, 10, "Overlay", colors.WHITE)
// @end
LUA_FUNCTION(l_sprite_draw_text) {
    Sprite* sprite = checkSprite(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    const char* text = luaL_checkstring(L, 4);
    uint16_t color = luaL_checkinteger(L, 5);
    if (sprite) sprite->drawText(x, y, text, color);
    return 0;
}

// @lua sprite:draw_line(x1, y1, x2, y2, color)
// @brief Draw a line in the sprite
// @description Draws a line between two points within the sprite buffer.
// @param x1 Start X
// @param y1 Start Y
// @param x2 End X
// @param y2 End Y
// @param color Line color
// @example
// sprite:draw_line(0, 0, 50, 50, colors.YELLOW)
// @end
LUA_FUNCTION(l_sprite_draw_line) {
    Sprite* sprite = checkSprite(L, 1);
    int x1 = luaL_checkinteger(L, 2);
    int y1 = luaL_checkinteger(L, 3);
    int x2 = luaL_checkinteger(L, 4);
    int y2 = luaL_checkinteger(L, 5);
    uint16_t color = luaL_checkinteger(L, 6);
    if (sprite) sprite->drawLine(x1, y1, x2, y2, color);
    return 0;
}

// @lua sprite:draw_circle(x, y, r, color)
// @brief Draw a circle outline in the sprite
// @description Draws a circle outline within the sprite buffer.
// @param x Center X
// @param y Center Y
// @param r Radius
// @param color Circle color
// @example
// sprite:draw_circle(50, 50, 20, colors.CYAN)
// @end
LUA_FUNCTION(l_sprite_draw_circle) {
    Sprite* sprite = checkSprite(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    int r = luaL_checkinteger(L, 4);
    uint16_t color = luaL_checkinteger(L, 5);
    if (sprite) sprite->drawCircle(x, y, r, color);
    return 0;
}

// @lua sprite:fill_circle(x, y, r, color)
// @brief Draw a filled circle in the sprite
// @description Draws a solid filled circle within the sprite buffer.
// @param x Center X
// @param y Center Y
// @param r Radius
// @param color Fill color
// @example
// sprite:fill_circle(50, 50, 15, colors.RED)
// @end
LUA_FUNCTION(l_sprite_fill_circle) {
    Sprite* sprite = checkSprite(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    int r = luaL_checkinteger(L, 4);
    uint16_t color = luaL_checkinteger(L, 5);
    if (sprite) sprite->fillCircle(x, y, r, color);
    return 0;
}

// @lua sprite:push(x, y, alpha)
// @brief Composite sprite onto display buffer
// @description Copies the sprite content to the main display buffer with optional
// alpha blending. Pixels matching the transparent color (set via set_transparent_color)
// are skipped. The alpha parameter controls overall opacity for fade effects.
// @param x X position on screen
// @param y Y position on screen
// @param alpha Opacity 0-255 (optional, default 255 = opaque)
// @example
// sprite:push(100, 50)          -- Fully opaque
// sprite:push(100, 50, 128)     -- 50% transparent
// @end
LUA_FUNCTION(l_sprite_push) {
    Sprite* sprite = checkSprite(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    int alpha = luaL_optinteger(L, 4, 255);
    if (sprite) sprite->push(x, y, (uint8_t)alpha);
    return 0;
}

// @lua sprite:destroy()
// @brief Free sprite memory
// @description Explicitly releases the sprite's pixel buffer from PSRAM. While sprites
// are automatically garbage collected, calling destroy() immediately frees memory
// when you know the sprite is no longer needed. After calling, the sprite is invalid.
// @example
// local sprite = ez.display.create_sprite(100, 100)
// -- ... use sprite ...
// sprite:destroy()  -- Free memory immediately
// @end
LUA_FUNCTION(l_sprite_destroy) {
    Sprite** pp = (Sprite**)luaL_checkudata(L, 1, SPRITE_METATABLE);
    if (pp && *pp) {
        delete *pp;
        *pp = nullptr;
    }
    return 0;
}

// @lua sprite:width() -> integer
// @brief Get sprite width
// @description Returns the width of the sprite in pixels as specified when created.
// @return Width in pixels
// @example
// local w = sprite:width()  -- Get sprite dimensions
// @end
LUA_FUNCTION(l_sprite_width) {
    Sprite* sprite = checkSprite(L, 1);
    lua_pushinteger(L, sprite ? sprite->width() : 0);
    return 1;
}

// @lua sprite:height() -> integer
// @brief Get sprite height
// @description Returns the height of the sprite in pixels as specified when created.
// @return Height in pixels
// @example
// local h = sprite:height()  -- Get sprite dimensions
// @end
LUA_FUNCTION(l_sprite_height) {
    Sprite* sprite = checkSprite(L, 1);
    lua_pushinteger(L, sprite ? sprite->height() : 0);
    return 1;
}

// Sprite __gc metamethod
LUA_FUNCTION(l_sprite_gc) {
    Sprite** pp = (Sprite**)lua_touserdata(L, 1);
    if (pp && *pp) {
        delete *pp;
        *pp = nullptr;
    }
    return 0;
}

// Sprite method table
static const luaL_Reg sprite_methods[] = {
    {"clear",                l_sprite_clear},
    {"set_transparent_color", l_sprite_set_transparent_color},
    {"fill_rect",            l_sprite_fill_rect},
    {"draw_rect",            l_sprite_draw_rect},
    {"fill_round_rect",      l_sprite_fill_round_rect},
    {"draw_round_rect",      l_sprite_draw_round_rect},
    {"draw_text",            l_sprite_draw_text},
    {"draw_line",            l_sprite_draw_line},
    {"draw_circle",          l_sprite_draw_circle},
    {"fill_circle",          l_sprite_fill_circle},
    {"push",                 l_sprite_push},
    {"destroy",              l_sprite_destroy},
    {"width",                l_sprite_width},
    {"height",               l_sprite_height},
    {nullptr, nullptr}
};

// @lua ez.display.create_sprite(width, height) -> Sprite
// @brief Create an off-screen sprite for alpha compositing
// @description Allocates an off-screen RGB565 pixel buffer in PSRAM for compositing
// operations. Sprites support transparency and alpha blending when pushed to the
// display. Useful for overlays, menus, and animated elements. Remember to call
// destroy() or let garbage collection free the memory when done.
// @param width Sprite width in pixels
// @param height Sprite height in pixels
// @return Sprite object, or nil if allocation failed
// @example
// local overlay = ez.display.create_sprite(200, 100)
// overlay:set_transparent_color(0xF81F)
// overlay:clear(0xF81F)
// overlay:fill_round_rect(0, 0, 200, 100, 10, colors.DARK_GRAY)
// overlay:draw_text(20, 40, "Popup Menu", colors.WHITE)
// overlay:push(60, 70, 200)  -- Draw at 78% opacity
// @end
LUA_FUNCTION(l_display_create_sprite) {
    LUA_CHECK_ARGC(L, 2);
    int width = luaL_checkinteger(L, 1);
    int height = luaL_checkinteger(L, 2);

    if (!display) {
        lua_pushnil(L);
        return 1;
    }

    Sprite* sprite = display->createSprite(width, height);
    if (!sprite) {
        lua_pushnil(L);
        return 1;
    }

    // Create userdata and set metatable
    Sprite** pp = (Sprite**)lua_newuserdata(L, sizeof(Sprite*));
    *pp = sprite;
    luaL_getmetatable(L, SPRITE_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

// ============================================================================
// Display module function table
// ============================================================================

// Function table for ez.display
static const luaL_Reg display_funcs[] = {
    {"clear",             l_display_clear},
    {"flush",             l_display_flush},
    {"set_brightness",    l_display_set_brightness},
    {"set_font_size",     l_display_set_font_size},
    {"draw_text",         l_display_draw_text},
    {"draw_text_bg",      l_display_draw_text_bg},
    {"draw_text_shadow",  l_display_draw_text_shadow},
    {"draw_text_centered", l_display_draw_text_centered},
    {"draw_char",         l_display_draw_char},
    {"draw_box",          l_display_draw_box},
    {"draw_hline",        l_display_draw_hline},
    {"fill_rect",         l_display_fill_rect},
    {"draw_rect",         l_display_draw_rect},
    {"fill_rect_dithered", l_display_fill_rect_dithered},
    {"fill_rect_hlines",  l_display_fill_rect_hlines},
    {"fill_rect_vlines",  l_display_fill_rect_vlines},
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
    {"save_screenshot",   l_display_save_screenshot},
    {"create_sprite",     l_display_create_sprite},
    {nullptr, nullptr}
};

// Register the display module
void registerDisplayModule(lua_State* L) {
    // Register Sprite metatable
    luaL_newmetatable(L, SPRITE_METATABLE);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");  // metatable.__index = metatable
    luaL_setfuncs(L, sprite_methods, 0);
    lua_pushcfunction(L, l_sprite_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    // Register main functions
    lua_register_module(L, "display", display_funcs);

    // Add color constants as ez.display.colors subtable
    lua_getglobal(L, "ez");
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

    Serial.println("[LuaRuntime] Registered ez.display");
}
