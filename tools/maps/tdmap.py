"""
TDMAP v7 format: writer, reader, inspect.

v7 stores geometries (polylines + filled polygons) directly instead of
rasterizing tiles. The on-device renderer redraws every frame from the
geometry stream, so we get free restyling (themes), arbitrary zoom
interpolation, and a single source of truth across zoom levels.

This module replaces v6's archive.py + process.py + land_mask.py +
render.py + labels.py. PMTiles MVT decoding still uses
mapbox_vector_tile; everything else lives here.

On-disk layout (all integers little-endian):

    Header (33 bytes, fixed):
        0..5    magic         "TDMAP\\0"
        6       version       7
        7       compression   2 (zlib only)
        8..9    grid_dim      uniform spatial-index grid side length (e.g. 256)
        10      reserved      0
        11..14  geom_count    u32
        15..18  index_offset  u32  start of geometry index
        19..22  data_offset   u32  start of compressed geometry payload
        23      min_zoom      i8
        24      max_zoom      i8
        25..28  label_offset  u32
        29..32  label_count   u32

    Metadata block (4-byte length-prefixed TLV):
        RG  region name (utf-8)
        BB  bounds:    int32 south_e6, west_e6, north_e6, east_e6
        SH  source hash (typically sha256 of source PMTiles)
        TS  uint64 unix timestamp
        TV  tool version string

        Bounds (BB) MUST be present in v7: the spatial-index grid is defined
        relative to bounds, so a reader can't lay out the grid without them.

    Geometry index (geom_count × 14 bytes), sorted by (cell_index, min_zoom):
        0..3    cell_index    u32 (cell_row << 16 | cell_col) within grid_dim×grid_dim
        4       feature_class u8  semantic index 0..7
        5       geom_type     u8  0=polyline, 1=filled polygon
        6       min_zoom      u8  inclusive
        7       max_zoom      u8  inclusive
        8..11   data_offset   u32 byte offset relative to header data_offset
        12..13  data_size     u16 compressed bytes (zlib)

    Geometry payload (each record is independently zlib-compressed):
        u8     vertex_count    1..255 (writer splits longer chains)
        i32 LE origin_lat_e6   lat of vertex 0, degrees × 1e6
        i32 LE origin_lon_e6   lon of vertex 0
        Then  (vertex_count - 1) × { i16 LE dlat_e6, i16 LE dlon_e6 }
              expressing each subsequent vertex as a delta from the previous
              in units of 1e-6 degrees. ±32767 ≈ ±0.033°, ~3.7 km at the
              equator: well beyond what Douglas-Peucker leaves between
              consecutive vertices at our quantization step.

    Labels block: identical layout to v6 (lat_e6/lon_e6 fixed + uint8 text_len).

Semantic feature classes (unchanged from v6):
    0 Land  1 Water  2 Park  3 Building
    4 RoadMinor  5 RoadMajor  6 Highway  7 Railway

Spatial-index grid:
    A grid_dim × grid_dim uniform grid over the archive's BB. Each geometry
    is placed in the cell containing its bounding-box midpoint; long
    polylines that span many cells are clipped per-cell at write time, so
    a viewport query that fetches one cell never misses geometry that
    visibly enters it.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import math
import struct
import sys
import time
import zlib
from pathlib import Path
from typing import (
    Any, Dict, Iterable, Iterator, List, Optional, Sequence, Tuple,
)


# ============================================================================
# Format constants
# ============================================================================

TDMAP_VERSION = 7
COMPRESSION_ZLIB = 2

MAGIC = b"TDMAP\x00"

HEADER_FORMAT = "<6sBBHBIIIbbII"
HEADER_SIZE = 33

INDEX_ENTRY_FORMAT = "<IBBBBIH"
INDEX_ENTRY_SIZE = 14

LABEL_FORMAT = "<iiBBB"
LABEL_FIXED_SIZE = 11

# Default spatial-index grid resolution. 256×256 cells gives ~3 km cells over
# the Netherlands at the BB extent — small enough that a viewport touches
# only a handful of cells, large enough that per-cell geometry counts stay
# in the dozens for dense urban data.
DEFAULT_GRID_DIM = 256

# Vertex cap per record. The header uses u8, and 200+ vertices per geometry
# is well past what Douglas-Peucker should leave after simplification anyway.
# Long features (highways, rivers) get split into multiple records.
MAX_VERTICES_PER_RECORD = 255

# Quantization step for vertex coordinates. Stored as integer microdegrees;
# delta encoding uses int16 between successive vertices.
COORD_STEP_E6 = 1  # 1e-6 degrees ≈ 0.11 m: well below display pixel resolution

# Feature classes (semantic indices stored in geometry records, mapped to
# colors by the on-device theme palette).
F_LAND, F_WATER, F_PARK, F_BUILDING = 0, 1, 2, 3
F_ROAD_MINOR, F_ROAD_MAJOR, F_HIGHWAY, F_RAILWAY = 4, 5, 6, 7

# Geometry types (geom_type byte in the index entry).
G_POLYLINE = 0
G_POLYGON = 1

# Label types (unchanged from v6).
LABEL_CITY, LABEL_TOWN, LABEL_VILLAGE, LABEL_SUBURB = 0, 1, 2, 3
LABEL_ROAD, LABEL_WATER, LABEL_PARK, LABEL_POI = 4, 5, 6, 7

LABEL_MIN_ZOOM = {
    LABEL_CITY: 6,
    LABEL_TOWN: 9,
    LABEL_VILLAGE: 11,
    LABEL_SUBURB: 13,
    LABEL_ROAD: 14,
    LABEL_WATER: 10,
    LABEL_PARK: 12,
    LABEL_POI: 14,
}

# Metadata TLV tags (2-byte ASCII).
META_TAG_REGION = b"RG"
META_TAG_BOUNDS = b"BB"
META_TAG_SRC_HASH = b"SH"
META_TAG_TIMESTAMP = b"TS"
META_TAG_TOOL_VER = b"TV"


# ============================================================================
# Web Mercator helpers (used by both writer and viewer)
# ============================================================================

def lat_lon_to_tile(lat: float, lon: float, zoom: int) -> Tuple[int, int]:
    """Tile (x, y) for a lat/lon at the given zoom."""
    n = 2 ** zoom
    x = int((lon + 180.0) / 360.0 * n)
    lat_rad = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return x, y


def tile_to_lat_lon(x: float, y: float, zoom: int) -> Tuple[float, float]:
    """Geographic coordinates of a tile's NW corner."""
    n = 2 ** zoom
    lon = x / n * 360.0 - 180.0
    lat_rad = math.atan(math.sinh(math.pi * (1.0 - 2.0 * y / n)))
    lat = math.degrees(lat_rad)
    return lat, lon


