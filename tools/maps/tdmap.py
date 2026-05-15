"""TDMAP archive format + tile pipeline (writer, reader, renderer, labels,
land mask, 3-bit packing). One module so a contributor reading the pipeline
end to end has one file to understand.

Format: TDMAP v6 raster archive. Each tile is a 256x256 grid of 3-bit
semantic feature indices (Land/Water/Park/Building/Roads/Railway). The
on-device renderer maps those indices to colors via the active theme.

Public surface used by make_map.py and tests:
  TDMAPWriter, TDMAPReader, verify_archive, inspect_archive
  LandMask, get_land_mask
  render_vector_tile, extract_labels
  pack_3bit_pixels, zlib_compress, zlib_decompress
  Constants: TILE_SIZE, TDMAP_VERSION, PALETTE_RGB, F (feature indices),
             LABEL_TYPE_*, LABEL_MIN_ZOOM
"""

from __future__ import annotations

import gzip
import hashlib
import io
import json
import math
import os
import struct
import time
import urllib.request
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO, Dict, Iterator, List, Optional, Tuple

import numpy as np
from PIL import Image, ImageDraw

import mapbox_vector_tile as mvt


# ============================================================================
# Constants
# ============================================================================

# Standard web mercator tile size.
TILE_SIZE = 256

# TDMAP archive format version. v6 stores 3-bit semantic indices per tile;
# colors live in the renderer's theme so a single archive serves both light
# and dark modes. Pre-v6 archives are no longer supported.
TDMAP_VERSION = 6

# Compression type for tile data (written to the archive header).
COMPRESSION_ZLIB = 2  # raw deflate stream wrapped in zlib header (RFC 1950)
DEFAULT_COMPRESSION = COMPRESSION_ZLIB

# Default RGB palette for documentation / browser viewer (light theme).
# The on-device renderer overrides this with theme-specific colors; the
# archive itself stores only the 3-bit indices.
PALETTE_RGB = [
    (255, 255, 255),  # 0: Land
    (160, 208, 240),  # 1: Water
    (200, 230, 200),  # 2: Park
    (208, 208, 208),  # 3: Building
    (136, 136, 136),  # 4: Road minor
    ( 96,  96,  96),  # 5: Road major
    ( 64,  64,  64),  # 6: Highway
    ( 48,  48,  48),  # 7: Railway
]


class F:
    """Semantic feature indices for tile pixels (3-bit, 0..7)."""
    LAND = 0
    WATER = 1
    PARK = 2
    BUILDING = 3
    ROAD_MINOR = 4
    ROAD_MAJOR = 5
    ROAD_HIGHWAY = 6
    RAILWAY = 7


# Label types (rendered with different font sizes on-device).
LABEL_TYPE_CITY    = 0
LABEL_TYPE_TOWN    = 1
LABEL_TYPE_VILLAGE = 2
LABEL_TYPE_SUBURB  = 3
LABEL_TYPE_ROAD    = 4
LABEL_TYPE_WATER   = 5
LABEL_TYPE_PARK    = 6
LABEL_TYPE_POI     = 7

LABEL_MIN_ZOOM = {
    LABEL_TYPE_CITY:    6,
    LABEL_TYPE_TOWN:    9,
    LABEL_TYPE_VILLAGE: 11,
    LABEL_TYPE_SUBURB:  13,
    LABEL_TYPE_ROAD:    14,
    LABEL_TYPE_WATER:   10,
    LABEL_TYPE_PARK:    12,
    LABEL_TYPE_POI:     14,
}

# Extra pixels rendered on each side of the tile before cropping to
# TILE_SIZE. MVT tiles carry a small geometry buffer past the extent;
# rendering on an enlarged canvas lets line caps land inside the halo so
# road/rail seams between tiles don't show abrupt butt-cap gaps.
RENDER_HALO = 8
RENDER_SIZE = TILE_SIZE + 2 * RENDER_HALO

# Road rendering: (feature_index, line_width).
ROAD_STYLE = {
    "motorway":       (F.ROAD_HIGHWAY, 3),
    "motorway_link":  (F.ROAD_HIGHWAY, 2),
    "trunk":          (F.ROAD_HIGHWAY, 2.5),
    "trunk_link":     (F.ROAD_HIGHWAY, 2),
    "primary":        (F.ROAD_MAJOR,   2),
    "primary_link":   (F.ROAD_MAJOR,   1.5),
    "secondary":      (F.ROAD_MAJOR,   1.5),
    "secondary_link": (F.ROAD_MAJOR,   1),
    "tertiary":       (F.ROAD_MAJOR,   1),
    "tertiary_link":  (F.ROAD_MAJOR,   0.8),
    "residential":    (F.ROAD_MINOR,   0.8),
    "living_street":  (F.ROAD_MINOR,   0.8),
    "unclassified":   (F.ROAD_MINOR,   0.8),
    "service":        (F.ROAD_MINOR,   0.5),
    "track":          (F.ROAD_MINOR,   0.3),
    "path":           (F.ROAD_MINOR,   0.3),
    "footway":        (F.ROAD_MINOR,   0.3),
    "cycleway":       (F.ROAD_MINOR,   0.3),
    "pedestrian":     (F.ROAD_MINOR,   0.5),
}


# ============================================================================
# 3-bit packing + zlib
# ============================================================================

def pack_3bit_pixels(indices: List[int]) -> bytes:
    """Pack 8 palette indices (3 bits each) into 3 bytes.

    Bit layout for 8 pixels (24 bits = 3 bytes):
      byte 0: [p0:2-0][p1:2-0][p2:1-0]
      byte 1: [p2:2][p3:2-0][p4:2-0][p5:0]
      byte 2: [p5:2-1][p6:2-0][p7:2-0]
    """
    if len(indices) % 8 != 0:
        indices = indices + [0] * (8 - len(indices) % 8)

    result = bytearray()
    for i in range(0, len(indices), 8):
        p = [idx & 0x07 for idx in indices[i:i + 8]]
        b0 = p[0] | (p[1] << 3) | ((p[2] & 0x03) << 6)
        b1 = ((p[2] >> 2) & 0x01) | (p[3] << 1) | (p[4] << 4) | ((p[5] & 0x01) << 7)
        b2 = ((p[5] >> 1) & 0x03) | (p[6] << 2) | (p[7] << 5)
        result.extend([b0, b1, b2])
    return bytes(result)


def zlib_compress(data: bytes, level: int = 9) -> bytes:
    """Deflate + zlib header. Decoded device-side via ESP32 ROM miniz."""
    return zlib.compress(data, level)


def zlib_decompress(data: bytes) -> bytes:
    """Inverse of zlib_compress -- used by the desktop viewer and tests."""
    return zlib.decompress(data)


