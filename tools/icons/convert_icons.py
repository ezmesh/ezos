#!/usr/bin/env python3
"""
Convert Tango SVG icons to RGB565 bitmap format for ESP32 displays.

Output format: .rgb565 files containing raw RGB565 pixel data (2 bytes per pixel)
File structure: Just raw pixels, row by row, top to bottom, left to right.
The file name encodes the size (e.g., icon_24.rgb565 for 24x24 icon)

Requires: cairosvg, Pillow (pip install cairosvg Pillow)

Usage:
    python convert_icons.py <tango_icons_dir> <output_dir>
    python convert_icons.py --icon ~/icons/scalable/actions/go-home.svg ./output --sizes 24
"""

import os
import sys
import struct
import argparse
from pathlib import Path
from io import BytesIO

try:
    from PIL import Image
except ImportError as e:
    print(f"Error: Pillow missing. Install with: pip install Pillow")
    print(f"Details: {e}")
    sys.exit(1)

# cairosvg is optional - only needed for SVG conversion
cairosvg = None
try:
    import cairosvg
except ImportError:
    pass  # SVG support disabled

SIZES = [16, 24, 32, 48, 64]

def rgb888_to_rgb565(r, g, b):
    """Convert RGB888 to RGB565 (big-endian for ESP32)."""
    # RGB565: RRRRRGGG GGGBBBBB
    r5 = (r >> 3) & 0x1F
    g6 = (g >> 2) & 0x3F
    b5 = (b >> 3) & 0x1F
    return (r5 << 11) | (g6 << 5) | b5

def convert_image_to_rgb565(img, transparent_color=0xF81F):
    """
    Convert PIL Image to RGB565 bytes.

    Args:
        img: PIL Image (will be converted to RGBA)
        transparent_color: RGB565 color to use for transparent pixels (default: magenta)

    Returns:
        bytes: Raw RGB565 data
    """
    img = img.convert('RGBA')
    width, height = img.size
    pixels = img.load()

    data = bytearray()
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]

            if a < 128:  # Treat as transparent
                color = transparent_color
            else:
                color = rgb888_to_rgb565(r, g, b)

            # Little-endian format (ESP32 native)
            data.append(color & 0xFF)
            data.append((color >> 8) & 0xFF)

    return bytes(data)

def convert_svg_to_rgb565(svg_path, output_dir, sizes=SIZES, transparent_color=0xF81F):
    """Convert a single SVG to multiple RGB565 bitmap sizes."""
    if cairosvg is None:
        print(f"Error: SVG support requires cairosvg. Install with: pip install cairosvg")
        return []

    svg_path = Path(svg_path)
    output_dir = Path(output_dir)

    # Get relative path structure (category/icon_name)
    name = svg_path.stem
    category = svg_path.parent.name

    results = []
    for size in sizes:
        size_dir = output_dir / f"{size}x{size}" / category
        size_dir.mkdir(parents=True, exist_ok=True)

        output_path = size_dir / f"{name}.rgb565"

        try:
            # Convert SVG to PNG in memory
            png_data = cairosvg.svg2png(
                url=str(svg_path),
                output_width=size,
                output_height=size
            )

            # Open with PIL
            img = Image.open(BytesIO(png_data))

            # Convert to RGB565
            rgb565_data = convert_image_to_rgb565(img, transparent_color)

            # Write to file
            with open(output_path, 'wb') as f:
                f.write(rgb565_data)

            results.append((size, output_path))

        except Exception as e:
            print(f"  Error converting {svg_path} at {size}px: {e}")

    return results

def convert_png_to_rgb565(png_path, output_dir, sizes=SIZES, transparent_color=0xF81F):
    """Convert a PNG to multiple RGB565 bitmap sizes."""
    png_path = Path(png_path)
    output_dir = Path(output_dir)

    name = png_path.stem
    category = png_path.parent.name

    results = []
    img = Image.open(png_path)

    for size in sizes:
        size_dir = output_dir / f"{size}x{size}" / category
        size_dir.mkdir(parents=True, exist_ok=True)

        output_path = size_dir / f"{name}.rgb565"

        try:
            # Resize image
            resized = img.resize((size, size), Image.Resampling.LANCZOS)

            # Convert to RGB565
            rgb565_data = convert_image_to_rgb565(resized, transparent_color)

            # Write to file
            with open(output_path, 'wb') as f:
                f.write(rgb565_data)

            results.append((size, output_path))

        except Exception as e:
            print(f"  Error converting {png_path} at {size}px: {e}")

    return results

def find_svg_icons(tango_dir):
    """Find all SVG icons in the Tango directory structure."""
    tango_dir = Path(tango_dir)

    # Look for scalable directory first
    scalable_dir = tango_dir / "scalable"
    if scalable_dir.exists():
        search_dir = scalable_dir
    else:
        search_dir = tango_dir

    svgs = list(search_dir.rglob("*.svg"))
    return svgs

def main():
    parser = argparse.ArgumentParser(description="Convert icons to RGB565 format for ESP32")
    parser.add_argument("input_path", help="Path to Tango icon directory or single SVG/PNG file")
    parser.add_argument("output_dir", help="Output directory for RGB565 icons")
    parser.add_argument("--sizes", nargs="+", type=int, default=SIZES,
                       help=f"Icon sizes to generate (default: {SIZES})")
    parser.add_argument("--category", help="Only convert icons from this category")
    parser.add_argument("--icon", help="Only convert this specific icon name")
    parser.add_argument("--transparent", type=lambda x: int(x, 0), default=0xF81F,
                       help="RGB565 color for transparency (default: 0xF81F magenta)")

    args = parser.parse_args()

    input_path = Path(args.input_path)
    output_dir = Path(args.output_dir)

    if not input_path.exists():
        print(f"Error: Input path not found: {input_path}")
        sys.exit(1)

    output_dir.mkdir(parents=True, exist_ok=True)

    # Check if input is a single file or directory
    if input_path.is_file():
        if input_path.suffix.lower() == '.svg':
            print(f"Converting single SVG: {input_path}")
            results = convert_svg_to_rgb565(input_path, output_dir, args.sizes, args.transparent)
        elif input_path.suffix.lower() in ['.png', '.jpg', '.jpeg']:
            print(f"Converting single image: {input_path}")
            results = convert_png_to_rgb565(input_path, output_dir, args.sizes, args.transparent)
        else:
            print(f"Error: Unsupported file type: {input_path.suffix}")
            sys.exit(1)

        print(f"Created {len(results)} files")
        for size, path in results:
            print(f"  {size}x{size}: {path}")
        return

    # Directory mode - find all SVGs
    print(f"Finding SVG icons in {input_path}...")
    svgs = find_svg_icons(input_path)

    if args.category:
        svgs = [s for s in svgs if s.parent.name == args.category]

    if args.icon:
        svgs = [s for s in svgs if s.stem == args.icon]

    print(f"Found {len(svgs)} SVG icons")
    print(f"Converting to sizes: {args.sizes}")
    print(f"Output directory: {output_dir}")
    print(f"Transparent color: 0x{args.transparent:04X}")
    print()

    converted = 0
    for svg in svgs:
        category = svg.parent.name
        name = svg.stem
        print(f"Converting {category}/{name}...")

        results = convert_svg_to_rgb565(svg, output_dir, args.sizes, args.transparent)
        if results:
            converted += 1

    print()
    print(f"Converted {converted} icons to {len(args.sizes)} sizes each")
    print(f"Total RGB565 files: {converted * len(args.sizes)}")

if __name__ == "__main__":
    main()
