"""
TDMAP archive format writer and reader.
Custom format optimized for ESP32 reading of map tiles from SD card.

Version 6: 3-bit semantic-index tiles (renderer owns the palette), TLV
metadata block, geographic labels with lat/lon coordinates deduped at
build time. v4/v5 reader support was removed when no v4/v5 archives
existed outside the dev machine — every release ships v6.
"""

import hashlib
import struct
import time
from pathlib import Path
from typing import List, Tuple, BinaryIO, Optional, Dict, Any

from config import (TILE_SIZE, TDMAP_VERSION,
                    COMPRESSION_ZLIB, DEFAULT_COMPRESSION)

# Metadata TLV tags (2 bytes each, ASCII). Values are little-endian.
META_TAG_REGION     = b"RG"  # UTF-8 region name
META_TAG_BOUNDS     = b"BB"  # 16 bytes: 4× int32_le (min_lat_e6, min_lon_e6, max_lat_e6, max_lon_e6)
META_TAG_SRC_HASH   = b"SH"  # Arbitrary bytes (typically SHA-256 digest of source PMTiles)
META_TAG_TIMESTAMP  = b"TS"  # 8 bytes: uint64_le UNIX epoch seconds
META_TAG_TOOL_VER   = b"TV"  # UTF-8 tool/generator version


# Archive header (33 bytes total). All multi-byte integers are little-endian.
# Magic(6) + version(1) + compression(1) + tile_size(2) + palette_count(1) +
# tile_count(4) + index_offset(4) + data_offset(4) + min_zoom(1) + max_zoom(1) +
# label_data_offset(4) + label_count(4)
# palette_count is always 0 in v6; the byte is kept for header-shape stability.
HEADER_FORMAT = "<6sBBHBIIIbbII"
HEADER_SIZE = 33

# Tile index entry format (11 bytes per tile)
# zoom(1) + x(2) + y(2) + offset(4) + size(2) = 11 bytes
INDEX_ENTRY_FORMAT = "<BHHIH"  # zoom, x, y, offset, compressed_size
INDEX_ENTRY_SIZE = 11

# Label entry: lat_e6(4) + lon_e6(4) + zoom_min(1) + zoom_max(1) +
# label_type(1) + text_len(1) + text(variable). lat_e6/lon_e6 are degrees ×
# 1,000,000 stored as int32. Labels are deduped at build time by
# (text, label_type, lat bucket, lon bucket).
LABEL_FORMAT = "<iiBBB"
LABEL_FIXED_SIZE = 11  # Fixed part before text_len


class TileEntry:
    """Represents a single tile in the archive index."""

    def __init__(self, zoom: int, x: int, y: int, offset: int = 0, size: int = 0):
        self.zoom = zoom
        self.x = x
        self.y = y
        self.offset = offset
        self.size = size

    def __repr__(self):
        return f"Tile(z={self.zoom}, x={self.x}, y={self.y}, off={self.offset}, sz={self.size})"