def get_raw_tile_size() -> int:
    """Size of an uncompressed 3-bit tile (24,576 bytes for 256x256)."""
    return (TILE_SIZE * TILE_SIZE * 3 + 7) // 8


# ============================================================================
# Land mask (OSM simplified land polygons + sidecar bitmap)
# ============================================================================

# Optional: shapely for full polygon operations. Without it we fall back to
# the committed sidecar bitmap.
try:
    from shapely.geometry import box, shape, Point  # noqa: F401
    from shapely.prepared import prep
    from shapely.ops import unary_union, transform
    HAS_SHAPELY = True
except ImportError:
    HAS_SHAPELY = False

OSM_LAND_URL = "https://osmdata.openstreetmap.de/download/simplified-land-polygons-complete-3857.zip"
CACHE_DIR = Path(__file__).parent / ".cache"
LAND_SHAPEFILE = CACHE_DIR / "simplified-land-polygons-complete-3857" / "simplified_land_polygons.shp"
LAND_GEOJSON = CACHE_DIR / "osm_land_wgs84.geojson"

# Committable sidecar: a low-resolution bit-packed land/water raster in
# equirectangular projection. Produced once with `python tdmap.py
# quantize-landmask`, checked into the repo so fresh clones don't need the
# 24 MB polygon download. Loads in milliseconds.
SIDECAR_DIR = Path(__file__).parent / "data"
SIDECAR_PATH = SIDECAR_DIR / "land_mask_2048x1024.npz"
SIDECAR_W = 2048
SIDECAR_H = 1024


def _mercator_to_wgs84(x: float, y: float) -> Tuple[float, float]:
    EARTH_RADIUS = 6378137.0
    lon = (x / EARTH_RADIUS) * (180.0 / math.pi)
    lat = (2.0 * math.atan(math.exp(y / EARTH_RADIUS)) - math.pi / 2.0) * (180.0 / math.pi)
    return (lon, lat)


def _transform_mercator_to_wgs84(geom):
    return transform(lambda x, y: _mercator_to_wgs84(x, y), geom)


def _download_osm_land() -> bool:
    """Download OSM simplified land polygons if not cached."""
    if LAND_GEOJSON.exists():
        return True
    CACHE_DIR.mkdir(exist_ok=True)
    zip_path = CACHE_DIR / "simplified-land-polygons-complete-3857.zip"
    print("Downloading OSM simplified land polygons (~24 MB)...")
    try:
        urllib.request.urlretrieve(OSM_LAND_URL, zip_path)
    except Exception as e:
        print(f"  failed: {e}")
        return False
    print("Extracting...")
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            zf.extractall(CACHE_DIR)
    except Exception as e:
        print(f"  failed: {e}")
        return False
    return True


class LandMask:
    """Land/water lookup for tile background decisions.

    Tries in order: shapely polygons -> committed sidecar bitmap -> 24 MB
    download. The sidecar is good enough for tile background decisions at
    z<=10; higher zooms rely on the vector tile's own coastline data.
    """

    def __init__(self):
        self.land_polygons = None
        self.prepared_land = None
        self.bitmap: Optional[np.ndarray] = None
        self._initialized = False

    def initialize(self, *, allow_download: bool = True) -> bool:
        if self._initialized:
            return self.land_polygons is not None or self.bitmap is not None
        self._initialized = True

        if HAS_SHAPELY:
            if LAND_GEOJSON.exists() and self._load_geojson():
                return True
            if LAND_SHAPEFILE.exists() and self._load_shapefile():
                return True

        if self._load_bitmap():
            return True

        if not allow_download:
            print("Land mask: no polygons or sidecar available, download disabled.")
            return False

        if not _download_osm_land():
            return False
        return self._load_shapefile()

    def _load_geojson(self) -> bool:
        try:
            print("Loading OSM land mask from cache...")
            with open(LAND_GEOJSON, "r") as f:
                data = json.load(f)
            polygons = [shape(feat["geometry"]) for feat in data.get("features", [])]
            self.land_polygons = unary_union(polygons)
            self.prepared_land = prep(self.land_polygons)
            return True
        except Exception as e:
            print(f"  GeoJSON load failed: {e}")
            return False

    def _load_shapefile(self) -> bool:
        try:
            import shapefile  # pyshp
        except ImportError:
            print("pyshp not installed; install with: pip install pyshp")
            return False

        try:
            print("Loading OSM land polygons from shapefile...")
            sf = shapefile.Reader(str(LAND_SHAPEFILE))
            polygons = []
            total = len(sf.shapeRecords())
            for i, shape_rec in enumerate(sf.shapeRecords()):
                if (i + 1) % 1000 == 0:
                    print(f"  Processing polygon {i + 1}/{total}...")
                geom = shape(shape_rec.shape.__geo_interface__)
                polygons.append(_transform_mercator_to_wgs84(geom))
            print("Merging polygons...")
            self.land_polygons = unary_union(polygons)
            self.prepared_land = prep(self.land_polygons)

            print("Caching as GeoJSON for faster future loads...")
            geojson = {
                "type": "FeatureCollection",
                "features": [{
                    "type": "Feature",
                    "geometry": self.land_polygons.__geo_interface__,
                    "properties": {},
                }],
            }
            with open(LAND_GEOJSON, "w") as f:
                json.dump(geojson, f)
            return True
        except Exception as e:
            print(f"  shapefile load failed: {e}")
            return False

    def _load_bitmap(self) -> bool:
        if not SIDECAR_PATH.exists():
            return False
        try:
            with np.load(SIDECAR_PATH) as f:
                packed = f["packed"]
                width = int(f["width"])
                height = int(f["height"])
            bits = np.unpackbits(packed)[: width * height].reshape((height, width))
            self.bitmap = bits.astype(bool)
            print(f"Loaded land sidecar {width}x{height}")
            return True
        except Exception as e:
            print(f"  sidecar load failed: {e}")
            return False

    def _sample_bitmap(self, lat: float, lon: float) -> bool:
        if self.bitmap is None:
            return False
        h, w = self.bitmap.shape
        lon = ((lon + 180.0) % 360.0) - 180.0
        lat = max(-90.0, min(90.0, lat))
        x = int((lon + 180.0) / 360.0 * w) % w
        y = int((90.0 - lat) / 180.0 * h)
        if y >= h:
            y = h - 1
        return bool(self.bitmap[y, x])

    def quantize_to_bitmap(self, width: int = SIDECAR_W, height: int = SIDECAR_H) -> np.ndarray:
        """Rasterize loaded polygons into an equirectangular bitmap. Slow
        (~minutes), one-shot generator step for the committed sidecar."""
        if self.land_polygons is None:
            raise RuntimeError("quantize_to_bitmap requires loaded polygons")

        from shapely.geometry import box as shp_box
        bitmap = np.zeros((height, width), dtype=bool)
        for row in range(height):
            if row % 64 == 0:
                print(f"  quantize row {row}/{height}")
            lat = 90.0 - (row + 0.5) / height * 180.0
            strip = shp_box(-180.0, lat - 180.0 / height / 2,
                             180.0, lat + 180.0 / height / 2)
            if not self.prepared_land.intersects(strip):
                continue
            row_polys = self.land_polygons.intersection(strip)
            row_prepared = prep(row_polys)
            for col in range(width):
                lon = -180.0 + (col + 0.5) / width * 360.0
                if row_prepared.contains(Point(lon, lat)):
                    bitmap[row, col] = True
        return bitmap

    def save_bitmap(self, bitmap: np.ndarray, path: Path = SIDECAR_PATH) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        h, w = bitmap.shape
        packed = np.packbits(bitmap.astype(np.uint8).ravel())
        np.savez_compressed(path, packed=packed, width=w, height=h)
        print(f"Wrote {path} ({path.stat().st_size // 1024} KB)")

    def tile_to_bbox(self, z: int, x: int, y: int) -> Tuple[float, float, float, float]:
        n = 2 ** z
        west = x / n * 360.0 - 180.0
        east = (x + 1) / n * 360.0 - 180.0
        north = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
        south = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))))
        return (west, south, east, north)

    def is_land_tile(self, z: int, x: int, y: int) -> bool:
        west, south, east, north = self.tile_to_bbox(z, x, y)
        center_lon = (west + east) / 2
        center_lat = (south + north) / 2
        if self.prepared_land is not None:
            return self.prepared_land.contains(Point(center_lon, center_lat))
        if self.bitmap is not None:
            return self._sample_bitmap(center_lat, center_lon)
        return self._simple_land_check(z, x, y)

    def get_land_fraction(self, z: int, x: int, y: int) -> float:
        west, south, east, north = self.tile_to_bbox(z, x, y)
        if self.prepared_land is not None:
            tile_box = box(west, south, east, north)
            if not self.prepared_land.intersects(tile_box):
                return 0.0
            try:
                return self.land_polygons.intersection(tile_box).area / tile_box.area
            except Exception:
                return 1.0 if self.is_land_tile(z, x, y) else 0.0
        if self.bitmap is not None:
            hits = 0
            for i in range(4):
                for j in range(4):
                    lat = south + (north - south) * (i + 0.5) / 4
                    lon = west + (east - west) * (j + 0.5) / 4
                    if self._sample_bitmap(lat, lon):
                        hits += 1
            return hits / 16.0
        return 0.5 if self._simple_land_check(z, x, y) else 0.0

    def _simple_land_check(self, z: int, x: int, y: int) -> bool:
        west, south, east, north = self.tile_to_bbox(z, x, y)
        center_lat = (south + north) / 2
        center_lon = (west + east) / 2
        if center_lat < -60 or center_lat > 85:
            return False
        if -30 < center_lon < -10 and -60 < center_lat < 60:
            return False
        if 150 < abs(center_lon) and -60 < center_lat < 60:
            return False
        return True


