#include "aa_font.h"

#include <LovyanGFX.hpp>

namespace aa_font {

// RGB565 alpha-over blend. `a` is the foreground coverage (0..255).
// Using 32-bit arithmetic keeps the intermediate multiplications exact and
// the rounding (+127) matches PIL's compositing.
static inline uint16_t blend565(uint16_t bg, uint16_t fg, uint8_t a) {
    uint32_t bg_r = (bg >> 11) & 0x1F;
    uint32_t bg_g = (bg >> 5) & 0x3F;
    uint32_t bg_b = bg & 0x1F;
    uint32_t fg_r = (fg >> 11) & 0x1F;
    uint32_t fg_g = (fg >> 5) & 0x3F;
    uint32_t fg_b = fg & 0x1F;
    uint32_t ai = a;
    uint32_t bi = 255 - a;
    uint32_t r = (fg_r * ai + bg_r * bi + 127) / 255;
    uint32_t g = (fg_g * ai + bg_g * bi + 127) / 255;
    uint32_t b = (fg_b * ai + bg_b * bi + 127) / 255;
    return static_cast<uint16_t>((r << 11) | (g << 5) | b);
}

void drawChar(LGFX_Sprite& buf, int x, int y_top, char c,
              uint16_t color, const Font& f) {
    uint8_t uc = static_cast<uint8_t>(c);
    if (uc < f.first || uc > f.last) return;

    const Glyph& g = f.glyphs[uc - f.first];
    if (g.w == 0 || g.h == 0) return;

    const uint8_t* data = f.alpha + g.off;
    const int gx0 = x + g.xo;
    const int gy0 = y_top + g.yo;

    for (int j = 0; j < g.h; ++j) {
        const int py = gy0 + j;
        const uint8_t* row = data + j * g.w;
        for (int i = 0; i < g.w; ++i) {
            const uint8_t a = row[i];
            if (a < 16) continue;
            const int px = gx0 + i;
            if (a >= 240) {
                buf.drawPixel(px, py, color);
            } else {
                uint32_t bg32 = buf.readPixel(px, py);
                uint16_t bg = static_cast<uint16_t>(bg32 & 0xFFFF);
                buf.drawPixel(px, py, blend565(bg, color, a));
            }
        }
    }
}

// Advances are Q8.8 subpixel values. We keep the pen position in Q8.8
// across the whole string and round only when placing each glyph, so
// fractional character widths accumulate cleanly. Rounding each char
// in isolation (as the generator used to do with ceil) produces
// uneven gaps — e.g. "Desktop" at 17px grouped as "Des"|"kto"|"p".
void drawText(LGFX_Sprite& buf, int x, int y_top, const char* text,
              uint16_t color, const Font& f) {
    if (!text) return;
    int pen_q8 = x << 8;
    for (const char* p = text; *p; ++p) {
        uint8_t uc = static_cast<uint8_t>(*p);
        if (uc < f.first || uc > f.last) continue;
        int cx = (pen_q8 + 128) >> 8;
        drawChar(buf, cx, y_top, *p, color, f);
        pen_q8 += f.glyphs[uc - f.first].adv;
    }
}

int textWidth(const char* text, const Font& f) {
    if (!text) return 0;
    int w_q8 = 0;
    for (const char* p = text; *p; ++p) {
        uint8_t uc = static_cast<uint8_t>(*p);
        if (uc >= f.first && uc <= f.last) {
            w_q8 += f.glyphs[uc - f.first].adv;
        }
    }
    return (w_q8 + 128) >> 8;
}

}  // namespace aa_font
