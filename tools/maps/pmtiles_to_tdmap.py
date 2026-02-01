#!/usr/bin/env python3
"""
PMTiles to TDMAP Converter

Reads vector tiles from a PMTiles archive, renders them to grayscale raster images,
and produces a .tdmap file optimized for T-Deck offline viewing.

Usage:
    python pmtiles_to_tdmap.py input.pmtiles --output output.tdmap
    python pmtiles_to_tdmap.py input.pmtiles --bounds 4.0,52.0,5.0,52.5 --zoom 10,14 -o nl.tdmap

Requirements:
    pip install pmtiles mapbox-vector-tile Pillow numpy shapely pyshp

    shapely + pyshp are used for the OSM land mask which determines
    whether tiles are over land or water. On first run, downloads ~24MB of
    OSM simplified land polygons for consistent tile backgrounds that align
    with OSM road data.

The script renders vector tiles using semantic feature indices:
- Land (background for inland tiles)
- Water (background for ocean tiles, plus lakes/rivers)
- Parks/forests
- Buildings
- Roads (minor, major, highway)
- Railways
"""

import argparse
import gzip
import json
import math
import multiprocessing as mp
import os
import struct
import sys
import time
from pathlib import Path
from typing import Iterator, List, Optional, Tuple, Dict, Any

import numpy as np
from PIL import Image, ImageDraw

# PMTiles reading
from pmtiles.reader import Reader as PMTilesReader, MmapSource
from pmtiles.tile import TileType

# Vector tile decoding
import mapbox_vector_tile as mvt

# Local modules for processing and archive writing
from config import (
    PALETTE_RGB, TILE_SIZE,
    LABEL_TYPE_CITY, LABEL_TYPE_TOWN, LABEL_TYPE_VILLAGE, LABEL_TYPE_SUBURB,
    LABEL_TYPE_ROAD, LABEL_TYPE_WATER, LABEL_TYPE_PARK, LABEL_TYPE_POI,
    LABEL_MIN_ZOOM
)
from process import pack_3bit_pixels, rle_compress
from archive import TDMAPWriter, verify_archive
from land_mask import get_land_mask, LandMask


# Feature indices for semantic tile encoding (3-bit, 0-7)
# Tiles store "what is here", renderer decides colors
class F:
    """Feature indices - what each pixel represents"""
    LAND = 0        # Background/land
    WATER = 1       # Water bodies (lakes, sea)
    PARK = 2        # Parks, forests, grass
    BUILDING = 3    # Buildings
    ROAD_MINOR = 4  # Residential, service, paths
    ROAD_MAJOR = 5  # Primary, secondary, tertiary
    ROAD_HIGHWAY = 6  # Motorway, trunk
    RAILWAY = 7     # Railways, waterways (lines)

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
    """Decompress tile data if gzipped."""
    if data[:2] == b'\x1f\x8b':  # gzip magic
        return gzip.decompress(data)
    return data


def get_layer(tile_data: dict, name: str) -> Optional[dict]:
    """Get a layer from decoded tile data by name."""
    for layer_name, layer in tile_data.items():
        if layer_name == name:
            return layer
    return None


def scale_coords(coords: List, extent: int, tile_size: int = TILE_SIZE) -> List:
    """Scale coordinates from tile extent to pixel coordinates.

    MVT uses screen coordinates (Y-down, origin at top-left), same as images.
    """
    scale = tile_size / extent
    if isinstance(coords[0], (list, tuple)):
        return [scale_coords(c, extent, tile_size) for c in coords]
    return [coords[0] * scale, coords[1] * scale]


def render_polygon(draw: ImageDraw, geometry: dict, extent: int, color: int):
    """Render a polygon geometry."""
    coords = geometry.get("coordinates", [])
    if not coords:
        return

    for ring in coords:
        if isinstance(ring[0][0], (list, tuple)):
            # MultiPolygon
            for poly in ring:
                scaled = scale_coords(poly, extent)
                if len(scaled) >= 3:
                    flat = [(p[0], p[1]) for p in scaled]
                    draw.polygon(flat, fill=color)
        else:
            # Simple polygon
            scaled = scale_coords(ring, extent)
            if len(scaled) >= 3:
                flat = [(p[0], p[1]) for p in scaled]
                draw.polygon(flat, fill=color)


def render_line(draw: ImageDraw, geometry: dict, extent: int, color: int, width: float):
    """Render a line geometry."""
    coords = geometry.get("coordinates", [])
    if not coords:
        return

    if isinstance(coords[0][0], (list, tuple)):
        # MultiLineString
        for line in coords:
            scaled = scale_coords(line, extent)
            if len(scaled) >= 2:
                flat = [(p[0], p[1]) for p in scaled]
                draw.line(flat, fill=color, width=max(1, int(width)))
    else:
        # Simple LineString
        scaled = scale_coords(coords, extent)
        if len(scaled) >= 2:
            flat = [(p[0], p[1]) for p in scaled]
            draw.line(flat, fill=color, width=max(1, int(width)))