_land_mask: Optional[LandMask] = None


def get_land_mask() -> LandMask:
    """Get or create the global LandMask instance (initializes on first call)."""
    global _land_mask
    if _land_mask is None:
        _land_mask = LandMask()
        _land_mask.initialize()
    return _land_mask


# ============================================================================
# Vector tile renderer (MVT -> indexed PIL Image)
# ============================================================================

def _decompress_tile(data: bytes) -> bytes:
    if data[:2] == b"\x1f\x8b":
        return gzip.decompress(data)
    return data


def _get_layer(decoded: dict, name: str) -> Optional[dict]:
    return decoded.get(name)


def _scale_coords(coords: List, extent: int, tile_size: int = TILE_SIZE,
                  offset: float = 0.0, mvt_dx: float = 0.0, mvt_dy: float = 0.0) -> List:
    """Scale MVT tile-extent coordinates to pixel coordinates. Y is down in
    both frames -- this function does NOT flip. (See git blame on 48ad897 for
    the regression caused by accidentally flipping in one axis.)
    """
    scale = tile_size / extent
    if isinstance(coords[0], (list, tuple)):
        return [_scale_coords(c, extent, tile_size, offset, mvt_dx, mvt_dy) for c in coords]
    return [(coords[0] + mvt_dx) * scale + offset,
            (coords[1] + mvt_dy) * scale + offset]


def _render_polygon(draw: ImageDraw.ImageDraw, geometry: dict, extent: int, color: int,
                    offset: float = 0.0, mvt_dx: float = 0.0, mvt_dy: float = 0.0):
    coords = geometry.get("coordinates", [])
    if not coords:
        return
    for ring in coords:
        if isinstance(ring[0][0], (list, tuple)):
            for poly in ring:
                scaled = _scale_coords(poly, extent, offset=offset, mvt_dx=mvt_dx, mvt_dy=mvt_dy)
                if len(scaled) >= 3:
                    draw.polygon([(p[0], p[1]) for p in scaled], fill=color)
        else:
            scaled = _scale_coords(ring, extent, offset=offset, mvt_dx=mvt_dx, mvt_dy=mvt_dy)
            if len(scaled) >= 3:
                draw.polygon([(p[0], p[1]) for p in scaled], fill=color)


def _render_line(draw: ImageDraw.ImageDraw, geometry: dict, extent: int, color: int,
                 width: float, offset: float = 0.0,
                 mvt_dx: float = 0.0, mvt_dy: float = 0.0):
    coords = geometry.get("coordinates", [])
    if not coords:
        return
    if isinstance(coords[0][0], (list, tuple)):
        for line in coords:
            scaled = _scale_coords(line, extent, offset=offset, mvt_dx=mvt_dx, mvt_dy=mvt_dy)
            if len(scaled) >= 2:
                draw.line([(p[0], p[1]) for p in scaled],
                          fill=color, width=max(1, int(width)))
    else:
        scaled = _scale_coords(coords, extent, offset=offset, mvt_dx=mvt_dx, mvt_dy=mvt_dy)
        if len(scaled) >= 2:
            draw.line([(p[0], p[1]) for p in scaled],
                      fill=color, width=max(1, int(width)))


def _get_road_style(props: dict) -> Optional[Tuple[int, float]]:
    road_class = props.get("class") or props.get("highway") or props.get("type", "")
    return ROAD_STYLE.get(road_class)


def _tile_pixel_to_lat_lon(zoom: int, tile_x: int, tile_y: int,
                            pixel_x: float, pixel_y: float,
                            extent: int = 4096) -> Tuple[float, float]:
    """MVT tile pixel -> WGS84 lat/lon. Used by the label extractor."""
    n = 2 ** zoom
    full_x = tile_x + pixel_x / extent
    full_y = tile_y + pixel_y / extent
    lon = full_x / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * full_y / n))))
    return lat, lon


