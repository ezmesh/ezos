"""
Land mask module for determining tile backgrounds.

Uses OpenStreetMap simplified land polygons to determine whether a tile
should have a land or water background. This ensures coastlines align
with OSM road data at all zoom levels.

On first run, downloads the OSM simplified land polygons (~24MB).
This provides coastlines suitable for zoom levels 0-14.
"""

import os
import urllib.request
import zipfile
from pathlib import Path
from typing import Tuple, Optional
import math

import numpy as np

# Optional: Use shapely for polygon operations if available
try:
    from shapely.geometry import box, shape
    from shapely.prepared import prep
    from shapely.ops import unary_union, transform
    import json
    HAS_SHAPELY = True
except ImportError:
    HAS_SHAPELY = False

# OSM simplified land polygons (~24MB) - generalized to ~300m, suitable for zoom 0-14
# Uses Mercator projection (EPSG:3857), will be transformed to WGS84 on load
OSM_LAND_URL = "https://osmdata.openstreetmap.de/download/simplified-land-polygons-complete-3857.zip"
CACHE_DIR = Path(__file__).parent / ".cache"
LAND_SHAPEFILE = CACHE_DIR / "simplified-land-polygons-complete-3857" / "simplified_land_polygons.shp"
LAND_GEOJSON = CACHE_DIR / "osm_land_wgs84.geojson"

# Committable sidecar: a low-resolution bit-packed land/water raster in
# equirectangular projection covering the whole globe. Produced once by
# `python land_mask.py quantize` and checked into the repo so fresh clones /
# CI runs don't need to download 24MB of polygons. Loads in milliseconds.
SIDECAR_DIR = Path(__file__).parent / "data"
SIDECAR_PATH = SIDECAR_DIR / "land_mask_2048x1024.npz"
SIDECAR_W = 2048  # longitude axis (-180..180 → 0..W)
SIDECAR_H = 1024  # latitude axis (90..-90 → 0..H)


def mercator_to_wgs84(x: float, y: float) -> Tuple[float, float]:
    """
    Convert Web Mercator (EPSG:3857) coordinates to WGS84 (EPSG:4326).

    Returns (longitude, latitude) in degrees.
    """
    # Web Mercator to WGS84 conversion
    # x is in meters, y is in meters
    EARTH_RADIUS = 6378137.0  # WGS84 semi-major axis

    lon = (x / EARTH_RADIUS) * (180.0 / math.pi)
    lat = (2.0 * math.atan(math.exp(y / EARTH_RADIUS)) - math.pi / 2.0) * (180.0 / math.pi)

    return (lon, lat)


def transform_mercator_to_wgs84(geom):
    """Transform a shapely geometry from Mercator to WGS84."""
    return transform(lambda x, y: mercator_to_wgs84(x, y), geom)


def download_osm_land() -> bool:
    """Download OSM simplified land polygons if not cached."""
    if LAND_GEOJSON.exists():
        return True

    CACHE_DIR.mkdir(exist_ok=True)
    zip_path = CACHE_DIR / "simplified-land-polygons-complete-3857.zip"

    print(f"Downloading OSM simplified land polygons (~24MB)...")
    try:
        urllib.request.urlretrieve(OSM_LAND_URL, zip_path)
    except Exception as e:
        print(f"Failed to download OSM land data: {e}")
        return False

    print("Extracting...")
    try:
        with zipfile.ZipFile(zip_path, 'r') as zf:
            zf.extractall(CACHE_DIR)
    except Exception as e:
        print(f"Failed to extract: {e}")
        return False

    print("OSM land data ready.")
    return True


