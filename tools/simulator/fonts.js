/**
 * Bitmap font loader for T-Deck OS Simulator
 * Loads and parses the actual GFX font files used by the firmware
 */

// Font file paths relative to the simulator directory
// From tools/simulator/ we need ../../ to reach project root
const FONT_PATHS = {
    tiny: '../../src/fonts/FreeMono5pt7b.h',
    small: '../../.pio/libdeps/t-deck-plus/LovyanGFX/src/lgfx/Fonts/GFXFF/FreeMono9pt7b.h',
    medium: '../../.pio/libdeps/t-deck-plus/LovyanGFX/src/lgfx/Fonts/GFXFF/FreeMono12pt7b.h',
    large: '../../.pio/libdeps/t-deck-plus/LovyanGFX/src/lgfx/Fonts/GFXFF/FreeMono18pt7b.h'
};

// Font metrics (charWidth, charHeight, yAdvance)
const FONT_METRICS = {
    tiny: { charWidth: 6, charHeight: 10, yAdvance: 10 },
    small: { charWidth: 7, charHeight: 12, yAdvance: 15 },
    medium: { charWidth: 8, charHeight: 16, yAdvance: 24 },
    large: { charWidth: 12, charHeight: 24, yAdvance: 32 }
};

// Parsed fonts cache
export const FONTS = {
    tiny: null,
    small: null,
    medium: null,
    large: null
};

// Loading state
let fontsLoaded = false;
let loadingPromise = null;

/**
 * Parse a C++ header file containing GFX font data
 * Handles format: FreeMono5pt7bBitmaps[], FreeMono5pt7bGlyphs[]
 */
function parseGFXFont(headerContent, name) {
    const font = {
        bitmaps: null,
        glyphs: [],
        first: 0x20,
        last: 0x7E,
        ...FONT_METRICS[name]
    };

    // Extract all hex bytes from the Bitmaps array (matches *Bitmaps[] pattern)
    const bitmapMatch = headerContent.match(/\w+Bitmaps\[\]/);
    if (bitmapMatch) {
        const bitmapStart = bitmapMatch.index;
        const bitmapEnd = headerContent.indexOf('};', bitmapStart);
        if (bitmapEnd !== -1) {
            const bitmapSection = headerContent.slice(bitmapStart, bitmapEnd + 2);
            const hexBytes = bitmapSection.match(/0x[0-9A-Fa-f]{2}/g);
            if (hexBytes) {
                font.bitmaps = new Uint8Array(hexBytes.map(h => parseInt(h, 16)));
            }
        }
    }

    // Extract all glyph entries (matches *Glyphs[] pattern)
    const glyphMatch = headerContent.match(/\w+Glyphs\[\]/);
    if (glyphMatch) {
        const glyphStart = glyphMatch.index;
        const glyphEnd = headerContent.indexOf('};', glyphStart);
        if (glyphEnd !== -1) {
            const glyphSection = headerContent.slice(glyphStart, glyphEnd + 2);
            // Match entries like { 0, 1, 1, 6, 0, -5 }
            const glyphEntries = glyphSection.match(/\{\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*\d+\s*,\s*-?\d+\s*,\s*-?\d+\s*\}/g);
            if (glyphEntries) {
                font.glyphs = glyphEntries.map(entry => {
                    const nums = entry.match(/-?\d+/g).map(Number);
                    return nums; // [offset, width, height, xAdvance, xOffset, yOffset]
                });
            }
        }
    }

    // Extract yAdvance from font struct (last number before closing brace)
    const fontMatch = headerContent.match(/0x20\s*,\s*0x7E\s*,\s*(\d+)\s*\}/);
    if (fontMatch) {
        font.yAdvance = parseInt(fontMatch[1], 10);
    }

    console.log(`[Fonts] Parsed ${name}: ${font.bitmaps?.length || 0} bytes, ${font.glyphs.length} glyphs, yAdvance=${font.yAdvance}`);
    return font;
}

/**
 * Load all fonts from the C++ header files
 */