class LabelEntry:
    """Represents a text label in the archive. Coordinates are geographic
    (lat/lon); labels are deduped by (text, label_type, lat bucket, lon
    bucket) at build time.
    """

    def __init__(
        self,
        lat: float,
        lon: float,
        zoom_min: int,
        zoom_max: int,
        label_type: int,
        text: str,
    ):
        self.lat = lat  # Latitude in degrees
        self.lon = lon  # Longitude in degrees
        self.zoom_min = zoom_min  # Min zoom to show label
        self.zoom_max = zoom_max  # Max zoom to show label
        self.label_type = label_type
        self.text = text

    @property
    def lat_e6(self) -> int:
        """Latitude as int32 (degrees * 1,000,000)."""
        return int(self.lat * 1_000_000)

    @property
    def lon_e6(self) -> int:
        """Longitude as int32 (degrees * 1,000,000)."""
        return int(self.lon * 1_000_000)

    def pack(self) -> bytes:
        text_bytes = self.text.encode('utf-8')[:255]
        return struct.pack(
            LABEL_FORMAT,
            self.lat_e6,
            self.lon_e6,
            self.zoom_min,
            self.zoom_max,
            self.label_type,
        ) + struct.pack('B', len(text_bytes)) + text_bytes

    @classmethod
    def unpack(cls, data: bytes, offset: int = 0) -> Tuple['LabelEntry', int]:
        lat_e6, lon_e6, zoom_min, zoom_max, label_type = struct.unpack_from(LABEL_FORMAT, data, offset)
        text_len = data[offset + LABEL_FIXED_SIZE]
        text_start = offset + LABEL_FIXED_SIZE + 1
        text = data[text_start:text_start + text_len].decode('utf-8', errors='replace')
        lat = lat_e6 / 1_000_000
        lon = lon_e6 / 1_000_000
        entry = cls(lat, lon, zoom_min, zoom_max, label_type, text)
        return entry, LABEL_FIXED_SIZE + 1 + text_len

    # Dedup bucket in degrees: 1° (~110 km). Large enough that a city label
    # that OSM anchors in several adjacent MVT tiles lands in a single bucket,
    # small enough that two distinct places sharing a name (e.g. "Newport" in
    # different countries) stay separate. The label_type is part of the key so
    # a village and a park with the same name don't collide.
    _DEDUP_STEP_E6 = 1_000_000  # 1.0°

    def dedup_key(self) -> Tuple[str, int, int, int]:
        step = self._DEDUP_STEP_E6
        return (self.text, self.label_type,
                self.lat_e6 // step, self.lon_e6 // step)

    def __repr__(self):
        return f"Label(z={self.zoom_min}-{self.zoom_max}, pos=({self.lat:.4f},{self.lon:.4f}), " \
               f"type={self.label_type}, text='{self.text}')"


class TDMAPWriter:
    """Writes tiles to TDMAP archive format."""

    MAGIC = b"TDMAP\x00"

    def __init__(self, output_path: Path, compression: int = DEFAULT_COMPRESSION):
        """
        Initialize archive writer.

        Args:
            output_path: Path to output .tdmap file
            compression: COMPRESSION_ZLIB (the only value in v6). Stored
                verbatim in the header byte for forward-compat with future
                codecs. Writer only sets the flag — actual compression
                happens upstream in ``process.py``.
        """
        self.output_path = Path(output_path)
        self.tiles: List[Tuple[TileEntry, bytes]] = []
        self.labels: List[LabelEntry] = []
        self._label_keys: set = set()  # For deduplication
        self.min_zoom = 255
        self.max_zoom = 0
        self.compression = compression
        # TLV metadata. Left unset → empty metadata block (length-prefixed
        # placeholder, no tags) so readers always find the tile index at the
        # same offset regardless of whether the writer set any tags.
        self._metadata: Dict[bytes, bytes] = {}

    # ------------------------------------------------------------------ metadata
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
        """Pack the TLV metadata block. Empty → zero-length placeholder."""
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

    def add_tile(self, zoom: int, x: int, y: int, data: bytes):
        """
        Add a processed tile to the archive.

        Args:
            zoom: Zoom level
            x: Tile X coordinate
            y: Tile Y coordinate
            data: Compressed tile data
        """
        entry = TileEntry(zoom, x, y, size=len(data))
        self.tiles.append((entry, data))
        self.min_zoom = min(self.min_zoom, zoom)
        self.max_zoom = max(self.max_zoom, zoom)

    def add_label(
        self,
        lat: float,
        lon: float,
        zoom_min: int,
        zoom_max: int,
        label_type: int,
        text: str,
    ):
        """
        Add a text label to the archive (with deduplication).

        Args:
            lat: Latitude in degrees
            lon: Longitude in degrees
            zoom_min: Minimum zoom level to show label
            zoom_max: Maximum zoom level to show label
            label_type: Label type (city, town, road, etc.)
            text: Label text
        """
        if not text or not text.strip():
            return

        entry = LabelEntry(lat, lon, zoom_min, zoom_max, label_type, text.strip())

        # Deduplicate by (text, lat_e6, lon_e6)
        key = entry.dedup_key()
        if key in self._label_keys:
            return
        self._label_keys.add(key)

        self.labels.append(entry)

    def write(self):
        """Write the complete archive to disk."""
        if not self.tiles:
            raise ValueError("No tiles to write")

        # Sort tiles by zoom, then x, then y for efficient binary search
        self.tiles.sort(key=lambda t: (t[0].zoom, t[0].x, t[0].y))

        # Sort labels by (zoom_min, lat, lon) for predictable output
        self.labels.sort(key=lambda l: (l.zoom_min, l.lat_e6, l.lon_e6))

        # Metadata block: 4-byte length prefix + TLV chunks. Always present
        # (even when empty) so readers don't need a version check to locate
        # the tile index.
        metadata_payload = self._pack_metadata()
        metadata_block = struct.pack("<I", len(metadata_payload)) + metadata_payload

        index_offset = HEADER_SIZE + len(metadata_block)
        data_offset = index_offset + len(self.tiles) * INDEX_ENTRY_SIZE

        # Calculate data offsets for each tile
        current_data_offset = data_offset
        for entry, data in self.tiles:
            entry.offset = current_data_offset
            current_data_offset += len(data)

        # Label data comes directly after tile data (no separate index)
        label_data_offset = current_data_offset
        label_count = len(self.labels)

        # Pack all labels
        label_data = b''.join(label.pack() for label in self.labels)

        with open(self.output_path, "wb") as f:
            # Write header. palette_count is fixed at 0; the slot is kept
            # for header-shape stability with the v4/v5 layout.
            header = struct.pack(
                HEADER_FORMAT,
                self.MAGIC,                    # magic (6 bytes)
                TDMAP_VERSION,                 # version (1 byte)
                self.compression,              # compression type (1 byte)
                TILE_SIZE,                     # tile size (2 bytes)
                0,                             # palette count (1 byte; always 0 in v6)
                len(self.tiles),               # tile count (4 bytes)
                index_offset,                  # index offset (4 bytes)
                data_offset,                   # data offset (4 bytes)
                self.min_zoom,                 # min zoom (1 byte)
                self.max_zoom,                 # max zoom (1 byte)
                label_data_offset,             # label data offset (4 bytes)
                label_count,                   # label count (4 bytes)
            )
            f.write(header)

            # Write metadata block (length prefix + TLV payload)
            f.write(metadata_block)

            # Write tile index
            for entry, _ in self.tiles:
                index_entry = struct.pack(
                    INDEX_ENTRY_FORMAT,
                    entry.zoom,
                    entry.x,
                    entry.y,
                    entry.offset,
                    entry.size
                )
                f.write(index_entry)

            # Write tile data
            for _, data in self.tiles:
                f.write(data)

            # Write label data (no index, just sequential labels)
            f.write(label_data)

        return self.output_path


class TDMAPReader:
    """Reads tiles from TDMAP archive format (for verification/preview)."""

    MAGIC = b"TDMAP\x00"

    def __init__(self, archive_path: Path):
        """
        Initialize archive reader.

        Args:
            archive_path: Path to .tdmap file
        """
        self.archive_path = Path(archive_path)
        self.tiles: List[TileEntry] = []
        self.labels: List[LabelEntry] = []
        self.min_zoom = 0
        self.max_zoom = 0
        self.tile_size = 256
        self.version = 0
        self.label_data_offset = 0
        self.label_count = 0
        # Metadata, populated on load. Unknown tags are collected under
        # their raw 2-byte key so `inspect` can surface them.
        self.metadata: Dict[bytes, bytes] = {}
        self.region_name: Optional[str] = None
        self.bounds: Optional[Tuple[float, float, float, float]] = None  # (west, south, east, north)
        self.source_hash: Optional[bytes] = None
        self.build_timestamp: Optional[int] = None
        self.tool_version: Optional[str] = None

        self._read_header()

    def _read_header(self):
        """Read and parse archive header and index."""
        with open(self.archive_path, "rb") as f:
            # Read header
            header_data = f.read(HEADER_SIZE)
            (
                magic, version, compression, tile_size, palette_count,
                tile_count, index_offset, data_offset, min_zoom, max_zoom,
                label_data_offset, label_count
            ) = struct.unpack(HEADER_FORMAT, header_data)

            if magic != self.MAGIC:
                raise ValueError(f"Invalid TDMAP magic: {magic}")
            if version != TDMAP_VERSION:
                raise ValueError(
                    f"Unsupported TDMAP version: {version} (this build only "
                    f"reads v{TDMAP_VERSION}; pre-v6 archives are no longer "
                    f"supported — regenerate with the current writer)")

            self.version = version
            self.tile_size = tile_size
            self.min_zoom = min_zoom
            self.max_zoom = max_zoom
            self.label_data_offset = label_data_offset
            self.label_count = label_count

            # Metadata block (4-byte length + TLV payload) sits between the
            # header and the tile index.
            meta_len_bytes = f.read(4)
            if len(meta_len_bytes) == 4:
                meta_len = struct.unpack("<I", meta_len_bytes)[0]
                meta_payload = f.read(meta_len)
                self._parse_metadata(meta_payload)

            # Read tile index
            f.seek(index_offset)
            for _ in range(tile_count):
                entry_data = f.read(INDEX_ENTRY_SIZE)
                zoom, x, y, offset, size = struct.unpack(INDEX_ENTRY_FORMAT, entry_data)
                self.tiles.append(TileEntry(zoom, x, y, offset, size))

            # Read labels (sequential list, no separate index)
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
        """Walk the TLV metadata block. Unknown tags are preserved so
        inspect can surface them, but don't populate any named attribute."""
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
        """
        Get compressed tile data by coordinates.
        Uses binary search for efficient lookup.

        Args:
            zoom: Zoom level
            x: Tile X coordinate
            y: Tile Y coordinate

        Returns:
            Compressed tile data, or None if not found
        """
        # Binary search for tile
        target = (zoom, x, y)
        lo, hi = 0, len(self.tiles) - 1

        while lo <= hi:
            mid = (lo + hi) // 2
            entry = self.tiles[mid]
            current = (entry.zoom, entry.x, entry.y)

            if current == target:
                # Found it - read the data
                with open(self.archive_path, "rb") as f:
                    f.seek(entry.offset)
                    return f.read(entry.size)
            elif current < target:
                lo = mid + 1
            else:
                hi = mid - 1

        return None

    def get_info(self) -> dict:
        """Get archive information."""
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

    def get_labels_in_bounds(
        self,
        min_lat: float,
        max_lat: float,
        min_lon: float,
        max_lon: float,
        zoom: int
    ) -> List[LabelEntry]:
        """
        Get all labels visible within geographic bounds at given zoom.

        Args:
            min_lat, max_lat: Latitude bounds
            min_lon, max_lon: Longitude bounds
            zoom: Current zoom level (for visibility filtering)

        Returns:
            List of labels within bounds and visible at zoom
        """
        result = []
        for label in self.labels:
            # Check zoom visibility
            if zoom < label.zoom_min or zoom > label.zoom_max:
                continue
            # Check bounds
            if label.lat < min_lat or label.lat > max_lat:
                continue
            if label.lon < min_lon or label.lon > max_lon:
                continue
            result.append(label)
        return result


def verify_archive(archive_path: Path) -> bool:
    """
    Verify archive integrity by reading header and checking tile count.

    Args:
        archive_path: Path to .tdmap file

    Returns:
        True if archive appears valid
    """
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


# Label type names must match tools/maps/config.py: 0=city, 1=town, 2=village,
# 3=suburb, 4=road, 5=water. Unknown codes are surfaced as-is so stale archives
# don't break inspect.
_LABEL_TYPE_NAMES = {0: "city", 1: "town", 2: "village", 3: "suburb", 4: "road", 5: "water"}


def inspect_archive(archive_path: Path, first_n_labels: int = 5) -> int:
    """
    Human-readable dump of archive contents.

    Prints:
      * Header/version/bounds
      * Tile count per zoom + compression stats per zoom
      * Label count by type
      * First N labels per zoom (for eyeballing positions)
    """
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
        ts = datetime.datetime.utcfromtimestamp(reader.build_timestamp)
        print(f"    built       : {ts.isoformat()}Z")
    if reader.tool_version:
        print(f"    tool        : {reader.tool_version}")
    if reader.source_hash:
        print(f"    source hash : {reader.source_hash[:16].hex()}… ({len(reader.source_hash)} bytes)")
    # Surface unknown tags (forward-compat aid)
    known = {META_TAG_REGION, META_TAG_BOUNDS, META_TAG_SRC_HASH,
             META_TAG_TIMESTAMP, META_TAG_TOOL_VER}
    for tag, value in reader.metadata.items():
        if tag not in known:
            print(f"    {tag.decode('ascii', errors='replace')} (unknown): {len(value)} bytes")

    # Per-zoom distribution. Report size on disk and compression ratio against
    # the uncompressed 3bpp baseline (tile_size^2 * 3 / 8 bytes per tile).
    uncompressed_bytes_per_tile = (info['tile_size'] ** 2 * 3 + 7) // 8
    by_zoom: dict[int, list] = {}
    for t in reader.tiles:
        by_zoom.setdefault(t.zoom, []).append(t.size)

    print("\n  Tiles per zoom (count | total KB | avg ratio vs 3bpp):")
    for z in sorted(by_zoom):
        sizes = by_zoom[z]
        total = sum(sizes)
        avg_ratio = uncompressed_bytes_per_tile / (total / len(sizes)) if sizes else 0
        print(f"    z{z:<2d}  {len(sizes):>6}  {total / 1024:>9.1f}  {avg_ratio:>6.1f}x")

    # Labels by type.
    by_type: dict[int, int] = {}
    for lbl in reader.labels:
        by_type[lbl.label_type] = by_type.get(lbl.label_type, 0) + 1
    if by_type:
        print("\n  Labels by type:")
        for t in sorted(by_type):
            name = _LABEL_TYPE_NAMES.get(t, f"unknown({t})")
            print(f"    {t} {name:<10}  {by_type[t]:>6}")

    # First N labels at each zoom_min. Useful for spot-checking that names
    # landed where they should.
    if reader.labels and first_n_labels > 0:
        print(f"\n  First {first_n_labels} labels by zoom_min:")
        by_zmin: dict[int, list] = {}
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


def _cli() -> int:
    import argparse
    p = argparse.ArgumentParser(
        prog="python -m tools.maps.archive",
        description="Inspect TDMAP archives.")
    sub = p.add_subparsers(dest="cmd", required=True)

    pi = sub.add_parser("inspect", help="Dump header, tile distribution, and labels")
    pi.add_argument("path", type=Path)
    pi.add_argument("--labels", type=int, default=5,
                    help="Show first N labels per zoom (default: 5, use 0 to skip)")

    pv = sub.add_parser("verify", help="Quick integrity check")
    pv.add_argument("path", type=Path)

    args = p.parse_args()
    if args.cmd == "inspect":
        return inspect_archive(args.path, first_n_labels=args.labels)
    if args.cmd == "verify":
        return 0 if verify_archive(args.path) else 1
    return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