def render_vector_tile(tile_data: bytes, zoom: int, tile_x: int = 0, tile_y: int = 0,
                       land_mask: Optional[LandMask] = None,
                       neighbour_tiles: Optional[Dict[Tuple[int, int], bytes]] = None,
                       ) -> Image.Image:
    """Render a vector tile to an indexed PIL Image (256x256, values 0-7).

    Each pixel is a semantic feature index; the on-device renderer maps
    indices to colors via the active theme palette.

    ``neighbour_tiles`` maps (dx, dy) in {-1, 0, 1}^2 to raw MVT bytes for
    surrounding tiles. Their geometry is drawn into this tile's halo so
    polygons and lines stitch across tile boundaries.
    """
    try:
        data = _decompress_tile(tile_data)
        decoded = mvt.decode(data, default_options={"y_coord_down": True})
    except Exception:
        if land_mask and land_mask.is_land_tile(zoom, tile_x, tile_y):
            return Image.new("L", (TILE_SIZE, TILE_SIZE), F.LAND)
        return Image.new("L", (TILE_SIZE, TILE_SIZE), F.WATER)

    extent = 4096
    for layer_name, layer in decoded.items():
        if "extent" in layer:
            extent = layer["extent"]
            break

    neighbour_decoded: List[Tuple[int, int, dict]] = []
    if neighbour_tiles:
        for (dx, dy), raw in neighbour_tiles.items():
            try:
                nd = mvt.decode(_decompress_tile(raw),
                                default_options={"y_coord_down": True})
            except Exception:
                continue
            neighbour_decoded.append((dx * extent, dy * extent, nd))

    # Tiles with explicit land/earth polygons define their own coastline;
    # tiles without need a fallback background derived from the land mask.
    has_land_polygons = False
    for layer_name in ("land", "earth"):
        layer = _get_layer(decoded, layer_name)
        if layer and layer.get("features"):
            for feature in layer.get("features", []):
                geom = feature.get("geometry", {})
                if geom.get("type") in ("Polygon", "MultiPolygon"):
                    has_land_polygons = True
                    break
            if has_land_polygons:
                break

    canvas_size = (RENDER_SIZE, RENDER_SIZE)
    draw_land_from_mask = False

    if has_land_polygons:
        img = Image.new("L", canvas_size, F.WATER)
    elif land_mask is not None:
        land_fraction = land_mask.get_land_fraction(zoom, tile_x, tile_y)
        if land_fraction <= 0.0:
            img = Image.new("L", canvas_size, F.WATER)
        elif land_fraction >= 1.0:
            img = Image.new("L", canvas_size, F.LAND)
        else:
            img = Image.new("L", canvas_size, F.WATER)
            draw_land_from_mask = True
    else:
        img = Image.new("L", canvas_size, F.LAND)

    draw = ImageDraw.Draw(img)

    # For mixed land/water tiles without coastline geometry, pull the
    # boundary out of the land-mask polygons.
    if draw_land_from_mask and land_mask is not None and land_mask.land_polygons is not None:
        west, south, east, north = land_mask.tile_to_bbox(zoom, tile_x, tile_y)
        tile_box = box(west, south, east, north)
        try:
            land_in_tile = land_mask.land_polygons.intersection(tile_box)
            if not land_in_tile.is_empty:
                def geo_to_pixel(lon, lat):
                    px = (lon - west) / (east - west) * TILE_SIZE + RENDER_HALO
                    py = (north - lat) / (north - south) * TILE_SIZE + RENDER_HALO
                    return (px, py)

                def draw_polygon_geo(geom):
                    if geom.geom_type == "Polygon":
                        coords = list(geom.exterior.coords)
                        if len(coords) >= 3:
                            pixels = [geo_to_pixel(lon, lat) for lon, lat in coords]
                            draw.polygon(pixels, fill=F.LAND)
                    elif geom.geom_type == "MultiPolygon":
                        for poly in geom.geoms:
                            draw_polygon_geo(poly)
                    elif geom.geom_type == "GeometryCollection":
                        for g in geom.geoms:
                            draw_polygon_geo(g)

                draw_polygon_geo(land_in_tile)
        except Exception:
            if land_mask.get_land_fraction(zoom, tile_x, tile_y) >= 0.5:
                draw.rectangle(
                    [RENDER_HALO, RENDER_HALO,
                     RENDER_HALO + TILE_SIZE - 1, RENDER_HALO + TILE_SIZE - 1],
                    fill=F.LAND)

    halo = RENDER_HALO
    sources: List[Tuple[int, int, dict]] = [(0, 0, decoded)]
    sources.extend(neighbour_decoded)

    # 1. Land/earth polygons (over the ocean background)
    for layer_name in ("land", "earth", "landcover"):
        for mvt_dx, mvt_dy, d in sources:
            layer = _get_layer(d, layer_name)
            if not layer:
                continue
            for feature in layer.get("features", []):
                geom = feature.get("geometry", {})
                if geom.get("type") in ("Polygon", "MultiPolygon"):
                    _render_polygon(draw, geom, extent, F.LAND,
                                    offset=halo, mvt_dx=mvt_dx, mvt_dy=mvt_dy)

    # 2. Water polygons (lakes, rivers)
    for layer_name in ("water", "waterway", "ocean"):
        for mvt_dx, mvt_dy, d in sources:
            layer = _get_layer(d, layer_name)
            if not layer:
                continue
            for feature in layer.get("features", []):
                geom = feature.get("geometry", {})
                if geom.get("type") in ("Polygon", "MultiPolygon"):
                    _render_polygon(draw, geom, extent, F.WATER,
                                    offset=halo, mvt_dx=mvt_dx, mvt_dy=mvt_dy)

    # 3. Land use (parks/forests)
    for mvt_dx, mvt_dy, d in sources:
        layer = _get_layer(d, "landuse")
        if not layer:
            continue
        for feature in layer.get("features", []):
            props = feature.get("properties", {})
            geom = feature.get("geometry", {})
            landuse_class = props.get("class") or props.get("landuse", "")
            if landuse_class in ("park", "grass", "forest", "wood", "meadow", "nature_reserve"):
                if geom.get("type") in ("Polygon", "MultiPolygon"):
                    _render_polygon(draw, geom, extent, F.PARK,
                                    offset=halo, mvt_dx=mvt_dx, mvt_dy=mvt_dy)

    # 4. Buildings (only at higher zoom)
    if zoom >= 13:
        for mvt_dx, mvt_dy, d in sources:
            layer = _get_layer(d, "building")
            if not layer:
                continue
            for feature in layer.get("features", []):
                geom = feature.get("geometry", {})
                if geom.get("type") in ("Polygon", "MultiPolygon"):
                    _render_polygon(draw, geom, extent, F.BUILDING,
                                    offset=halo, mvt_dx=mvt_dx, mvt_dy=mvt_dy)

    # 5. Waterways (lines)
    for mvt_dx, mvt_dy, d in sources:
        layer = _get_layer(d, "waterway")
        if not layer:
            continue
        for feature in layer.get("features", []):
            geom = feature.get("geometry", {})
            if geom.get("type") in ("LineString", "MultiLineString"):
                _render_line(draw, geom, extent, F.WATER, 1,
                             offset=halo, mvt_dx=mvt_dx, mvt_dy=mvt_dy)

    # 6. Railways
    for mvt_dx, mvt_dy, d in sources:
        layer = _get_layer(d, "transportation")
        if not layer:
            continue
        for feature in layer.get("features", []):
            props = feature.get("properties", {})
            if props.get("class") == "rail":
                geom = feature.get("geometry", {})
                if geom.get("type") in ("LineString", "MultiLineString"):
                    _render_line(draw, geom, extent, F.RAILWAY, 1,
                                 offset=halo, mvt_dx=mvt_dx, mvt_dy=mvt_dy)

    # 7. Roads (sort by importance so bigger draws on top)
    road_order = ["path", "service", "residential", "tertiary", "secondary",
                  "primary", "trunk", "motorway"]

    def _road_sort_key(f):
        props = f.get("properties", {})
        road_class = props.get("class") or props.get("highway") or ""
        for i, cls in enumerate(road_order):
            if cls in road_class:
                return i
        return -1

    for mvt_dx, mvt_dy, d in sources:
        layer = _get_layer(d, "transportation")
        if not layer:
            continue
        for feature in sorted(layer.get("features", []), key=_road_sort_key):
            props = feature.get("properties", {})
            geom = feature.get("geometry", {})
            if props.get("class") == "rail":
                continue
            style = _get_road_style(props)
            if style and geom.get("type") in ("LineString", "MultiLineString"):
                feature_idx, width = style
                scaled_width = width * (zoom / 14.0)
                _render_line(draw, geom, extent, feature_idx, scaled_width,
                             offset=halo, mvt_dx=mvt_dx, mvt_dy=mvt_dy)

    # Crop the halo off, returning the visible TILE_SIZE square.
    return img.crop((halo, halo, halo + TILE_SIZE, halo + TILE_SIZE))


