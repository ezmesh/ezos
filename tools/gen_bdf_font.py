#!/usr/bin/env python3
"""
Convert a BDF bitmap font into an Adafruit-GFX compatible C++ header.

BDF is a pixel-native text format — one glyph per STARTCHAR block with
explicit per-row bit patterns — so no rasterisation or thresholding is
needed. The output shape matches the existing FreeMono*pt7b.h headers
in src/fonts/: a packed bit-stream, a GFXglyph table, and a GFXfont
blob. LovyanGFX renders these straight to the panel with no alpha
blending (mono bitmap stays mono bitmap all the way through).

Supports BDF in the common variant used by Spleen / Cozette / Terminus
(ISO10646-1 encoding, BBX / DWIDTH / BITMAP blocks with hex-per-row
bitmap lines padded to byte boundaries).
"""

import argparse
from pathlib import Path


FIRST_CHAR = 0x20
LAST_CHAR  = 0x7E


def parse_bdf(path: Path) -> dict:
    """Minimal BDF parser, returns one entry per glyph plus font metrics."""
    with path.open() as f:
        lines = f.readlines()

    i = 0
    meta = {}
    glyphs = {}
    while i < len(lines):
        line = lines[i].rstrip()
        if line.startswith("FONTBOUNDINGBOX"):
            parts = line.split()
            meta["bbx_w"] = int(parts[1])
            meta["bbx_h"] = int(parts[2])
            meta["bbx_xoff"] = int(parts[3])
            meta["bbx_yoff"] = int(parts[4])
        elif line == "STARTCHAR" or line.startswith("STARTCHAR "):
            # Gather glyph block until ENDCHAR.
            g = {"name": line.split(maxsplit=1)[1] if " " in line else ""}
            i += 1
            while i < len(lines) and lines[i].rstrip() != "ENDCHAR":
                l = lines[i].rstrip()
                if l.startswith("ENCODING"):
                    g["enc"] = int(l.split()[1])
                elif l.startswith("DWIDTH"):
                    g["dwidth"] = int(l.split()[1])
                elif l.startswith("BBX"):
                    p = l.split()
                    g["w"] = int(p[1]); g["h"] = int(p[2])
                    g["xo"] = int(p[3]); g["yo"] = int(p[4])
                elif l == "BITMAP":
                    g["rows"] = []
                    i += 1
                    while lines[i].rstrip() != "ENDCHAR":
                        g["rows"].append(lines[i].strip())
                        i += 1
                    break
                i += 1
            if "enc" in g and g["enc"] >= 0:
                glyphs[g["enc"]] = g
        i += 1

    return {"meta": meta, "glyphs": glyphs}


def extract_bits(rows: list, width: int) -> list:
    """Decode BDF BITMAP hex rows into a flat bit list (MSB-first per byte,
    truncated to `width` bits per row)."""
    bits = []
    for row in rows:
        # Each row is big-endian hex, padded up to full bytes.
        value = int(row, 16) if row else 0
        total_bits = len(row) * 4
        # Bits are MSB-first within the row; take the leftmost `width`.
        for i in range(width):
            if i >= total_bits:
                bits.append(0)
                continue
            bit = (value >> (total_bits - 1 - i)) & 1
            bits.append(bit)
    return bits


HEADER_TEMPLATE = '''\
// {name} - converted from {src}
// Cell: {xAdv}x{yAdv} (xAdvance={xAdv}, yAdvance={yAdv})
// Source licence: see original BDF file.

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
  0x{first:02X}, 0x{last:02X}, {yAdv} }};
'''