export async function loadFonts() {
    if (fontsLoaded) return FONTS;
    if (loadingPromise) return loadingPromise;

    loadingPromise = (async () => {
        const entries = Object.entries(FONT_PATHS);

        for (const [name, path] of entries) {
            try {
                const response = await fetch(path);
                if (response.ok) {
                    const content = await response.text();
                    FONTS[name] = parseGFXFont(content, name);
                    console.log(`[Fonts] Loaded ${name} font: ${FONTS[name].glyphs.length} glyphs`);
                } else {
                    console.warn(`[Fonts] Failed to load ${name}: ${response.status}`);
                    // Create fallback
                    FONTS[name] = { fallback: true, ...FONT_METRICS[name] };
                }
            } catch (e) {
                console.warn(`[Fonts] Error loading ${name}:`, e.message);
                FONTS[name] = { fallback: true, ...FONT_METRICS[name] };
            }
        }

        fontsLoaded = true;
        return FONTS;
    })();

    return loadingPromise;
}

/**
 * Render a single glyph from bitmap font data
 */
export function renderGlyph(ctx, font, charCode, x, y, color) {
    if (!font || !font.bitmaps || !font.glyphs) {
        return font?.charWidth || 8;
    }

    if (charCode < font.first || charCode > font.last) {
        return font.charWidth;
    }

    const glyphIndex = charCode - font.first;
    const glyph = font.glyphs[glyphIndex];

    if (!glyph) {
        return font.charWidth;
    }

    const [offset, width, height, xAdvance, xOffset, yOffset] = glyph;

    if (width === 0 || height === 0) {
        return xAdvance;
    }

    const drawX = Math.floor(x + xOffset);
    const drawY = Math.floor(y + yOffset);

    ctx.fillStyle = color;

    let bitIndex = 0;
    const bitmaps = font.bitmaps;

    for (let row = 0; row < height; row++) {
        for (let col = 0; col < width; col++) {
            const byteIndex = offset + Math.floor(bitIndex / 8);
            const bitPosition = 7 - (bitIndex % 8);

            if (byteIndex < bitmaps.length) {
                const bit = (bitmaps[byteIndex] >> bitPosition) & 1;
                if (bit) {
                    ctx.fillRect(drawX + col, drawY + row, 1, 1);
                }
            }
            bitIndex++;
        }
    }

    return xAdvance;
}

/**
 * Render text using bitmap font
 */
export function renderText(ctx, font, text, x, y, color) {
    if (!text) return 0;

    // Fallback to canvas text if font not loaded
    if (!font || font.fallback || !font.bitmaps) {
        ctx.fillStyle = color;
        ctx.font = `${font?.charHeight || 16}px monospace`;
        ctx.textBaseline = 'top';
        ctx.fillText(text, x, y);
        return ctx.measureText(text).width;
    }

    // Bitmap rendering
    // The y coordinate should be the TOP of the text bounding box.
    // GFX glyphs use negative yOffset to position above baseline.
    // Use charHeight (typical glyph height) to calculate baseline position.
    const baseline = y + (font.charHeight || Math.floor(font.yAdvance * 0.67));
    let cursorX = x;

    for (let i = 0; i < text.length; i++) {
        const charCode = text.charCodeAt(i);
        const advance = renderGlyph(ctx, font, charCode, cursorX, baseline, color);
        cursorX += advance;
    }

    return cursorX - x;
}

/**
 * Measure text width
 */
export function measureText(ctx, font, text) {
    if (!text) return 0;

    if (!font || font.fallback || !font.bitmaps) {
        ctx.font = `${font?.charHeight || 16}px monospace`;
        return ctx.measureText(text).width;
    }

    let width = 0;
    for (let i = 0; i < text.length; i++) {
        const charCode = text.charCodeAt(i);
        if (charCode >= font.first && charCode <= font.last) {
            const glyph = font.glyphs[charCode - font.first];
            width += glyph ? glyph[3] : font.charWidth;
        } else {
            width += font.charWidth;
        }
    }
    return width;
}

/**
 * Get font by size name
 */
export function getFont(size) {
    const sizeName = typeof size === 'string' ? size.toLowerCase() : 'medium';
    return FONTS[sizeName] || FONTS.medium;
}
