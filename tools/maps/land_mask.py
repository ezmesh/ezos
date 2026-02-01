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
        self._initialized = False

    def initialize(self) -> bool:
        """Load land polygons. Returns True if successful."""
        if self._initialized:
            return self.land_polygons is not None

        self._initialized = True

        if not HAS_SHAPELY:
            print("Warning: shapely not installed. Install with: pip install shapely")
            print("Falling back to simple latitude-based heuristic.")
            return False

        # Try to load cached GeoJSON first (already in WGS84)
        if LAND_GEOJSON.exists():
            return self._load_geojson()

        # Try to load from shapefile (Mercator, needs transform)
        if LAND_SHAPEFILE.exists():
            return self._load_shapefile()

        # Download OSM land data
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
        if self.prepared_land is None:
            # Fallback: simple latitude-based heuristic
            return self._simple_land_check(z, x, y)

        west, south, east, north = self.tile_to_bbox(z, x, y)

        # Check tile center point
        center_lon = (west + east) / 2
        center_lat = (south + north) / 2

        from shapely.geometry import Point
        center = Point(center_lon, center_lat)

        return self.prepared_land.contains(center)

    def tile_intersects_land(self, z: int, x: int, y: int) -> bool:
        """Check if tile bbox intersects any land polygon."""
        if self.prepared_land is None:
            return self._simple_land_check(z, x, y)

        west, south, east, north = self.tile_to_bbox(z, x, y)
        tile_box = box(west, south, east, north)

        return self.prepared_land.intersects(tile_box)

    def get_land_fraction(self, z: int, x: int, y: int) -> float:
        """
        Estimate what fraction of the tile is land (0.0 to 1.0).

        Useful for deciding background when tile has partial land coverage.
        """
        if self.prepared_land is None:
            return 0.5 if self._simple_land_check(z, x, y) else 0.0

        west, south, east, north = self.tile_to_bbox(z, x, y)
        tile_box = box(west, south, east, north)

        if not self.prepared_land.intersects(tile_box):
            return 0.0

        try:
            intersection = self.land_polygons.intersection(tile_box)
            return intersection.area / tile_box.area
        except Exception:
            # Geometry error, fall back to contains check
            return 1.0 if self.is_land_tile(z, x, y) else 0.0

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