# ============================================================================
# Label extractor (MVT -> list of label dicts)
# ============================================================================

def extract_labels(tile_data: bytes, zoom: int, tile_x: int, tile_y: int) -> List[dict]:
    """Extract place + water labels from a single MVT tile.

    Returns dicts with keys: zoom_min, zoom_max, lat, lon, label_type, text.
    Coordinates are geographic so labels survive resampling into different
    archive extents.
    """
    labels: List[dict] = []

    try:
        data = _decompress_tile(tile_data)
        decoded = mvt.decode(data, default_options={"y_coord_down": True})
    except Exception:
        return labels

    extent = 4096
    for _name, layer in decoded.items():
        if "extent" in layer:
            extent = layer["extent"]
            break

    # Place labels
    for layer_name in ("place", "place_name", "place_label"):
        layer = _get_layer(decoded, layer_name)
        if not layer:
            continue
        for feature in layer.get("features", []):
            props = feature.get("properties", {})
            geom = feature.get("geometry", {})

            name = props.get("name") or props.get("name:en") or props.get("name:latin")
            if not name:
                continue

            place_class = props.get("class") or props.get("place") or props.get("type", "")
            label_type = None
            if place_class in ("city", "metropolis"):
                label_type = LABEL_TYPE_CITY
            elif place_class == "town":
                label_type = LABEL_TYPE_TOWN
            elif place_class in ("village", "hamlet"):
                label_type = LABEL_TYPE_VILLAGE
            elif place_class in ("suburb", "neighbourhood", "neighborhood", "quarter"):
                label_type = LABEL_TYPE_SUBURB
            else:
                continue

            coords = geom.get("coordinates", [])
            if geom.get("type") == "Point" and len(coords) >= 2:
                lat, lon = _tile_pixel_to_lat_lon(zoom, tile_x, tile_y,
                                                    coords[0], coords[1], extent)
                labels.append({
                    "zoom_min":   LABEL_MIN_ZOOM.get(label_type, zoom),
                    "zoom_max":   14,
                    "lat":        lat,
                    "lon":        lon,
                    "label_type": label_type,
                    "text":       name[:50],
                })

    # Water labels
    for layer_name in ("water_name", "waterway_label"):
        layer = _get_layer(decoded, layer_name)
        if not layer:
            continue
        for feature in layer.get("features", []):
            props = feature.get("properties", {})
            geom = feature.get("geometry", {})

            name = props.get("name") or props.get("name:en")
            if not name:
                continue

            coords = geom.get("coordinates", [])
            px, py = None, None
            if geom.get("type") == "Point" and len(coords) >= 2:
                px, py = coords[0], coords[1]
            elif geom.get("type") in ("LineString", "MultiLineString"):
                if coords and isinstance(coords[0][0], (list, tuple)):
                    coords = coords[0]
                if len(coords) >= 2:
                    mid = len(coords) // 2
                    px, py = coords[mid][0], coords[mid][1]

            if px is None:
                continue

            lat, lon = _tile_pixel_to_lat_lon(zoom, tile_x, tile_y, px, py, extent)
            labels.append({
                "zoom_min":   LABEL_MIN_ZOOM[LABEL_TYPE_WATER],
                "zoom_max":   14,
                "lat":        lat,
                "lon":        lon,
                "label_type": LABEL_TYPE_WATER,
                "text":       name[:50],
            })

    return labels


# ============================================================================
# TDMAP archive format (writer + reader)
# ============================================================================

# Metadata TLV tags (2 bytes each, ASCII).
META_TAG_REGION    = b"RG"  # UTF-8 region name
META_TAG_BOUNDS    = b"BB"  # 16 bytes: 4x int32_le (min_lat_e6, min_lon_e6, max_lat_e6, max_lon_e6)
META_TAG_SRC_HASH  = b"SH"  # Arbitrary bytes (typically SHA-256 of source PMTiles)
META_TAG_TIMESTAMP = b"TS"  # 8 bytes: uint64_le UNIX epoch seconds
META_TAG_TOOL_VER  = b"TV"  # UTF-8 tool/generator version

# Header (33 bytes). LE multi-byte ints.
# Magic(6) + version(1) + compression(1) + tile_size(2) + palette_count(1) +
# tile_count(4) + index_offset(4) + data_offset(4) + min_zoom(1) + max_zoom(1) +
# label_data_offset(4) + label_count(4)
HEADER_FORMAT = "<6sBBHBIIIbbII"
HEADER_SIZE = 33