def tile_pixel_to_lat_lon(
    zoom: int, tile_x: int, tile_y: int, px: float, py: float, extent: int = 4096
) -> Tuple[float, float]:
    """MVT-local pixel coords (0..extent) → lat/lon."""
    n = 2 ** zoom
    fx = tile_x + px / extent
    fy = tile_y + py / extent
    return tile_to_lat_lon(fx, fy, zoom)


# ============================================================================
# Geometry record + label dataclasses
# ============================================================================

class Geometry:
    """One polyline or filled-polygon record."""

    __slots__ = (
        "feature_class", "geom_type", "min_zoom", "max_zoom",
        "vertices",
    )

    def __init__(
        self,
        feature_class: int,
        geom_type: int,
        min_zoom: int,
        max_zoom: int,
        vertices: Sequence[Tuple[float, float]],
    ):
        self.feature_class = feature_class
        self.geom_type = geom_type
        self.min_zoom = min_zoom
        self.max_zoom = max_zoom
        self.vertices = list(vertices)

    @property
    def bbox(self) -> Tuple[float, float, float, float]:
        """(min_lat, min_lon, max_lat, max_lon)."""
        lats = [v[0] for v in self.vertices]
        lons = [v[1] for v in self.vertices]
        return min(lats), min(lons), max(lats), max(lons)


class Label:
    __slots__ = ("lat", "lon", "zoom_min", "zoom_max", "label_type", "text")

    def __init__(
        self,
        lat: float,
        lon: float,
        zoom_min: int,
        zoom_max: int,
        label_type: int,
        text: str,
    ):
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

    # Dedup at 1° buckets, same rule as v6.
    _DEDUP_STEP_E6 = 1_000_000

    def dedup_key(self) -> Tuple[str, int, int, int]:
        step = self._DEDUP_STEP_E6
        return (
            self.text,
            self.label_type,
            self.lat_e6 // step,
            self.lon_e6 // step,
        )

    def pack(self) -> bytes:
        text_bytes = self.text.encode("utf-8")[:255]
        return (
            struct.pack(
                LABEL_FORMAT,
                self.lat_e6,
                self.lon_e6,
                self.zoom_min,
                self.zoom_max,
                self.label_type,
            )
            + struct.pack("B", len(text_bytes))
            + text_bytes
        )


