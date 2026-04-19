#!/usr/bin/env python3
"""
Pre-rasterise a TTF into an anti-aliased bitmap font for ezOS.

Each glyph is stored as an 8-bit alpha mask; the on-device renderer blends
these against the framebuffer to get smooth edges without a TTF engine.

Output: one C++ header per (font, size) combination under `src/fonts/`.

Usage:
    python tools/gen_aa_font.py
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


# -----------------------------------------------------------------------------
# Build configuration
# -----------------------------------------------------------------------------

@dataclass
class FontSpec:
    ttf:       Path        # TTF/TTC file to rasterise
    size_px:   int         # pixel size (roughly matches lgfx FreeMono sizes)
    weight:    int         # variable-font weight axis (400 = regular)
    out_name:  str         # C++ namespace / generated header stem


REPO_ROOT = Path(__file__).resolve().parent.parent
# Atkinson Hyperlegible (Braille Institute, OFL). Picked over Inter for the
# AA UI fonts because its glyphs are designed for maximum distinctiveness
# at low PPEM — side-bearings don't rely on sub-pixel detail, so letters
# in a word read as evenly spaced even at 9-11 px. Inter's tighter UI
# metrics degrade into visible "clumps" around glyphs with a +1 px left
# bearing (e.g. k/p in "Desktop"). We keep the `InterAA*` namespaces so
# the C++ side doesn't need plumbing changes.
ATK_TTF = REPO_ROOT / "tools" / "fonts" / "AtkinsonHyperlegible-Regular.ttf"

FONTS = [
    FontSpec(ATK_TTF,  9, 400, "InterAA9"),
    FontSpec(ATK_TTF, 11, 400, "InterAA11"),
    FontSpec(ATK_TTF, 13, 400, "InterAA13"),
    FontSpec(ATK_TTF, 17, 400, "InterAA17"),
]

FIRST_CHAR = 0x20    # space
LAST_CHAR  = 0x7E    # tilde


# -----------------------------------------------------------------------------
# Glyph extraction
# -----------------------------------------------------------------------------

@dataclass
class Glyph:
    char:       int
    width:      int
    height:     int
    x_offset:   int   # pixels to add to cursor x before drawing
    y_offset:   int   # pixels from the top of the text row
    x_advance:  int   # Q8.8 fixed-point advance (pixels * 256). Storing
                      # subpixel precision lets the renderer accumulate a
                      # fractional pen position across a string instead of
                      # rounding each character in isolation — crucial for
                      # even inter-letter spacing at small sizes.
    data_offset: int


def rasterise(spec: FontSpec) -> tuple[list[Glyph], bytes, int, int]:
    font = ImageFont.truetype(str(spec.ttf), spec.size_px)
    # Variable-font axis for Inter: "wght" controls weight.
    try:
        font.set_variation_by_axes([spec.weight])
    except Exception:
        pass

    ascent, descent = font.getmetrics()
    y_advance = ascent + descent

    # Generous canvas — big enough for descenders and any side bearings.
    canvas_w = spec.size_px * 3
    canvas_h = y_advance + spec.size_px

    alpha = bytearray()
    glyphs: list[Glyph] = []

    for code in range(FIRST_CHAR, LAST_CHAR + 1):
        ch = chr(code)

        # Render the glyph on a blank canvas with the baseline pinned at
        # y = ascent (anchor "ls" = left, baseline). That way cropping the
        # bbox yields a y_offset measured from the row top: capital letters
        # get yo ≈ 0, x-height glyphs yo ≈ ascent - x_height, descenders
        # stretch below ascent.
        img = Image.new("L", (canvas_w, canvas_h), 0)
        ImageDraw.Draw(img).text(
            (0, ascent), ch, fill=255, anchor="ls", font=font,
        )

        bbox = img.getbbox()
        # Store the subpixel advance as Q8.8 so the renderer can keep a
        # fractional pen position across a string. This avoids the
        # per-character rounding bias (ceil lost even spacing; round
        # risks touching glyphs) and reproduces the font's designed
        # metrics to within 1/256 px.
        x_advance = round(font.getlength(ch) * 256)

        if bbox is None:
            # Space-like glyph: only an advance, no pixels.
            glyphs.append(Glyph(
                char=code, width=0, height=0,
                x_offset=0, y_offset=0,
                x_advance=x_advance,
                data_offset=len(alpha),
            ))
            continue

        cropped = img.crop(bbox)
        w, h = cropped.size
        xo, yo = bbox[0], bbox[1]

        # tobytes() on a real Image returns unpadded row-major bytes.
        pixels = cropped.tobytes()
        data_offset = len(alpha)
        alpha.extend(pixels)

        glyphs.append(Glyph(
            char=code,
            width=w,
            height=h,
            x_offset=xo,
            y_offset=yo,
            x_advance=x_advance,
            data_offset=data_offset,
        ))

    return glyphs, bytes(alpha), ascent, y_advance


# -----------------------------------------------------------------------------
# Header emission
# -----------------------------------------------------------------------------

HEADER_TEMPLATE = """\
#pragma once

