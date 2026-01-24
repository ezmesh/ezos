#!/usr/bin/env python3
"""
Icon Generation Tool for T-Deck OS

This tool manages icon generation from prompts and conversion to RGB565 format.

Usage:
    python generate.py generate    # Generate SVGs from prompts (prints instructions)
    python generate.py convert     # Convert SVGs to RGB565
    python generate.py all         # Generate and convert
    python generate.py list        # List all icon prompts
"""

import os
import sys
import struct
from pathlib import Path

# Paths
SCRIPT_DIR = Path(__file__).parent
PROMPTS_DIR = SCRIPT_DIR / "prompts"
BASE_PROMPT = PROMPTS_DIR / "base.txt"
ICONS_PROMPTS_DIR = PROMPTS_DIR / "icons"
WALLPAPERS_PROMPTS_DIR = PROMPTS_DIR / "wallpapers"
OUTPUT_DIR = SCRIPT_DIR / "output"
SVG_DIR = OUTPUT_DIR / "svg"
WALLPAPERS_SVG_DIR = OUTPUT_DIR / "wallpapers"
DATA_ICONS_DIR = SCRIPT_DIR.parent.parent / "data" / "icons"
DATA_WALLPAPERS_DIR = SCRIPT_DIR.parent.parent / "data" / "wallpapers"

# Icon sizes to generate
SIZES = [24, 32]


def read_prompt(path: Path) -> str:
    """Read a prompt file."""
    with open(path, 'r') as f:
        return f.read().strip()


def parse_icon_prompt(content: str) -> dict:
    """Parse an icon prompt file to extract metadata and description."""
    lines = content.split('\n')
    result = {'output': None, 'description': []}

    for line in lines:
        line = line.strip()
        if line.startswith('# Output:'):
            result['output'] = line.replace('# Output:', '').strip()
        elif not line.startswith('#') and line:
            result['description'].append(line)

    result['description'] = '\n'.join(result['description'])
    return result


def list_icons():
    """List all icon prompts."""
    print("Available icon prompts:\n")

    for prompt_file in sorted(ICONS_PROMPTS_DIR.glob("*.txt")):
        content = read_prompt(prompt_file)
        parsed = parse_icon_prompt(content)
        name = prompt_file.stem
        output = parsed['output'] or name
        print(f"  {name:15} -> {output}")

    print(f"\nTotal: {len(list(ICONS_PROMPTS_DIR.glob('*.txt')))} icons")


def generate_prompts():
    """Print combined prompts for Claude Code to generate SVGs."""
    base = read_prompt(BASE_PROMPT)

    print("=" * 60)
    print("ICON GENERATION PROMPTS FOR CLAUDE CODE")
    print("=" * 60)
    print("\nGenerate SVG icons and save them to:")
    print(f"  {SVG_DIR}/")
    print("\n" + "=" * 60)

    for prompt_file in sorted(ICONS_PROMPTS_DIR.glob("*.txt")):
        content = read_prompt(prompt_file)
        parsed = parse_icon_prompt(content)
        name = prompt_file.stem
        output_name = parsed['output'].replace('/', '_') if parsed['output'] else name

        print(f"\n--- {name}.svg (save as: {output_name}.svg) ---\n")
        print("BASE STYLE:")
        print(base)
        print("\nICON SPECIFIC:")
        print(parsed['description'])
        print()


def svg_to_rgb565(svg_path: Path, size: int) -> bytes:
    """Convert SVG to RGB565 binary data."""
    try:
        import cairosvg
        from PIL import Image
        import io
    except ImportError:
        print("Error: Required packages not installed.")
        print("Run: pip install cairosvg pillow")
        sys.exit(1)

    # Render SVG to PNG at target size
    png_data = cairosvg.svg2png(
        url=str(svg_path),
        output_width=size,
        output_height=size
    )

    # Open with PIL
    img = Image.open(io.BytesIO(png_data))
    img = img.convert('RGBA')

    # Convert to RGB565 with transparency handling
    pixels = img.load()
    data = bytearray()

    for y in range(size):
        for x in range(size):
            r, g, b, a = pixels[x, y]

            # Use magenta (0xF81F) for transparent pixels
            if a < 128:
                color = 0xF81F  # Magenta = transparent
            else:
                # Convert to RGB565
                r5 = (r >> 3) & 0x1F
                g6 = (g >> 2) & 0x3F
                b5 = (b >> 3) & 0x1F
                color = (r5 << 11) | (g6 << 5) | b5

            # Big-endian byte order (matches display expectations)
            data.append((color >> 8) & 0xFF)
            data.append(color & 0xFF)

    return bytes(data)