def convert(bdf_path: Path, out_path: Path, name: str) -> None:
    parsed = parse_bdf(bdf_path)
    meta = parsed["meta"]
    glyphs = parsed["glyphs"]

    # Font cell and advance — for a monospace BDF these are uniform.
    bbx_w = meta["bbx_w"]
    bbx_h = meta["bbx_h"]
    bbx_yoff = meta["bbx_yoff"]
    y_advance = bbx_h

    # Force a uniform advance (max of all glyph DWIDTHs, fallback to bbx_w).
    adv = max((g.get("dwidth", bbx_w) for g in glyphs.values()), default=bbx_w)

    # Pack bitmap data per glyph, byte-aligned between glyphs so the
    # offsets stored in GFXglyph resolve to whole bytes (matches the
    # Adafruit renderer's assumptions).
    byte_stream = []
    bit_buffer = []
    glyph_table = []

    for code in range(FIRST_CHAR, LAST_CHAR + 1):
        g = glyphs.get(code)
        if g is None:
            glyph_table.append({"offset": len(byte_stream),
                                "w": 0, "h": 0, "adv": adv, "xo": 0, "yo": 0})
            continue

        w, h = g["w"], g["h"]
        # BDF yOffset is "offset of bottom row above the baseline" with
        # positive going up. Adafruit GFX wants yOffset measured from
        # baseline with negative meaning above (row origin = top-left
        # of glyph). Convert: gfx_yo = -(h + bdf_yo).
        gfx_yo = -(h + g["yo"])
        bits = extract_bits(g.get("rows", []), w)

        # Flush leftover bits to byte boundary before a new glyph so
        # the recorded offset is byte-aligned.
        while len(bit_buffer) % 8 != 0:
            bit_buffer.append(0)

        offset = len(bit_buffer) // 8 + len(byte_stream)
        # Actually: we accumulate into byte_stream by flushing bit_buffer
        # periodically. Simpler to accumulate everything in bit_buffer
        # and convert once at the end — but offsets need to be known
        # per glyph, so compute from running byte total.
        glyph_table.append({
            "offset": len(byte_stream) + len(bit_buffer) // 8,
            "w": w, "h": h, "adv": adv, "xo": g["xo"], "yo": gfx_yo,
        })
        bit_buffer.extend(bits)

        # Pad this glyph's bit-run to byte boundary and move it into
        # byte_stream so the next glyph starts fresh.
        while len(bit_buffer) % 8 != 0:
            bit_buffer.append(0)
        for b in range(0, len(bit_buffer), 8):
            byte = 0
            for k in range(8):
                if bit_buffer[b + k]:
                    byte |= 1 << (7 - k)
            byte_stream.append(byte)
        bit_buffer.clear()

    # Emit header.
    bitmap_rows = []
    for i in range(0, len(byte_stream), 12):
        row = ", ".join(f"0x{b:02X}" for b in byte_stream[i:i + 12])
        bitmap_rows.append("  " + row + ",")

    glyph_rows = []
    for i, g in enumerate(glyph_table):
        code = FIRST_CHAR + i
        disp = chr(code) if 0x20 < code < 0x7F and code != ord("'") and code != ord("\\") else "?"
        glyph_rows.append(
            f"  {{ {g['offset']:5d}, {g['w']:3d}, {g['h']:3d}, "
            f"{g['adv']:3d}, {g['xo']:4d}, {g['yo']:4d} }},  // 0x{code:02X} '{disp}'"
        )

    out = HEADER_TEMPLATE.format(
        name=name,
        src=bdf_path.name,
        xAdv=adv,
        yAdv=y_advance,
        first=FIRST_CHAR,
        last=LAST_CHAR,
        bitmap_rows="\n".join(bitmap_rows),
        glyph_rows="\n".join(glyph_rows),
    )
    out_path.write_text(out)
    print(f"  {name}: {len(byte_stream)} bytes, "
          f"{adv}x{y_advance} cell -> {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bdf",  type=Path)
    ap.add_argument("--name", required=True,
                    help="Font name / symbol prefix (e.g. Spleen6x12)")
    ap.add_argument("--out",  type=Path,
                    help="Output header path (default: src/fonts/<name>.h)")
    args = ap.parse_args()
    out = args.out or (Path(__file__).resolve().parent.parent / "src" / "fonts"
                       / f"{args.name}.h")
    convert(args.bdf, out, args.name)


if __name__ == "__main__":
    main()
