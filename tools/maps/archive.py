"""
TDMAP archive format writer and reader.
Custom format optimized for ESP32 reading of map tiles from SD card.

Version 4: Geographic labels with lat/lon coordinates, deduped at build time.
"""

import struct
from pathlib import Path
from typing import List, Tuple, BinaryIO, Optional

from config import PALETTE_RGB565, TILE_SIZE, TDMAP_VERSION, COMPRESSION_RLE


# Archive header format v4 (33 bytes total)
# All multi-byte integers are little-endian
# Magic(6) + version(1) + compression(1) + tile_size(2) + palette_count(1) +
# tile_count(4) + index_offset(4) + data_offset(4) + min_zoom(1) + max_zoom(1) +
# label_data_offset(4) + label_count(4) = 33 bytes
HEADER_FORMAT = "<6sBBHBIIIbbII"
HEADER_SIZE = 33  # 6+1+1+2+1+4+4+4+1+1+4+4 = 33 bytes

# Palette entry format: 8 RGB565 values (16 bytes)
PALETTE_FORMAT = "<8H"
PALETTE_SIZE = 16

# Tile index entry format (11 bytes per tile)
# zoom(1) + x(2) + y(2) + offset(4) + size(2) = 11 bytes
INDEX_ENTRY_FORMAT = "<BHHIH"  # zoom, x, y, offset, compressed_size
INDEX_ENTRY_SIZE = 11

# Label entry format v4 (variable size) - geographic coords, no tile index
# lat_e6(4) + lon_e6(4) + zoom_min(1) + zoom_max(1) + label_type(1) + text_len(1) + text(variable)
# = 12 + text_len bytes
# lat_e6/lon_e6 are latitude/longitude multiplied by 1,000,000 stored as int32
# Labels are deduped by (text, lat_e6, lon_e6) at build time - no runtime dedup needed
LABEL_FORMAT_V4 = "<iiBBB"  # lat_e6, lon_e6, zoom_min, zoom_max, label_type
LABEL_SIZE_V4 = 11  # Fixed part before text_len


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
    """Represents a text label in the archive.

    v4 format: Uses lat/lon coordinates directly (geographic).
    Labels are deduped by (text, lat_e6, lon_e6) at build time.
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
        """Pack label to v4 binary format."""
        text_bytes = self.text.encode('utf-8')[:255]
        return struct.pack(
            LABEL_FORMAT_V4,
            self.lat_e6,
            self.lon_e6,
            self.zoom_min,
            self.zoom_max,
            self.label_type,
        ) + struct.pack('B', len(text_bytes)) + text_bytes

    @classmethod
    def unpack(cls, data: bytes, offset: int = 0) -> Tuple['LabelEntry', int]:
        """Unpack label from v4 format, returns (entry, bytes_consumed)."""
        lat_e6, lon_e6, zoom_min, zoom_max, label_type = struct.unpack_from(LABEL_FORMAT_V4, data, offset)
        text_len = data[offset + LABEL_SIZE_V4]
        text_start = offset + LABEL_SIZE_V4 + 1
        text = data[text_start:text_start + text_len].decode('utf-8', errors='replace')
        lat = lat_e6 / 1_000_000
        lon = lon_e6 / 1_000_000
        entry = cls(lat, lon, zoom_min, zoom_max, label_type, text)
        return entry, LABEL_SIZE_V4 + 1 + text_len

    def dedup_key(self) -> Tuple[str, int, int]:
        """Key for deduplication: (text, lat_e6, lon_e6)."""
        return (self.text, self.lat_e6, self.lon_e6)

    def __repr__(self):
        return f"Label(z={self.zoom_min}-{self.zoom_max}, pos=({self.lat:.4f},{self.lon:.4f}), " \
               f"type={self.label_type}, text='{self.text}')"


class TDMAPWriter:
    """Writes tiles to TDMAP archive format."""

    MAGIC = b"TDMAP\x00"

    def __init__(self, output_path: Path):
        """
        Initialize archive writer.

        Args:
            output_path: Path to output .tdmap file
        """
        self.output_path = Path(output_path)
        self.tiles: List[Tuple[TileEntry, bytes]] = []
        self.labels: List[LabelEntry] = []
        self._label_keys: set = set()  # For deduplication
        self.min_zoom = 255
        self.max_zoom = 0

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

        # Calculate offsets
        index_offset = HEADER_SIZE + PALETTE_SIZE
        data_offset = index_offset + len(self.tiles) * INDEX_ENTRY_SIZE

        # Calculate data offsets for each tile
        current_data_offset = data_offset
        for entry, data in self.tiles:
            entry.offset = current_data_offset
            current_data_offset += len(data)

        # Label data comes directly after tile data (no index in v4)
        label_data_offset = current_data_offset
        label_count = len(self.labels)

        # Pack all labels
        label_data = b''.join(label.pack() for label in self.labels)

        with open(self.output_path, "wb") as f:
            # Write header
            header = struct.pack(
                HEADER_FORMAT,
                self.MAGIC,                    # magic (6 bytes)
                TDMAP_VERSION,                 # version (1 byte)
                COMPRESSION_RLE,               # compression type (1 byte)
                TILE_SIZE,                     # tile size (2 bytes)
                len(PALETTE_RGB565),           # palette count (1 byte)
                len(self.tiles),               # tile count (4 bytes)
                index_offset,                  # index offset (4 bytes)
                data_offset,                   # data offset (4 bytes)
                self.min_zoom,                 # min zoom (1 byte)
                self.max_zoom,                 # max zoom (1 byte)
                label_data_offset,             # label data offset (4 bytes)
                label_count,                   # label count (4 bytes)
            )
            f.write(header)

            # Write palette
            palette = struct.pack(PALETTE_FORMAT, *PALETTE_RGB565)
            f.write(palette)

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
        self.palette: List[int] = []
        self.min_zoom = 0
        self.max_zoom = 0
        self.tile_size = 256
        self.version = 0
        self.label_data_offset = 0
        self.label_count = 0

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
            if version != 4:
                raise ValueError(f"Unsupported TDMAP version: {version} (only v4 supported)")

            self.version = version
            self.tile_size = tile_size
            self.min_zoom = min_zoom
            self.max_zoom = max_zoom
            self.label_data_offset = label_data_offset
            self.label_count = label_count

            # Read palette
            palette_data = f.read(PALETTE_SIZE)
            self.palette = list(struct.unpack(PALETTE_FORMAT, palette_data))

            # Read tile index
            f.seek(index_offset)
            for _ in range(tile_count):
                entry_data = f.read(INDEX_ENTRY_SIZE)
                zoom, x, y, offset, size = struct.unpack(INDEX_ENTRY_FORMAT, entry_data)
                self.tiles.append(TileEntry(zoom, x, y, offset, size))

            # Read labels (v4: sequential list, no index)
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
