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

# Semantic feature indices stored in tiles (0-7)
# Tiles encode "what is here", renderer maps to colors
# Index:  0=Land, 1=Water, 2=Park, 3=Building, 4=RoadMinor, 5=RoadMajor, 6=Highway, 7=Railway

# Default RGB palette for TDMAP file header (light theme)
# Renderers can override this with their own palettes
PALETTE_RGB = [
    (255, 255, 255),  # 0: Land - white
    (160, 208, 240),  # 1: Water - light blue
    (200, 230, 200),  # 2: Park - light green
    (208, 208, 208),  # 3: Building - light gray
    (136, 136, 136),  # 4: Road minor - medium gray
    (96, 96, 96),     # 5: Road major - dark gray
    (64, 64, 64),     # 6: Highway - darker gray
    (48, 48, 48),     # 7: Railway - near black
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
TDMAP_VERSION = 4  # v4: geographic labels with lat/lon, no tile index, deduped

# Compression type for tile data
COMPRESSION_RLE = 1

# Label types (rendered with different font sizes in Lua)
LABEL_TYPE_CITY = 0       # Large cities (population > 100k)
LABEL_TYPE_TOWN = 1       # Towns (population > 10k)
LABEL_TYPE_VILLAGE = 2    # Villages and smaller places
LABEL_TYPE_SUBURB = 3     # Suburbs, neighborhoods
LABEL_TYPE_ROAD = 4       # Road names
LABEL_TYPE_WATER = 5      # Water body names
LABEL_TYPE_PARK = 6       # Parks, forests
LABEL_TYPE_POI = 7        # Points of interest

# Minimum zoom level for each label type to appear
LABEL_MIN_ZOOM = {
    LABEL_TYPE_CITY: 6,
    LABEL_TYPE_TOWN: 9,
    LABEL_TYPE_VILLAGE: 11,
    LABEL_TYPE_SUBURB: 13,
    LABEL_TYPE_ROAD: 14,
    LABEL_TYPE_WATER: 10,
    LABEL_TYPE_PARK: 12,
    LABEL_TYPE_POI: 14,
}