def get_road_style(props: dict) -> Optional[Tuple[int, float]]:
    """Get road rendering style based on properties."""
    # Try different property names used by various tilemaker configs
    road_class = props.get("class") or props.get("highway") or props.get("type", "")
    return ROAD_STYLE.get(road_class)


def render_vector_tile(tile_data: bytes, zoom: int, tile_x: int = 0, tile_y: int = 0,
                       land_mask: LandMask = None) -> Image.Image:
    """
    Render a vector tile to an indexed PIL Image.

    Each pixel value is a feature index (0-7) representing what's at that location.
    The renderer maps indices to actual colors.

    Args:
        tile_data: Raw MVT data (possibly gzipped)
        zoom: Zoom level (affects rendering detail)
        tile_x: Tile X coordinate (for land mask lookup)
        tile_y: Tile Y coordinate (for land mask lookup)
        land_mask: Optional LandMask instance for background detection

    Returns:
        Indexed PIL Image (256x256) with values 0-7
    """
    # Decompress if needed
    try:
        data = decompress_tile(tile_data)
        decoded = mvt.decode(data)
    except Exception as e:
        # Return blank tile on decode error - use land mask if available
        if land_mask and land_mask.is_land_tile(zoom, tile_x, tile_y):
            return Image.new("L", (TILE_SIZE, TILE_SIZE), F.LAND)
        return Image.new("L", (TILE_SIZE, TILE_SIZE), F.WATER)

    # Get extent (default 4096 for most vector tiles)
    extent = 4096
    for layer_name, layer in decoded.items():
        if "extent" in layer:
            extent = layer["extent"]
            break

    # Check if tile has explicit coastline data (land/earth polygons that define coastline)
    # Note: having lakes (water layer) doesn't count as coastline data - that's just water on land
    has_land_polygons = False
    for layer_name in ["land", "earth"]:
        layer = get_layer(decoded, layer_name)
        if layer and layer.get("features"):
            for feature in layer.get("features", []):
                geom = feature.get("geometry", {})
                if geom.get("type") in ("Polygon", "MultiPolygon"):
                    has_land_polygons = True
                    break
            if has_land_polygons:
                break

    # Coastline data means we have explicit land polygons to draw
    # (the land/earth layer defines where land is, water is everywhere else)
    has_coastline_data = has_land_polygons

    # Determine background and whether to draw land mask polygons
    # For tiles WITHOUT coastline data (common at low zoom in regional extracts),
    # we need to draw land/water from the OSM land mask
    draw_land_from_mask = False

    if has_coastline_data:
        # Tile has coastline data - use water background, draw land from vector tile
        img = Image.new("L", (TILE_SIZE, TILE_SIZE), F.WATER)
    elif land_mask is not None:
        # No coastline data - check if tile is mixed land/water
        land_fraction = land_mask.get_land_fraction(zoom, tile_x, tile_y)

        if land_fraction <= 0.0:
            # Pure ocean - water background
            img = Image.new("L", (TILE_SIZE, TILE_SIZE), F.WATER)
        elif land_fraction >= 1.0:
            # Pure land - land background
            img = Image.new("L", (TILE_SIZE, TILE_SIZE), F.LAND)
        else:
            # Mixed land/water tile without coastline data in vector tile
            # Draw land polygons from OSM mask
            img = Image.new("L", (TILE_SIZE, TILE_SIZE), F.WATER)
            draw_land_from_mask = True
    else:
        # No land mask available - assume land
        img = Image.new("L", (TILE_SIZE, TILE_SIZE), F.LAND)

    draw = ImageDraw.Draw(img)

    # Draw land from OSM mask for tiles without coastline data
    if draw_land_from_mask and land_mask is not None and land_mask.land_polygons is not None:
        from shapely.geometry import box
        west, south, east, north = land_mask.tile_to_bbox(zoom, tile_x, tile_y)
        tile_box = box(west, south, east, north)

        try:
            # Get intersection of land with tile
            land_in_tile = land_mask.land_polygons.intersection(tile_box)
            if not land_in_tile.is_empty:
                # Convert to tile pixel coordinates and draw
                def geo_to_pixel(lon, lat):
                    px = (lon - west) / (east - west) * TILE_SIZE
                    # Use Y-up coordinates (same as MVT) - the final FLIP_TOP_BOTTOM will correct it
                    py = (lat - south) / (north - south) * TILE_SIZE
                    return (px, py)

                def draw_polygon_geo(geom):
                    if geom.geom_type == 'Polygon':
                        coords = list(geom.exterior.coords)
                        if len(coords) >= 3:
                            pixels = [geo_to_pixel(lon, lat) for lon, lat in coords]
                            draw.polygon(pixels, fill=F.LAND)
                    elif geom.geom_type == 'MultiPolygon':
                        for poly in geom.geoms:
                            draw_polygon_geo(poly)
                    elif geom.geom_type == 'GeometryCollection':
                        for g in geom.geoms:
                            draw_polygon_geo(g)

                draw_polygon_geo(land_in_tile)
        except Exception as e:
            # Geometry error - fall back to land fraction-based background
            if land_mask.get_land_fraction(zoom, tile_x, tile_y) >= 0.5:
                draw.rectangle([0, 0, TILE_SIZE-1, TILE_SIZE-1], fill=F.LAND)

    # Render layers in order (back to front)

    # 1. Land/earth polygons (draw land over the ocean background)
    for layer_name in ["land", "earth", "landcover"]:
        layer = get_layer(decoded, layer_name)
        if layer:
            for feature in layer.get("features", []):
                geom = feature.get("geometry", {})
                if geom.get("type") in ("Polygon", "MultiPolygon"):
                    render_polygon(draw, geom, extent, F.LAND)

    # 2. Water polygons (lakes, rivers - these cut through land)
    for layer_name in ["water", "waterway", "ocean"]:
        layer = get_layer(decoded, layer_name)
        if layer:
            for feature in layer.get("features", []):
                geom = feature.get("geometry", {})
                if geom.get("type") in ("Polygon", "MultiPolygon"):
                    render_polygon(draw, geom, extent, F.WATER)

    # 2. Land use (parks/forests)
    layer = get_layer(decoded, "landuse")
    if layer:
        for feature in layer.get("features", []):
            props = feature.get("properties", {})
            geom = feature.get("geometry", {})
            landuse_class = props.get("class") or props.get("landuse", "")

            # Only render parks/forests as distinct feature, rest stays as land
            if landuse_class in ("park", "grass", "forest", "wood", "meadow", "nature_reserve"):
                if geom.get("type") in ("Polygon", "MultiPolygon"):
                    render_polygon(draw, geom, extent, F.PARK)

    # 3. Buildings (only at higher zoom levels)
    if zoom >= 13:
        layer = get_layer(decoded, "building")
        if layer:
            for feature in layer.get("features", []):
                geom = feature.get("geometry", {})
                if geom.get("type") in ("Polygon", "MultiPolygon"):
                    render_polygon(draw, geom, extent, F.BUILDING)

    # 4. Waterways (lines) - use RAILWAY index since it's for linear features
    layer = get_layer(decoded, "waterway")
    if layer:
        for feature in layer.get("features", []):
            geom = feature.get("geometry", {})
            if geom.get("type") in ("LineString", "MultiLineString"):
                render_line(draw, geom, extent, F.WATER, 1)

    # 5. Railways
    layer = get_layer(decoded, "transportation")
    if layer:
        for feature in layer.get("features", []):
            props = feature.get("properties", {})
            if props.get("class") == "rail":
                geom = feature.get("geometry", {})
                if geom.get("type") in ("LineString", "MultiLineString"):
                    render_line(draw, geom, extent, F.RAILWAY, 1)

    # 6. Roads (render by class, smaller roads first so bigger roads draw on top)
    layer = get_layer(decoded, "transportation")
    if layer:
        # Sort features by road importance (render less important first)
        road_order = ["path", "service", "residential", "tertiary", "secondary", "primary", "trunk", "motorway"]

        def road_sort_key(f):
            props = f.get("properties", {})
            road_class = props.get("class") or props.get("highway") or ""
            for i, cls in enumerate(road_order):
                if cls in road_class:
                    return i
            return -1

        features = sorted(layer.get("features", []), key=road_sort_key)

        for feature in features:
            props = feature.get("properties", {})
            geom = feature.get("geometry", {})

            # Skip railways (handled above)
            if props.get("class") == "rail":
                continue

            style = get_road_style(props)
            if style and geom.get("type") in ("LineString", "MultiLineString"):
                feature_idx, width = style
                # Scale width by zoom level
                scaled_width = width * (zoom / 14.0)
                render_line(draw, geom, extent, feature_idx, scaled_width)

    # MVT coordinates use Y-up (geographic) convention within tiles,
    # but PIL uses Y-down (screen) convention, so flip vertically
    return img.transpose(Image.FLIP_TOP_BOTTOM)