def convert_icons():
    """Convert all SVGs to RGB565 format."""
    if not SVG_DIR.exists():
        print(f"Error: SVG directory not found: {SVG_DIR}")
        print("Run 'generate' first and create SVG files.")
        sys.exit(1)

    svg_files = list(SVG_DIR.glob("*.svg"))
    if not svg_files:
        print(f"Error: No SVG files found in {SVG_DIR}")
        sys.exit(1)

    print(f"Converting {len(svg_files)} SVG files to RGB565...\n")

    for svg_path in sorted(svg_files):
        name = svg_path.stem  # e.g., "messages", "channels"

        for size in SIZES:
            output_dir = DATA_ICONS_DIR / f"{size}x{size}"
            output_dir.mkdir(parents=True, exist_ok=True)

            output_path = output_dir / f"{name}.rgb565"

            try:
                rgb565_data = svg_to_rgb565(svg_path, size)

                with open(output_path, 'wb') as f:
                    f.write(rgb565_data)

                print(f"  {name} @ {size}x{size} -> {output_path.relative_to(DATA_ICONS_DIR.parent.parent)}")
            except Exception as e:
                print(f"  ERROR: {name} @ {size}x{size}: {e}")

    print("\nDone!")


def svg_to_rgb565_wallpaper(svg_path: Path, size: int) -> bytes:
    """Convert SVG wallpaper to RGB565 binary data (no transparency)."""
    try:
        import cairosvg
        from PIL import Image
        import io
    except ImportError:
        print("Error: Required packages not installed.")
        print("Run: pip install cairosvg pillow")
        sys.exit(1)

    # Render SVG to PNG at target size
    png_data = cairosvg.svg2png(
        url=str(svg_path),
        output_width=size,
        output_height=size
    )

    # Open with PIL
    img = Image.open(io.BytesIO(png_data))
    img = img.convert('RGB')

    # Convert to RGB565
    pixels = img.load()
    data = bytearray()

    for y in range(size):
        for x in range(size):
            r, g, b = pixels[x, y]
            # Convert to RGB565
            r5 = (r >> 3) & 0x1F
            g6 = (g >> 2) & 0x3F
            b5 = (b >> 3) & 0x1F
            color = (r5 << 11) | (g6 << 5) | b5

            # Big-endian byte order (matches display expectations)
            data.append((color >> 8) & 0xFF)
            data.append(color & 0xFF)

    return bytes(data)


def convert_wallpapers():
    """Convert all wallpaper SVGs to RGB565 format."""
    if not WALLPAPERS_SVG_DIR.exists():
        print(f"No wallpapers directory found: {WALLPAPERS_SVG_DIR}")
        return

    svg_files = list(WALLPAPERS_SVG_DIR.glob("*.svg"))
    if not svg_files:
        print(f"No wallpaper SVG files found in {WALLPAPERS_SVG_DIR}")
        return

    print(f"Converting {len(svg_files)} wallpaper files to RGB565...\n")

    DATA_WALLPAPERS_DIR.mkdir(parents=True, exist_ok=True)

    for svg_path in sorted(svg_files):
        name = svg_path.stem

        # Get SVG dimensions from the file
        with open(svg_path, 'r') as f:
            content = f.read()
            # Extract viewBox dimensions
            import re
            match = re.search(r'viewBox="0 0 (\d+) (\d+)"', content)
            if match:
                size = int(match.group(1))  # Assume square
            else:
                size = 16  # Default

        output_path = DATA_WALLPAPERS_DIR / f"{name}.rgb565"

        try:
            rgb565_data = svg_to_rgb565_wallpaper(svg_path, size)

            with open(output_path, 'wb') as f:
                f.write(rgb565_data)

            print(f"  {name} @ {size}x{size} -> {output_path.relative_to(DATA_WALLPAPERS_DIR.parent.parent)}")
        except Exception as e:
            print(f"  ERROR: {name}: {e}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    command = sys.argv[1]

    if command == "list":
        list_icons()
    elif command == "generate":
        generate_prompts()
    elif command == "convert":
        convert_icons()
        convert_wallpapers()
    elif command == "icons":
        convert_icons()
    elif command == "wallpapers":
        convert_wallpapers()
    elif command == "all":
        generate_prompts()
        print("\n" + "=" * 60)
        print("After creating SVG files, run: python generate.py convert")
        print("=" * 60)
    else:
        print(f"Unknown command: {command}")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