#include <cstdint>

// Auto-generated anti-aliased bitmap font.
// Source: {src}
// Size:   {size}px, weight {weight}
// Range:  0x{first:02X}..0x{last:02X}
//
// Do not edit by hand — regenerate with `python tools/gen_aa_font.py`.

namespace {ns} {{

static const uint8_t alpha_data[] = {{
{alpha_rows}
}};

struct __attribute__((packed)) Glyph {{
    uint8_t  w;
    uint8_t  h;
    int8_t   xo;
    int8_t   yo;
    uint16_t adv;   // Q8.8 pixels (pixels * 256)
    uint16_t off;
}};

static const Glyph glyphs[] = {{
{glyph_rows}
}};

constexpr uint8_t  first_char = 0x{first:02X};
constexpr uint8_t  last_char  = 0x{last:02X};
constexpr uint8_t  ascent     = {ascent};
constexpr uint8_t  y_advance  = {y_adv};

}}  // namespace {ns}
"""


def format_alpha(alpha: bytes, indent: str = "    ", width: int = 16) -> str:
    lines = []
    for i in range(0, len(alpha), width):
        row = ", ".join(f"0x{b:02x}" for b in alpha[i:i + width])
        lines.append(f"{indent}{row},")
    return "\n".join(lines)


def format_glyphs(glyphs: list[Glyph]) -> str:
    lines = []
    for g in glyphs:
        disp = chr(g.char) if 0x20 < g.char < 0x7F else "?"
        if g.char == ord("'") or g.char == ord("\\"):
            disp = "?"
        lines.append(
            f"    {{ {g.width:3d}, {g.height:3d}, {g.x_offset:3d}, "
            f"{g.y_offset:3d}, {g.x_advance:5d}, {g.data_offset:5d} }},"
            f"  // '{disp}'"
        )
    return "\n".join(lines)


def emit(spec: FontSpec, glyphs: list[Glyph], alpha: bytes,
         ascent: int, y_adv: int) -> None:
    out = REPO_ROOT / "src" / "fonts" / f"{spec.out_name}.h"
    content = HEADER_TEMPLATE.format(
        src=spec.ttf.name,
        size=spec.size_px,
        weight=spec.weight,
        first=FIRST_CHAR,
        last=LAST_CHAR,
        ns=spec.out_name,
        alpha_rows=format_alpha(alpha),
        glyph_rows=format_glyphs(glyphs),
        ascent=ascent,
        y_adv=y_adv,
    )
    out.write_text(content)
    print(f"  {spec.out_name}: {len(alpha):5d}B alpha, {len(glyphs)} glyphs -> {out}")


def main() -> None:
    missing = [s.ttf for s in FONTS if not s.ttf.exists()]
    if missing:
        names = ", ".join(str(p) for p in sorted(set(missing)))
        raise SystemExit(f"Source TTF(s) not found: {names}")
    print("Rasterising AA fonts")
    for spec in FONTS:
        glyphs, alpha, ascent, y_adv = rasterise(spec)
        emit(spec, glyphs, alpha, ascent, y_adv)
    print("Done.")


if __name__ == "__main__":
    main()