def tile_pixel_to_lat_lon(zoom: int, tile_x: int, tile_y: int, pixel_x: float, pixel_y: float, extent: int = 4096) -> Tuple[float, float]:
    """
    Convert tile coordinates + pixel offset to lat/lon.

    Args:
        zoom: Tile zoom level
        tile_x, tile_y: Tile coordinates
        pixel_x, pixel_y: Position within tile (0 to extent-1)
        extent: Tile extent (default 4096 for MVT)

    Returns:
        (latitude, longitude) in degrees
    """
    n = 2 ** zoom
    # MVT coordinates have Y=0 at the bottom (south), but web tiles use Y=0 at top (north)
    # Flip the Y coordinate to match web tile convention
    pixel_y_flipped = extent - pixel_y
    # Convert pixel offset to fraction of tile (0 to 1)
    frac_x = pixel_x / extent
    frac_y = pixel_y_flipped / extent
    # Full tile coordinates including fractional part
    full_x = tile_x + frac_x
    full_y = tile_y + frac_y
    # Convert to lon/lat
    lon = full_x / n * 360.0 - 180.0
    lat_rad = math.atan(math.sinh(math.pi * (1 - 2 * full_y / n)))
    lat = math.degrees(lat_rad)
    return (lat, lon)


def extract_labels(tile_data: bytes, zoom: int, tile_x: int, tile_y: int) -> List[dict]:
    """
    Extract text labels from a vector tile.

    Args:
        tile_data: Raw MVT data (possibly gzipped)
        zoom: Zoom level
        tile_x: Tile X coordinate
        tile_y: Tile Y coordinate

    Returns:
        List of label dicts with keys: zoom_min, zoom_max, lat, lon, label_type, text
    """
    labels = []

    try:
        data = decompress_tile(tile_data)
        decoded = mvt.decode(data)
    except Exception:
        return labels

    # Get extent (default 4096 for most vector tiles)
    extent = 4096
    for layer_name, layer in decoded.items():
        if "extent" in layer:
            extent = layer["extent"]
            break

    # Extract place labels (cities, towns, villages)
    for layer_name in ["place", "place_name", "place_label"]:
        layer = get_layer(decoded, layer_name)
        if not layer:
            continue

        for feature in layer.get("features", []):
            props = feature.get("properties", {})
            geom = feature.get("geometry", {})

            # Get place name
            name = props.get("name") or props.get("name:en") or props.get("name:latin")
            if not name:
                continue

            # Get place class/type
            place_class = props.get("class") or props.get("place") or props.get("type", "")

            # Determine label type based on place class
            label_type = LABEL_TYPE_VILLAGE  # default
            zoom_max = 14

            if place_class in ("city", "metropolis"):
                label_type = LABEL_TYPE_CITY
                zoom_max = 14
            elif place_class in ("town",):
                label_type = LABEL_TYPE_TOWN
                zoom_max = 14
            elif place_class in ("village", "hamlet"):
                label_type = LABEL_TYPE_VILLAGE
                zoom_max = 14
            elif place_class in ("suburb", "neighbourhood", "neighborhood", "quarter"):
                label_type = LABEL_TYPE_SUBURB
                zoom_max = 14
            else:
                # Skip unknown place types
                continue

            # Get position (center point for the label)
            coords = geom.get("coordinates", [])
            if geom.get("type") == "Point" and len(coords) >= 2:
                # Convert tile pixel to lat/lon
                lat, lon = tile_pixel_to_lat_lon(zoom, tile_x, tile_y, coords[0], coords[1], extent)

                zoom_min = LABEL_MIN_ZOOM.get(label_type, zoom)

                labels.append({
                    "zoom_min": zoom_min,
                    "zoom_max": zoom_max,
                    "lat": lat,
                    "lon": lon,
                    "label_type": label_type,
                    "text": name[:50],  # Limit length
                })

    # Extract water labels
    for layer_name in ["water_name", "waterway_label"]:
        layer = get_layer(decoded, layer_name)
        if not layer:
            continue

        for feature in layer.get("features", []):
            props = feature.get("properties", {})
            geom = feature.get("geometry", {})

            name = props.get("name") or props.get("name:en")
            if not name:
                continue

            # Get centroid of the geometry
            coords = geom.get("coordinates", [])
            px, py = None, None
            if geom.get("type") == "Point" and len(coords) >= 2:
                px, py = coords[0], coords[1]
            elif geom.get("type") in ("LineString", "MultiLineString"):
                # Use midpoint of line
                if isinstance(coords[0][0], (list, tuple)):
                    coords = coords[0]  # First line of multiline
                if len(coords) >= 2:
                    mid_idx = len(coords) // 2
                    px, py = coords[mid_idx][0], coords[mid_idx][1]

            if px is None:
                continue

            lat, lon = tile_pixel_to_lat_lon(zoom, tile_x, tile_y, px, py, extent)

            labels.append({
                "zoom_min": LABEL_MIN_ZOOM[LABEL_TYPE_WATER],
                "zoom_max": 14,
                "lat": lat,
                "lon": lon,
                "label_type": LABEL_TYPE_WATER,
                "text": name[:50],
            })

    return labels


