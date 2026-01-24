#!/usr/bin/env python3
"""
Generate a simple test bitmap in RGB565 format.
Creates a 24x24 icon with a house shape for testing.
"""

import os
import sys
from pathlib import Path

def rgb888_to_rgb565(r, g, b):
    """Convert RGB888 to RGB565 (big-endian for ESP32)."""
    r5 = (r >> 3) & 0x1F
    g6 = (g >> 2) & 0x3F
    b5 = (b >> 3) & 0x1F
    return (r5 << 11) | (g6 << 5) | b5

def create_test_icon(size=24):
    """Create a simple house icon."""
    # Colors
    TRANSPARENT = 0xF81F  # Magenta
    CYAN = rgb888_to_rgb565(0, 255, 255)
    WHITE = rgb888_to_rgb565(255, 255, 255)
    DARK = rgb888_to_rgb565(50, 50, 50)

    # Create pixel grid (all transparent initially)
    pixels = [[TRANSPARENT] * size for _ in range(size)]

    # Draw a simple house shape
    # Roof (triangle)
    mid = size // 2
    for y in range(2, mid):
        roof_width = (y - 1) * 2
        start_x = mid - (y - 1)
        for x in range(start_x, start_x + roof_width):
            if 0 <= x < size:
                pixels[y][x] = CYAN

    # House body (rectangle)
    body_left = 4
    body_right = size - 4
    body_top = mid
    body_bottom = size - 3

    for y in range(body_top, body_bottom):
        for x in range(body_left, body_right):
            pixels[y][x] = WHITE

    # Door (rectangle in center)
    door_left = mid - 2
    door_right = mid + 2
    door_top = body_bottom - 6

    for y in range(door_top, body_bottom):
        for x in range(door_left, door_right):
            pixels[y][x] = DARK

    return pixels

def save_rgb565(pixels, output_path):
    """Save pixels as RGB565 big-endian binary file."""
    data = bytearray()
    for row in pixels:
        for color in row:
            # Big-endian format
            data.append((color >> 8) & 0xFF)
            data.append(color & 0xFF)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, 'wb') as f:
        f.write(data)

def main():
    # Default output to data/icons
    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent

    output_dir = project_root / "data" / "icons" / "24x24" / "actions"
    output_path = output_dir / "go-home.rgb565"

    print(f"Generating test bitmap: {output_path}")

    pixels = create_test_icon(24)
    save_rgb565(pixels, output_path)

    print(f"Created {24*24*2} byte RGB565 file")
    print("Done!")

if __name__ == "__main__":
    main()