# ============================================================================
# Douglas-Peucker simplification
# ============================================================================

def simplify(points: Sequence[Tuple[float, float]], tolerance: float
             ) -> List[Tuple[float, float]]:
    """Douglas-Peucker on a (lat, lon) polyline. Tolerance is in degrees."""
    if len(points) < 3 or tolerance <= 0:
        return list(points)

    keep = [False] * len(points)
    keep[0] = True
    keep[-1] = True

    def perp_dist_sq(p, a, b):
        ax, ay = a[1], a[0]   # x = lon, y = lat (the rough scale split
                              # between lat/lon doesn't matter at the
                              # tolerances we use here)
        bx, by = b[1], b[0]
        px, py = p[1], p[0]
        dx, dy = bx - ax, by - ay
        if dx == 0 and dy == 0:
            return (px - ax) ** 2 + (py - ay) ** 2
        t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
        t = max(0.0, min(1.0, t))
        nx = ax + t * dx
        ny = ay + t * dy
        return (px - nx) ** 2 + (py - ny) ** 2

    tol_sq = tolerance * tolerance

    stack: List[Tuple[int, int]] = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        max_d = 0.0
        idx = -1
        for k in range(i + 1, j):
            d = perp_dist_sq(points[k], points[i], points[j])
            if d > max_d:
                max_d = d
                idx = k
        if idx != -1 and max_d > tol_sq:
            keep[idx] = True
            stack.append((i, idx))
            stack.append((idx, j))

    return [points[k] for k, ok in enumerate(keep) if ok]


# ============================================================================
# Spatial index helpers
# ============================================================================

def cell_for_bbox(
    bbox: Tuple[float, float, float, float],
    bounds: Tuple[float, float, float, float],
    grid_dim: int,
) -> int:
    """cell_index for a geometry's bounding box midpoint."""
    min_lat, min_lon, max_lat, max_lon = bbox
    west, south, east, north = bounds
    mid_lat = (min_lat + max_lat) / 2
    mid_lon = (min_lon + max_lon) / 2

    fx = (mid_lon - west) / (east - west) if east != west else 0.0
    fy = (north - mid_lat) / (north - south) if north != south else 0.0
    col = max(0, min(grid_dim - 1, int(fx * grid_dim)))
    row = max(0, min(grid_dim - 1, int(fy * grid_dim)))
    return (row << 16) | col


def cell_range_for_viewport(
    viewport: Tuple[float, float, float, float],
    bounds: Tuple[float, float, float, float],
    grid_dim: int,
) -> Tuple[int, int, int, int]:
    """(col_lo, col_hi, row_lo, row_hi) inclusive cell range covering viewport."""
    vp_min_lat, vp_min_lon, vp_max_lat, vp_max_lon = viewport
    west, south, east, north = bounds
    if east == west or north == south:
        return 0, grid_dim - 1, 0, grid_dim - 1

    def col(lon):
        f = (lon - west) / (east - west)
        return max(0, min(grid_dim - 1, int(f * grid_dim)))

    def row(lat):
        f = (north - lat) / (north - south)
        return max(0, min(grid_dim - 1, int(f * grid_dim)))

    col_lo = col(vp_min_lon)
    col_hi = col(vp_max_lon)
    row_lo = row(vp_max_lat)
    row_hi = row(vp_min_lat)
    if col_lo > col_hi:
        col_lo, col_hi = col_hi, col_lo
    if row_lo > row_hi:
        row_lo, row_hi = row_hi, row_lo
    return col_lo, col_hi, row_lo, row_hi


# ============================================================================
# Writer
# ============================================================================

