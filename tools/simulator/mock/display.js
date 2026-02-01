/**
 * Display mock module
 * Maps ez.display functions to HTML5 Canvas
 */

import { FONTS, getFont, renderText, measureText, loadFonts } from '../fonts.js';

// Export loadFonts for initialization
export { loadFonts };

// Convert RGB565 to CSS color
function rgb565ToCSS(color) {
    const r = ((color >> 11) & 0x1F) << 3;
    const g = ((color >> 5) & 0x3F) << 2;
    const b = (color & 0x1F) << 3;
    return `rgb(${r},${g},${b})`;
}

// Convert RGB to RGB565
function rgbToRgb565(r, g, b) {
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

export function createDisplayModule(ctx, canvas) {
    const WIDTH = 320;
    const HEIGHT = 240;

    // Current font state
    let currentFontName = 'medium';
    let currentFont = FONTS.medium || { fallback: true, charWidth: 8, charHeight: 16, yAdvance: 16 };
    let fontSize = 16;

    // Disable antialiasing for crisp pixel-perfect rendering
    ctx.imageSmoothingEnabled = false;
    ctx.webkitImageSmoothingEnabled = false;
    ctx.mozImageSmoothingEnabled = false;
    ctx.msImageSmoothingEnabled = false;

    // Pre-defined colors (RGB565 values)
    const colors = {
        BLACK: 0x0000,
        WHITE: 0xFFFF,
        RED: 0xF800,
        GREEN: 0x07E0,
        BLUE: 0x001F,
        YELLOW: 0xFFE0,
        CYAN: 0x07FF,
        MAGENTA: 0xF81F,
        ORANGE: 0xFD20,
        GRAY: 0x8410,
        DARK_GRAY: 0x4208,
        LIGHT_GRAY: 0xC618,
    };

    const module = {
        // Screen dimensions (uppercase for direct access)
        WIDTH,
        HEIGHT,
        // Screen dimensions (lowercase for Lua compatibility)
        width: WIDTH,
        height: HEIGHT,
        // Character-based dimensions (assuming default 8x16 font)
        cols: Math.floor(WIDTH / 8),   // 40 columns
        rows: Math.floor(HEIGHT / 16), // 15 rows

        // Colors (spread for direct access like ez.display.WHITE)
        ...colors,

        // Colors as nested table (for ez.display.colors.WHITE)
        colors,

        // Create RGB565 color from components
        rgb(r, g, b) {
            return rgbToRgb565(r, g, b);
        },

        // Clear screen with color
        clear(color = 0x0000) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.fillRect(0, 0, WIDTH, HEIGHT);
        },

        // Flush display buffer (no-op in browser - canvas updates immediately)
        flush() {
            // No-op
        },

        // Fill rectangle
        fill_rect(x, y, w, h, color) {
            if (color === undefined) {
                console.warn('[Display] fill_rect called with undefined color at', x, y, w, h);
            }
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.fillRect(Math.floor(x), Math.floor(y), Math.floor(w), Math.floor(h));
        },

        // Draw rectangle outline
        draw_rect(x, y, w, h, color) {
            // Use fill for crisp 1px borders without antialiasing
            const c = rgb565ToCSS(color);
            ctx.fillStyle = c;
            x = Math.floor(x); y = Math.floor(y);
            w = Math.floor(w); h = Math.floor(h);
            ctx.fillRect(x, y, w, 1);           // Top
            ctx.fillRect(x, y + h - 1, w, 1);   // Bottom
            ctx.fillRect(x, y, 1, h);           // Left
            ctx.fillRect(x + w - 1, y, 1, h);   // Right
        },

        // Draw text using bitmap font
        draw_text(x, y, text, color = 0xFFFF) {
            const colorCSS = rgb565ToCSS(color);
            renderText(ctx, currentFont, String(text), Math.floor(x), Math.floor(y), colorCSS);
        },

        // Draw text with background rectangle
        draw_text_bg(x, y, text, fgColor = 0xFFFF, bgColor = 0x0000, padding = 1) {
            const textStr = String(text);
            const textWidth = measureText(ctx, currentFont, textStr);
            const fontHeight = currentFont.yAdvance || 16;
            // Draw background
            ctx.fillStyle = rgb565ToCSS(bgColor);
            ctx.fillRect(
                Math.floor(x - padding),
                Math.floor(y - padding),
                Math.ceil(textWidth + padding * 2),
                Math.ceil(fontHeight + padding * 2)
            );
            // Draw text
            const fgCSS = rgb565ToCSS(fgColor);
            renderText(ctx, currentFont, textStr, Math.floor(x), Math.floor(y), fgCSS);
        },

        // Draw text with shadow offset
        draw_text_shadow(x, y, text, fgColor = 0xFFFF, shadowColor = 0x0000, offset = 1) {
            const textStr = String(text);
            // Draw shadow (offset down and right)
            const shadowCSS = rgb565ToCSS(shadowColor);
            renderText(ctx, currentFont, textStr, Math.floor(x + offset), Math.floor(y + offset), shadowCSS);
            // Draw text on top
            const fgCSS = rgb565ToCSS(fgColor);
            renderText(ctx, currentFont, textStr, Math.floor(x), Math.floor(y), fgCSS);
        },

        // Draw horizontally centered text
        // Lua API: draw_text_centered(y, text, color) - x is calculated to center on screen
        draw_text_centered(y, text, color = 0xFFFF) {
            const textStr = String(text);
            const textWidth = measureText(ctx, currentFont, textStr);
            const x = Math.floor((WIDTH - textWidth) / 2);
            const colorCSS = rgb565ToCSS(color);
            renderText(ctx, currentFont, textStr, x, Math.floor(y), colorCSS);
        },

        // Get text width in pixels
        text_width(text) {
            return Math.ceil(measureText(ctx, currentFont, String(text)));
        },

        // Set font size (can be number or string like "tiny", "small", "medium", "large")
        set_font_size(size) {
            const fallbackFont = { fallback: true, charWidth: 8, charHeight: 16, yAdvance: 16 };
            if (typeof size === 'string') {
                const sizeLower = size.toLowerCase();
                if (sizeLower === 'tiny') {
                    currentFontName = 'tiny';
                    currentFont = FONTS.tiny || fallbackFont;
                    fontSize = 10;
                } else if (sizeLower === 'small') {
                    currentFontName = 'small';
                    currentFont = FONTS.small || fallbackFont;
                    fontSize = 12;
                } else if (sizeLower === 'medium') {
                    currentFontName = 'medium';
                    currentFont = FONTS.medium || fallbackFont;
                    fontSize = 16;
                } else if (sizeLower === 'large') {
                    currentFontName = 'large';
                    currentFont = FONTS.large || fallbackFont;
                    fontSize = 24;
                } else {
                    // Try to parse as number
                    const numSize = parseInt(size, 10);
                    if (numSize <= 10) {
                        currentFontName = 'tiny';
                        currentFont = FONTS.tiny || fallbackFont;
                        fontSize = 10;
                    } else if (numSize <= 12) {
                        currentFontName = 'small';
                        currentFont = FONTS.small || fallbackFont;
                        fontSize = 12;
                    } else if (numSize <= 18) {
                        currentFontName = 'medium';
                        currentFont = FONTS.medium || fallbackFont;
                        fontSize = 16;
                    } else {
                        currentFontName = 'large';
                        currentFont = FONTS.large || fallbackFont;
                        fontSize = 24;
                    }
                }
            } else {
                const numSize = Number(size) || 16;
                if (numSize <= 10) {
                    currentFontName = 'tiny';
                    currentFont = FONTS.tiny || fallbackFont;
                    fontSize = 10;
                } else if (numSize <= 12) {
                    currentFontName = 'small';
                    currentFont = FONTS.small || fallbackFont;
                    fontSize = 12;
                } else if (numSize <= 18) {
                    currentFontName = 'medium';
                    currentFont = FONTS.medium || fallbackFont;
                    fontSize = 16;
                } else {
                    currentFontName = 'large';
                    currentFont = FONTS.large || fallbackFont;
                    fontSize = 24;
                }
            }
        },

        // Get current font size
        get_font_size() {
            return fontSize;
        },

        // Get font width (for monospace, character width)
        get_font_width() {
            return currentFont?.charWidth || 8;
        },

        // Get font height (uses charHeight, not yAdvance, to match device firmware)
        get_font_height() {
            return currentFont?.charHeight || fontSize;
        },

        // Get number of text columns that fit on screen
        get_cols() {
            return Math.floor(WIDTH / (currentFont?.charWidth || 8));
        },

        // Get number of text rows that fit on screen (uses charHeight to match device)
        get_rows() {
            return Math.floor(HEIGHT / (currentFont?.charHeight || fontSize));
        },

        // Draw line
        draw_line(x1, y1, x2, y2, color) {
            // Bresenham's line algorithm for crisp pixel lines
            x1 = Math.floor(x1); y1 = Math.floor(y1);
            x2 = Math.floor(x2); y2 = Math.floor(y2);
            ctx.fillStyle = rgb565ToCSS(color);
            const dx = Math.abs(x2 - x1);
            const dy = Math.abs(y2 - y1);
            const sx = x1 < x2 ? 1 : -1;
            const sy = y1 < y2 ? 1 : -1;
            let err = dx - dy;
            while (true) {
                ctx.fillRect(x1, y1, 1, 1);
                if (x1 === x2 && y1 === y2) break;
                const e2 = 2 * err;
                if (e2 > -dy) { err -= dy; x1 += sx; }
                if (e2 < dx) { err += dx; y1 += sy; }
            }
        },

        // Draw horizontal line
        draw_hline(x, y, w, color) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.fillRect(Math.floor(x), Math.floor(y), Math.floor(w), 1);
        },

        // Draw vertical line
        draw_vline(x, y, h, color) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.fillRect(Math.floor(x), Math.floor(y), 1, Math.floor(h));
        },

        // Draw single pixel
        draw_pixel(x, y, color) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.fillRect(Math.floor(x), Math.floor(y), 1, 1);
        },

        // Draw circle outline
        draw_circle(cx, cy, r, color) {
            // Midpoint circle algorithm for crisp pixel circles
            cx = Math.floor(cx); cy = Math.floor(cy); r = Math.floor(r);
            ctx.fillStyle = rgb565ToCSS(color);
            let x = r, y = 0, err = 0;
            while (x >= y) {
                ctx.fillRect(cx + x, cy + y, 1, 1);
                ctx.fillRect(cx + y, cy + x, 1, 1);
                ctx.fillRect(cx - y, cy + x, 1, 1);
                ctx.fillRect(cx - x, cy + y, 1, 1);
                ctx.fillRect(cx - x, cy - y, 1, 1);
                ctx.fillRect(cx - y, cy - x, 1, 1);
                ctx.fillRect(cx + y, cy - x, 1, 1);
                ctx.fillRect(cx + x, cy - y, 1, 1);
                y++;
                err += 1 + 2 * y;
                if (2 * (err - x) + 1 > 0) { x--; err += 1 - 2 * x; }
            }
        },

        // Fill circle
        fill_circle(cx, cy, r, color) {
            // Filled circle using horizontal spans
            cx = Math.floor(cx); cy = Math.floor(cy); r = Math.floor(r);
            ctx.fillStyle = rgb565ToCSS(color);
            let x = r, y = 0, err = 0;
            while (x >= y) {
                ctx.fillRect(cx - x, cy + y, 2 * x + 1, 1);
                ctx.fillRect(cx - x, cy - y, 2 * x + 1, 1);
                ctx.fillRect(cx - y, cy + x, 2 * y + 1, 1);
                ctx.fillRect(cx - y, cy - x, 2 * y + 1, 1);
                y++;
                err += 1 + 2 * y;
                if (2 * (err - x) + 1 > 0) { x--; err += 1 - 2 * x; }
            }
        },

        // Draw rounded rectangle
        draw_rounded_rect(x, y, w, h, r, color) {
            x = Math.floor(x); y = Math.floor(y);
            w = Math.floor(w); h = Math.floor(h); r = Math.floor(r);
            ctx.fillStyle = rgb565ToCSS(color);
            // Horizontal lines
            ctx.fillRect(x + r, y, w - 2 * r, 1);
            ctx.fillRect(x + r, y + h - 1, w - 2 * r, 1);
            // Vertical lines
            ctx.fillRect(x, y + r, 1, h - 2 * r);
            ctx.fillRect(x + w - 1, y + r, 1, h - 2 * r);
            // Corner arcs using midpoint circle algorithm
            const drawCornerArc = (cx, cy, quadrant) => {
                let px = r, py = 0, err = 0;
                while (px >= py) {
                    const points = [
                        [cx + px, cy - py], [cx + py, cy - px],  // Q0: top-right
                        [cx - py, cy - px], [cx - px, cy - py],  // Q1: top-left
                        [cx - px, cy + py], [cx - py, cy + px],  // Q2: bottom-left
                        [cx + py, cy + px], [cx + px, cy + py],  // Q3: bottom-right
                    ];
                    const start = quadrant * 2;
                    ctx.fillRect(points[start][0], points[start][1], 1, 1);
                    ctx.fillRect(points[start + 1][0], points[start + 1][1], 1, 1);
                    py++;
                    err += 1 + 2 * py;
                    if (2 * (err - px) + 1 > 0) { px--; err += 1 - 2 * px; }
                }
            };
            drawCornerArc(x + w - 1 - r, y + r, 0);         // Top-right
            drawCornerArc(x + r, y + r, 1);                 // Top-left
            drawCornerArc(x + r, y + h - 1 - r, 2);         // Bottom-left
            drawCornerArc(x + w - 1 - r, y + h - 1 - r, 3); // Bottom-right
        },

        // Fill rounded rectangle
        fill_rounded_rect(x, y, w, h, r, color) {
            x = Math.floor(x); y = Math.floor(y);
            w = Math.floor(w); h = Math.floor(h); r = Math.floor(r);
            // Clamp radius to half the minimum dimension
            r = Math.min(r, Math.floor(w / 2), Math.floor(h / 2));
            if (r <= 0) {
                ctx.fillStyle = rgb565ToCSS(color);
                ctx.fillRect(x, y, w, h);
                return;
            }
            ctx.fillStyle = rgb565ToCSS(color);
            // Main body rectangles (non-overlapping)
            ctx.fillRect(x + r, y, w - 2 * r, h);         // Center column
            ctx.fillRect(x, y + r, r, h - 2 * r);         // Left side
            ctx.fillRect(x + w - r, y + r, r, h - 2 * r); // Right side
            // Fill corner quadrants using midpoint circle algorithm
            // Each quadrant only fills its respective corner area
            const fillQuadrant = (cx, cy, quadrant) => {
                // quadrant: 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right
                let px = r, py = 0, err = 0;
                while (px >= py) {
                    // Draw horizontal spans for the quadrant
                    if (quadrant === 0) {
                        // Top-left: draw from cx-px to cx, at cy-py and cy-px
                        ctx.fillRect(cx - px, cy - py, px + 1, 1);
                        ctx.fillRect(cx - py, cy - px, py + 1, 1);
                    } else if (quadrant === 1) {
                        // Top-right: draw from cx to cx+px, at cy-py and cy-px
                        ctx.fillRect(cx, cy - py, px + 1, 1);
                        ctx.fillRect(cx, cy - px, py + 1, 1);
                    } else if (quadrant === 2) {
                        // Bottom-left: draw from cx-px to cx, at cy+py and cy+px
                        ctx.fillRect(cx - px, cy + py, px + 1, 1);
                        ctx.fillRect(cx - py, cy + px, py + 1, 1);
                    } else {
                        // Bottom-right: draw from cx to cx+px, at cy+py and cy+px
                        ctx.fillRect(cx, cy + py, px + 1, 1);
                        ctx.fillRect(cx, cy + px, py + 1, 1);
                    }
                    py++;
                    err += 1 + 2 * py;
                    if (2 * (err - px) + 1 > 0) { px--; err += 1 - 2 * px; }
                }
            };
            fillQuadrant(x + r - 1, y + r - 1, 0);             // Top-left
            fillQuadrant(x + w - r, y + r - 1, 1);             // Top-right
            fillQuadrant(x + r - 1, y + h - r, 2);             // Bottom-left
            fillQuadrant(x + w - r, y + h - r, 3);             // Bottom-right
        },

        // Draw triangle outline
        draw_triangle(x1, y1, x2, y2, x3, y3, color) {
            // Draw three lines using the line function
            module.draw_line(x1, y1, x2, y2, color);
            module.draw_line(x2, y2, x3, y3, color);
            module.draw_line(x3, y3, x1, y1, color);
        },

        // Fill triangle
        fill_triangle(x1, y1, x2, y2, x3, y3, color) {
            x1 = Math.floor(x1); y1 = Math.floor(y1);
            x2 = Math.floor(x2); y2 = Math.floor(y2);
            x3 = Math.floor(x3); y3 = Math.floor(y3);
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.beginPath();
            ctx.moveTo(x1, y1);
            ctx.lineTo(x2, y2);
            ctx.lineTo(x3, y3);
            ctx.closePath();
            ctx.fill();
        },

        // Draw 1-bit bitmap (monochrome icons) with optional scaling
        // Lua API: draw_bitmap_1bit(x, y, width, height, data, scale, color)
        // scale defaults to 1, color defaults to WHITE (0xFFFF)
        // data can be a string (from C++) or Lua table of bytes (from simulator)
        draw_bitmap_1bit(x, y, w, h, data, scale = 1, color = 0xFFFF) {
            if (!data) return;

            // Determine how to access bytes based on data type
            let getByteAt;
            let dataLen;

            if (typeof data === 'string') {
                // JavaScript string - use charCodeAt (works for C++ native strings)
                getByteAt = (idx) => data.charCodeAt(idx);
                dataLen = data.length;
            } else if (data instanceof Uint8Array || Array.isArray(data)) {
                // Typed array or JS array
                getByteAt = (idx) => data[idx];
                dataLen = data.length;
            } else if (typeof data === 'object' && data !== null) {
                // Lua table from Wasmoon (1-indexed object with numeric keys)
                // Count numeric keys to get length
                const numericKeys = Object.keys(data).filter(k => !isNaN(k) && k > 0);
                dataLen = numericKeys.length;
                if (dataLen === 0) return;
                // Lua tables are 1-indexed
                getByteAt = (idx) => data[idx + 1] || 0;
            } else {
                return;
            }

            if (dataLen === 0) return;

            x = Math.floor(x); y = Math.floor(y);
            scale = Math.floor(scale) || 1;
            ctx.fillStyle = rgb565ToCSS(color);

            // Each bit represents a pixel, 8 pixels per byte
            let byteIdx = 0;
            let bitIdx = 7;  // MSB first

            for (let py = 0; py < h; py++) {
                for (let px = 0; px < w; px++) {
                    if (byteIdx >= dataLen) return;

                    const byte = getByteAt(byteIdx);
                    const bit = (byte >> bitIdx) & 1;

                    if (bit) {
                        // Draw scaled pixel (scale x scale rectangle)
                        ctx.fillRect(x + px * scale, y + py * scale, scale, scale);
                    }

                    bitIdx--;
                    if (bitIdx < 0) {
                        bitIdx = 7;
                        byteIdx++;
                    }
                }
            }
        },

        // Draw bitmap (RGB565 data)
        draw_bitmap(x, y, w, h, data) {
            if (!data || data.length === 0) return;

            const imageData = ctx.createImageData(w, h);
            const pixels = imageData.data;

            for (let i = 0; i < w * h && i * 2 + 1 < data.length; i++) {
                // RGB565 is little-endian
                const lo = data.charCodeAt(i * 2);
                const hi = data.charCodeAt(i * 2 + 1);
                const color = (hi << 8) | lo;

                const r = ((color >> 11) & 0x1F) << 3;
                const g = ((color >> 5) & 0x3F) << 2;
                const b = (color & 0x1F) << 3;

                pixels[i * 4] = r;
                pixels[i * 4 + 1] = g;
                pixels[i * 4 + 2] = b;
                pixels[i * 4 + 3] = 255;
            }

            ctx.putImageData(imageData, x, y);
        },

        // Draw indexed bitmap (3-bit palette)
        // Matches the packing format from Python process.py:
        //   b0 = p[0] | (p[1] << 3) | ((p[2] & 0x03) << 6)
        //   b1 = ((p[2] >> 2) & 0x01) | (p[3] << 1) | (p[4] << 4) | ((p[5] & 0x01) << 7)
        //   b2 = ((p[5] >> 1) & 0x03) | (p[6] << 2) | (p[7] << 5)
        draw_indexed_bitmap(x, y, w, h, data, palette) {
            if (!data || data.length === 0) {
                console.warn(`[Display] draw_indexed_bitmap: no data`);
                return;
            }

            const isString = typeof data.charCodeAt === 'function';

            // Detect indexing mode for Wasmoon userdata (1-indexed vs 0-indexed)
            // Check if data[0] is undefined but data[1] exists, indicating 1-indexed
            let dataOffset = 0;
            if (!isString) {
                if (data[0] === undefined && data[1] !== undefined) {
                    dataOffset = 1;  // 1-indexed (Wasmoon Lua tables)
                }
            }

            // Helper function to get byte value at index
            // Handles strings, arrays, and Lua userdata objects (from Wasmoon)
            const getByte = isString
                ? (idx) => data.charCodeAt(idx)
                : (idx) => {
                    const val = data[idx + dataOffset];
                    return (val !== undefined ? val : 0) & 0xFF;
                };

            // Detect palette indexing mode (palette indices are 0-7 for 3-bit)
            let paletteOffset = 0;
            if (palette && palette[0] === undefined && palette[1] !== undefined) {
                paletteOffset = 1;  // 1-indexed palette
            }

            // Helper to get palette color
            const getColor = (idx) => {
                if (!palette) return 0;
                const color = palette[idx + paletteOffset];
                return color !== undefined ? color : 0;
            };

            const imageData = ctx.createImageData(w, h);
            const pixels = imageData.data;

            // Decode 3-bit indexed data - 8 pixels packed into 3 bytes (LSB-first)
            // Unpacking (reverse of Python packing):
            //   p0 = (b0 >> 0) & 0x07
            //   p1 = (b0 >> 3) & 0x07
            //   p2 = ((b0 >> 6) & 0x03) | ((b1 & 0x01) << 2)
            //   p3 = (b1 >> 1) & 0x07
            //   p4 = (b1 >> 4) & 0x07
            //   p5 = ((b1 >> 7) & 0x01) | ((b2 & 0x03) << 1)
            //   p6 = (b2 >> 2) & 0x07
            //   p7 = (b2 >> 5) & 0x07
            const totalPixels = w * h;
            let pixelIdx = 0;
            let byteIdx = 0;

            while (pixelIdx < totalPixels) {
                const b0 = getByte(byteIdx);
                const b1 = getByte(byteIdx + 1);
                const b2 = getByte(byteIdx + 2);
                byteIdx += 3;

                // Unpack 8 pixels from 3 bytes
                const p = [
                    (b0 >> 0) & 0x07,
                    (b0 >> 3) & 0x07,
                    ((b0 >> 6) & 0x03) | ((b1 & 0x01) << 2),
                    (b1 >> 1) & 0x07,
                    (b1 >> 4) & 0x07,
                    ((b1 >> 7) & 0x01) | ((b2 & 0x03) << 1),
                    (b2 >> 2) & 0x07,
                    (b2 >> 5) & 0x07,
                ];

                // Write pixels to image data
                for (let j = 0; j < 8 && pixelIdx < totalPixels; j++, pixelIdx++) {
                    const colorIdx = p[j];
                    const color = getColor(colorIdx);
                    // BGR565: BBBBBGGGGGGRRRRR
                    const b = ((color >> 11) & 0x1F) << 3;
                    const g = ((color >> 5) & 0x3F) << 2;
                    const r = (color & 0x1F) << 3;

                    pixels[pixelIdx * 4] = r;
                    pixels[pixelIdx * 4 + 1] = g;
                    pixels[pixelIdx * 4 + 2] = b;
                    pixels[pixelIdx * 4 + 3] = 255;
                }
            }

            ctx.putImageData(imageData, x, y);
        },

        // Draw scaled indexed bitmap (for map tile fallback rendering)
        // Shows a scaled-up portion of a parent tile while child tile loads
        draw_indexed_bitmap_scaled(x, y, dest_w, dest_h, data, palette, src_x, src_y, src_w, src_h) {
            if (!data || data.length === 0) {
                return;
            }

            const SRC_SIZE = 256;  // Source bitmap is always 256x256
            const isString = typeof data.charCodeAt === 'function';

            // Detect indexing mode
            let dataOffset = 0;
            if (!isString) {
                if (data[0] === undefined && data[1] !== undefined) {
                    dataOffset = 1;
                }
            }

            const getByte = isString
                ? (idx) => data.charCodeAt(idx)
                : (idx) => {
                    const val = data[idx + dataOffset];
                    return (val !== undefined ? val : 0) & 0xFF;
                };

            // Palette handling
            let paletteOffset = 0;
            if (palette && palette[0] === undefined && palette[1] !== undefined) {
                paletteOffset = 1;
            }

            const getColor = (idx) => {
                if (!palette) return 0;
                const color = palette[idx + paletteOffset];
                return color !== undefined ? color : 0;
            };

            // Get pixel from source bitmap at (px, py)
            const getPixel = (px, py) => {
                if (px < 0 || px >= SRC_SIZE || py < 0 || py >= SRC_SIZE) {
                    return getColor(0);
                }
                const pixelIndex = py * SRC_SIZE + px;
                const groupIndex = Math.floor(pixelIndex / 8);
                const pixelInGroup = pixelIndex % 8;
                const byteOffset = groupIndex * 3;

                const b0 = getByte(byteOffset);
                const b1 = getByte(byteOffset + 1);
                const b2 = getByte(byteOffset + 2);

                let paletteIndex;
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
                return getColor(paletteIndex);
            };

            // Create scaled image
            const imageData = ctx.createImageData(dest_w, dest_h);
            const pixels = imageData.data;

            // Scale factors
            const scaleX = src_w / dest_w;
            const scaleY = src_h / dest_h;

            for (let dy = 0; dy < dest_h; dy++) {
                const srcY = Math.floor(src_y + dy * scaleY);
                for (let dx = 0; dx < dest_w; dx++) {
                    const srcX = Math.floor(src_x + dx * scaleX);
                    const color = getPixel(srcX, srcY);

                    // BGR565: BBBBBGGGGGGRRRRR
                    const b = ((color >> 11) & 0x1F) << 3;
                    const g = ((color >> 5) & 0x3F) << 2;
                    const r = (color & 0x1F) << 3;

                    const idx = (dy * dest_w + dx) * 4;
                    pixels[idx] = r;
                    pixels[idx + 1] = g;
                    pixels[idx + 2] = b;
                    pixels[idx + 3] = 255;
                }
            }

            ctx.putImageData(imageData, x, y);
        },

        // Set clip region
        set_clip(x, y, w, h) {
            ctx.save();
            ctx.beginPath();
            ctx.rect(x, y, w, h);
            ctx.clip();
        },

        // Clear clip region
        clear_clip() {
            ctx.restore();
        },

        // Get pixel color at position
        get_pixel(x, y) {
            const imageData = ctx.getImageData(x, y, 1, 1);
            const [r, g, b] = imageData.data;
            return rgbToRgb565(r, g, b);
        },

        // Get screen width
        get_width() {
            return WIDTH;
        },

        // Get screen height
        get_height() {
            return HEIGHT;
        },

        // Set brightness (no-op in browser)
        set_brightness(level) {
            // Silent in simulator - brightness changes don't affect canvas
            return true;
        },

        // Get brightness
        get_brightness() {
            return 200;
        },

        // Draw bitmap with transparency
        draw_bitmap_transparent(x, y, w, h, data, transparentColor) {
            if (!data || data.length === 0) return;

            const imageData = ctx.createImageData(w, h);
            const pixels = imageData.data;

            for (let i = 0; i < w * h && i * 2 + 1 < data.length; i++) {
                // RGB565 is little-endian
                const lo = data.charCodeAt(i * 2);
                const hi = data.charCodeAt(i * 2 + 1);
                const color = (hi << 8) | lo;

                // Skip transparent pixels
                if (color === transparentColor) {
                    pixels[i * 4 + 3] = 0; // Alpha = 0
                    continue;
                }

                const r = ((color >> 11) & 0x1F) << 3;
                const g = ((color >> 5) & 0x3F) << 2;
                const b = (color & 0x1F) << 3;

                pixels[i * 4] = r;
                pixels[i * 4 + 1] = g;
                pixels[i * 4 + 2] = b;
                pixels[i * 4 + 3] = 255;
            }

            ctx.putImageData(imageData, x, y);
        },

        // Save screenshot (simulated - logs to console)
        save_screenshot(path) {
            console.log(`[Screenshot] Would save to: ${path}`);
            // In a real browser environment, we could use canvas.toBlob() and download
            // For simulation, just return success
            return true;
        },
    };

    // Aliases for Lua compatibility (some code uses draw_round_rect instead of draw_rounded_rect)
    module.draw_round_rect = module.draw_rounded_rect;
    module.fill_round_rect = module.fill_rounded_rect;

    return module;
}
