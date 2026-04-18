"""
MVT → indexed raster rendering.

Pure-function stage of the TDMAP pipeline: takes raw MVT bytes and returns a
256×256 indexed PIL Image whose pixel values are semantic feature indices
(0..7, see `F`). The renderer is stateless and deterministic apart from the
optional land mask (which only affects tiles without explicit coastline data).

Split out from `pmtiles_to_tdmap.py` so it can be tested in isolation (see
`tools/maps/tests/test_land_road_alignment.py`) without dragging in the
PMTiles reader, checkpoint logic, or multiprocessing harness.
"""

import gzip
import math
from typing import List, Optional, Tuple

from PIL import Image, ImageDraw
import mapbox_vector_tile as mvt

from config import TILE_SIZE
from land_mask import LandMask


# Feature indices for semantic tile encoding (3-bit, 0-7).
# Tiles store "what is here"; the renderer decides colors.
class F:
    LAND = 0
    WATER = 1
    PARK = 2
    BUILDING = 3
    ROAD_MINOR = 4
    ROAD_MAJOR = 5
    ROAD_HIGHWAY = 6
    RAILWAY = 7


# Road rendering: (feature_index, line_width)
ROAD_STYLE = {
    "motorway": (F.ROAD_HIGHWAY, 3),
    "motorway_link": (F.ROAD_HIGHWAY, 2),
    "trunk": (F.ROAD_HIGHWAY, 2.5),
    "trunk_link": (F.ROAD_HIGHWAY, 2),
    "primary": (F.ROAD_MAJOR, 2),
    "primary_link": (F.ROAD_MAJOR, 1.5),
    "secondary": (F.ROAD_MAJOR, 1.5),
    "secondary_link": (F.ROAD_MAJOR, 1),
    "tertiary": (F.ROAD_MAJOR, 1),
    "tertiary_link": (F.ROAD_MAJOR, 0.8),
    "residential": (F.ROAD_MINOR, 0.8),
    "living_street": (F.ROAD_MINOR, 0.8),
    "unclassified": (F.ROAD_MINOR, 0.8),
    "service": (F.ROAD_MINOR, 0.5),
    "track": (F.ROAD_MINOR, 0.3),
    "path": (F.ROAD_MINOR, 0.3),
    "footway": (F.ROAD_MINOR, 0.3),
    "cycleway": (F.ROAD_MINOR, 0.3),
    "pedestrian": (F.ROAD_MINOR, 0.5),
}


def decompress_tile(data: bytes) -> bytes:
    if data[:2] == b"\x1f\x8b":
        return gzip.decompress(data)
    return data


def get_layer(tile_data: dict, name: str) -> Optional[dict]:
    for layer_name, layer in tile_data.items():
        if layer_name == name:
            return layer
    return None


def scale_coords(coords: List, extent: int, tile_size: int = TILE_SIZE) -> List:
    """Scale MVT tile-extent coordinates to pixel coordinates. Y is down in
    both frames — this function does NOT flip. (See git blame on 48ad897 for
    the regression caused by accidentally flipping in one axis.)"""
    scale = tile_size / extent
    if isinstance(coords[0], (list, tuple)):
        return [scale_coords(c, extent, tile_size) for c in coords]
    return [coords[0] * scale, coords[1] * scale]


def render_polygon(draw: ImageDraw, geometry: dict, extent: int, color: int):
    coords = geometry.get("coordinates", [])
    if not coords:
        return
    for ring in coords:
        if isinstance(ring[0][0], (list, tuple)):
            for poly in ring:
                scaled = scale_coords(poly, extent)
                if len(scaled) >= 3:
                    draw.polygon([(p[0], p[1]) for p in scaled], fill=color)
        else:
            scaled = scale_coords(ring, extent)
            if len(scaled) >= 3:
                draw.polygon([(p[0], p[1]) for p in scaled], fill=color)


def render_line(draw: ImageDraw, geometry: dict, extent: int, color: int, width: float):
    coords = geometry.get("coordinates", [])
    if not coords:
        return
    if isinstance(coords[0][0], (list, tuple)):
        for line in coords:
            scaled = scale_coords(line, extent)
            if len(scaled) >= 2:
                draw.line([(p[0], p[1]) for p in scaled], fill=color, width=max(1, int(width)))
    else:
        scaled = scale_coords(coords, extent)
        if len(scaled) >= 2:
            draw.line([(p[0], p[1]) for p in scaled], fill=color, width=max(1, int(width)))


def get_road_style(props: dict) -> Optional[Tuple[int, float]]:
    road_class = props.get("class") or props.get("highway") or props.get("type", "")
    return ROAD_STYLE.get(road_class)


def tile_pixel_to_lat_lon(
    zoom: int, tile_x: int, tile_y: int,
    pixel_x: float, pixel_y: float,
    extent: int = 4096,
) -> Tuple[float, float]:
    """MVT tile pixel → WGS84 lat/lon. Used by the label extractor."""
    n = 2 ** zoom
    full_x = tile_x + pixel_x / extent
    full_y = tile_y + pixel_y / extent
    lon = full_x / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * full_y / n))))
    return lat, lon


# The full render_vector_tile body stays in pmtiles_to_tdmap.py until the
# feature-specific logic (coastline detection, layer priorities, building
# opacity) is tidied up — it is 215 lines of domain logic that doesn't benefit
# from being moved here now that the primitive helpers already live here.
# Callers should import render_vector_tile from pmtiles_to_tdmap.
