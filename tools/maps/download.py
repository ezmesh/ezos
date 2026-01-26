"""
Tile downloading with caching and rate limiting.
Fetches PNG tiles from Stadia Maps Stamen Toner style.
"""

import os
import time
import math
from pathlib import Path
from typing import Optional, Tuple, Iterator

import requests

from config import TILE_SOURCE, TILE_SIZE


class TileDownloader:
    """Downloads map tiles with local caching and rate limiting."""

    def __init__(self, cache_dir: Optional[Path] = None):
        """
        Initialize downloader with cache directory.

        Args:
            cache_dir: Path to cache downloaded tiles. Defaults to tools/maps/.cache
        """
        if cache_dir is None:
            cache_dir = Path(__file__).parent / ".cache"
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)

        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": TILE_SOURCE["user_agent"]
        })

        self.last_request_time = 0
        self.rate_limit_sec = TILE_SOURCE["rate_limit_ms"] / 1000.0

        # Statistics
        self.tiles_downloaded = 0
        self.tiles_cached = 0
        self.bytes_downloaded = 0

    def _cache_path(self, z: int, x: int, y: int) -> Path:
        """Get cache file path for a tile."""
        return self.cache_dir / str(z) / str(x) / f"{y}.png"

    def _rate_limit(self):
        """Enforce rate limiting between requests."""
        elapsed = time.time() - self.last_request_time
        if elapsed < self.rate_limit_sec:
            time.sleep(self.rate_limit_sec - elapsed)
        self.last_request_time = time.time()

    def get_tile(self, z: int, x: int, y: int) -> Optional[bytes]:
        """
        Get a tile, from cache if available, otherwise download.

        Args:
            z: Zoom level
            x: Tile X coordinate
            y: Tile Y coordinate

        Returns:
            PNG image data as bytes, or None on failure
        """
        cache_path = self._cache_path(z, x, y)

        # Check cache first
        if cache_path.exists():
            self.tiles_cached += 1
            return cache_path.read_bytes()

        # Download tile
        self._rate_limit()
        url = TILE_SOURCE["url"].format(z=z, x=x, y=y)

        try:
            response = self.session.get(url, timeout=30)
            response.raise_for_status()

            # Cache the tile
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_bytes(response.content)

            self.tiles_downloaded += 1
            self.bytes_downloaded += len(response.content)

            return response.content

        except requests.RequestException as e:
            print(f"Failed to download tile z={z} x={x} y={y}: {e}")
            return None

    def get_stats(self) -> dict:
        """Get download statistics."""
        return {
            "downloaded": self.tiles_downloaded,
            "cached": self.tiles_cached,
            "bytes": self.bytes_downloaded,
        }


def lat_lon_to_tile(lat: float, lon: float, zoom: int) -> Tuple[int, int]:
    """
    Convert latitude/longitude to tile coordinates at given zoom level.
    Uses Web Mercator projection (EPSG:3857).

    Args:
        lat: Latitude in degrees (-85.05 to 85.05)
        lon: Longitude in degrees (-180 to 180)
        zoom: Zoom level (0-19)

    Returns:
        Tuple of (tile_x, tile_y)
    """
    n = 2 ** zoom
    x = int((lon + 180.0) / 360.0 * n)
    lat_rad = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return (x, y)


def tile_to_lat_lon(x: int, y: int, zoom: int) -> Tuple[float, float]:
    """
    Convert tile coordinates to latitude/longitude (top-left corner of tile).

    Args:
        x: Tile X coordinate
        y: Tile Y coordinate
        zoom: Zoom level

    Returns:
        Tuple of (latitude, longitude) in degrees
    """
    n = 2 ** zoom
    lon = x / n * 360.0 - 180.0
    lat_rad = math.atan(math.sinh(math.pi * (1 - 2 * y / n)))
    lat = math.degrees(lat_rad)
    return (lat, lon)


def get_tiles_in_bounds(
    bounds: Optional[Tuple[float, float, float, float]],
    zoom: int
) -> Iterator[Tuple[int, int]]:
    """
    Generate all tile coordinates within geographic bounds at given zoom.

    Args:
        bounds: (west, south, east, north) in degrees, or None for full world
        zoom: Zoom level

    Yields:
        (x, y) tile coordinates
    """
    n = 2 ** zoom

    if bounds is None:
        # Full world coverage
        for x in range(n):
            for y in range(n):
                yield (x, y)
    else:
        west, south, east, north = bounds

        # Convert bounds to tile coordinates
        x_min, y_max = lat_lon_to_tile(south, west, zoom)
        x_max, y_min = lat_lon_to_tile(north, east, zoom)

        # Clamp to valid range
        x_min = max(0, x_min)
        x_max = min(n - 1, x_max)
        y_min = max(0, y_min)
        y_max = min(n - 1, y_max)

        for x in range(x_min, x_max + 1):
            for y in range(y_min, y_max + 1):
                yield (x, y)


def count_tiles_in_bounds(
    bounds: Optional[Tuple[float, float, float, float]],
    zoom: int
) -> int:
    """Count number of tiles in bounds at given zoom level."""
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
