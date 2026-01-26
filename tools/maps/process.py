"""
Tile processing: grayscale conversion, dithering, and RLE compression.
Converts PNG tiles to 3-bit indexed format for T-Deck display.
"""

import io
from typing import List, Tuple

from PIL import Image

from config import PALETTE_RGB, TILE_SIZE


def load_tile_image(png_data: bytes) -> Image.Image:
    """Load PNG data and convert to grayscale."""
    img = Image.open(io.BytesIO(png_data))
    # Convert to grayscale, handling RGBA images
    if img.mode == "RGBA":
        # Create white background for transparent areas
        background = Image.new("RGB", img.size, (255, 255, 255))
        background.paste(img, mask=img.split()[3])  # Use alpha as mask
        img = background
    return img.convert("L")  # Grayscale


def find_nearest_palette_index(gray_value: int) -> int:
    """
    Find the index of the nearest color in the 8-color palette.
    Palette colors are grayscale, so we only compare the first component.
    """
    best_index = 0
    best_distance = abs(gray_value - PALETTE_RGB[0][0])

    for i, color in enumerate(PALETTE_RGB[1:], 1):
        distance = abs(gray_value - color[0])
        if distance < best_distance:
            best_distance = distance
            best_index = i

    return best_index


def floyd_steinberg_dither(img: Image.Image) -> List[int]:
    """
    Apply Floyd-Steinberg dithering to reduce grayscale image to 8 colors.

    Error diffusion pattern:
         *   7/16
    3/16 5/16 1/16

    Args:
        img: Grayscale PIL Image (256x256)

    Returns:
        List of palette indices (0-7), one per pixel, row-major order
    """
    width, height = img.size

    # Work with floats for error diffusion accuracy
    pixels = [[float(img.getpixel((x, y))) for x in range(width)] for y in range(height)]
    result = []

    for y in range(height):
        for x in range(width):
            old_pixel = pixels[y][x]

            # Quantize to nearest palette color
            # Clamp to valid range before finding nearest
            clamped = max(0, min(255, int(old_pixel)))
            new_index = find_nearest_palette_index(clamped)
            new_pixel = PALETTE_RGB[new_index][0]  # Grayscale value of palette color

            result.append(new_index)

            # Calculate quantization error
            error = old_pixel - new_pixel

            # Distribute error to neighboring pixels (Floyd-Steinberg coefficients)
            if x + 1 < width:
                pixels[y][x + 1] += error * 7 / 16
            if y + 1 < height:
                if x > 0:
                    pixels[y + 1][x - 1] += error * 3 / 16
                pixels[y + 1][x] += error * 5 / 16
                if x + 1 < width:
                    pixels[y + 1][x + 1] += error * 1 / 16

    return result


def pack_3bit_pixels(indices: List[int]) -> bytes:
    """
    Pack 8 palette indices (3 bits each) into 3 bytes.

    Bit layout for 8 pixels (24 bits = 3 bytes):
    Byte 0: [p0:2-0][p1:2-0][p2:1-0]
    Byte 1: [p2:2][p3:2-0][p4:2-0][p5:0]
    Byte 2: [p5:2-1][p6:2-0][p7:2-0]

    Args:
        indices: List of palette indices (0-7), length must be multiple of 8

    Returns:
        Packed bytes
    """
    if len(indices) % 8 != 0:
        # Pad with zeros
        indices = indices + [0] * (8 - len(indices) % 8)

    result = bytearray()

    for i in range(0, len(indices), 8):
        # Get 8 3-bit values
        p = [idx & 0x07 for idx in indices[i:i+8]]

        # Pack into 3 bytes (24 bits)
        # Simple sequential packing: bits 0-2 = p0, bits 3-5 = p1, etc.
        b0 = p[0] | (p[1] << 3) | ((p[2] & 0x03) << 6)
        b1 = ((p[2] >> 2) & 0x01) | (p[3] << 1) | (p[4] << 4) | ((p[5] & 0x01) << 7)
        b2 = ((p[5] >> 1) & 0x03) | (p[6] << 2) | (p[7] << 5)

        result.extend([b0, b1, b2])

    return bytes(result)


def rle_compress(data: bytes) -> bytes:
    """
    Run-length encode byte data.

    Format: For each run:
    - If count == 1: just output the byte (unless it's the escape byte 0xFF)
    - If count > 1 or byte is 0xFF: output [0xFF, count, byte]
    - Maximum count per run is 255

    Args:
        data: Raw bytes to compress

    Returns:
        RLE compressed bytes
    """
    if not data:
        return b""

    result = bytearray()
    i = 0

    while i < len(data):
        byte = data[i]
        count = 1

        # Count consecutive identical bytes
        while i + count < len(data) and data[i + count] == byte and count < 255:
            count += 1

        if count > 2 or byte == 0xFF:
            # Use RLE encoding: escape byte, count, value
            result.extend([0xFF, count, byte])
        elif count == 2:
            # Two bytes: cheaper to output directly (unless it's escape byte)
            result.extend([byte, byte])
        else:
            # Single byte
            result.append(byte)

        i += count

    return bytes(result)


def rle_decompress(data: bytes) -> bytes:
    """
    Decompress RLE-encoded data.

    Args:
        data: RLE compressed bytes

    Returns:
        Decompressed bytes
    """
    result = bytearray()
    i = 0

    while i < len(data):
        if data[i] == 0xFF and i + 2 < len(data):
            count = data[i + 1]
            value = data[i + 2]
            result.extend([value] * count)
            i += 3
        else:
            result.append(data[i])
            i += 1

    return bytes(result)


def process_tile(png_data: bytes) -> bytes:
    """
    Full processing pipeline for a single tile.

    1. Load PNG and convert to grayscale
    2. Apply Floyd-Steinberg dithering to 8-color palette
    3. Pack to 3 bits per pixel
    4. RLE compress

    Args:
        png_data: Raw PNG image data

    Returns:
        Compressed tile data
    """
    # Load and convert to grayscale
    img = load_tile_image(png_data)

    # Resize if not standard tile size
    if img.size != (TILE_SIZE, TILE_SIZE):
        img = img.resize((TILE_SIZE, TILE_SIZE), Image.Resampling.LANCZOS)

    # Dither to 8-color palette
    indices = floyd_steinberg_dither(img)

    # Pack to 3 bits per pixel
    packed = pack_3bit_pixels(indices)

    # RLE compress
    compressed = rle_compress(packed)

    return compressed


def get_raw_tile_size() -> int:
    """Get size of uncompressed 3-bit tile data in bytes."""
    # 256x256 pixels * 3 bits = 196608 bits = 24576 bytes
    # But we pack 8 pixels into 3 bytes, so: 256*256/8*3 = 24576
    return (TILE_SIZE * TILE_SIZE * 3 + 7) // 8