def lat_lon_to_tile(lat: float, lon: float, zoom: int) -> Tuple[int, int]:
    """Convert latitude/longitude to tile coordinates."""
    n = 2 ** zoom
    x = int((lon + 180.0) / 360.0 * n)
    lat_rad = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return (x, y)


def get_tiles_in_bounds(
    bounds: Optional[Tuple[float, float, float, float]],
    zoom: int
) -> Iterator[Tuple[int, int]]:
    """Generate all tile coordinates within bounds at given zoom."""
    n = 2 ** zoom

    if bounds is None:
        for x in range(n):
            for y in range(n):
                yield (x, y)
    else:
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


def count_tiles_in_bounds(bounds: Optional[Tuple[float, float, float, float]], zoom: int) -> int:
    """Count tiles in bounds at given zoom."""
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


# Global variable for worker process PMTiles reader and land mask
_worker_reader = None
_worker_pmtiles_path = None
_worker_land_mask = None


def _init_worker(pmtiles_path: str):
    """Initialize worker process with its own PMTiles reader and land mask."""
    global _worker_reader, _worker_pmtiles_path, _worker_land_mask
    _worker_pmtiles_path = pmtiles_path
    # Open file and create reader in this worker process
    f = open(pmtiles_path, "rb")
    source = MmapSource(f)
    _worker_reader = PMTilesReader(source)
    # Initialize land mask (shared across tiles in this worker)
    _worker_land_mask = get_land_mask()