class LandMask:
    """
    Determines whether map tiles are over land or water.

    Uses OSM simplified land polygons for accurate lookups that align
    with OSM road data. The simplified version (~300m resolution) is
    suitable for zoom levels 0-14.
    """

    def __init__(self):
        self.land_polygons = None
        self.prepared_land = None
        # Bit-packed global raster (1 = land, 0 = water) used as a fast fallback
        # when the full polygon set isn't available.
        self.bitmap: Optional[np.ndarray] = None
        self._initialized = False

    def initialize(self, *, allow_download: bool = True) -> bool:
        """Load land polygons. Returns True if any lookup backend is available.

        Tries in order: shapely polygons from cache → committed sidecar bitmap
        → download + regenerate. When ``allow_download`` is False (CI), skip
        the 24MB download and accept bitmap-only lookups.
        """
        if self._initialized:
            return self.land_polygons is not None or self.bitmap is not None

        self._initialized = True

        # Prefer the full polygon set (enables coastline drawing on mixed tiles).
        if HAS_SHAPELY:
            if LAND_GEOJSON.exists() and self._load_geojson():
                return True
            if LAND_SHAPEFILE.exists() and self._load_shapefile():
                return True
        else:
            print("Warning: shapely not installed. Install with: pip install shapely")

        # Fall back to the committed sidecar bitmap. Good enough for tile
        # background decisions at z≤10; higher zooms rely on the vector tile's
        # own coastline data.
        if self._load_bitmap():
            return True

        if not allow_download:
            print("Land mask: no polygons or sidecar available, and download is disabled.")
            return False

        # Last resort: download the 24MB archive and regenerate.
        if not download_osm_land():
            return False
        return self._load_shapefile()

    def _load_geojson(self) -> bool:
        """Load land polygons from cached GeoJSON (already WGS84)."""
        try:
            print("Loading OSM land mask from cache...")
            with open(LAND_GEOJSON, 'r') as f:
                data = json.load(f)

            polygons = []
            for feature in data.get('features', []):
                geom = shape(feature['geometry'])
                polygons.append(geom)

            self.land_polygons = unary_union(polygons)
            self.prepared_land = prep(self.land_polygons)
            print(f"Loaded OSM land mask from GeoJSON cache")
            return True
        except Exception as e:
            print(f"Failed to load GeoJSON: {e}")
            return False

    def _load_shapefile(self) -> bool:
        """Load land polygons from shapefile, transform to WGS84, and cache."""
        try:
            import shapefile  # pyshp
        except ImportError:
            print("Warning: pyshp not installed. Install with: pip install pyshp")
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
                # Transform from Mercator to WGS84
                geom_wgs84 = transform_mercator_to_wgs84(geom)
                polygons.append(geom_wgs84)

            print("Merging polygons...")
            self.land_polygons = unary_union(polygons)
            self.prepared_land = prep(self.land_polygons)

            # Cache as GeoJSON for faster future loads
            print("Caching as GeoJSON for faster future loads...")
            geojson = {
                'type': 'FeatureCollection',
                'features': [{
                    'type': 'Feature',
                    'geometry': self.land_polygons.__geo_interface__,
                    'properties': {}
                }]
            }
            with open(LAND_GEOJSON, 'w') as f:
                json.dump(geojson, f)

            print(f"Loaded OSM land mask, cached as GeoJSON")
            return True
        except Exception as e:
            print(f"Failed to load shapefile: {e}")
            import traceback
            traceback.print_exc()
            return False

    # -----------------------------------------------------------------------
    # Sidecar bitmap
    # -----------------------------------------------------------------------

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
            print(f"Loaded land sidecar {width}x{height} ({SIDECAR_PATH.name})")
            return True
        except Exception as e:
            print(f"Failed to load land sidecar: {e}")
            return False

    def _sample_bitmap(self, lat: float, lon: float) -> bool:
        """Look up a single (lat, lon) point in the bitmap. Assumes equirectangular
        projection: x ∈ [0, W) maps to lon ∈ [-180, 180), y ∈ [0, H) maps to
        lat ∈ (90, -90]."""
        if self.bitmap is None:
            return False
        h, w = self.bitmap.shape
        # Wrap lon into [-180, 180); clamp lat to [-90, 90].
        lon = ((lon + 180.0) % 360.0) - 180.0
        lat = max(-90.0, min(90.0, lat))
        x = int((lon + 180.0) / 360.0 * w) % w
        y = int((90.0 - lat) / 180.0 * h)
        if y >= h:
            y = h - 1
        return bool(self.bitmap[y, x])

    def quantize_to_bitmap(self, width: int = SIDECAR_W, height: int = SIDECAR_H) -> np.ndarray:
        """Rasterize the loaded land polygons into an equirectangular bitmap.

        Requires that `self.land_polygons` is populated (run with a full
        shapely polygon set). Returns a boolean array of shape (height, width).
        """
        if self.land_polygons is None:
            raise RuntimeError("quantize_to_bitmap requires loaded polygons")

        from shapely.geometry import box as shp_box
        bitmap = np.zeros((height, width), dtype=bool)

        # Sample the center of each pixel. For a 2048×1024 grid this is ~2M
        # point-in-polygon tests; slow but a one-shot generator step, so fine.
        # Process row-by-row; print progress every 64 rows.
        for row in range(height):
            if row % 64 == 0:
                print(f"  quantize row {row}/{height}")
            lat = 90.0 - (row + 0.5) / height * 180.0
            # Build a single horizontal strip box and intersect polygons once
            # per row, then test each column center against the strip.
            strip = shp_box(-180.0, lat - 180.0 / height / 2,
                             180.0, lat + 180.0 / height / 2)
            if not self.prepared_land.intersects(strip):
                continue
            row_polys = self.land_polygons.intersection(strip)
            from shapely.prepared import prep
            row_prepared = prep(row_polys)
            from shapely.geometry import Point
            for col in range(width):
                lon = -180.0 + (col + 0.5) / width * 360.0
                if row_prepared.contains(Point(lon, lat)):
                    bitmap[row, col] = True

        return bitmap

    def save_bitmap(self, bitmap: np.ndarray, path: Path = SIDECAR_PATH) -> None:
        """Bit-pack and persist a bitmap produced by quantize_to_bitmap()."""
        path.parent.mkdir(parents=True, exist_ok=True)
        h, w = bitmap.shape
        packed = np.packbits(bitmap.astype(np.uint8).ravel())
        np.savez_compressed(path, packed=packed, width=w, height=h)
        print(f"Wrote {path} ({path.stat().st_size // 1024} KB)")

    def tile_to_bbox(self, z: int, x: int, y: int) -> Tuple[float, float, float, float]:
        """Convert tile coordinates to lat/lon bounding box (west, south, east, north)."""
        n = 2 ** z

        # Tile edges in longitude
        west = x / n * 360.0 - 180.0
        east = (x + 1) / n * 360.0 - 180.0

        # Tile edges in latitude (Web Mercator)
        north_rad = math.atan(math.sinh(math.pi * (1 - 2 * y / n)))
        south_rad = math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n)))
        north = math.degrees(north_rad)
        south = math.degrees(south_rad)

        return (west, south, east, north)

    def is_land_tile(self, z: int, x: int, y: int) -> bool:
        """
        Check if a tile is predominantly over land.

        Returns True if the tile center is over land, False otherwise.
        For tiles that straddle the coastline, the vector tile's land
        polygons will provide the actual boundary.
        """
        west, south, east, north = self.tile_to_bbox(z, x, y)
        center_lon = (west + east) / 2
        center_lat = (south + north) / 2

        if self.prepared_land is not None:
            from shapely.geometry import Point
            return self.prepared_land.contains(Point(center_lon, center_lat))

        if self.bitmap is not None:
            return self._sample_bitmap(center_lat, center_lon)

        return self._simple_land_check(z, x, y)

    def tile_intersects_land(self, z: int, x: int, y: int) -> bool:
        """Check if tile bbox intersects any land polygon."""
        west, south, east, north = self.tile_to_bbox(z, x, y)

        if self.prepared_land is not None:
            return self.prepared_land.intersects(box(west, south, east, north))

        if self.bitmap is not None:
            # Sample a 4×4 grid inside the tile; any hit = intersects.
            for i in range(4):
                for j in range(4):
                    lat = south + (north - south) * (i + 0.5) / 4
                    lon = west + (east - west) * (j + 0.5) / 4
                    if self._sample_bitmap(lat, lon):
                        return True
            return False

        return self._simple_land_check(z, x, y)

    def get_land_fraction(self, z: int, x: int, y: int) -> float:
        """
        Estimate what fraction of the tile is land (0.0 to 1.0).

        Useful for deciding background when tile has partial land coverage.
        """
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
            # Approximate via 4×4 sampling. Coarse but stable and ~30× faster
            # than shapely for the tile-background decision.
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
        """
        Simple fallback when shapely is not available.

        Uses basic latitude check - most land is between 60S and 85N,
        and most ocean is outside this range or in specific areas.
        This is very approximate!
        """
        west, south, east, north = self.tile_to_bbox(z, x, y)
        center_lat = (south + north) / 2
        center_lon = (west + east) / 2

        # Antarctica and Arctic are mostly not land at sea level
        if center_lat < -60 or center_lat > 85:
            return False

        # Very rough ocean detection (Atlantic, Pacific centers)
        if -30 < center_lon < -10 and -60 < center_lat < 60:
            return False  # Atlantic
        if 150 < abs(center_lon) and -60 < center_lat < 60:
            return False  # Pacific

        return True