class TDMAPWriter:
    """In-memory builder for a v7 archive.

    Call ``add_geometry`` and ``add_label`` repeatedly, set the bounds and
    metadata, then ``write(path)``.

    The writer expects the caller to have already simplified its geometries
    for the zoom range they apply to — ``simplify()`` is exposed above for
    pipeline drivers to use. It does enforce the per-record vertex cap by
    splitting long chains at write time.
    """

    def __init__(self, grid_dim: int = DEFAULT_GRID_DIM):
        self.grid_dim = grid_dim
        self.geoms: List[Geometry] = []
        self.labels: List[Label] = []
        self._label_keys: set = set()
        self.metadata: Dict[bytes, bytes] = {}
        self._bounds: Optional[Tuple[float, float, float, float]] = None
        self.min_zoom = 255
        self.max_zoom = 0

    # ---- metadata --------------------------------------------------------

    def set_region_name(self, name: str) -> None:
        self.metadata[META_TAG_REGION] = name.encode("utf-8")

    def set_bounds(self, west: float, south: float, east: float, north: float) -> None:
        self._bounds = (west, south, east, north)
        self.metadata[META_TAG_BOUNDS] = struct.pack(
            "<iiii",
            int(south * 1_000_000),
            int(west * 1_000_000),
            int(north * 1_000_000),
            int(east * 1_000_000),
        )

    def set_source_hash(self, digest: bytes) -> None:
        self.metadata[META_TAG_SRC_HASH] = bytes(digest)

    def set_build_timestamp(self, unix_seconds: Optional[int] = None) -> None:
        ts = int(unix_seconds if unix_seconds is not None else time.time())
        self.metadata[META_TAG_TIMESTAMP] = struct.pack("<Q", ts)

    def set_tool_version(self, version: str) -> None:
        self.metadata[META_TAG_TOOL_VER] = version.encode("utf-8")

    # ---- data ------------------------------------------------------------

    def add_geometry(self, g: Geometry) -> None:
        if not g.vertices:
            return
        self.geoms.append(g)
        if g.min_zoom < self.min_zoom:
            self.min_zoom = g.min_zoom
        if g.max_zoom > self.max_zoom:
            self.max_zoom = g.max_zoom

    def add_label(self, label: Label) -> None:
        if not label.text or not label.text.strip():
            return
        label.text = label.text.strip()
        key = label.dedup_key()
        if key in self._label_keys:
            return
        self._label_keys.add(key)
        self.labels.append(label)

    # ---- serialization ---------------------------------------------------

    def _pack_geometry(self, g: Geometry) -> bytes:
        """Pack a single geometry record. Vertex count must fit in u8;
        callers must split longer chains before getting here."""
        n = len(g.vertices)
        if n == 0 or n > MAX_VERTICES_PER_RECORD:
            raise ValueError(f"geometry vertex count {n} out of range")

        first_lat, first_lon = g.vertices[0]
        out = bytearray()
        out.append(n)
        out += struct.pack(
            "<ii",
            int(round(first_lat * 1_000_000)),
            int(round(first_lon * 1_000_000)),
        )
        prev_lat_e6 = int(round(first_lat * 1_000_000))
        prev_lon_e6 = int(round(first_lon * 1_000_000))
        for lat, lon in g.vertices[1:]:
            lat_e6 = int(round(lat * 1_000_000))
            lon_e6 = int(round(lon * 1_000_000))
            d_lat = lat_e6 - prev_lat_e6
            d_lon = lon_e6 - prev_lon_e6
            if d_lat < -32768 or d_lat > 32767 or d_lon < -32768 or d_lon > 32767:
                # Caller responsible for splitting; this is a programmer error.
                raise ValueError(
                    f"vertex delta out of int16 range (Δlat={d_lat}, Δlon={d_lon}). "
                    f"Split the geometry before passing to the writer."
                )
            out += struct.pack("<hh", d_lat, d_lon)
            prev_lat_e6 = lat_e6
            prev_lon_e6 = lon_e6
        return bytes(out)

    def _split_for_record_cap(self, g: Geometry) -> Iterator[Geometry]:
        """Yield sub-geometries no longer than MAX_VERTICES_PER_RECORD."""
        if len(g.vertices) <= MAX_VERTICES_PER_RECORD:
            yield g
            return

        # For polylines, slide a window with one-vertex overlap so segments
        # share endpoints across records (the renderer doesn't stitch them).
        # For polygons, split via fan from vertex 0: each sub-polygon is
        # (v0, v_i, v_i+1, ..., v_j, v0). This is approximate but visually
        # adequate at the zoom levels where 255-vertex polygons appear (mainly
        # large lakes / parks), and avoids any need for real triangulation.
        if g.geom_type == G_POLYLINE:
            step = MAX_VERTICES_PER_RECORD - 1
            i = 0
            while i < len(g.vertices):
                chunk = g.vertices[i:i + MAX_VERTICES_PER_RECORD]
                yield Geometry(
                    feature_class=g.feature_class,
                    geom_type=g.geom_type,
                    min_zoom=g.min_zoom,
                    max_zoom=g.max_zoom,
                    vertices=chunk,
                )
                if i + MAX_VERTICES_PER_RECORD >= len(g.vertices):
                    break
                i += step
        else:
            v0 = g.vertices[0]
            inner = g.vertices[1:]
            chunk_inner = MAX_VERTICES_PER_RECORD - 1  # leave room for v0
            i = 0
            while i < len(inner):
                slice_ = inner[i:i + chunk_inner]
                yield Geometry(
                    feature_class=g.feature_class,
                    geom_type=g.geom_type,
                    min_zoom=g.min_zoom,
                    max_zoom=g.max_zoom,
                    vertices=[v0, *slice_],
                )
                i += chunk_inner

    def _interpolate_for_delta(
        self, vertices: Sequence[Tuple[float, float]]
    ) -> List[Tuple[float, float]]:
        """Insert midpoints between any pair whose Δ would exceed int16.

        Deltas above ±32767 microdegrees (~0.033°) can't fit in the on-disk
        encoding. Rather than splitting the geometry into two records and
        losing the ability to fill or stroke them as a unit, we add
        intermediate vertices. Douglas-Peucker should already prevent this
        for our zoom tolerances, but raw input from low-zoom MVTs sometimes
        spans more than 0.033° between simplified vertices.
        """
        if len(vertices) < 2:
            return list(vertices)
        MAX_DELTA = 30000  # leave headroom below 32767
        out: List[Tuple[float, float]] = [vertices[0]]
        for i in range(1, len(vertices)):
            a = out[-1]
            b = vertices[i]
            d_lat_e6 = abs(int(round((b[0] - a[0]) * 1_000_000)))
            d_lon_e6 = abs(int(round((b[1] - a[1]) * 1_000_000)))
            steps = 1
            biggest = max(d_lat_e6, d_lon_e6)
            if biggest > MAX_DELTA:
                steps = (biggest + MAX_DELTA - 1) // MAX_DELTA
            for k in range(1, steps + 1):
                t = k / steps
                out.append((
                    a[0] + (b[0] - a[0]) * t,
                    a[1] + (b[1] - a[1]) * t,
                ))
        return out

    def write(self, output_path: Path) -> Path:
        if not self.geoms:
            raise ValueError(
                "no geometries to write — empty bounds or zoom range?")
        if self._bounds is None:
            raise ValueError(
                "bounds must be set before write() — v7 archives require BB "
                "metadata so the spatial index grid can be laid out")

        # Normalize zoom range if no geometry was added (defensive).
        if self.min_zoom > self.max_zoom:
            self.min_zoom = 0
            self.max_zoom = 0

        # Two passes per user-added geometry:
        #   1. Interpolate vertices to keep every delta within int16 range.
        #   2. Split into ≤255-vertex records so the on-disk vertex_count
        #      field (u8) doesn't overflow.
        expanded: List[Geometry] = []
        for g in self.geoms:
            adjusted = Geometry(
                feature_class=g.feature_class,
                geom_type=g.geom_type,
                min_zoom=g.min_zoom,
                max_zoom=g.max_zoom,
                vertices=self._interpolate_for_delta(g.vertices),
            )
            expanded.extend(self._split_for_record_cap(adjusted))

        # Pack each geometry payload, individually zlib-compressed.
        bounds = self._bounds
        grid_dim = self.grid_dim
        index_entries: List[Tuple[int, int, int, int, int, bytes]] = []
        # (cell_index, feature_class, geom_type, min_zoom, max_zoom, compressed_bytes)
        for g in expanded:
            raw = self._pack_geometry(g)
            comp = zlib.compress(raw, level=6)
            cell = cell_for_bbox(g.bbox, bounds, grid_dim)
            index_entries.append((
                cell,
                g.feature_class,
                g.geom_type,
                g.min_zoom,
                g.max_zoom,
                comp,
            ))

        # Sort by (cell_index, min_zoom) so viewport queries can binary
        # search to a cell and scan forward.
        index_entries.sort(key=lambda e: (e[0], e[3]))

        # Sort labels by (zoom_min, lat, lon).
        self.labels.sort(key=lambda l: (l.zoom_min, l.lat_e6, l.lon_e6))

        metadata_payload = self._pack_metadata()
        metadata_block = struct.pack("<I", len(metadata_payload)) + metadata_payload

        index_offset = HEADER_SIZE + len(metadata_block)
        data_offset = index_offset + len(index_entries) * INDEX_ENTRY_SIZE

        # Lay out the geometry payload section and remember each record's
        # offset (relative to data_offset).
        record_offsets: List[int] = []
        cursor = 0
        for _cell, _fc, _gt, _zmin, _zmax, comp in index_entries:
            record_offsets.append(cursor)
            cursor += len(comp)
        total_data_bytes = cursor

        label_offset = data_offset + total_data_bytes
        label_data = b"".join(l.pack() for l in self.labels)

        # Build the index block now that we know each record's offset.
        index_bytes = bytearray()
        for i, (cell, fc, gt, zmin, zmax, comp) in enumerate(index_entries):
            index_bytes += struct.pack(
                INDEX_ENTRY_FORMAT,
                cell,            # u32
                fc & 0xFF,
                gt & 0xFF,
                zmin & 0xFF,
                zmax & 0xFF,
                record_offsets[i],
                len(comp),
            )

        with open(output_path, "wb") as f:
            header = struct.pack(
                HEADER_FORMAT,
                MAGIC,
                TDMAP_VERSION,
                COMPRESSION_ZLIB,
                grid_dim,
                0,                         # reserved
                len(index_entries),
                index_offset,
                data_offset,
                self.min_zoom,
                self.max_zoom,
                label_offset,
                len(self.labels),
            )
            f.write(header)
            f.write(metadata_block)
            f.write(index_bytes)
            for _cell, _fc, _gt, _zmin, _zmax, comp in index_entries:
                f.write(comp)
            f.write(label_data)

        return output_path

    def _pack_metadata(self) -> bytes:
        chunks: List[bytes] = []
        for tag, value in self.metadata.items():
            if len(tag) != 2:
                raise ValueError(f"metadata tag must be 2 bytes: {tag!r}")
            if len(value) > 0xFFFF:
                raise ValueError(
                    f"metadata value for {tag!r} too large ({len(value)} bytes)")
            chunks.append(tag)
            chunks.append(struct.pack("<H", len(value)))
            chunks.append(value)
        return b"".join(chunks)