def _process_tile_worker(args: Tuple[int, int, int]) -> Optional[Dict[str, Any]]:
    """
    Worker function to process a single tile.

    Args:
        args: Tuple of (z, x, y)

    Returns:
        Dict with tile data and labels, or None if tile not found
    """
    global _worker_reader, _worker_land_mask
    z, x, y = args

    try:
        tile_data = _worker_reader.get(z, x, y)
    except Exception:
        return {"status": "missing", "z": z, "x": x, "y": y}

    if tile_data is None:
        return {"status": "missing", "z": z, "x": x, "y": y}

    try:
        # Render vector tile to raster using land mask for consistent backgrounds
        img = render_vector_tile(tile_data, z, x, y, _worker_land_mask)
        compressed = process_tile_image(img)

        # Extract labels
        labels = extract_labels(tile_data, z, x, y)

        return {
            "status": "ok",
            "z": z,
            "x": x,
            "y": y,
            "data": compressed,
            "labels": labels
        }
    except Exception as e:
        return {"status": "failed", "z": z, "x": x, "y": y, "error": str(e)}


def process_tile_image(img: Image.Image) -> bytes:
    """
    Process an indexed image through the TDMAP pipeline.

    Pixels are already feature indices (0-7), so no dithering needed.
    1. Pack to 3 bits per pixel
    2. RLE compress
    """
    # Ensure correct size and mode
    if img.size != (TILE_SIZE, TILE_SIZE):
        img = img.resize((TILE_SIZE, TILE_SIZE), Image.Resampling.NEAREST)
    if img.mode != "L":
        img = img.convert("L")

    # Get pixel data as array
    indices = np.array(img, dtype=np.uint8)

    # Clamp to valid range 0-7 (in case of any artifacts)
    indices = np.clip(indices, 0, 7)

    # Convert to flat list for pack_3bit_pixels
    indices_list = indices.flatten().tolist()

    # Pack to 3 bits per pixel
    packed = pack_3bit_pixels(indices_list)

    # RLE compress
    compressed = rle_compress(packed)

    return compressed


class Checkpoint:
    """Manages checkpoint save/load for resumable tile generation."""

    def __init__(self, checkpoint_path: Path, save_interval: int = 500):
        self.path = checkpoint_path
        self.save_interval = save_interval
        self.data: Dict[str, Any] = {
            "version": 2,  # v2: labels use lat/lon instead of tile coords
            "processed_tiles": [],  # List of "z/x/y" strings
            "labels": [],  # List of label dicts with lat/lon
            "seen_label_keys": [],  # List of (text, lat_e6, lon_e6) for dedup
            "stats": {
                "processed": 0,
                "missing": 0,
                "failed": 0,
                "labels_extracted": 0,
            },
            "last_position": None,  # {"zoom": z, "x": x, "y": y}
            "config": {},  # bounds, zoom_range for validation
        }
        self.tiles_since_save = 0

    def load(self) -> bool:
        """Load checkpoint from disk. Returns True if valid checkpoint found."""
        if not self.path.exists():
            return False

        try:
            with open(self.path, "r") as f:
                self.data = json.load(f)
            print(f"Loaded checkpoint: {self.data['stats']['processed']:,} tiles processed")
            return True
        except Exception as e:
            print(f"Warning: Could not load checkpoint: {e}")
            return False

    def save(self):
        """Save checkpoint to disk."""
        self.data["last_saved"] = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(self.path, "w") as f:
            json.dump(self.data, f)
        self.tiles_since_save = 0

    def should_save(self) -> bool:
        """Check if it's time to save a checkpoint."""
        return self.tiles_since_save >= self.save_interval

    def mark_tile_processed(self, z: int, x: int, y: int):
        """Mark a tile as processed."""
        key = f"{z}/{x}/{y}"
        self.data["processed_tiles"].append(key)
        self.data["last_position"] = {"zoom": z, "x": x, "y": y}
        self.data["stats"]["processed"] += 1
        self.tiles_since_save += 1

    def mark_tile_missing(self):
        """Increment missing tile count."""
        self.data["stats"]["missing"] += 1
        self.tiles_since_save += 1

    def mark_tile_failed(self):
        """Increment failed tile count."""
        self.data["stats"]["failed"] += 1
        self.tiles_since_save += 1

    def is_tile_processed(self, z: int, x: int, y: int) -> bool:
        """Check if a tile was already processed."""
        key = f"{z}/{x}/{y}"
        return key in self._processed_set

    def add_label(self, label: dict):
        """Add a label to checkpoint data (dedup key is computed from lat/lon)."""
        self.data["labels"].append(label)
        # Store dedup key as (text, lat_e6, lon_e6)
        lat_e6 = int(label["lat"] * 1_000_000)
        lon_e6 = int(label["lon"] * 1_000_000)
        self.data["seen_label_keys"].append([label["text"], lat_e6, lon_e6])
        self.data["stats"]["labels_extracted"] += 1

    def get_seen_labels(self) -> set:
        """Get set of already-seen label keys as (text, lat_e6, lon_e6)."""
        return set(tuple(k) for k in self.data.get("seen_label_keys", []))

    def prepare_for_resume(self):
        """Build lookup structures for efficient resume checking."""
        self._processed_set = set(self.data.get("processed_tiles", []))

    def set_config(self, bounds, zoom_range):
        """Store configuration for validation on resume."""
        self.data["config"] = {
            "bounds": list(bounds) if bounds else None,
            "zoom_range": list(zoom_range) if zoom_range else None,
        }

    def validate_config(self, bounds, zoom_range) -> bool:
        """Check if current config matches checkpoint config."""
        stored = self.data.get("config", {})
        stored_bounds = tuple(stored.get("bounds")) if stored.get("bounds") else None
        stored_zoom = tuple(stored.get("zoom_range")) if stored.get("zoom_range") else None
        return stored_bounds == bounds and stored_zoom == zoom_range

    def delete(self):
        """Remove checkpoint file after successful completion."""
        if self.path.exists():
            self.path.unlink()
            print(f"Removed checkpoint file: {self.path}")


