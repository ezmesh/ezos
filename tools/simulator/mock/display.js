/**
 * Display mock module
 * Maps tdeck.display functions to HTML5 Canvas
 */

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

    let currentFont = '16px monospace';
    let fontSize = 16;

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
        // Screen dimensions
        WIDTH,
        HEIGHT,

        // Colors
        ...colors,

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
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.fillRect(x, y, w, h);
        },

        // Draw rectangle outline
        draw_rect(x, y, w, h, color) {
            ctx.strokeStyle = rgb565ToCSS(color);
            ctx.lineWidth = 1;
            ctx.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1);
        },

        // Draw text
        draw_text(x, y, text, color = 0xFFFF) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.font = currentFont;
            ctx.textBaseline = 'top';
            ctx.fillText(String(text), x, y);
        },

        // Draw centered text
        draw_text_centered(x, y, text, color = 0xFFFF) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.font = currentFont;
            ctx.textBaseline = 'top';
            ctx.textAlign = 'center';
            ctx.fillText(String(text), x, y);
            ctx.textAlign = 'left';
        },

        // Get text width in pixels
        text_width(text) {
            ctx.font = currentFont;
            return Math.ceil(ctx.measureText(String(text)).width);
        },

        // Set font size
        set_font_size(size) {
            fontSize = size;
            currentFont = `${size}px monospace`;
        },

        // Get current font size
        get_font_size() {
            return fontSize;
        },

        // Draw line
        draw_line(x1, y1, x2, y2, color) {
            ctx.strokeStyle = rgb565ToCSS(color);
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(x1 + 0.5, y1 + 0.5);
            ctx.lineTo(x2 + 0.5, y2 + 0.5);
            ctx.stroke();
        },

        // Draw horizontal line
        draw_hline(x, y, w, color) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.fillRect(x, y, w, 1);
        },

        // Draw vertical line
        draw_vline(x, y, h, color) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.fillRect(x, y, 1, h);
        },

        // Draw single pixel
        draw_pixel(x, y, color) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.fillRect(x, y, 1, 1);
        },

        // Draw circle outline
        draw_circle(cx, cy, r, color) {
            ctx.strokeStyle = rgb565ToCSS(color);
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.arc(cx, cy, r, 0, Math.PI * 2);
            ctx.stroke();
        },

        // Fill circle
        fill_circle(cx, cy, r, color) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.beginPath();
            ctx.arc(cx, cy, r, 0, Math.PI * 2);
            ctx.fill();
        },

        // Draw rounded rectangle
        draw_rounded_rect(x, y, w, h, r, color) {
            ctx.strokeStyle = rgb565ToCSS(color);
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.roundRect(x + 0.5, y + 0.5, w - 1, h - 1, r);
            ctx.stroke();
        },

        // Fill rounded rectangle
        fill_rounded_rect(x, y, w, h, r, color) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.beginPath();
            ctx.roundRect(x, y, w, h, r);
            ctx.fill();
        },

        // Draw triangle outline
        draw_triangle(x1, y1, x2, y2, x3, y3, color) {
            ctx.strokeStyle = rgb565ToCSS(color);
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(x1 + 0.5, y1 + 0.5);
            ctx.lineTo(x2 + 0.5, y2 + 0.5);
            ctx.lineTo(x3 + 0.5, y3 + 0.5);
            ctx.closePath();
            ctx.stroke();
        },

        // Fill triangle
        fill_triangle(x1, y1, x2, y2, x3, y3, color) {
            ctx.fillStyle = rgb565ToCSS(color);
            ctx.beginPath();
            ctx.moveTo(x1, y1);
            ctx.lineTo(x2, y2);
            ctx.lineTo(x3, y3);
            ctx.closePath();
            ctx.fill();
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
        draw_indexed_bitmap(x, y, w, h, data, palette) {
            if (!data || data.length === 0) return;

            const imageData = ctx.createImageData(w, h);
            const pixels = imageData.data;

            // Decode 3-bit indexed data
            let bitPos = 0;
            for (let i = 0; i < w * h; i++) {
                const byteIdx = Math.floor(bitPos / 8);
                const bitOffset = bitPos % 8;

                if (byteIdx >= data.length) break;

                let colorIdx;
                if (bitOffset <= 5) {
                    colorIdx = (data.charCodeAt(byteIdx) >> (5 - bitOffset)) & 0x07;
                } else {
                    const bitsFromFirstByte = 8 - bitOffset;
                    const bitsFromSecondByte = 3 - bitsFromFirstByte;
                    colorIdx = ((data.charCodeAt(byteIdx) & ((1 << bitsFromFirstByte) - 1)) << bitsFromSecondByte);
                    if (byteIdx + 1 < data.length) {
                        colorIdx |= (data.charCodeAt(byteIdx + 1) >> (8 - bitsFromSecondByte));
                    }
                }

                bitPos += 3;

                // Get color from palette
                const color = palette && palette[colorIdx] !== undefined ? palette[colorIdx] : 0;
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
    };

    return module;
}
