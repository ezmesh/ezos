"""
Configuration for T-Deck offline map tile generation.
Defines tile sources, regions, and color palette for RGB565 display.
"""

# Tile source configuration
# Using OpenStreetMap standard tiles - will be converted to grayscale
# For production use, consider setting up your own tile server or using a paid service
TILE_SOURCE = {
    "url": "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
    "attribution": "OpenStreetMap contributors",
    "rate_limit_ms": 1000,  # OSM requires max 1 req/sec for bulk downloads
    "user_agent": "TDeckOS-MapTool/1.0 (offline map generation for embedded device, contact: github.com/tdeck-os)",
}

# Region definitions with bounding boxes (west, south, east, north) and zoom ranges
# Higher zoom = more detail, exponentially more tiles
REGIONS = {
    "global": {
        "bounds": None,  # Full world coverage
        "zoom": (0, 6),  # Overview level: ~5,500 tiles
        "description": "Global overview coverage",
    },
    "europe": {
        "bounds": (-12.0, 34.0, 45.0, 72.0),  # Western Europe to Urals
        "zoom": (7, 10),  # Regional detail: ~20,000 tiles
        "description": "European regional coverage",
    },
    "netherlands": {
        "bounds": (3.2, 50.7, 7.3, 53.7),  # Netherlands + border areas
        "zoom": (11, 14),  # Street-level detail: ~50,000 tiles
        "description": "Netherlands detailed coverage",
    },
}

# 8-color grayscale palette optimized for monochrome map display
# These are designed for Floyd-Steinberg dithering to produce readable maps
PALETTE_RGB = [
    (0, 0, 0),        # 0: Pure black - roads, text, borders
    (40, 40, 40),     # 1: Near black - secondary roads
    (80, 80, 80),     # 2: Dark gray - tertiary features
    (120, 120, 120),  # 3: Medium dark - parks, water outlines
    (160, 160, 160),  # 4: Medium gray - building fill
    (200, 200, 200),  # 5: Light gray - land areas
    (230, 230, 230),  # 6: Near white - water areas
    (255, 255, 255),  # 7: Pure white - background
]


def rgb_to_rgb565(r, g, b):
    """Convert 8-bit RGB to 16-bit RGB565 format used by T-Deck display."""
    r5 = (r >> 3) & 0x1F
    g6 = (g >> 2) & 0x3F
    b5 = (b >> 3) & 0x1F
    return (r5 << 11) | (g6 << 5) | b5


# Pre-computed RGB565 palette for TDMAP archive
PALETTE_RGB565 = [rgb_to_rgb565(*color) for color in PALETTE_RGB]

# Standard web mercator tile size
TILE_SIZE = 256

# TDMAP archive format version
TDMAP_VERSION = 1

# Compression type for tile data
COMPRESSION_RLE = 1