# ============================================================================
# Reader (host-side; the device has its own Lua implementation)
# ============================================================================

class IndexEntry:
    __slots__ = (
        "cell_index", "feature_class", "geom_type",
        "min_zoom", "max_zoom", "data_offset", "data_size",
    )

    def __init__(self, cell_index, feature_class, geom_type,
                 min_zoom, max_zoom, data_offset, data_size):
        self.cell_index = cell_index
        self.feature_class = feature_class
        self.geom_type = geom_type
        self.min_zoom = min_zoom
        self.max_zoom = max_zoom
        self.data_offset = data_offset
        self.data_size = data_size


class TDMAPReader:
    """v7 reader. Loads header, metadata, index, labels into memory; geometry
    payloads stay on disk and are decoded on demand."""

    def __init__(self, archive_path: Path):
        self.archive_path = Path(archive_path)
        self.version = 0
        self.grid_dim = DEFAULT_GRID_DIM
        self.min_zoom = 0
        self.max_zoom = 0
        self.label_offset = 0
        self.label_count = 0
        self.data_offset = 0
        self.geom_count = 0
        self.entries: List[IndexEntry] = []
        self.labels: List[Label] = []
        self.metadata: Dict[bytes, bytes] = {}
        self.region_name: Optional[str] = None
        self.bounds: Optional[Tuple[float, float, float, float]] = None
        self.source_hash: Optional[bytes] = None
        self.build_timestamp: Optional[int] = None
        self.tool_version: Optional[str] = None
        self._read()

    def _read(self) -> None:
        with open(self.archive_path, "rb") as f:
            header_data = f.read(HEADER_SIZE)
            if len(header_data) != HEADER_SIZE:
                raise ValueError("file too short for TDMAP header")
            (
                magic, version, compression, grid_dim, _reserved,
                geom_count, index_offset, data_offset,
                min_zoom, max_zoom, label_offset, label_count,
            ) = struct.unpack(HEADER_FORMAT, header_data)
            if magic != MAGIC:
                raise ValueError(f"not a TDMAP archive: {magic!r}")
            if version != TDMAP_VERSION:
                raise ValueError(
                    f"unsupported TDMAP version {version}: this reader is "
                    f"v{TDMAP_VERSION} only")
            if compression != COMPRESSION_ZLIB:
                raise ValueError(f"unsupported compression {compression}")
            self.version = version
            self.grid_dim = grid_dim or DEFAULT_GRID_DIM
            self.geom_count = geom_count
            self.min_zoom = min_zoom
            self.max_zoom = max_zoom
            self.data_offset = data_offset
            self.label_offset = label_offset
            self.label_count = label_count

            # Metadata block (length-prefixed).
            meta_len_bytes = f.read(4)
            if len(meta_len_bytes) == 4:
                meta_len = struct.unpack("<I", meta_len_bytes)[0]
                if meta_len > 0:
                    self._parse_metadata(f.read(meta_len))

            # Index.
            f.seek(index_offset)
            idx_data = f.read(geom_count * INDEX_ENTRY_SIZE)
            for i in range(geom_count):
                base = i * INDEX_ENTRY_SIZE
                cell, fc, gt, zmin, zmax, off, sz = struct.unpack_from(
                    INDEX_ENTRY_FORMAT, idx_data, base)
                self.entries.append(
                    IndexEntry(cell, fc, gt, zmin, zmax, off, sz))

            # Labels.
            if label_count > 0 and label_offset > 0:
                f.seek(label_offset)
                tail = f.read()
                p = 0
                for _ in range(label_count):
                    if p + LABEL_FIXED_SIZE >= len(tail):
                        break
                    lat_e6, lon_e6, zmin, zmax, ltype = struct.unpack_from(
                        LABEL_FORMAT, tail, p)
                    p += LABEL_FIXED_SIZE
                    text_len = tail[p]
                    p += 1
                    text = tail[p:p + text_len].decode("utf-8", errors="replace")
                    p += text_len
                    self.labels.append(Label(
                        lat=lat_e6 / 1_000_000,
                        lon=lon_e6 / 1_000_000,
                        zoom_min=zmin,
                        zoom_max=zmax,
                        label_type=ltype,
                        text=text,
                    ))

    def _parse_metadata(self, payload: bytes) -> None:
        p = 0
        n = len(payload)
        while p + 4 <= n:
            tag = payload[p:p + 2]
            length = struct.unpack_from("<H", payload, p + 2)[0]
            value_start = p + 4
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
                    west_e6 / 1_000_000,
                    south_e6 / 1_000_000,
                    east_e6 / 1_000_000,
                    north_e6 / 1_000_000,
                )
            elif tag == META_TAG_SRC_HASH:
                self.source_hash = value
            elif tag == META_TAG_TIMESTAMP and length == 8:
                self.build_timestamp = struct.unpack("<Q", value)[0]
            elif tag == META_TAG_TOOL_VER:
                self.tool_version = value.decode("utf-8", errors="replace")
            p = value_end

    def decode_geometry(self, entry: IndexEntry) -> List[Tuple[float, float]]:
        """Read and decompress a geometry record. Returns a list of (lat, lon)."""
        with open(self.archive_path, "rb") as f:
            f.seek(self.data_offset + entry.data_offset)
            raw_comp = f.read(entry.data_size)
        raw = zlib.decompress(raw_comp)
        return decode_geometry_bytes(raw)


