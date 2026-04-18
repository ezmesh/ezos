#!/usr/bin/env python3
"""
Download Lucide SVGs and generate 1-bit bitmap icons for ezOS.

Produces two sizes per icon:
  sm = 16x16 (for menu list items, drawn at 1x)
  lg = 24x24 (for desktop icons, drawn at 2x = 48px on screen)

Output: lua/ezui/icons.lua
"""

import io
import struct
import urllib.request
from pathlib import Path

import cairosvg
from PIL import Image

ICONS = [
    "mail",
    "users",
    "map",
    "grid-3x3",        # "grid" was removed; "grid-3x3" is the replacement
    "hash",
    "radio-tower",
    "folder",
    "settings",
    "terminal",
    "info",
    "message-square",  # Lucide uses "message-square" for the message bubble icon
]

# Map from Lucide SVG name to our Lua key name
LUA_NAMES = {
    "mail": "mail",
    "users": "users",
    "map": "map",
    "grid-3x3": "grid",
    "hash": "hash",
    "radio-tower": "radio_tower",
    "folder": "folder",
    "settings": "settings",
    "terminal": "terminal",
    "info": "info",
    "message-square": "message",
}

SIZES = {
    "sm": 16,
    "lg": 24,
}

SVG_BASE_URL = "https://raw.githubusercontent.com/lucide-icons/lucide/main/icons/{name}.svg"

THRESHOLD = 128  # Pixel values below this are "on" (foreground)


def download_svg(name: str) -> bytes:
    """Download an SVG from the Lucide GitHub repo."""
    url = SVG_BASE_URL.format(name=name)
    print(f"  Downloading {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "ezos-icon-gen/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def svg_to_bitmap(svg_data: bytes, size: int) -> tuple[list[list[int]], int]:
    """
    Rasterize SVG to a 1-bit bitmap at the given size.

    Returns (2D list of 0/1 values, count of set bits).
    The SVGs use stroke on transparent background, so dark pixels = icon.
    """
    # Render SVG to PNG at target size
    png_data = cairosvg.svg2png(
        bytestring=svg_data,
        output_width=size,
        output_height=size,
    )

    img = Image.open(io.BytesIO(png_data)).convert("RGBA")

    # The Lucide SVGs are stroked paths on transparent background.
    # We want: opaque dark pixels -> 1 (foreground), everything else -> 0
    bitmap = []
    set_bits = 0
    for y in range(size):
        row = []
        for x in range(size):
            r, g, b, a = img.getpixel((x, y))
            # Combine alpha and luminance: a pixel is "on" if it's
            # sufficiently opaque AND sufficiently dark
            luminance = 0.299 * r + 0.587 * g + 0.114 * b
            # For anti-aliased edges, use alpha-weighted luminance
            # A fully transparent pixel should be off regardless of color
            effective = 255 - (a / 255.0) * (255 - luminance)
            if effective < THRESHOLD:
                row.append(1)
                set_bits += 1
            else:
                row.append(0)
        bitmap.append(row)

    return bitmap, set_bits


def pack_bits(bitmap: list[list[int]], width: int, height: int) -> bytes:
    """
    Pack a 2D bitmap into a continuous MSB-first bit stream.
    No row padding -- bits flow continuously across rows.
    """
    # Flatten to bit stream
    bits = []
    for row in bitmap:
        bits.extend(row)

    # Pack into bytes, MSB first
    packed = []
    for i in range(0, len(bits), 8):
        byte = 0
        for j in range(8):
            if i + j < len(bits):
                byte |= bits[i + j] << (7 - j)
        packed.append(byte)

    return bytes(packed)


def bytes_to_lua_string(data: bytes) -> str:
    """Convert bytes to a Lua hex-escaped string literal."""
    parts = []
    for b in data:
        parts.append(f"\\x{b:02x}")
    return '"' + "".join(parts) + '"'


def main():
    output_path = Path(__file__).parent.parent / "lua" / "ezui" / "icons.lua"

    print("Generating Lucide icon bitmaps for ezOS")
    print(f"Output: {output_path}")
    print()

    # Download all SVGs first
    svg_cache: dict[str, bytes] = {}
    for name in ICONS:
        print(f"[{name}]")
        svg_cache[name] = download_svg(name)

    print()

    # Generate bitmaps at both sizes
    icon_data: dict[str, dict[str, tuple[int, bytes, int]]] = {}

    for name in ICONS:
        lua_name = LUA_NAMES[name]
        icon_data[lua_name] = {}
        svg = svg_cache[name]

        for size_key, size in SIZES.items():
            bitmap, set_bits = svg_to_bitmap(svg, size)
            total_bits = size * size
            packed = pack_bits(bitmap, size, size)
            pct = 100.0 * set_bits / total_bits
            print(f"  {lua_name:15s} {size_key} ({size:2d}x{size:2d}): {set_bits:4d}/{total_bits:4d} bits set ({pct:5.1f}%) -> {len(packed)} bytes")

            # Sanity checks
            if set_bits == 0:
                print(f"    WARNING: No bits set! Icon may be invisible.")
            elif set_bits == total_bits:
                print(f"    WARNING: All bits set! Icon may be a solid block.")
            elif pct < 3.0:
                print(f"    WARNING: Very few bits set, icon may be too sparse.")
            elif pct > 60.0:
                print(f"    WARNING: Many bits set, icon may be too dense.")

            icon_data[lua_name][size_key] = (size, packed, set_bits)

    print()

    # Generate Lua file
    lines = []
    lines.append('-- 1-bit bitmap icons derived from the Lucide icon set')
    lines.append('-- https://github.com/lucide-icons/lucide (ISC License)')
    lines.append('--')
    lines.append('-- Each entry has two sizes:')
    lines.append('--   sm = {width, height, data}  16x16 for menu list item icons (1x scale)')
    lines.append('--   lg = {width, height, data}  24x24 for desktop icons (2x scale = 48px)')
    lines.append('--')
    lines.append('-- Data is a packed 1-bit bitmap string (MSB first, continuous bit')
    lines.append('-- stream without row padding).')
    lines.append('--')
    lines.append('-- Render with:')
    lines.append('--   ez.display.draw_bitmap_1bit(x, y, icon.lg[1], icon.lg[2], icon.lg[3], 2, color)')
    lines.append('--   ez.display.draw_bitmap_1bit(x, y, icon.sm[1], icon.sm[2], icon.sm[3], 1, color)')
    lines.append('')
    lines.append('local icons = {}')
    lines.append('')

    for name in ICONS:
        lua_name = LUA_NAMES[name]
        data = icon_data[lua_name]

        sm_size, sm_packed, _ = data["sm"]
        lg_size, lg_packed, _ = data["lg"]

        sm_str = bytes_to_lua_string(sm_packed)
        lg_str = bytes_to_lua_string(lg_packed)

        lines.append(f'icons.{lua_name} = {{')
        lines.append(f'    sm = {{{sm_size}, {sm_size}, {sm_str}}},')
        lines.append(f'    lg = {{{lg_size}, {lg_size}, {lg_str}}},')
        lines.append(f'}}')
        lines.append('')

    lines.append('return icons')
    lines.append('')

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines))
    print(f"Written to {output_path}")
    print("Done!")


if __name__ == "__main__":
    main()