# Global instance for reuse
_land_mask: Optional[LandMask] = None


def get_land_mask() -> LandMask:
    """Get or create the global land mask instance."""
    global _land_mask
    if _land_mask is None:
        _land_mask = LandMask()
        _land_mask.initialize()
    return _land_mask


def is_land_tile(z: int, x: int, y: int) -> bool:
    """Convenience function to check if a tile is over land."""
    return get_land_mask().is_land_tile(z, x, y)


def _cli() -> int:
    import argparse
    p = argparse.ArgumentParser(
        prog="python land_mask.py",
        description="Land mask sidecar generator")
    sub = p.add_subparsers(dest="cmd", required=True)

    pq = sub.add_parser("quantize", help="Generate the committable sidecar bitmap")
    pq.add_argument("--width", type=int, default=SIDECAR_W)
    pq.add_argument("--height", type=int, default=SIDECAR_H)
    pq.add_argument("--output", type=Path, default=SIDECAR_PATH)

    args = p.parse_args()
    if args.cmd == "quantize":
        mask = LandMask()
        # Force the shapely path so we have polygons to rasterize.
        if not (LAND_GEOJSON.exists() or LAND_SHAPEFILE.exists()):
            if not download_osm_land():
                print("quantize: OSM land data download failed")
                return 1
        if not mask.initialize(allow_download=True):
            print("quantize: could not load polygons")
            return 1
        if mask.land_polygons is None:
            print("quantize: shapely polygons unavailable; cannot rasterize")
            return 1
        bitmap = mask.quantize_to_bitmap(args.width, args.height)
        mask.save_bitmap(bitmap, args.output)
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