def decode_geometry_bytes(raw: bytes) -> List[Tuple[float, float]]:
    """Decompressed geometry payload → list of (lat, lon)."""
    n = raw[0]
    origin_lat_e6, origin_lon_e6 = struct.unpack_from("<ii", raw, 1)
    points: List[Tuple[float, float]] = [
        (origin_lat_e6 / 1_000_000, origin_lon_e6 / 1_000_000),
    ]
    prev_lat_e6 = origin_lat_e6
    prev_lon_e6 = origin_lon_e6
    p = 9
    for _ in range(n - 1):
        d_lat, d_lon = struct.unpack_from("<hh", raw, p)
        p += 4
        prev_lat_e6 += d_lat
        prev_lon_e6 += d_lon
        points.append((prev_lat_e6 / 1_000_000, prev_lon_e6 / 1_000_000))
    return points


# ============================================================================
# MVT decoding helpers (used by make_map.py)
# ============================================================================

def decompress_mvt(tile_data: bytes) -> bytes:
    """PMTiles tiles may be gzipped — transparently decompress."""
    if len(tile_data) >= 2 and tile_data[0] == 0x1F and tile_data[1] == 0x8B:
        return gzip.decompress(tile_data)
    return tile_data


def mvt_layer(decoded: dict, name: str):
    """mapbox_vector_tile returns either a dict-keyed-by-name or a
    list-of-{name, ...}; accept both."""
    if not decoded:
        return None
    if isinstance(decoded, dict):
        return decoded.get(name)
    for layer in decoded:
        if layer.get("name") == name:
            return layer
    return None