# Tile index entry: zoom(1) + x(2) + y(2) + offset(4) + size(2) = 11 bytes.
INDEX_ENTRY_FORMAT = "<BHHIH"
INDEX_ENTRY_SIZE = 11

# Label entry: lat_e6(4) + lon_e6(4) + zmin(1) + zmax(1) + type(1) +
# text_len(1) + text(variable). Labels deduped at build time.
LABEL_FORMAT = "<iiBBB"
LABEL_FIXED_SIZE = 11


class TileEntry:
    """Single tile in the archive index."""

    def __init__(self, zoom: int, x: int, y: int, offset: int = 0, size: int = 0):
        self.zoom = zoom
        self.x = x
        self.y = y
        self.offset = offset
        self.size = size

    def __repr__(self):
        return f"Tile(z={self.zoom}, x={self.x}, y={self.y}, off={self.offset}, sz={self.size})"


class LabelEntry:
    """Text label with geographic coordinates. Deduped by (text, type, lat
    bucket, lon bucket) at build time so repeated city labels in adjacent MVT
    tiles collapse into one record."""

    _DEDUP_STEP_E6 = 1_000_000  # 1 deg buckets

    def __init__(self, lat: float, lon: float, zoom_min: int, zoom_max: int,
                 label_type: int, text: str):
        self.lat = lat
        self.lon = lon
        self.zoom_min = zoom_min
        self.zoom_max = zoom_max
        self.label_type = label_type
        self.text = text

    @property
    def lat_e6(self) -> int:
        return int(self.lat * 1_000_000)

    @property
    def lon_e6(self) -> int:
        return int(self.lon * 1_000_000)

    def pack(self) -> bytes:
        text_bytes = self.text.encode("utf-8")[:255]
        return struct.pack(LABEL_FORMAT, self.lat_e6, self.lon_e6,
                            self.zoom_min, self.zoom_max, self.label_type
                          ) + struct.pack("B", len(text_bytes)) + text_bytes

    @classmethod
    def unpack(cls, data: bytes, offset: int = 0) -> Tuple["LabelEntry", int]:
        lat_e6, lon_e6, zmin, zmax, ltype = struct.unpack_from(LABEL_FORMAT, data, offset)
        text_len = data[offset + LABEL_FIXED_SIZE]
        text_start = offset + LABEL_FIXED_SIZE + 1
        text = data[text_start:text_start + text_len].decode("utf-8", errors="replace")
        return (cls(lat_e6 / 1_000_000, lon_e6 / 1_000_000, zmin, zmax, ltype, text),
                LABEL_FIXED_SIZE + 1 + text_len)

    def dedup_key(self) -> Tuple[str, int, int, int]:
        step = self._DEDUP_STEP_E6
        return (self.text, self.label_type,
                self.lat_e6 // step, self.lon_e6 // step)

    def __repr__(self):
        return (f"Label(z={self.zoom_min}-{self.zoom_max}, "
                f"pos=({self.lat:.4f},{self.lon:.4f}), "
                f"type={self.label_type}, text='{self.text}')")


class TDMAPWriter:
    """Writes tiles + labels to a TDMAP v6 archive."""

    MAGIC = b"TDMAP\x00"

    def __init__(self, output_path: Path, compression: int = DEFAULT_COMPRESSION):
        self.output_path = Path(output_path)
        self.tiles: List[Tuple[TileEntry, bytes]] = []
        self.labels: List[LabelEntry] = []
        self._label_keys: set = set()
        self.min_zoom = 255
        self.max_zoom = 0
        self.compression = compression
        self._metadata: Dict[bytes, bytes] = {}

    # -------- metadata setters --------
    def set_region_name(self, name: str):
        self._metadata[META_TAG_REGION] = name.encode("utf-8")

    def set_bounds(self, west: float, south: float, east: float, north: float):
        self._metadata[META_TAG_BOUNDS] = struct.pack(
            "<iiii",
            int(south * 1_000_000),
            int(west  * 1_000_000),
            int(north * 1_000_000),
            int(east  * 1_000_000),
        )

    def set_source_hash(self, digest: bytes):
        self._metadata[META_TAG_SRC_HASH] = bytes(digest)

    def set_build_timestamp(self, unix_seconds: Optional[int] = None):
        ts = int(unix_seconds if unix_seconds is not None else time.time())
        self._metadata[META_TAG_TIMESTAMP] = struct.pack("<Q", ts)

    def set_tool_version(self, version: str):
        self._metadata[META_TAG_TOOL_VER] = version.encode("utf-8")

    def _pack_metadata(self) -> bytes:
        chunks = []
        for tag, value in self._metadata.items():
            if len(tag) != 2:
                raise ValueError(f"metadata tag must be 2 bytes: {tag!r}")
            if len(value) > 0xFFFF:
                raise ValueError(f"metadata value for {tag!r} too large ({len(value)} bytes)")
            chunks.append(tag)
            chunks.append(struct.pack("<H", len(value)))
            chunks.append(value)
        return b"".join(chunks)

    # -------- accumulation --------
    def add_tile(self, zoom: int, x: int, y: int, data: bytes):
        entry = TileEntry(zoom, x, y, size=len(data))
        self.tiles.append((entry, data))
        self.min_zoom = min(self.min_zoom, zoom)
        self.max_zoom = max(self.max_zoom, zoom)

    def add_label(self, lat: float, lon: float, zoom_min: int, zoom_max: int,
                  label_type: int, text: str):
        if not text or not text.strip():
            return
        entry = LabelEntry(lat, lon, zoom_min, zoom_max, label_type, text.strip())
        key = entry.dedup_key()
        if key in self._label_keys:
            return
        self._label_keys.add(key)
        self.labels.append(entry)

    # -------- emit --------
    def write(self):
        if not self.tiles:
            raise ValueError("No tiles to write")

        self.tiles.sort(key=lambda t: (t[0].zoom, t[0].x, t[0].y))
        self.labels.sort(key=lambda l: (l.zoom_min, l.lat_e6, l.lon_e6))

        metadata_payload = self._pack_metadata()
        metadata_block = struct.pack("<I", len(metadata_payload)) + metadata_payload

        index_offset = HEADER_SIZE + len(metadata_block)
        data_offset = index_offset + len(self.tiles) * INDEX_ENTRY_SIZE

        cursor = data_offset
        for entry, data in self.tiles:
            entry.offset = cursor
            cursor += len(data)

        label_data_offset = cursor
        label_data = b"".join(label.pack() for label in self.labels)

        with open(self.output_path, "wb") as f:
            f.write(struct.pack(
                HEADER_FORMAT,
                self.MAGIC, TDMAP_VERSION, self.compression,
                TILE_SIZE, 0,  # palette_count fixed at 0 in v6
                len(self.tiles), index_offset, data_offset,
                self.min_zoom, self.max_zoom,
                label_data_offset, len(self.labels),
            ))
            f.write(metadata_block)
            for entry, _ in self.tiles:
                f.write(struct.pack(INDEX_ENTRY_FORMAT,
                                     entry.zoom, entry.x, entry.y,
                                     entry.offset, entry.size))
            for _, data in self.tiles:
                f.write(data)
            f.write(label_data)
        return self.output_path


class TDMAPReader:
    """Reads tiles from a TDMAP archive (verification / preview / inspect)."""

    MAGIC = b"TDMAP\x00"

    def __init__(self, archive_path: Path):
        self.archive_path = Path(archive_path)
        self.tiles: List[TileEntry] = []
        self.labels: List[LabelEntry] = []
        self.min_zoom = 0
        self.max_zoom = 0
        self.tile_size = 256
        self.version = 0
        self.label_data_offset = 0
        self.label_count = 0
        self.metadata: Dict[bytes, bytes] = {}
        self.region_name: Optional[str] = None
        self.bounds: Optional[Tuple[float, float, float, float]] = None
        self.source_hash: Optional[bytes] = None
        self.build_timestamp: Optional[int] = None
        self.tool_version: Optional[str] = None
        self._read_header()

    def _read_header(self):
        with open(self.archive_path, "rb") as f:
            header_data = f.read(HEADER_SIZE)
            (magic, version, compression, tile_size, _palette_count,
             tile_count, index_offset, _data_offset, min_zoom, max_zoom,
             label_data_offset, label_count) = struct.unpack(HEADER_FORMAT, header_data)

            if magic != self.MAGIC:
                raise ValueError(f"Invalid TDMAP magic: {magic!r}")
            if version != TDMAP_VERSION:
                raise ValueError(
                    f"Unsupported TDMAP version: {version} (this build only "
                    f"reads v{TDMAP_VERSION}; pre-v6 archives are no longer "
                    f"supported -- regenerate with the current writer)")

            self.version = version
            self.tile_size = tile_size
            self.min_zoom = min_zoom
            self.max_zoom = max_zoom
            self.label_data_offset = label_data_offset
            self.label_count = label_count

            meta_len_bytes = f.read(4)
            if len(meta_len_bytes) == 4:
                meta_len = struct.unpack("<I", meta_len_bytes)[0]
                self._parse_metadata(f.read(meta_len))

            f.seek(index_offset)
            for _ in range(tile_count):
                entry_data = f.read(INDEX_ENTRY_SIZE)
                zoom, x, y, offset, size = struct.unpack(INDEX_ENTRY_FORMAT, entry_data)
                self.tiles.append(TileEntry(zoom, x, y, offset, size))

            if self.label_count > 0 and self.label_data_offset > 0:
                f.seek(self.label_data_offset)
                labels_data = f.read()
                offset = 0
                for _ in range(self.label_count):
                    if offset >= len(labels_data):
                        break
                    label, consumed = LabelEntry.unpack(labels_data, offset)
                    self.labels.append(label)
                    offset += consumed

    def _parse_metadata(self, payload: bytes):
        offset = 0
        n = len(payload)
        while offset + 4 <= n:
            tag = payload[offset:offset + 2]
            length = struct.unpack_from("<H", payload, offset + 2)[0]
            value_start = offset + 4
            value_end = value_start + length
            if value_end > n:
                break
            value = payload[value_start:value_end]
            self.metadata[tag] = value
            if tag == META_TAG_REGION:
                self.region_name = value.decode("utf-8", errors="replace")
            elif tag == META_TAG_BOUNDS and length == 16:
                south_e6, west_e6, north_e6, east_e6 = struct.unpack("<iiii", value)
                self.bounds = (
                    west_e6  / 1_000_000,
                    south_e6 / 1_000_000,
                    east_e6  / 1_000_000,
                    north_e6 / 1_000_000,
                )
            elif tag == META_TAG_SRC_HASH:
                self.source_hash = value
            elif tag == META_TAG_TIMESTAMP and length == 8:
                self.build_timestamp = struct.unpack("<Q", value)[0]
            elif tag == META_TAG_TOOL_VER:
                self.tool_version = value.decode("utf-8", errors="replace")
            offset = value_end

    def get_tile_data(self, zoom: int, x: int, y: int) -> Optional[bytes]:
        target = (zoom, x, y)
        lo, hi = 0, len(self.tiles) - 1
        while lo <= hi:
            mid = (lo + hi) // 2
            entry = self.tiles[mid]
            current = (entry.zoom, entry.x, entry.y)
            if current == target:
                with open(self.archive_path, "rb") as f:
                    f.seek(entry.offset)
                    return f.read(entry.size)
            elif current < target:
                lo = mid + 1
            else:
                hi = mid - 1
        return None

    def get_info(self) -> dict:
        total_size = sum(t.size for t in self.tiles)
        return {
            "version": self.version,
            "tile_count": len(self.tiles),
            "label_count": len(self.labels),
            "min_zoom": self.min_zoom,
            "max_zoom": self.max_zoom,
            "tile_size": self.tile_size,
            "total_data_size": total_size,
            "file_size": self.archive_path.stat().st_size,
        }


def verify_archive(archive_path: Path) -> bool:
    """Read header, count tiles, sanity-check. Loud on failure."""
    try:
        reader = TDMAPReader(archive_path)
        info = reader.get_info()
        print(f"Archive verified (v{info['version']}): {info['tile_count']} tiles, "
              f"{info['label_count']} labels, "
              f"zoom {info['min_zoom']}-{info['max_zoom']}, "
              f"size {info['file_size'] / 1024 / 1024:.1f} MB")
        return True
    except Exception as e:
        print(f"Archive verification failed: {e}")
        return False


_LABEL_TYPE_NAMES = {
    0: "city", 1: "town", 2: "village", 3: "suburb",
    4: "road", 5: "water", 6: "park", 7: "poi",
}


def inspect_archive(archive_path: Path, first_n_labels: int = 5) -> int:
    """Human-readable dump: header, tile distribution per zoom, labels."""
    reader = TDMAPReader(archive_path)
    info = reader.get_info()

    print(f"\n== {archive_path} ==")
    print(f"  version       : {info['version']}")
    print(f"  file size     : {info['file_size'] / 1024 / 1024:.2f} MB")
    print(f"  tile size     : {info['tile_size']} px")
    print(f"  zoom range    : {info['min_zoom']}..{info['max_zoom']}")
    print(f"  tile count    : {info['tile_count']}")
    print(f"  label count   : {info['label_count']}")

    print("\n  Metadata:")
    if reader.region_name:
        print(f"    region      : {reader.region_name}")
    if reader.bounds:
        w, s, e, n = reader.bounds
        print(f"    bounds      : W={w:+8.3f} S={s:+7.3f} E={e:+8.3f} N={n:+7.3f}")
    if reader.build_timestamp:
        import datetime
        ts = datetime.datetime.fromtimestamp(reader.build_timestamp, datetime.timezone.utc)
        print(f"    built       : {ts.isoformat().replace('+00:00', 'Z')}")
    if reader.tool_version:
        print(f"    tool        : {reader.tool_version}")
    if reader.source_hash:
        print(f"    source hash : {reader.source_hash[:16].hex()}... ({len(reader.source_hash)} bytes)")
    known = {META_TAG_REGION, META_TAG_BOUNDS, META_TAG_SRC_HASH,
             META_TAG_TIMESTAMP, META_TAG_TOOL_VER}
    for tag, value in reader.metadata.items():
        if tag not in known:
            print(f"    {tag.decode('ascii', errors='replace')} (unknown): {len(value)} bytes")

    uncompressed_bytes_per_tile = (info["tile_size"] ** 2 * 3 + 7) // 8
    by_zoom: Dict[int, list] = {}
    for t in reader.tiles:
        by_zoom.setdefault(t.zoom, []).append(t.size)

    print("\n  Tiles per zoom (count | total KB | avg ratio vs 3bpp):")
    for z in sorted(by_zoom):
        sizes = by_zoom[z]
        total = sum(sizes)
        avg_ratio = uncompressed_bytes_per_tile / (total / len(sizes)) if sizes else 0
        print(f"    z{z:<2d}  {len(sizes):>6}  {total / 1024:>9.1f}  {avg_ratio:>6.1f}x")

    by_type: Dict[int, int] = {}
    for lbl in reader.labels:
        by_type[lbl.label_type] = by_type.get(lbl.label_type, 0) + 1
    if by_type:
        print("\n  Labels by type:")
        for t in sorted(by_type):
            name = _LABEL_TYPE_NAMES.get(t, f"unknown({t})")
            print(f"    {t} {name:<10}  {by_type[t]:>6}")

    if reader.labels and first_n_labels > 0:
        print(f"\n  First {first_n_labels} labels by zoom_min:")
        by_zmin: Dict[int, list] = {}
        for lbl in reader.labels:
            by_zmin.setdefault(lbl.zoom_min, []).append(lbl)
        for z in sorted(by_zmin)[:6]:
            group = by_zmin[z][:first_n_labels]
            print(f"    zoom_min={z}:")
            for lbl in group:
                name = _LABEL_TYPE_NAMES.get(lbl.label_type, str(lbl.label_type))
                print(f"      ({lbl.lat:+8.4f},{lbl.lon:+9.4f}) {name:<7} {lbl.text}")

    print()
    return 0


# ============================================================================
# Web Mercator helpers
# ============================================================================

def lat_lon_to_tile(lat: float, lon: float, zoom: int) -> Tuple[int, int]:
    """WGS84 -> integer tile coords."""
    n = 2 ** zoom
    x = int((lon + 180.0) / 360.0 * n)
    lat_rad = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return (x, y)


def tiles_in_bounds(bounds: Optional[Tuple[float, float, float, float]],
                    zoom: int) -> Iterator[Tuple[int, int]]:
    """Yield (x, y) for every tile inside bounds at this zoom."""
    n = 2 ** zoom
    if bounds is None:
        for x in range(n):
            for y in range(n):
                yield (x, y)
        return
    west, south, east, north = bounds
    x_min, y_max = lat_lon_to_tile(south, west, zoom)
    x_max, y_min = lat_lon_to_tile(north, east, zoom)
    x_min = max(0, x_min)
    x_max = min(n - 1, x_max)
    y_min = max(0, y_min)
    y_max = min(n - 1, y_max)
    for x in range(x_min, x_max + 1):
        for y in range(y_min, y_max + 1):
            yield (x, y)


def count_tiles_in_bounds(bounds: Optional[Tuple[float, float, float, float]],
                           zoom: int) -> int:
    """How many tiles cover bounds at this zoom (cheap; no iteration)."""
    n = 2 ** zoom
    if bounds is None:
        return n * n
    west, south, east, north = bounds
    x_min, y_max = lat_lon_to_tile(south, west, zoom)
    x_max, y_min = lat_lon_to_tile(north, east, zoom)
    x_min = max(0, x_min)
    x_max = min(n - 1, x_max)
    y_min = max(0, y_min)
    y_max = min(n - 1, y_max)
    return (x_max - x_min + 1) * (y_max - y_min + 1)


def process_tile_image(img: Image.Image) -> bytes:
    """Indexed image -> compressed 3-bit packed bytes for archive storage."""
    if img.size != (TILE_SIZE, TILE_SIZE):
        img = img.resize((TILE_SIZE, TILE_SIZE), Image.Resampling.NEAREST)
    if img.mode != "L":
        img = img.convert("L")
    indices = np.array(img, dtype=np.uint8)
    indices = np.clip(indices, 0, 7)
    packed = pack_3bit_pixels(indices.flatten().tolist())
    return zlib_compress(packed)


# ============================================================================
# CLI: tdmap.py inspect / verify / quantize-landmask (low-level utilities)
# ============================================================================

def _cli() -> int:
    import argparse
    p = argparse.ArgumentParser(
        prog="python -m tools.maps.tdmap",
        description="Low-level TDMAP utilities (inspect, verify, "
                    "regenerate land-mask sidecar). For building archives "
                    "use make_map.py.")
    sub = p.add_subparsers(dest="cmd", required=True)

    pi = sub.add_parser("inspect", help="Dump header, tile distribution, labels")
    pi.add_argument("path", type=Path)
    pi.add_argument("--labels", type=int, default=5,
                    help="First N labels per zoom_min (default 5; 0 to skip)")

    pv = sub.add_parser("verify", help="Quick integrity check")
    pv.add_argument("path", type=Path)

    pq = sub.add_parser("quantize-landmask", help="Regenerate the committed land-mask sidecar")
    pq.add_argument("--width",  type=int, default=SIDECAR_W)
    pq.add_argument("--height", type=int, default=SIDECAR_H)
    pq.add_argument("--output", type=Path, default=SIDECAR_PATH)

    args = p.parse_args()
    if args.cmd == "inspect":
        return inspect_archive(args.path, first_n_labels=args.labels)
    if args.cmd == "verify":
        return 0 if verify_archive(args.path) else 1
    if args.cmd == "quantize-landmask":
        if not HAS_SHAPELY:
            print("quantize-landmask requires shapely: pip install shapely")
            return 1
        mask = LandMask()
        if not (LAND_GEOJSON.exists() or LAND_SHAPEFILE.exists()):
            if not _download_osm_land():
                return 1
        if not mask.initialize(allow_download=True) or mask.land_polygons is None:
            print("could not load polygons for quantization")
            return 1
        bitmap = mask.quantize_to_bitmap(args.width, args.height)
        mask.save_bitmap(bitmap, args.output)
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
