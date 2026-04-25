#!/usr/bin/env python3
"""
Generate an Adafruit-GFX compatible 1-bit bitmap monospace font header
from a TTF, at a given pixel size. Emits the same on-disk shape as the
existing FreeMono5pt7b.h — a packed bitstream + GFXglyph table + a
GFXfont blob — so the result can drop into src/fonts/ and be used by
display.cpp without any renderer changes.

Rasterisation uses PIL's text rendering with anti-aliasing disabled
(effectively thresholded). Alpha >= 128 → bit set. The font is forced
into a fixed advance by taking the max glyph advance across ASCII
0x20..0x7E, which preserves column alignment that a monospace callsite
(terminal, matrix debug) depends on.
"""

import io
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


FIRST_CHAR = 0x20
LAST_CHAR  = 0x7E

HEADER_TEMPLATE = '''\
// {name} - generated from {src}
// Character dimensions: {xAdvance}x{yAdvance} (xAdvance={xAdvance}, yAdvance={yAdvance})
// License: same as upstream {src_license}

#pragma once

#include <LovyanGFX.hpp>

const uint8_t {name}Bitmaps[] PROGMEM = {{
{bitmap_rows}
}};

const lgfx::GFXglyph {name}Glyphs[] PROGMEM = {{
{glyph_rows}
}};

const lgfx::GFXfont {name} PROGMEM = {{
  (uint8_t  *){name}Bitmaps,
  (lgfx::GFXglyph *){name}Glyphs,
  0x{first:02X}, 0x{last:02X}, {yAdvance} }};
'''


def rasterise(ttf_path: Path, size_px: int) -> tuple[dict, list]:
    font = ImageFont.truetype(str(ttf_path), size_px)
    ascent, descent = font.getmetrics()
    y_advance = ascent + descent

    # Fixed advance — take the widest glyph we'll render to guarantee
    # monospacing at the rasteriser level.
    max_adv = 0
    for code in range(FIRST_CHAR, LAST_CHAR + 1):
        adv = int(round(font.getlength(chr(code))))
        if adv > max_adv:
            max_adv = adv

    canvas_w = max_adv + 2
    canvas_h = y_advance + size_px

    bits = []
    glyphs = []

    for code in range(FIRST_CHAR, LAST_CHAR + 1):
        ch = chr(code)
        # Render onto a grayscale canvas at anchor ls (left, baseline) —
        # gives us an AA mask we can threshold into clean binary. We
        # then sweep a threshold value down until ~every character has
        # stable, well-connected glyphs; high default threshold loses
        # strokes at small sizes.
        img = Image.new("L", (canvas_w, canvas_h), 0)
        draw = ImageDraw.Draw(img)
        draw.text((0, ascent), ch, fill=255, anchor="ls", font=font)

        bbox = img.getbbox()
        if bbox is None:
            glyphs.append({
                "offset": len(bits) // 8 + (1 if len(bits) % 8 else 0),
                "w": 0, "h": 0, "adv": max_adv, "xo": 0, "yo": 0,
            })
            continue

        cropped = img.crop(bbox)
        w, h = cropped.size
        xo = bbox[0]
        yo = bbox[1] - ascent   # relative to baseline; negative above

        # Threshold at 64 (low) so faint stroke edges survive — small
        # sizes render very faintly with PIL's AA, and 128 drops most
        # of the glyph.
        offset = len(bits)
        for py in range(h):
            for px in range(w):
                bits.append(1 if cropped.getpixel((px, py)) >= 64 else 0)

        # Round the byte offset — Adafruit GFX layout expects bitmaps
        # to start at a byte boundary per glyph. Pad the bit stream to
        # a byte before writing the next glyph.
        while len(bits) % 8 != 0:
            bits.append(0)

        glyphs.append({
            "offset": offset // 8,
            "w": w, "h": h, "adv": max_adv, "xo": xo, "yo": yo,
        })

    # Pack bits into bytes, MSB-first.
    byte_stream = []
    for i in range(0, len(bits), 8):
        byte = 0
        for j in range(8):
            if i + j < len(bits) and bits[i + j]:
                byte |= 1 << (7 - j)
        byte_stream.append(byte)

    meta = {
        "name":        None,  # filled by caller
        "src":         ttf_path.name,
        "src_license": "GNU FreeFont (GPLv3) or whatever the source ships",
        "xAdvance":    max_adv,
        "yAdvance":    y_advance,
        "first":       FIRST_CHAR,
        "last":        LAST_CHAR,
    }
    return meta, byte_stream, glyphs


def emit(meta: dict, byte_stream: list, glyphs: list, out_path: Path):
    bitmap_rows = []
    for i in range(0, len(byte_stream), 12):
        row = ", ".join(f"0x{b:02X}" for b in byte_stream[i:i + 12])
        bitmap_rows.append("  " + row + ",")
    bitmap_src = "\n".join(bitmap_rows)

    glyph_rows = []
    for i, g in enumerate(glyphs):
        code = FIRST_CHAR + i
        disp = chr(code) if 0x20 < code < 0x7F and code != ord("'") and code != ord("\\") else "?"
        glyph_rows.append(
            f"  {{ {g['offset']:5d}, {g['w']:3d}, {g['h']:3d}, "
            f"{g['adv']:3d}, {g['xo']:4d}, {g['yo']:4d} }},  // 0x{code:02X} '{disp}'"
        )
    glyph_src = "\n".join(glyph_rows)

    out = HEADER_TEMPLATE.format(
        bitmap_rows=bitmap_src,
        glyph_rows=glyph_src,
        **meta,
    )
    out_path.write_text(out)


def main():
    repo = Path(__file__).resolve().parent.parent
    # IBM Plex Mono Light — thin strokes at pixel scale, cleaner than
    # DejaVu Sans Mono (which reads as bold at small sizes) and hints
    # better than FreeMono.
    ttf = Path("/usr/share/fonts/google-fonts/ofl/ibmplexmono/IBMPlexMono-Light.ttf")
    for size_px, name in [(11, "FreeMono7pt7b")]:
        meta, byte_stream, glyphs = rasterise(ttf, size_px)
        meta["name"] = name
        out = repo / "src" / "fonts" / f"{name}.h"
        emit(meta, byte_stream, glyphs, out)
        print(f"  {name}: {len(byte_stream)} bytes, "
              f"{meta['xAdvance']}x{meta['yAdvance']} per cell -> {out}")


if __name__ == "__main__":
    main()