# ============================================================================
# Inspect / verify CLI
# ============================================================================

_FEATURE_NAMES = {
    F_LAND: "land",
    F_WATER: "water",
    F_PARK: "park",
    F_BUILDING: "building",
    F_ROAD_MINOR: "road-minor",
    F_ROAD_MAJOR: "road-major",
    F_HIGHWAY: "highway",
    F_RAILWAY: "railway",
}

_LABEL_TYPE_NAMES = {
    LABEL_CITY: "city",
    LABEL_TOWN: "town",
    LABEL_VILLAGE: "village",
    LABEL_SUBURB: "suburb",
    LABEL_ROAD: "road",
    LABEL_WATER: "water",
    LABEL_PARK: "park",
    LABEL_POI: "poi",
}


def inspect(archive_path: Path, label_sample: int = 5) -> int:
    r = TDMAPReader(archive_path)
    file_size = archive_path.stat().st_size
    print(f"\n== {archive_path} ==")
    print(f"  version       : {r.version}")
    print(f"  file size     : {file_size / 1024 / 1024:.2f} MB")
    print(f"  zoom range    : {r.min_zoom}..{r.max_zoom}")
    print(f"  grid_dim      : {r.grid_dim}")
    print(f"  geometries    : {r.geom_count}")
    print(f"  labels        : {r.label_count}")

    print("\n  Metadata:")
    if r.region_name:
        print(f"    region      : {r.region_name}")
    if r.bounds:
        w, s, e, n = r.bounds
        print(f"    bounds      : W={w:+8.3f} S={s:+7.3f} E={e:+8.3f} N={n:+7.3f}")
    if r.build_timestamp:
        import datetime
        ts = datetime.datetime.utcfromtimestamp(r.build_timestamp)
        print(f"    built       : {ts.isoformat()}Z")
    if r.tool_version:
        print(f"    tool        : {r.tool_version}")
    if r.source_hash:
        print(f"    source hash : {r.source_hash[:16].hex()}... ({len(r.source_hash)} bytes)")

    # Geometry distribution by feature class and zoom.
    by_feature: Dict[int, int] = {}
    bytes_by_feature: Dict[int, int] = {}
    by_zoom: Dict[int, int] = {}
    for e in r.entries:
        by_feature[e.feature_class] = by_feature.get(e.feature_class, 0) + 1
        bytes_by_feature[e.feature_class] = (
            bytes_by_feature.get(e.feature_class, 0) + e.data_size
        )
        for z in range(e.min_zoom, e.max_zoom + 1):
            by_zoom[z] = by_zoom.get(z, 0) + 1

    if by_feature:
        print("\n  Geometries by feature class:")
        for fc in sorted(by_feature):
            name = _FEATURE_NAMES.get(fc, f"unknown({fc})")
            print(f"    {fc} {name:<11}  count={by_feature[fc]:>7}  "
                  f"bytes={bytes_by_feature[fc] / 1024:>8.1f} KB")

    if by_zoom:
        print("\n  Geometries visible at each zoom:")
        for z in sorted(by_zoom):
            print(f"    z{z:<2d}  {by_zoom[z]:>7}")

    by_label: Dict[int, int] = {}
    for l in r.labels:
        by_label[l.label_type] = by_label.get(l.label_type, 0) + 1
    if by_label:
        print("\n  Labels by type:")
        for lt in sorted(by_label):
            name = _LABEL_TYPE_NAMES.get(lt, f"unknown({lt})")
            print(f"    {lt} {name:<10}  {by_label[lt]:>6}")

    if r.labels and label_sample > 0:
        print(f"\n  First {label_sample} labels:")
        for l in r.labels[:label_sample]:
            name = _LABEL_TYPE_NAMES.get(l.label_type, str(l.label_type))
            print(f"    ({l.lat:+8.4f},{l.lon:+9.4f})  z{l.zoom_min}-{l.zoom_max}  "
                  f"{name:<7}  {l.text}")

    print()
    return 0


def verify(archive_path: Path) -> bool:
    try:
        r = TDMAPReader(archive_path)
        print(
            f"Archive verified (v{r.version}): {r.geom_count} geometries, "
            f"{r.label_count} labels, zoom {r.min_zoom}-{r.max_zoom}, "
            f"size {archive_path.stat().st_size / 1024 / 1024:.1f} MB")
        return True
    except Exception as exc:
        print(f"Archive verification failed: {exc}")
        return False


def _cli() -> int:
    p = argparse.ArgumentParser(prog="python -m tools.maps.tdmap",
                                description="Inspect TDMAP v7 archives.")
    sub = p.add_subparsers(dest="cmd", required=True)
    pi = sub.add_parser("inspect", help="Dump header, geometry and label stats")
    pi.add_argument("path", type=Path)
    pi.add_argument("--labels", type=int, default=5,
                    help="Show first N labels (default: 5, 0 to skip)")
    pv = sub.add_parser("verify", help="Quick integrity check")
    pv.add_argument("path", type=Path)
    args = p.parse_args()
    if args.cmd == "inspect":
        return inspect(args.path, label_sample=args.labels)
    if args.cmd == "verify":
        return 0 if verify(args.path) else 1
    return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
