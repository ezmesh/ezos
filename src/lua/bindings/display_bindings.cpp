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

    // Bare names map to the FreeMono bitmap sizes; `_aa` variants map
    // to the Inter AA pack. FreeSans was retired; callers that want a
    // proportional tiny use "tiny_aa".
    FontSize size = FontSize::MEDIUM;
    if (strcmp(sizeStr, "tiny") == 0) {
        size = FontSize::TINY;
    } else if (strcmp(sizeStr, "small") == 0) {
        size = FontSize::SMALL;
    } else if (strcmp(sizeStr, "large") == 0) {
        size = FontSize::LARGE;
    } else if (strcmp(sizeStr, "tiny_aa") == 0) {
        size = FontSize::TINY_AA;
    } else if (strcmp(sizeStr, "small_aa") == 0) {
        size = FontSize::SMALL_AA;
    } else if (strcmp(sizeStr, "medium_aa") == 0) {
        size = FontSize::MEDIUM_AA;
    } else if (strcmp(sizeStr, "large_aa") == 0) {
        size = FontSize::LARGE_AA;
    }

    if (display) {
        display->setFontSize(size);
    }
    return 0;
}

// @lua ez.display.set_font_style(style)
// @brief Set font style (weight/slope)
// @description Selects a style variant of the current AA font — bold, italic,
// or both. Bitmap mono fonts (tiny/small/medium/large) ignore this; they only
// ship in a regular weight. The generated AA pack covers all four combinations
// per size (see tools/gen_aa_font.py).
// @param style One of "regular", "bold", "italic", or "bold_italic"
// @example
// ez.display.set_font_size("small_aa")
// ez.display.set_font_style("bold")
// ez.display.draw_text(10, 10, "Heading", colors.WHITE)
// ez.display.set_font_style("regular")
// @end
LUA_FUNCTION(l_display_set_font_style) {
    LUA_CHECK_ARGC(L, 1);
    const char* s = luaL_checkstring(L, 1);

    FontStyle style = FontStyle::REGULAR;
    if (strcmp(s, "bold") == 0) {
        style = FontStyle::BOLD;
    } else if (strcmp(s, "italic") == 0) {
        style = FontStyle::ITALIC;
    } else if (strcmp(s, "bold_italic") == 0 || strcmp(s, "bolditalic") == 0) {
        style = FontStyle::BOLD_ITALIC;
    }

    if (display) {
        display->setFontStyle(style);
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

// @lua ez.display.draw_hline(x, y, w, color)
// @brief Draw a 1-pixel horizontal line in pixel coordinates
// @param x X start position in pixels
// @param y Y position in pixels
// @param w Width in pixels
// @param color Line color (RGB565)
LUA_FUNCTION(l_display_draw_hline) {
    LUA_CHECK_ARGC_RANGE(L, 3, 4);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    uint16_t color = luaL_optintegerdefault(L, 4, Colors::BORDER);

    if (display) {
        display->getBuffer().drawFastHLine(x, y, w, color);
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

// @lua ez.display.draw_wifi(x, y, bars)
// @brief Draw a WiFi signal strength icon (3 ascending cyan bars).
// @param x X position in pixels
// @param y Y position in pixels
// @param bars Signal strength (0-3 bars filled)
// @end
LUA_FUNCTION(l_display_draw_wifi) {
    LUA_CHECK_ARGC(L, 3);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int bars = luaL_checkinteger(L, 3);
    bars = constrain(bars, 0, 3);
    if (display) display->drawWifi(x, y, bars);
    return 0;
}

// @lua ez.display.draw_gps(x, y, bars)
// @brief Draw a GPS fix indicator (3 ascending orange bars + satellite dot).
// @param x X position in pixels
// @param y Y position in pixels
// @param bars Fix quality (0-3 bars filled)
// @end
LUA_FUNCTION(l_display_draw_gps) {
    LUA_CHECK_ARGC(L, 3);
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int bars = luaL_checkinteger(L, 3);
    bars = constrain(bars, 0, 3);
    if (display) display->drawGps(x, y, bars);
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

    // Get palette table (8 RGB565 colors).
    // The TFT panel expects big-endian RGB565 on the SPI wire. fillRect swaps
    // internally; pushImage (used by drawBitmap below) does not, so we
    // pre-swap each palette entry once. Without this, WATER (0xA69E) draws as
    // 0x9EA6 — a saturated lime green — which is exactly what issue-reports
    // of "coastline flipped, water is green" turned out to be.
    luaL_checktype(L, 6, LUA_TTABLE);
    uint16_t palette[8];
    for (int i = 0; i < 8; i++) {
        lua_rawgeti(L, 6, i + 1);  // Lua arrays are 1-indexed
        uint16_t c = (uint16_t)lua_tointeger(L, -1);
        palette[i] = (c >> 8) | (c << 8);
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

    // Get palette table. Pre-swap to BE RGB565 — see the comment in
    // l_display_draw_indexed_bitmap for the byte-order rationale.
    luaL_checktype(L, 6, LUA_TTABLE);
    uint16_t palette[8];
    for (int i = 0; i < 8; i++) {
        lua_rawgeti(L, 6, i + 1);
        uint16_t c = (uint16_t)lua_tointeger(L, -1);
        palette[i] = (c >> 8) | (c << 8);
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

// @lua sprite:draw_jpeg(x, y, data [, scale_x, scale_y, off_x, off_y, max_w, max_h])
// @brief Decode JPEG data into the sprite's pixel buffer
// @description Identical parameters to ez.display.draw_jpeg but rasterises into
// the off-screen sprite. Decode happens once; subsequent push() calls reuse the
// cached pixels without re-decoding.
LUA_FUNCTION(l_sprite_draw_jpeg) {
    Sprite* sprite = checkSprite(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    size_t dataLen;
    const char* data = luaL_checklstring(L, 4, &dataLen);
    float scale_x = (float)luaL_optnumber(L, 5, 1.0);
    float scale_y = (float)luaL_optnumber(L, 6, 0.0);
    int off_x = (int)luaL_optinteger(L, 7, 0);
    int off_y = (int)luaL_optinteger(L, 8, 0);
    int max_w = (int)luaL_optinteger(L, 9, 0);
    int max_h = (int)luaL_optinteger(L, 10, 0);
    bool ok = sprite ? sprite->drawJpeg((const uint8_t*)data, dataLen,
                                        x, y, max_w, max_h,
                                        off_x, off_y, scale_x, scale_y)
                     : false;
    lua_pushboolean(L, ok);
    return 1;
}

// @lua sprite:draw_png(x, y, data [, scale_x, scale_y, off_x, off_y, max_w, max_h])
// @brief Decode PNG data into the sprite's pixel buffer
LUA_FUNCTION(l_sprite_draw_png) {
    Sprite* sprite = checkSprite(L, 1);
    int x = luaL_checkinteger(L, 2);
    int y = luaL_checkinteger(L, 3);
    size_t dataLen;
    const char* data = luaL_checklstring(L, 4, &dataLen);
    float scale_x = (float)luaL_optnumber(L, 5, 1.0);
    float scale_y = (float)luaL_optnumber(L, 6, 0.0);
    int off_x = (int)luaL_optinteger(L, 7, 0);
    int off_y = (int)luaL_optinteger(L, 8, 0);
    int max_w = (int)luaL_optinteger(L, 9, 0);
    int max_h = (int)luaL_optinteger(L, 10, 0);
    bool ok = sprite ? sprite->drawPng((const uint8_t*)data, dataLen,
                                       x, y, max_w, max_h,
                                       off_x, off_y, scale_x, scale_y)
                     : false;
    lua_pushboolean(L, ok);
    return 1;
}

// @lua sprite:get_raw() -> string
// @brief Return the sprite's raw pixel buffer as a binary string
// @description The returned string contains width*height*2 bytes in LGFX
// buffer format (big-endian RGB565). This is the same layout that
// ez.display.draw_bitmap consumes, so the bytes can be cached to flash
// (via ez.storage.write_file) and blitted straight back next boot with
// no per-pixel conversion. Useful for decoding JPEG/PNG assets once
// and keeping them as fast-blit raw images.
LUA_FUNCTION(l_sprite_get_raw) {
    Sprite* sprite = checkSprite(L, 1);
    if (!sprite) { lua_pushnil(L); return 1; }
    const uint8_t* buf = sprite->rawBuffer();
    size_t len = sprite->rawBufferSize();
    if (!buf || len == 0) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, (const char*)buf, len);
    return 1;
}

// @lua sprite:set_raw(data)
// @brief Overwrite the sprite's pixel buffer with raw RGB565 bytes
// @description Inverse of get_raw(). Copies width*height*2 bytes from
// `data` into the sprite's pixel buffer in LGFX byte order. Used by
// the paint app's undo history to restore a previous canvas snapshot
// without a per-pixel fill_rect loop. The data length must match the
// sprite's exact buffer size; shorter strings are rejected so a
// stray call can't read past the end of `data`.
// @param data Raw bytes string previously returned by get_raw()
LUA_FUNCTION(l_sprite_set_raw) {
    Sprite* sprite = checkSprite(L, 1);
    if (!sprite) return 0;
    size_t inLen;
    const char* in = luaL_checklstring(L, 2, &inLen);
    size_t expected = sprite->rawBufferSize();
    if (expected == 0) return 0;
    if (inLen < expected) {
        return luaL_error(L,
            "sprite:set_raw: data too short -- got %zu bytes, expected %zu "
            "(width*height*2)",
            inLen, expected);
    }
    // rawBuffer() returns a const pointer for read-only consumers; the
    // underlying LGFX buffer is mutable, so const_cast is safe here.
    uint8_t* buf = const_cast<uint8_t*>(sprite->rawBuffer());
    if (buf) memcpy(buf, in, expected);
    return 0;
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
    {"draw_jpeg",            l_sprite_draw_jpeg},
    {"draw_png",             l_sprite_draw_png},
    {"get_raw",              l_sprite_get_raw},
    {"set_raw",              l_sprite_set_raw},
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

// @lua ez.display.draw_jpeg(x, y, data [, scale_x, scale_y, off_x, off_y, max_w, max_h])
// @brief Decode and draw a JPEG image from memory
// @description Decodes JPEG data and draws it to the display at the given position.
// Supports optional pan (off_x/off_y crop the source image) and zoom (scale_x/y).
// Decode happens in C++ using the LovyanGFX built-in TJpgDec decoder.
// @param x X position on screen
// @param y Y position on screen
// @param data JPEG file data as a string (from async_read or file load)
// @param scale_x Horizontal scale factor (default 1.0)
// @param scale_y Vertical scale factor (default = scale_x)
// @param off_x Source image X offset (pan, default 0)
// @param off_y Source image Y offset (pan, default 0)
// @param max_w Maximum output width (default 0 = unlimited)
// @param max_h Maximum output height (default 0 = unlimited)
// @return true on success, false on decode error
LUA_FUNCTION(l_display_draw_jpeg) {
    if (!display) { lua_pushboolean(L, false); return 1; }
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    size_t dataLen;
    const char* data = luaL_checklstring(L, 3, &dataLen);
    float scale_x = (float)luaL_optnumber(L, 4, 1.0);
    float scale_y = (float)luaL_optnumber(L, 5, 0.0);
    int off_x = (int)luaL_optinteger(L, 6, 0);
    int off_y = (int)luaL_optinteger(L, 7, 0);
    int max_w = (int)luaL_optinteger(L, 8, 0);
    int max_h = (int)luaL_optinteger(L, 9, 0);

    bool ok = display->getBuffer().drawJpg(
        (const uint8_t*)data, dataLen, x, y,
        max_w, max_h, off_x, off_y, scale_x, scale_y);
    lua_pushboolean(L, ok);
    return 1;
}

// @lua ez.display.draw_png(x, y, data [, scale_x, scale_y, off_x, off_y, max_w, max_h])
// @brief Decode and draw a PNG image from memory
// @description Same pan/zoom parameters as draw_jpeg.
// @return true on success
LUA_FUNCTION(l_display_draw_png) {
    if (!display) { lua_pushboolean(L, false); return 1; }
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    size_t dataLen;
    const char* data = luaL_checklstring(L, 3, &dataLen);
    float scale_x = (float)luaL_optnumber(L, 4, 1.0);
    float scale_y = (float)luaL_optnumber(L, 5, 0.0);
    int off_x = (int)luaL_optinteger(L, 6, 0);
    int off_y = (int)luaL_optinteger(L, 7, 0);
    int max_w = (int)luaL_optinteger(L, 8, 0);
    int max_h = (int)luaL_optinteger(L, 9, 0);

    bool ok = display->getBuffer().drawPng(
        (const uint8_t*)data, dataLen, x, y,
        max_w, max_h, off_x, off_y, scale_x, scale_y);
    lua_pushboolean(L, ok);
    return 1;
}

// @lua ez.display.get_image_size(data) -> width, height
// @brief Parse JPEG or PNG header to get dimensions without rendering
// @description Scans the file header of a JPEG (SOF marker) or PNG (IHDR
// chunk) and returns image dimensions. Both formats are auto-detected by
// file signature. Returns nil, nil if the format is unrecognized or the
// header is incomplete.
// @return width, height (integers) or nil, nil on error
LUA_FUNCTION(l_display_get_image_size) {
    LUA_CHECK_ARGC(L, 1);
    size_t dataLen;
    const char* data = luaL_checklstring(L, 1, &dataLen);
    const uint8_t* p = (const uint8_t*)data;

    // PNG: 8-byte signature [89 50 4E 47 0D 0A 1A 0A] then IHDR chunk
    // [length:4][type:4="IHDR"][width:4 BE][height:4 BE][...]
    if (dataLen >= 24
            && p[0] == 0x89 && p[1] == 0x50 && p[2] == 0x4E && p[3] == 0x47
            && p[4] == 0x0D && p[5] == 0x0A && p[6] == 0x1A && p[7] == 0x0A) {
        uint32_t w = ((uint32_t)p[16] << 24) | ((uint32_t)p[17] << 16)
                   | ((uint32_t)p[18] << 8)  |  (uint32_t)p[19];
        uint32_t h = ((uint32_t)p[20] << 24) | ((uint32_t)p[21] << 16)
                   | ((uint32_t)p[22] << 8)  |  (uint32_t)p[23];
        lua_pushinteger(L, (lua_Integer)w);
        lua_pushinteger(L, (lua_Integer)h);
        return 2;
    }

    // JPEG: scan for SOF (Start Of Frame) marker.
    if (dataLen >= 4 && p[0] == 0xFF && p[1] == 0xD8) {
        size_t i = 2;
        while (i + 9 < dataLen) {
            if (p[i] != 0xFF) { i++; continue; }
            uint8_t m = p[i + 1];
            // Non-differential Huffman SOF markers: C0..C3, C5..C7, C9..CB, CD..CF
            // (skip DHT=C4, DAC=CC, JPG=C8)
            if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
                // SOF segment: [FF][Mn][len:2][precision:1][height:2][width:2]
                uint16_t h = (p[i + 5] << 8) | p[i + 6];
                uint16_t w = (p[i + 7] << 8) | p[i + 8];
                lua_pushinteger(L, w);
                lua_pushinteger(L, h);
                return 2;
            }
            // Markers without a payload: SOI, EOI, RST0..RST7
            if (m == 0xD8 || m == 0xD9 || (m >= 0xD0 && m <= 0xD7)) {
                i += 2;
                continue;
            }
            if (i + 3 >= dataLen) break;
            uint16_t seg_len = (p[i + 2] << 8) | p[i + 3];
            i += 2 + seg_len;
        }
    }

    lua_pushnil(L);
    lua_pushnil(L);
    return 2;
}

// @lua ez.display.set_clip_rect(x, y, w, h)
// @brief Set a clipping rectangle for all subsequent draw operations
// @description Restricts drawing to the specified rectangle. Any pixels drawn
// outside this region are discarded. Use clear_clip_rect() to remove.
// Essential for scrollable containers that must not draw outside their bounds.
// @param x Left edge of clip region
// @param y Top edge of clip region
// @param w Width of clip region
// @param h Height of clip region
LUA_FUNCTION(l_display_set_clip_rect) {
    LUA_CHECK_ARGC(L, 4);
    if (!display) return 0;
    int x = luaL_checkinteger(L, 1);
    int y = luaL_checkinteger(L, 2);
    int w = luaL_checkinteger(L, 3);
    int h = luaL_checkinteger(L, 4);
    display->getBuffer().setClipRect(x, y, w, h);
    return 0;
}

// @lua ez.display.clear_clip_rect()
// @brief Remove the clipping rectangle, restoring full-screen drawing
LUA_FUNCTION(l_display_clear_clip_rect) {
    if (!display) return 0;
    display->getBuffer().clearClipRect();
    return 0;
}

// ============================================================================
// Scene3D: batched software-rasterizer API
// ----------------------------------------------------------------------------
// Rationale: calling fill_triangle from Lua once per triangle pays the
// Lua→C crossing cost ~150 times per frame, and the per-vertex transform
// math in Lua is the hottest loop in simple 3D games like wasteland.lua.
// Scene3D accepts world-space triangles once (or per frame for dynamic
// sprites) and renders the whole set in a single render call, performing
// transform, near-plane clip, back-face cull, painter's-algorithm sort,
// and fillTriangle all in native code.
//
// Usage (Lua side):
//   scene = ez.display.scene_new()
//   ez.display.scene_add_tri(scene, x1,y1,z1, x2,y2,z2, x3,y3,z3, color)
//   ... once per static triangle ...
//   static_count = ez.display.scene_mark_static(scene)
//
//   -- each frame:
//   ez.display.scene_reset_to(scene, static_count)
//   ez.display.scene_add_tri(scene, ...)  -- for each dynamic sprite tri
//   ez.display.scene_render(scene, px, py, pz, yaw_cos, yaw_sin,
//                           focal, cx, cy, near, fog_k)
// ============================================================================

#include <vector>
#include <algorithm>

#define SCENE3D_METATABLE "ez.Scene3D"

struct Scene3D {
    // World-space triangles: 10 floats each (9 vertex coords + color).
    std::vector<float> world_buf;
    size_t tri_count = 0;

    // Camera context used by the billboard helpers to orient quads
    // toward the camera and apply a small forward nudge so billboards
    // beat the ground tile they stand on in depth comparisons.
    // Updated once per frame by ez.display.scene_set_camera().
    float cam_px = 0.0f;
    float cam_pz = 0.0f;
    float cam_yc = 1.0f;   // cos(yaw)
    float cam_ys = 0.0f;   // sin(yaw)
    float cam_fwd = 0.0f;  // forward nudge distance (world units)
};

struct ProjTri {
    int sx1, sy1, sx2, sy2, sx3, sy3;
    uint16_t color;
    float z;
};

// Scratch buffer reused across render calls to avoid allocating a new
// vector every frame. Not thread-safe, but the Lua runtime is single-
// threaded on this hardware.
static std::vector<ProjTri> s_proj_buf;

static Scene3D* checkScene3D(lua_State* L, int idx) {
    Scene3D** pp = (Scene3D**)luaL_checkudata(L, idx, SCENE3D_METATABLE);
    if (!pp || !*pp) {
        luaL_error(L, "invalid Scene3D");
        return nullptr;
    }
    return *pp;
}

// Darken an RGB565 color by factor 0..1. Mirrors the Lua shade() helper.
static inline uint16_t shade_rgb565(uint16_t color, float f) {
    if (f >= 1.0f) return color;
    if (f <= 0.0f) return 0;
    int r = (int)(((color >> 11) & 0x1F) * f);
    int g = (int)(((color >> 5) & 0x3F) * f);
    int b = (int)((color & 0x1F) * f);
    return (uint16_t)((r << 11) | (g << 5) | b);
}

// Project a camera-space triangle (already past near-plane) and push it
// into the scratch buffer if it passes back-face and off-screen checks.
static inline void project_and_push(
    float cx1, float cy1, float cz1,
    float cx2, float cy2, float cz2,
    float cx3, float cy3, float cz3,
    uint16_t base_color,
    float focal, float cx, float cy, float fog_k,
    int screen_w, int screen_h)
{
    float i1 = focal / cz1;
    float i2 = focal / cz2;
    float i3 = focal / cz3;
    float sx1 = cx + cx1 * i1;
    float sy1 = cy - cy1 * i1;
    float sx2 = cx + cx2 * i2;
    float sy2 = cy - cy2 * i2;
    float sx3 = cx + cx3 * i3;
    float sy3 = cy - cy3 * i3;

    // Back-face cull (CW on screen means facing away, since screen Y is
    // inverted vs world Y — triangles authored CCW when viewed from
    // outside remain CCW on screen here).
    float area2 = (sx2 - sx1) * (sy3 - sy1) - (sx3 - sx1) * (sy2 - sy1);
    if (area2 >= 0) return;

    float minx = sx1 < sx2 ? (sx1 < sx3 ? sx1 : sx3) : (sx2 < sx3 ? sx2 : sx3);
    float maxx = sx1 > sx2 ? (sx1 > sx3 ? sx1 : sx3) : (sx2 > sx3 ? sx2 : sx3);
    if (maxx < 0 || minx > screen_w) return;
    float miny = sy1 < sy2 ? (sy1 < sy3 ? sy1 : sy3) : (sy2 < sy3 ? sy2 : sy3);
    float maxy = sy1 > sy2 ? (sy1 > sy3 ? sy1 : sy3) : (sy2 > sy3 ? sy2 : sy3);
    if (maxy < 0 || miny > screen_h) return;

    float avg_z = (cz1 + cz2 + cz3) * (1.0f / 3.0f);
    float fog = 1.0f / (1.0f + avg_z * fog_k);

    ProjTri t;
    t.sx1 = (int)sx1; t.sy1 = (int)sy1;
    t.sx2 = (int)sx2; t.sy2 = (int)sy2;
    t.sx3 = (int)sx3; t.sy3 = (int)sy3;
    t.color = shade_rgb565(base_color, fog);
    t.z = avg_z;
    s_proj_buf.push_back(t);
}

// @lua ez.display.scene_new() -> Scene3D
// @brief Allocate a new 3D scene buffer
LUA_FUNCTION(l_scene_new) {
    Scene3D** pp = (Scene3D**)lua_newuserdata(L, sizeof(Scene3D*));
    *pp = new Scene3D();
    luaL_getmetatable(L, SCENE3D_METATABLE);
    lua_setmetatable(L, -2);
    return 1;
}

LUA_FUNCTION(l_scene_gc) {
    Scene3D** pp = (Scene3D**)lua_touserdata(L, 1);
    if (pp && *pp) {
        delete *pp;
        *pp = nullptr;
    }
    return 0;
}

// @lua ez.display.scene_add_tri(scene, x1,y1,z1, x2,y2,z2, x3,y3,z3, color)
// @brief Append a world-space triangle. CCW winding when viewed from the
// visible side; colour is the pre-shaded RGB565 base (fog is applied at
// render time).
LUA_FUNCTION(l_scene_add_tri) {
    Scene3D* s = checkScene3D(L, 1);
    float v[10];
    for (int i = 0; i < 9; i++) v[i] = (float)lua_tonumber(L, 2 + i);
    v[9] = (float)lua_tointeger(L, 11);
    s->world_buf.insert(s->world_buf.end(), v, v + 10);
    s->tri_count++;
    return 0;
}

// Internal helper: push two triangles that together form a CCW-wound
// quad from four corners. Callers pass vertices in order; the visible
// side is the one that sees them wound counter-clockwise. Shared by
// scene_add_quad, scene_add_aabb, and scene_add_road_strip so the
// triangulation happens in exactly one place.
static inline void push_quad(
    Scene3D* s,
    float x1, float y1, float z1,
    float x2, float y2, float z2,
    float x3, float y3, float z3,
    float x4, float y4, float z4,
    int color)
{
    float col = (float)color;
    float v[20] = {
        x1, y1, z1,   x2, y2, z2,   x3, y3, z3,   col,
        x1, y1, z1,   x3, y3, z3,   x4, y4, z4,   col,
    };
    s->world_buf.insert(s->world_buf.end(), v, v + 20);
    s->tri_count += 2;
}

// @lua ez.display.scene_add_quad(scene, x1,y1,z1, x2,y2,z2, x3,y3,z3, x4,y4,z4, color)
// @brief Append a planar quad as two triangles in one call.
// @description Convenience wrapper for the extremely common "submit a
// flat surface" pattern (ground tiles, walls, roof panels, road
// segments). Winding order is the same as the tris it expands to:
// CCW as seen from the visible side. Saves 1 Lua→C crossing + 10 stack
// reads per surface compared to two scene_add_tri calls; for a world
// built from hundreds of quads this cuts build-time perceptibly.
LUA_FUNCTION(l_scene_add_quad) {
    Scene3D* s = checkScene3D(L, 1);
    float v[12];
    for (int i = 0; i < 12; i++) v[i] = (float)lua_tonumber(L, 2 + i);
    int color = (int)lua_tointeger(L, 14);
    push_quad(s,
        v[0],  v[1],  v[2],
        v[3],  v[4],  v[5],
        v[6],  v[7],  v[8],
        v[9],  v[10], v[11],
        color);
    return 0;
}

// @lua ez.display.scene_add_aabb(scene, x0,y0,z0, x1,y1,z1, side_color, top_color)
// @brief Append an axis-aligned box (5 visible faces, bottom omitted).
// @description The bottom face is skipped because every use so far has
// the box resting on a floor surface that already covers it — drawing
// it wastes triangle budget for no visible difference. `side_color` is
// used for the four vertical faces; `top_color` for the top cap. Pass
// the same colour for both if you want a monochrome box.
//
// Corners are given as two opposite points: (x0,y0,z0) and (x1,y1,z1).
// The call normalises them so the caller doesn't have to care which is
// min and which is max.
LUA_FUNCTION(l_scene_add_aabb) {
    Scene3D* s = checkScene3D(L, 1);
    float x0 = (float)lua_tonumber(L, 2);
    float y0 = (float)lua_tonumber(L, 3);
    float z0 = (float)lua_tonumber(L, 4);
    float x1 = (float)lua_tonumber(L, 5);
    float y1 = (float)lua_tonumber(L, 6);
    float z1 = (float)lua_tonumber(L, 7);
    int side_color = (int)lua_tointeger(L, 8);
    int top_color  = (int)lua_tointeger(L, 9);

    // Normalise so lo / hi are always min / max.
    if (x0 > x1) { float t = x0; x0 = x1; x1 = t; }
    if (y0 > y1) { float t = y0; y0 = y1; y1 = t; }
    if (z0 > z1) { float t = z0; z0 = z1; z1 = t; }

    // Top (y = y1), viewed from above, CCW.
    push_quad(s,
        x0, y1, z0,   x1, y1, z0,   x1, y1, z1,   x0, y1, z1,
        top_color);
    // North face (+z), viewed from +z, CCW.
    push_quad(s,
        x1, y0, z1,   x0, y0, z1,   x0, y1, z1,   x1, y1, z1,
        side_color);
    // South face (-z), viewed from -z, CCW.
    push_quad(s,
        x0, y0, z0,   x1, y0, z0,   x1, y1, z0,   x0, y1, z0,
        side_color);
    // East face (+x), viewed from +x, CCW.
    push_quad(s,
        x1, y0, z0,   x1, y0, z1,   x1, y1, z1,   x1, y1, z0,
        side_color);
    // West face (-x), viewed from -x, CCW.
    push_quad(s,
        x0, y0, z1,   x0, y0, z0,   x0, y1, z0,   x0, y1, z1,
        side_color);
    return 0;
}

// @lua ez.display.scene_add_road_strip(scene, points_table, half_width, y, color)
// @brief Append a ribbon of quads along a centerline, width held
// constant (perpendicular-to-segment).
// @description `points_table` is an array of {x, z} pairs — typically a
// closed track ring, but works for open roads too. Consecutive points
// define a segment; for each segment, this helper computes a
// perpendicular direction (rotated 90° in the XZ plane) and emits a
// flat quad of length=segment and width=2*half_width centred on the
// segment, all at vertical `y`. No allocation per segment — the quads
// append directly into the scene buffer.
//
// Use for: race tracks, footpaths, rivers, belt ribbons — anything
// whose centerline is known and whose cross-section is a constant
// horizontal width.
LUA_FUNCTION(l_scene_add_road_strip) {
    Scene3D* s = checkScene3D(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    float half_w = (float)lua_tonumber(L, 3);
    float y      = (float)lua_tonumber(L, 4);
    int color    = (int)lua_tointeger(L, 5);

    size_t n = (size_t)lua_rawlen(L, 2);
    if (n < 2) return 0;

    // First point
    lua_rawgeti(L, 2, 1);
    lua_rawgeti(L, -1, 1);
    float px = (float)lua_tonumber(L, -1);
    lua_pop(L, 1);
    lua_rawgeti(L, -1, 2);
    float pz = (float)lua_tonumber(L, -1);
    lua_pop(L, 2);

    for (size_t i = 2; i <= n; i++) {
        lua_rawgeti(L, 2, (lua_Integer)i);
        lua_rawgeti(L, -1, 1);
        float qx = (float)lua_tonumber(L, -1);
        lua_pop(L, 1);
        lua_rawgeti(L, -1, 2);
        float qz = (float)lua_tonumber(L, -1);
        lua_pop(L, 2);

        // Perpendicular direction in XZ plane.
        float dx = qx - px;
        float dz = qz - pz;
        float len = sqrtf(dx * dx + dz * dz);
        if (len > 1e-6f) {
            // Unit perpendicular: rotate (dx, dz) by 90° CCW in XZ.
            // (px, pz) right side = +perp; left side = -perp.
            float nx = -dz / len * half_w;
            float nz =  dx / len * half_w;
            // Four corners; winding CCW when viewed from +y (above).
            push_quad(s,
                px - nx, y, pz - nz,
                qx - nx, y, qz - nz,
                qx + nx, y, qz + nz,
                px + nx, y, pz + nz,
                color);
        }
        px = qx;
        pz = qz;
    }
    return 0;
}

// @lua ez.display.scene_count(scene) -> int
// @lua ez.display.scene_set_camera(scene, px, pz, yaw_cos, yaw_sin [, fwd_nudge])
// @brief Update the billboard camera context.
// @description The billboard helpers (scene_add_billboard,
// scene_add_billboard_split) need to know where the camera is and which
// way it faces to orient their quads. Call this once per frame before
// submitting billboards — saves passing the parameters on every
// primitive call and lets the C side do the right/forward math in
// native code instead of Lua.
// @param fwd_nudge optional world-space distance to shift billboards
// toward the camera so they beat coincident ground tiles in the
// painter's / z-buffer depth comparison.
LUA_FUNCTION(l_scene_set_camera) {
    Scene3D* s = checkScene3D(L, 1);
    s->cam_px  = (float)lua_tonumber(L, 2);
    s->cam_pz  = (float)lua_tonumber(L, 3);
    s->cam_yc  = (float)lua_tonumber(L, 4);
    s->cam_ys  = (float)lua_tonumber(L, 5);
    s->cam_fwd = (float)luaL_optnumber(L, 6, 0.0);
    return 0;
}

// Internal helper: compute the four billboard corners in world space
// given the camera context on the Scene3D. Writes into the out[] array:
// [tlx, tlz, trx, trz, ty, by] (Y values are the same for left/right).
static inline void compute_billboard_corners(
    const Scene3D* s,
    float wx, float wy, float wz, float half_w, float full_h,
    float out[6])
{
    float rx = s->cam_yc;   // right vector x in XZ plane
    float rz = -s->cam_ys;  // right vector z in XZ plane

    // Forward nudge toward camera: shift (wx, wz) a small distance
    // along the camera→billboard direction. Skipped for degenerate
    // cases or when fwd_nudge is zero.
    if (s->cam_fwd > 0.0f) {
        float fdx = wx - s->cam_px;
        float fdz = wz - s->cam_pz;
        float flen2 = fdx * fdx + fdz * fdz;
        if (flen2 > 1e-6f) {
            float scale = s->cam_fwd / sqrtf(flen2);
            wx -= fdx * scale;
            wz -= fdz * scale;
        }
    }

    float tlx = wx - rx * half_w;
    float tlz = wz - rz * half_w;
    float trx = wx + rx * half_w;
    float trz = wz + rz * half_w;
    out[0] = tlx; out[1] = tlz;
    out[2] = trx; out[3] = trz;
    out[4] = wy + full_h * 0.5f;   // top y
    out[5] = wy - full_h * 0.5f;   // bottom y
}

// @lua ez.display.scene_add_billboard(scene, wx, wy, wz, half_w, full_h, color)
// @brief Append a camera-facing quad (2 triangles) at world position
// (wx, wy, wz). `wy` is the vertical centre of the quad. Camera
// context must be set via scene_set_camera first.
LUA_FUNCTION(l_scene_add_billboard) {
    Scene3D* s = checkScene3D(L, 1);
    float wx = (float)lua_tonumber(L, 2);
    float wy = (float)lua_tonumber(L, 3);
    float wz = (float)lua_tonumber(L, 4);
    float hw = (float)lua_tonumber(L, 5);
    float fh = (float)lua_tonumber(L, 6);
    float color = (float)lua_tointeger(L, 7);

    float c[6];
    compute_billboard_corners(s, wx, wy, wz, hw, fh, c);
    float tlx = c[0], tlz = c[1], trx = c[2], trz = c[3];
    float ty = c[4], by = c[5];

    // Triangle 1: top-left, bottom-left, bottom-right
    // Triangle 2: top-left, bottom-right, top-right
    // Wound CCW as seen from camera so back-face cull keeps them visible.
    float v[20] = {
        tlx, ty, tlz,   tlx, by, tlz,   trx, by, trz,   color,
        tlx, ty, tlz,   trx, by, trz,   trx, ty, trz,   color,
    };
    s->world_buf.insert(s->world_buf.end(), v, v + 20);
    s->tri_count += 2;
    return 0;
}

// @lua ez.display.scene_add_billboard_split(scene, wx, wy, wz, half_w,
//                                            full_h, color_top, color_bot)
// @brief Append a camera-facing quad split horizontally at its midline
// with a different colour on each half (4 triangles total). Useful for
// foliage / pickup sprites that want a simple vertical gradient without
// a real lighting model.
LUA_FUNCTION(l_scene_add_billboard_split) {
    Scene3D* s = checkScene3D(L, 1);
    float wx = (float)lua_tonumber(L, 2);
    float wy = (float)lua_tonumber(L, 3);
    float wz = (float)lua_tonumber(L, 4);
    float hw = (float)lua_tonumber(L, 5);
    float fh = (float)lua_tonumber(L, 6);
    float ctop = (float)lua_tointeger(L, 7);
    float cbot = (float)lua_tointeger(L, 8);

    float c[6];
    compute_billboard_corners(s, wx, wy, wz, hw, fh, c);
    float tlx = c[0], tlz = c[1], trx = c[2], trz = c[3];
    float ty = c[4], by = c[5];
    float my = wy;  // midline

    // Top half (ctop): 2 triangles
    // Bottom half (cbot): 2 triangles
    float v[40] = {
        // top half
        tlx, ty, tlz,   tlx, my, tlz,   trx, my, trz,   ctop,
        tlx, ty, tlz,   trx, my, trz,   trx, ty, trz,   ctop,
        // bottom half
        tlx, my, tlz,   tlx, by, tlz,   trx, by, trz,   cbot,
        tlx, my, tlz,   trx, by, trz,   trx, my, trz,   cbot,
    };
    s->world_buf.insert(s->world_buf.end(), v, v + 40);
    s->tri_count += 4;
    return 0;
}

LUA_FUNCTION(l_scene_count) {
    Scene3D* s = checkScene3D(L, 1);
    lua_pushinteger(L, (lua_Integer)s->tri_count);
    return 1;
}

// @lua ez.display.scene_mark_static(scene) -> int
// @brief Return the current triangle count so callers can later restore
// the buffer to exactly these triangles (used as a static/dynamic split).
LUA_FUNCTION(l_scene_mark_static) {
    Scene3D* s = checkScene3D(L, 1);
    lua_pushinteger(L, (lua_Integer)s->tri_count);
    return 1;
}

// @lua ez.display.scene_reset_to(scene, count)
// @brief Truncate the scene's triangle buffer back to `count` triangles.
LUA_FUNCTION(l_scene_reset_to) {
    Scene3D* s = checkScene3D(L, 1);
    size_t n = (size_t)luaL_checkinteger(L, 2);
    if (n > s->tri_count) n = s->tri_count;
    s->tri_count = n;
    s->world_buf.resize(n * 10);
    return 0;
}

// @lua ez.display.scene_clear(scene)
LUA_FUNCTION(l_scene_clear) {
    Scene3D* s = checkScene3D(L, 1);
    s->tri_count = 0;
    s->world_buf.clear();
    return 0;
}

// @lua ez.display.scene_render(scene, px, py, pz, yaw_cos, yaw_sin,
//                              focal, cx, cy, near, fog_k [, far]) -> int drawn
// @brief Transform, clip, sort, and fill every triangle in the scene.
// Returns the number of triangles actually drawn (post-cull).
//
// Parameters:
//   px, py, pz   — camera (player eye) position in world units
//   yaw_cos/sin  — cos/sin of camera yaw (pre-computed to save Lua work)
//   focal        — focal length in pixels
//   cx, cy       — principal point (screen centre for the 3D view)
//   near         — near clip plane distance
//   fog_k        — fog coefficient: brightness = 1 / (1 + avg_z * fog_k)
//   far          — (optional) far clip distance in world units. When
//                  supplied, any triangle whose three vertices are all
//                  beyond `far` is skipped before projection. Omit or
//                  pass 0 to disable the far cull.
LUA_FUNCTION(l_scene_render) {
    Scene3D* s = checkScene3D(L, 1);
    float px = (float)lua_tonumber(L, 2);
    float py = (float)lua_tonumber(L, 3);
    float pz = (float)lua_tonumber(L, 4);
    float yc = (float)lua_tonumber(L, 5);
    float ys = (float)lua_tonumber(L, 6);
    float focal = (float)lua_tonumber(L, 7);
    float cx = (float)lua_tonumber(L, 8);
    float cy = (float)lua_tonumber(L, 9);
    float nearp = (float)lua_tonumber(L, 10);
    float fog_k = (float)lua_tonumber(L, 11);
    float farp = (float)luaL_optnumber(L, 12, 0.0);
    bool far_enabled = farp > 0.0f;

    if (!display) { lua_pushinteger(L, 0); return 1; }
    int screen_w = display->getWidth();
    int screen_h = display->getHeight();

    s_proj_buf.clear();
    s_proj_buf.reserve(s->tri_count);

    const float* buf = s->world_buf.data();
    // Pre-computed squared far distance for the horizontal-plane check.
    // We test the world-space horizontal distance from camera to each
    // vertex; if all three vertices lie beyond `far`, the triangle
    // can't possibly fall inside the view frustum in camera space.
    // Cheaper than doing the full transform then checking cz > far.
    float far_sq = far_enabled ? farp * farp : 0.0f;

    for (size_t i = 0; i < s->tri_count; i++) {
        const float* t = buf + i * 10;
        float wx1 = t[0], wy1 = t[1], wz1 = t[2];
        float wx2 = t[3], wy2 = t[4], wz2 = t[5];
        float wx3 = t[6], wy3 = t[7], wz3 = t[8];
        uint16_t color = (uint16_t)t[9];

        if (far_enabled) {
            float h1dx = wx1 - px, h1dz = wz1 - pz;
            float d1 = h1dx * h1dx + h1dz * h1dz;
            if (d1 > far_sq) {
                float h2dx = wx2 - px, h2dz = wz2 - pz;
                float d2 = h2dx * h2dx + h2dz * h2dz;
                if (d2 > far_sq) {
                    float h3dx = wx3 - px, h3dz = wz3 - pz;
                    float d3 = h3dx * h3dx + h3dz * h3dz;
                    if (d3 > far_sq) continue;
                }
            }
        }

        // World → camera (yaw-only rotation around Y)
        float dx1 = wx1 - px, dz1 = wz1 - pz;
        float cx1 = dx1 * yc - dz1 * ys;
        float cy1 = wy1 - py;
        float cz1 = dx1 * ys + dz1 * yc;

        float dx2 = wx2 - px, dz2 = wz2 - pz;
        float cx2 = dx2 * yc - dz2 * ys;
        float cy2 = wy2 - py;
        float cz2 = dx2 * ys + dz2 * yc;

        float dx3 = wx3 - px, dz3 = wz3 - pz;
        float cx3 = dx3 * yc - dz3 * ys;
        float cy3 = wy3 - py;
        float cz3 = dx3 * ys + dz3 * yc;

        bool in1 = cz1 >= nearp;
        bool in2 = cz2 >= nearp;
        bool in3 = cz3 >= nearp;

        int inside = (in1 ? 1 : 0) + (in2 ? 1 : 0) + (in3 ? 1 : 0);
        if (inside == 0) continue;

        if (inside == 3) {
            project_and_push(cx1, cy1, cz1, cx2, cy2, cz2, cx3, cy3, cz3,
                             color, focal, cx, cy, fog_k, screen_w, screen_h);
            continue;
        }

        // Partial near-plane clip: walk edges and emit a 3- or 4-vertex
        // polygon, then fan-triangulate. Sutherland-Hodgman style.
        float pcx[4], pcy[4], pcz[4];
        int n = 0;
        auto clip_edge = [&](float ax, float ay, float az,
                             float bx, float by, float bz,
                             bool ain, bool bin) {
            if (ain) {
                pcx[n] = ax; pcy[n] = ay; pcz[n] = az; n++;
            }
            if (ain != bin) {
                float t = (nearp - az) / (bz - az);
                pcx[n] = ax + (bx - ax) * t;
                pcy[n] = ay + (by - ay) * t;
                pcz[n] = nearp;
                n++;
            }
        };
        clip_edge(cx1, cy1, cz1, cx2, cy2, cz2, in1, in2);
        clip_edge(cx2, cy2, cz2, cx3, cy3, cz3, in2, in3);
        clip_edge(cx3, cy3, cz3, cx1, cy1, cz1, in3, in1);

        if (n < 3) continue;
        // Fan-triangulate from vertex 0
        for (int k = 1; k + 1 < n; k++) {
            project_and_push(
                pcx[0], pcy[0], pcz[0],
                pcx[k], pcy[k], pcz[k],
                pcx[k + 1], pcy[k + 1], pcz[k + 1],
                color, focal, cx, cy, fog_k, screen_w, screen_h);
        }
    }

    // Painter's sort: far first (descending z). stable_sort keeps the
    // submission order for ties — important for coincident billboards
    // (shadow flares, trunks, canopy clusters) that share the same avg_z
    // and need to draw in the exact order the game submitted them.
    std::stable_sort(s_proj_buf.begin(), s_proj_buf.end(),
              [](const ProjTri& a, const ProjTri& b) { return a.z > b.z; });

    for (const auto& t : s_proj_buf) {
        display->fillTriangle(t.sx1, t.sy1, t.sx2, t.sy2, t.sx3, t.sy3, t.color);
    }

    lua_pushinteger(L, (lua_Integer)s_proj_buf.size());
    return 1;
}

// ============================================================================
// Scene3D + z-buffered rasterizer
// ----------------------------------------------------------------------------
// Alternative render path to scene_render that uses a per-pixel depth
// buffer instead of a painter's-algorithm sort. The z-buffer lives in
// internal SRAM (fast, no wait states) so per-pixel z-tests are cheap
// next to the PSRAM colour writes they save. Triangles can be drawn in
// any order without ordering artifacts, and overdraw early-outs before
// touching the PSRAM framebuffer.
//
// Depth quantization: 8-bit linear in camera-space Z across [NEAR, FAR].
// For our scene scale (hills ~1m, buildings ~3m, view ~30m) this is
// more than enough precision — smaller than the billboard nudge we were
// using to beat the painter's tie-breaker.
// ============================================================================

#define ZBUF_W 320
#define ZBUF_H 240

// Active viewport rectangle used by fill_tri_z / fill_span_z for
// pixel-level clipping. Set by scene_render_z_run before rasterising so
// callers can render into a sub-region of the screen (e.g. a square
// viewport with HUD around it) without having triangles bleed out.
// Defaults cover the full framebuffer.
static int s_vp_x0 = 0;
static int s_vp_y0 = 0;
static int s_vp_x1 = ZBUF_W - 1;
static int s_vp_y1 = ZBUF_H - 1;

// Z-buffer allocated lazily on first scene_render_z call. Using a heap
// pointer instead of a static .bss array avoids pushing ~77 KB out of
// DRAM at link time, which was squeezing other init allocations on
// this build. heap_caps_malloc with MALLOC_CAP_INTERNAL keeps it in
// fast internal SRAM; if that fails we'll fall back to the default
// allocator (may land in PSRAM — slower but functional).
static uint8_t* z_buffer = nullptr;

#include "esp_heap_caps.h"

static inline bool zbuf_ensure() {
    if (z_buffer) return true;
    z_buffer = (uint8_t*)heap_caps_malloc(
        (size_t)ZBUF_W * ZBUF_H,
        MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
    if (!z_buffer) {
        z_buffer = (uint8_t*)malloc((size_t)ZBUF_W * ZBUF_H);
    }
    return z_buffer != nullptr;
}

static inline void zbuf_clear_far() {
    memset(z_buffer, 0xFF, (size_t)ZBUF_W * ZBUF_H);
}

static inline uint16_t shade_565(uint16_t color, float f) {
    if (f >= 1.0f) return color;
    if (f <= 0.0f) return 0;
    int r = (int)(((color >> 11) & 0x1F) * f);
    int g = (int)(((color >> 5) & 0x3F) * f);
    int b = (int)((color & 0x1F) * f);
    return (uint16_t)((r << 11) | (g << 5) | b);
}

// Fill one horizontal span at scan-line y. xl/xr are integer endpoints
// (inclusive); zl_fp/zr_fp are 16.16 fixed-point encoded depths. Per
// pixel: read z-buffer (SRAM), compare, then only commit z + colour if
// the new depth is nearer. LovyanGFX's sprite buffer stores RGB565 in
// panel byte-order (big-endian for ST7789), so we bswap the colour
// once per span before the inner loop.
__attribute__((hot))
static inline void fill_span_z(
    uint16_t* __restrict fb, int y,
    int xl, int xr, int32_t zl_fp, int32_t zr_fp,
    uint16_t color_be)
{
    if (xl < s_vp_x0) {
        // Clip against viewport left, advance z_fp by the clipped
        // amount so interpolation stays correct.
        int dx = xr - xl;
        if (dx > 0) zl_fp += (int32_t)(((int64_t)(zr_fp - zl_fp) * (s_vp_x0 - xl)) / dx);
        xl = s_vp_x0;
    }
    if (xr > s_vp_x1) xr = s_vp_x1;
    if (xr < xl) return;

    int count = xr - xl + 1;
    int32_t dz_fp = (count > 1) ? (zr_fp - zl_fp) / (count - 1) : 0;

    uint8_t* __restrict zp = &z_buffer[y * ZBUF_W + xl];
    uint16_t* __restrict pp = &fb[y * ZBUF_W + xl];
    int32_t z_fp = zl_fp;

    // No per-pixel clamp: z_fp is guaranteed in [0, 255<<16] by the
    // pre-clamped vertex depths + linear interpolation staying in range.
    for (int i = 0; i < count; i++) {
        uint8_t zb = (uint8_t)(z_fp >> 16);
        if (zb < zp[i]) {
            zp[i] = zb;
            pp[i] = color_be;
        }
        z_fp += dz_fp;
    }
}

// Flat-shaded z-buffered triangle fill. Screen coords are integers and
// z per-vertex is pre-clamped to [0, 255]. Edge walking is done in
// 16.16 fixed point so per-scanline advancement is one integer add
// (no float ops, no float→int conversion). Inner span fill is also
// integer-only fixed-point.
//
// Why fixed-point instead of pure Bresenham (LGFX-style err-accumulator):
//   the pure-integer scheme needs two interleaved accumulators per
//   edge (one for x, one for z) with branch-heavy inner whiles. A 16.16
//   add matches Bresenham's throughput on the ESP32-S3 with far simpler
//   setup and fewer branches.
static void fill_tri_z(
    uint16_t* fb,
    int ax, int ay, int az,
    int bx, int by, int bz,
    int cx, int cy, int cz,
    uint16_t color_be)
{
    // Sort vertices by y ascending (a.y <= b.y <= c.y).
    if (by < ay) { int t=ax;ax=bx;bx=t; t=ay;ay=by;by=t; t=az;az=bz;bz=t; }
    if (cy < ay) { int t=ax;ax=cx;cx=t; t=ay;ay=cy;cy=t; t=az;az=cz;cz=t; }
    if (cy < by) { int t=bx;bx=cx;cx=t; t=by;by=cy;cy=t; t=bz;bz=cz;cz=t; }

    if (cy == ay) return;  // Zero-height
    if (ay > s_vp_y1 || cy < s_vp_y0) return;

    // Long edge A→C: 16.16 step per scanline.
    int32_t dx_ac_fp = (int32_t)(((int64_t)(cx - ax) << 16) / (cy - ay));
    int32_t dz_ac_fp = (int32_t)(((int64_t)(cz - az) << 16) / (cy - ay));

    // Top half: ay → by
    if (by > ay) {
        int32_t dx_ab_fp = (int32_t)(((int64_t)(bx - ax) << 16) / (by - ay));
        int32_t dz_ab_fp = (int32_t)(((int64_t)(bz - az) << 16) / (by - ay));

        int y_start = ay;
        int y_end   = by - 1;
        int clip_top = 0;
        if (y_start < s_vp_y0) { clip_top = s_vp_y0 - y_start; y_start = s_vp_y0; }
        if (y_end > s_vp_y1) y_end = s_vp_y1;

        // Starting positions in 16.16 (shifted up, then advanced past
        // any clipped scanlines).
        int32_t xl_fp = ((int32_t)ax << 16) + dx_ac_fp * clip_top;
        int32_t zl_fp = ((int32_t)az << 16) + dz_ac_fp * clip_top;
        int32_t xr_fp = ((int32_t)ax << 16) + dx_ab_fp * clip_top;
        int32_t zr_fp = ((int32_t)az << 16) + dz_ab_fp * clip_top;

        for (int y = y_start; y <= y_end; y++) {
            int ixl = xl_fp >> 16;
            int ixr = xr_fp >> 16;
            if (ixl <= ixr) {
                fill_span_z(fb, y, ixl, ixr, zl_fp, zr_fp, color_be);
            } else {
                fill_span_z(fb, y, ixr, ixl, zr_fp, zl_fp, color_be);
            }
            xl_fp += dx_ac_fp; zl_fp += dz_ac_fp;
            xr_fp += dx_ab_fp; zr_fp += dz_ab_fp;
        }
    }

    // Bottom half: by → cy
    if (cy > by) {
        int32_t dx_bc_fp = (int32_t)(((int64_t)(cx - bx) << 16) / (cy - by));
        int32_t dz_bc_fp = (int32_t)(((int64_t)(cz - bz) << 16) / (cy - by));

        int y_start = by;
        int y_end   = cy - 1;
        // Continue long-edge accumulator from y=ay (no recompute).
        int32_t xl_fp = ((int32_t)ax << 16) + dx_ac_fp * (y_start - ay);
        int32_t zl_fp = ((int32_t)az << 16) + dz_ac_fp * (y_start - ay);
        int32_t xr_fp = (int32_t)bx << 16;
        int32_t zr_fp = (int32_t)bz << 16;

        int clip_top = 0;
        if (y_start < s_vp_y0) {
            clip_top = s_vp_y0 - y_start;
            y_start = s_vp_y0;
            xl_fp += dx_ac_fp * clip_top;
            zl_fp += dz_ac_fp * clip_top;
            xr_fp += dx_bc_fp * clip_top;
            zr_fp += dz_bc_fp * clip_top;
        }
        if (y_end > s_vp_y1) y_end = s_vp_y1;

        for (int y = y_start; y <= y_end; y++) {
            int ixl = xl_fp >> 16;
            int ixr = xr_fp >> 16;
            if (ixl <= ixr) {
                fill_span_z(fb, y, ixl, ixr, zl_fp, zr_fp, color_be);
            } else {
                fill_span_z(fb, y, ixr, ixl, zr_fp, zl_fp, color_be);
            }
            xl_fp += dx_ac_fp; zl_fp += dz_ac_fp;
            xr_fp += dx_bc_fp; zr_fp += dz_bc_fp;
        }
    }
}

// Project a camera-space triangle, cull back-faces, and z-fill.
// Returns true if the triangle contributed at least one pixel-test.
static inline bool project_and_fill_z(
    uint16_t* fb,
    float cx1, float cy1, float cz1,
    float cx2, float cy2, float cz2,
    float cx3, float cy3, float cz3,
    uint16_t base_color,
    float focal, float cx, float cy, float fog_k, float light,
    int screen_w, int screen_h,
    float inv_near, float inv_span)
{
    float i1 = focal / cz1;
    float i2 = focal / cz2;
    float i3 = focal / cz3;
    float sx1 = cx + cx1 * i1;
    float sy1 = cy - cy1 * i1;
    float sx2 = cx + cx2 * i2;
    float sy2 = cy - cy2 * i2;
    float sx3 = cx + cx3 * i3;
    float sy3 = cy - cy3 * i3;

    // Back-face cull (same convention as scene_render)
    float area2 = (sx2 - sx1) * (sy3 - sy1) - (sx3 - sx1) * (sy2 - sy1);
    if (area2 >= 0) return false;

    float minx = sx1 < sx2 ? (sx1 < sx3 ? sx1 : sx3) : (sx2 < sx3 ? sx2 : sx3);
    float maxx = sx1 > sx2 ? (sx1 > sx3 ? sx1 : sx3) : (sx2 > sx3 ? sx2 : sx3);
    if (maxx < s_vp_x0 || minx > s_vp_x1) return false;
    float miny = sy1 < sy2 ? (sy1 < sy3 ? sy1 : sy3) : (sy2 < sy3 ? sy2 : sy3);
    float maxy = sy1 > sy2 ? (sy1 > sy3 ? sy1 : sy3) : (sy2 > sy3 ? sy2 : sy3);
    if (maxy < s_vp_y0 || miny > s_vp_y1) return false;
    (void)screen_w; (void)screen_h;

    // Sub-pixel triangle reject: the actual filled area is at most half
    // the screen-space bounding box (signed area / 2 ≤ bbox / 2). A
    // bbox area below ~4 px² yields a tri that contributes 0–2 pixels
    // while still paying full setup cost — not worth the triangles.
    // Dominant on dense distant foliage where trunks project to sub-
    // pixel slivers.
    if ((maxx - minx) * (maxy - miny) < 4.0f) return false;

    // Hyperbolic depth encoding — 1/z mapped into [0, 255]. Pre-clamped
    // so the inner loop can skip per-pixel clamping.
    int z1i = (int)((inv_near - 1.0f / cz1) * inv_span * 255.0f);
    int z2i = (int)((inv_near - 1.0f / cz2) * inv_span * 255.0f);
    int z3i = (int)((inv_near - 1.0f / cz3) * inv_span * 255.0f);
    if (z1i < 0) z1i = 0; else if (z1i > 255) z1i = 255;
    if (z2i < 0) z2i = 0; else if (z2i > 255) z2i = 255;
    if (z3i < 0) z3i = 0; else if (z3i > 255) z3i = 255;

    float avg_z = (cz1 + cz2 + cz3) * (1.0f / 3.0f);
    float fog = light / (1.0f + avg_z * fog_k);
    uint16_t col = shade_565(base_color, fog);
    uint16_t col_be = (uint16_t)__builtin_bswap16(col);

    // Screen-space vertex rounding: +0.5 then truncate is a cheap
    // integer-round that matches LGFX's convention for pixel-centre.
    fill_tri_z(fb,
               (int)(sx1 + 0.5f), (int)(sy1 + 0.5f), z1i,
               (int)(sx2 + 0.5f), (int)(sy2 + 0.5f), z2i,
               (int)(sx3 + 0.5f), (int)(sy3 + 0.5f), z3i,
               col_be);
    return true;
}

// @lua ez.display.scene_render_z(scene, px, py, pz, yaw_cos, yaw_sin,
//                                focal, cx, cy, near, fog_k, far) -> int drawn
// @brief Z-buffered alternative to scene_render.
// Clears the z-buffer, then transforms, clips, and z-fills every
// triangle with no painter's-algorithm sort. Colour writes to the
// PSRAM framebuffer only happen for pixels that win the z-test, so
// heavy overdraw (forest, overlapping foliage) costs mostly SRAM
// reads.
// Parameters passed to the scene-render loop. Packaged as a struct so
// the same implementation can be called synchronously from Lua or
// dispatched to the render task on the other core.
struct RenderCtx {
    Scene3D* scene;
    float px, py, pz;
    float yc, ys;
    float focal, cx, cy;
    float nearp, fog_k;
    float farp;
    float light;
    int vp_x, vp_y, vp_w, vp_h;  // clip rect within the framebuffer
    int drawn;  // output
};

// Core of scene_render_z: takes a RenderCtx, runs the full transform →
// clip → z-fill pipeline, writes the triangle count back into the ctx.
// Self-contained so it can run on any core — callers are responsible
// for ensuring zbuf_ensure() was called and the display framebuffer is
// valid before invoking.
static void scene_render_z_run(RenderCtx* ctx)
{
    Scene3D* s = ctx->scene;
    float px = ctx->px, py = ctx->py, pz = ctx->pz;
    float yc = ctx->yc, ys = ctx->ys;
    float focal = ctx->focal, cx = ctx->cx, cy = ctx->cy;
    float nearp = ctx->nearp, fog_k = ctx->fog_k;
    float farp = ctx->farp, light = ctx->light;

    int screen_w = display->getWidth();
    int screen_h = display->getHeight();

    // Push viewport rect into the per-frame globals that fill_tri_z and
    // fill_span_z consult for pixel clipping. Clamp the caller's rect
    // to the physical framebuffer so we can't write out-of-bounds.
    s_vp_x0 = ctx->vp_x;
    s_vp_y0 = ctx->vp_y;
    s_vp_x1 = ctx->vp_x + ctx->vp_w - 1;
    s_vp_y1 = ctx->vp_y + ctx->vp_h - 1;
    if (s_vp_x0 < 0) s_vp_x0 = 0;
    if (s_vp_y0 < 0) s_vp_y0 = 0;
    if (s_vp_x1 > screen_w - 1) s_vp_x1 = screen_w - 1;
    if (s_vp_y1 > screen_h - 1) s_vp_y1 = screen_h - 1;

    zbuf_clear_far();

    uint16_t* fb = (uint16_t*)display->getBuffer().getBuffer();
    if (!fb) { ctx->drawn = 0; return; }

    // Hyperbolic (1/z) depth quantisation — see scene_render_z() Lua
    // docstring for the mapping and rationale.
    float inv_near = 1.0f / nearp;
    float inv_span = 1.0f / (inv_near - 1.0f / farp);
    int drawn = 0;

    const float* buf = s->world_buf.data();
    float far_sq = farp * farp;

    for (size_t i = 0; i < s->tri_count; i++) {
        const float* t = buf + i * 10;
        float wx1 = t[0], wy1 = t[1], wz1 = t[2];
        float wx2 = t[3], wy2 = t[4], wz2 = t[5];
        float wx3 = t[6], wy3 = t[7], wz3 = t[8];
        uint16_t color = (uint16_t)t[9];

        // Two-stage frustum pre-cull: do the cheapest rejection first
        // and skip full camera-space transform for geometry that can't
        // contribute pixels.
        float dx1 = wx1 - px, dz1 = wz1 - pz;
        float dx2 = wx2 - px, dz2 = wz2 - pz;
        float dx3 = wx3 - px, dz3 = wz3 - pz;

        // Stage 1: world far-cull. Squared horizontal distance from
        // camera — if every vertex is beyond `far_sq` the tri is gone.
        float d1 = dx1 * dx1 + dz1 * dz1;
        float d2 = dx2 * dx2 + dz2 * dz2;
        float d3 = dx3 * dx3 + dz3 * dz3;
        if (d1 > far_sq && d2 > far_sq && d3 > far_sq) continue;

        // Stage 2: compute camera-space z only (cheaper than full
        // transform — skips the cx rotation). Reject if every vertex
        // is behind the near plane or beyond the far plane.
        float cz1 = dx1 * ys + dz1 * yc;
        float cz2 = dx2 * ys + dz2 * yc;
        float cz3 = dx3 * ys + dz3 * yc;

        if (cz1 >= farp && cz2 >= farp && cz3 >= farp) continue;
        if (cz1 < nearp && cz2 < nearp && cz3 < nearp) continue;

        // Remaining transform: cx and cy only now that we know the tri
        // might be visible.
        float cx1 = dx1 * yc - dz1 * ys;
        float cy1 = wy1 - py;
        float cx2 = dx2 * yc - dz2 * ys;
        float cy2 = wy2 - py;
        float cx3 = dx3 * yc - dz3 * ys;
        float cy3 = wy3 - py;

        bool in1 = cz1 >= nearp;
        bool in2 = cz2 >= nearp;
        bool in3 = cz3 >= nearp;
        int inside = (in1 ? 1 : 0) + (in2 ? 1 : 0) + (in3 ? 1 : 0);

        if (inside == 3) {
            if (project_and_fill_z(fb,
                    cx1, cy1, cz1, cx2, cy2, cz2, cx3, cy3, cz3,
                    color, focal, cx, cy, fog_k, light, screen_w, screen_h,
                    inv_near, inv_span)) {
                drawn++;
            }
            continue;
        }

        // Partial near-plane clip (same Sutherland-Hodgman as scene_render)
        float pcx[4], pcy[4], pcz[4];
        int n = 0;
        auto emit = [&](float x, float y, float z) {
            pcx[n] = x; pcy[n] = y; pcz[n] = z; n++;
        };
        auto edge = [&](float ax,float ay,float az, float bx,float by,float bz,
                         bool ain, bool bin) {
            if (ain) emit(ax, ay, az);
            if (ain != bin) {
                float tt = (nearp - az) / (bz - az);
                emit(ax + (bx - ax) * tt, ay + (by - ay) * tt, nearp);
            }
        };
        edge(cx1, cy1, cz1, cx2, cy2, cz2, in1, in2);
        edge(cx2, cy2, cz2, cx3, cy3, cz3, in2, in3);
        edge(cx3, cy3, cz3, cx1, cy1, cz1, in3, in1);
        if (n < 3) continue;
        for (int k = 1; k + 1 < n; k++) {
            if (project_and_fill_z(fb,
                    pcx[0], pcy[0], pcz[0],
                    pcx[k], pcy[k], pcz[k],
                    pcx[k+1], pcy[k+1], pcz[k+1],
                    color, focal, cx, cy, fog_k, light, screen_w, screen_h,
                    inv_near, inv_span)) {
                drawn++;
            }
        }
    }

    ctx->drawn = drawn;
}

// Synchronous entry point — unpacks Lua args into a RenderCtx and runs
// the pipeline on the calling thread.
LUA_FUNCTION(l_scene_render_z) {
    RenderCtx ctx;
    ctx.scene = checkScene3D(L, 1);
    ctx.px    = (float)lua_tonumber(L, 2);
    ctx.py    = (float)lua_tonumber(L, 3);
    ctx.pz    = (float)lua_tonumber(L, 4);
    ctx.yc    = (float)lua_tonumber(L, 5);
    ctx.ys    = (float)lua_tonumber(L, 6);
    ctx.focal = (float)lua_tonumber(L, 7);
    ctx.cx    = (float)lua_tonumber(L, 8);
    ctx.cy    = (float)lua_tonumber(L, 9);
    ctx.nearp = (float)lua_tonumber(L, 10);
    ctx.fog_k = (float)lua_tonumber(L, 11);
    ctx.farp  = (float)luaL_optnumber(L, 12, 40.0);
    ctx.light = (float)luaL_optnumber(L, 13, 1.0);
    ctx.vp_x  = (int)luaL_optinteger(L, 14, 0);
    ctx.vp_y  = (int)luaL_optinteger(L, 15, 0);
    ctx.vp_w  = (int)luaL_optinteger(L, 16, display ? display->getWidth() : 320);
    ctx.vp_h  = (int)luaL_optinteger(L, 17, display ? display->getHeight() : 240);
    ctx.drawn = 0;

    if (!display) { lua_pushinteger(L, 0); return 1; }
    if (!zbuf_ensure()) { lua_pushinteger(L, 0); return 1; }
    scene_render_z_run(&ctx);
    lua_pushinteger(L, ctx.drawn);
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
    {"set_font_style",    l_display_set_font_style},
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
    {"draw_wifi",         l_display_draw_wifi},
    {"draw_gps",          l_display_draw_gps},
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
    {"set_clip_rect",     l_display_set_clip_rect},
    {"clear_clip_rect",   l_display_clear_clip_rect},
    {"draw_jpeg",         l_display_draw_jpeg},
    {"draw_png",          l_display_draw_png},
    {"get_image_size",    l_display_get_image_size},
    {"scene_new",                 l_scene_new},
    {"scene_add_tri",             l_scene_add_tri},
    {"scene_add_quad",            l_scene_add_quad},
    {"scene_add_aabb",            l_scene_add_aabb},
    {"scene_add_road_strip",      l_scene_add_road_strip},
    {"scene_add_billboard",       l_scene_add_billboard},
    {"scene_add_billboard_split", l_scene_add_billboard_split},
    {"scene_set_camera",          l_scene_set_camera},
    {"scene_count",               l_scene_count},
    {"scene_mark_static",         l_scene_mark_static},
    {"scene_reset_to",            l_scene_reset_to},
    {"scene_clear",               l_scene_clear},
    {"scene_render",              l_scene_render},
    {"scene_render_z",            l_scene_render_z},
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

    // Register Scene3D metatable (just a GC finalizer — methods are
    // accessed via ez.display.scene_*, not via method-call syntax).
    luaL_newmetatable(L, SCENE3D_METATABLE);
    lua_pushcfunction(L, l_scene_gc);
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