def convert_pmtiles(
    input_path: Path,
    output_path: Path,
    bounds: Optional[Tuple[float, float, float, float]] = None,
    zoom_range: Optional[Tuple[int, int]] = None,
    dry_run: bool = False,
    resume: bool = True,
    checkpoint_interval: int = 500,
    workers: int = None
):
    """
    Convert PMTiles vector tiles to TDMAP raster archive.

    Args:
        input_path: Path to input .pmtiles file
        output_path: Path to output .tdmap file
        bounds: Geographic bounds (west, south, east, north) or None for all
        zoom_range: (min_zoom, max_zoom) or None to use PMTiles metadata
        dry_run: Only count tiles, don't process
        resume: Whether to resume from checkpoint if available
        checkpoint_interval: Save checkpoint every N tiles
        workers: Number of parallel workers (default: CPU count)
    """
    # Default to number of CPUs
    if workers is None:
        workers = max(1, mp.cpu_count())

    print(f"Opening PMTiles: {input_path}")
    print(f"Using {workers} parallel workers")

    # Initialize land mask (downloads OSM data on first run)
    print("Initializing land mask...")
    land_mask = get_land_mask()
    if land_mask.land_polygons is not None:
        print("  Land mask ready (OSM simplified)")
    else:
        print("  Warning: Land mask not available, using fallback heuristics")

    # Checkpoint file path (same name as output with .checkpoint extension)
    checkpoint_path = output_path.with_suffix(".checkpoint")
    checkpoint = Checkpoint(checkpoint_path, save_interval=checkpoint_interval)

    # Load checkpoint if exists (validation happens after we know actual bounds/zoom)
    checkpoint_loaded = resume and checkpoint.load()

    with open(input_path, "rb") as f:
        source = MmapSource(f)
        reader = PMTilesReader(source)
        header = reader.header()

        # Get zoom range from header or arguments
        min_zoom = header.get("min_zoom", 0)
        max_zoom = header.get("max_zoom", 14)

        if zoom_range:
            min_zoom, max_zoom = zoom_range

        print(f"Tile type: {header.get('tile_type', 'unknown')}")
        print(f"Zoom range: {min_zoom} - {max_zoom}")

        if bounds:
            print(f"Bounds: {bounds}")
        else:
            # Try to get bounds from PMTiles (stored as e7 = degrees * 10^7)
            if "min_lon_e7" in header:
                pmtiles_bounds = (
                    header.get("min_lon_e7", -1800000000) / 1e7,
                    header.get("min_lat_e7", -850000000) / 1e7,
                    header.get("max_lon_e7", 1800000000) / 1e7,
                    header.get("max_lat_e7", 850000000) / 1e7,
                )
                bounds = pmtiles_bounds
                print(f"Bounds (from PMTiles): {bounds}")

        # Now that we have actual bounds/zoom, validate checkpoint
        effective_zoom_range = (min_zoom, max_zoom)
        resuming = False
        if checkpoint_loaded:
            if checkpoint.validate_config(bounds, effective_zoom_range):
                print("Resuming from checkpoint...")
                resuming = True
                checkpoint.prepare_for_resume()
            else:
                print("Warning: Checkpoint config doesn't match current settings.")
                print("  Starting fresh (old checkpoint will be overwritten).")
                checkpoint = Checkpoint(checkpoint_path, save_interval=checkpoint_interval)

        # Store config in checkpoint for new runs
        if not resuming:
            checkpoint.set_config(bounds, effective_zoom_range)

        # Estimate tile count
        total_tiles = 0
        for z in range(min_zoom, max_zoom + 1):
            total_tiles += count_tiles_in_bounds(bounds, z)

        print(f"Estimated tiles: {total_tiles:,}")

        if dry_run:
            # Rough size estimate
            estimated_size_mb = total_tiles * 3 / 1024  # ~3KB average per tile
            print(f"Estimated archive size: ~{estimated_size_mb:.0f} MB")
            return

        # Create archive writer
        writer = TDMAPWriter(output_path)

        # Initialize stats from checkpoint or fresh
        if resuming:
            # Check checkpoint version compatibility
            checkpoint_version = checkpoint.data.get("version", 1)
            if checkpoint_version < 2:
                print("Warning: Old checkpoint format (v1). Starting fresh.")
                resuming = False
                checkpoint = Checkpoint(checkpoint_path, save_interval=checkpoint_interval)
                checkpoint.set_config(bounds, effective_zoom_range)
                checkpoint.prepare_for_resume()

        if resuming:
            processed = checkpoint.data["stats"]["processed"]
            missing = checkpoint.data["stats"]["missing"]
            failed = checkpoint.data["stats"]["failed"]
            labels_extracted = checkpoint.data["stats"]["labels_extracted"]
            seen_labels = checkpoint.get_seen_labels()

            # Re-add labels from checkpoint to writer (v2 format: lat/lon)
            for label in checkpoint.data.get("labels", []):
                writer.add_label(
                    label["lat"],
                    label["lon"],
                    label["zoom_min"],
                    label["zoom_max"],
                    label["label_type"],
                    label["text"],
                )

            print(f"Resumed: {processed:,} tiles already processed, {labels_extracted:,} labels")
        else:
            processed = 0
            missing = 0
            failed = 0
            labels_extracted = 0
            seen_labels = set()
            checkpoint.prepare_for_resume()

        skipped = 0
        start_time = time.time()

        # Build list of tiles to process (excluding already-processed ones)
        tiles_to_process = []
        for z in range(min_zoom, max_zoom + 1):
            for x, y in get_tiles_in_bounds(bounds, z):
                if not checkpoint.is_tile_processed(z, x, y):
                    tiles_to_process.append((z, x, y))
                else:
                    skipped += 1

        remaining = len(tiles_to_process)
        print(f"\nTiles to process: {remaining:,} (skipped {skipped:,} already done)")

        if remaining == 0:
            print("All tiles already processed!")
        else:
            try:
                # Create process pool with per-worker PMTiles readers
                with mp.Pool(
                    processes=workers,
                    initializer=_init_worker,
                    initargs=(str(input_path),)
                ) as pool:

                    # Process tiles in parallel using imap_unordered for memory efficiency
                    # chunksize balances overhead vs responsiveness
                    chunksize = max(1, min(100, remaining // (workers * 4)))

                    results_iter = pool.imap_unordered(
                        _process_tile_worker,
                        tiles_to_process,
                        chunksize=chunksize
                    )

                    # Collect results
                    for result in results_iter:
                        z, x, y = result["z"], result["x"], result["y"]

                        if result["status"] == "missing":
                            missing += 1
                            checkpoint.mark_tile_missing()

                        elif result["status"] == "failed":
                            print(f"\nFailed tile z={z} x={x} y={y}: {result.get('error', 'unknown')}")
                            failed += 1
                            checkpoint.mark_tile_failed()

                        elif result["status"] == "ok":
                            # Add tile to archive
                            writer.add_tile(z, x, y, result["data"])
                            processed += 1
                            checkpoint.mark_tile_processed(z, x, y)

                            # Process labels (v4 format: lat/lon, dedupe by text+coords)
                            for label in result.get("labels", []):
                                # Compute dedup key from coordinates
                                lat_e6 = int(label["lat"] * 1_000_000)
                                lon_e6 = int(label["lon"] * 1_000_000)
                                label_key = (label["text"], lat_e6, lon_e6)
                                if label_key not in seen_labels:
                                    seen_labels.add(label_key)
                                    writer.add_label(
                                        label["lat"],
                                        label["lon"],
                                        label["zoom_min"],
                                        label["zoom_max"],
                                        label["label_type"],
                                        label["text"],
                                    )
                                    labels_extracted += 1
                                    checkpoint.add_label(label)

                            # Periodic checkpoint save
                            if checkpoint.should_save():
                                checkpoint.save()
                                print(f"\n  [Checkpoint saved at {processed:,} tiles]")

                        # Progress indicator
                        total_handled = processed + missing + failed
                        if total_handled % 100 == 0:
                            elapsed = time.time() - start_time
                            # Calculate rate based only on content tiles (excludes empty water tiles)
                            content_tiles = processed + failed
                            content_rate = content_tiles / elapsed if elapsed > 0 else 0
                            # ETA based on worst-case (all remaining are content tiles)
                            tiles_left = remaining - total_handled
                            eta = tiles_left / content_rate if content_rate > 0 else 0
                            print(f"\r  Progress: {total_handled:,}/{remaining:,} "
                                  f"({content_rate:.1f} content/s, ETA: {eta/60:.0f}m) "
                                  f"[empty: {missing}, failed: {failed}, labels: {labels_extracted}]",
                                  end="", flush=True)

                    print()  # Newline after progress

            except KeyboardInterrupt:
                print("\n\nInterrupted! Saving checkpoint...")
                checkpoint.save()
                print(f"Checkpoint saved. Run again to resume from {processed:,} tiles.")
                sys.exit(1)

        print(f"\nWriting archive to {output_path}...")
        writer.write()

        print("\nVerifying archive...")
        verify_archive(output_path)

        # Clean up checkpoint on success
        checkpoint.delete()

        elapsed = time.time() - start_time
        print(f"\nComplete! (took {elapsed/60:.1f} minutes)")
        print(f"  Tiles processed: {processed:,}")
        print(f"  Tiles missing: {missing:,}")
        print(f"  Tiles failed: {failed}")
        print(f"  Labels extracted: {labels_extracted:,}")


def parse_bounds(bounds_str: str) -> Tuple[float, float, float, float]:
    """Parse bounds string 'west,south,east,north' to tuple."""
    parts = [float(x.strip()) for x in bounds_str.split(",")]
    if len(parts) != 4:
        raise ValueError("Bounds must be 'west,south,east,north'")
    return tuple(parts)


def parse_zoom(zoom_str: str) -> Tuple[int, int]:
    """Parse zoom string 'min,max' to tuple."""
    parts = [int(x.strip()) for x in zoom_str.split(",")]
    if len(parts) == 1:
        return (parts[0], parts[0])
    elif len(parts) == 2:
        return tuple(parts)
    else:
        raise ValueError("Zoom must be 'min,max' or single value")


def main():
    parser = argparse.ArgumentParser(
        description="Convert PMTiles vector tiles to TDMAP raster archive for T-Deck",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s netherlands.pmtiles -o netherlands.tdmap
      Convert all tiles in the PMTiles file

  %(prog)s netherlands.pmtiles --bounds 4.0,52.0,5.5,52.5 --zoom 10,14 -o amsterdam.tdmap
      Convert only tiles within specified bounds and zoom range

  %(prog)s netherlands.pmtiles -j 8 -o netherlands.tdmap
      Use 8 parallel workers for faster processing

  %(prog)s netherlands.pmtiles --dry-run
      Estimate tile count without processing

Parallelization:
  By default, uses all available CPU cores for parallel tile processing.
  Use -j/--workers to limit or increase the number of workers.

Resume behavior:
  The script automatically saves checkpoints every 500 tiles (configurable).
  If interrupted (Ctrl+C), simply run the same command again to resume.
  Use --no-resume to force starting fresh.
  Checkpoint files are named <output>.checkpoint and deleted on success.
"""
    )

    parser.add_argument(
        "input",
        type=Path,
        help="Input .pmtiles file"
    )

    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=None,
        help="Output .tdmap file (default: input name with .tdmap extension)"
    )

    parser.add_argument(
        "--bounds", "-b",
        type=str,
        help="Geographic bounds: west,south,east,north (degrees)"
    )

    parser.add_argument(
        "--zoom", "-z",
        type=str,
        help="Zoom range: min,max (e.g., '10,14')"
    )

    parser.add_argument(
        "--dry-run", "-n",
        action="store_true",
        help="Only estimate tile count, don't process"
    )

    parser.add_argument(
        "--no-resume",
        action="store_true",
        help="Don't resume from checkpoint, start fresh"
    )

    parser.add_argument(
        "--checkpoint-interval",
        type=int,
        default=500,
        metavar="N",
        help="Save checkpoint every N tiles (default: 500)"
    )

    parser.add_argument(
        "--workers", "-j",
        type=int,
        default=None,
        metavar="N",
        help=f"Number of parallel workers (default: CPU count = {mp.cpu_count()})"
    )

    args = parser.parse_args()

    # Validate input
    if not args.input.exists():
        print(f"Error: Input file not found: {args.input}")
        sys.exit(1)

    # Default output name
    output_path = args.output
    if output_path is None:
        output_path = args.input.with_suffix(".tdmap")

    # Parse bounds and zoom
    bounds = None
    zoom_range = None

    if args.bounds:
        bounds = parse_bounds(args.bounds)

    if args.zoom:
        zoom_range = parse_zoom(args.zoom)

    # Print configuration
    print("PMTiles to TDMAP Converter")
    print("=" * 40)
    print(f"Input: {args.input}")
    print(f"Output: {output_path}")
    print()

    # Convert
    convert_pmtiles(
        args.input,
        output_path,
        bounds=bounds,
        zoom_range=zoom_range,
        dry_run=args.dry_run,
        resume=not args.no_resume,
        checkpoint_interval=args.checkpoint_interval,
        workers=args.workers
    )


if __name__ == "__main__":
    main()
