#pragma once

#include <cstdint>
#include <LovyanGFX.hpp>

// Anti-aliased bitmap font runtime.
//
// Generated fonts (src/fonts/InterAA*.h) emit a `Glyph` struct, a contiguous
// `alpha_data` array, plus `ascent`, `y_advance`, `first_char`, `last_char`
// constants inside their own namespace. The layout below matches the
// generated one byte-for-byte; we reinterpret_cast the generated arrays into
// this common view so a single renderer can drive all sizes.
namespace aa_font {

struct Glyph {
    uint8_t  w;
    uint8_t  h;
    int8_t   xo;
    int8_t   yo;
    uint8_t  adv;
    uint16_t off;
} __attribute__((packed));

struct Font {
    const uint8_t* alpha;
    const Glyph*   glyphs;
    uint8_t        first;
    uint8_t        last;
    uint8_t        ascent;
    uint8_t        y_advance;
};

void drawChar(LGFX_Sprite& buf, int x, int y_top, char c,
              uint16_t color, const Font& f);
void drawText(LGFX_Sprite& buf, int x, int y_top, const char* text,
              uint16_t color, const Font& f);
int  textWidth(const char* text, const Font& f);

}  // namespace aa_font
