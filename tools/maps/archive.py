"""
TDMAP archive format writer and reader.
Custom format optimized for ESP32 reading of map tiles from SD card.

Version 2 adds label support for dynamic text rendering.
"""

import struct
from pathlib import Path
from typing import List, Tuple, BinaryIO, Optional

from config import PALETTE_RGB565, TILE_SIZE, TDMAP_VERSION, COMPRESSION_RLE


# Archive header format v3 (33 bytes total)
# All multi-byte integers are little-endian
# Magic(6) + version(1) + compression(1) + tile_size(2) + palette_count(1) +
# tile_count(4) + index_offset(4) + data_offset(4) + min_zoom(1) + max_zoom(1) +
# label_index_offset(4) + label_index_count(4) = 33 bytes
# v3 changes: labels_offset -> label_index_offset, labels_count -> label_index_count
# Labels are now stored per-tile with a spatial index for lazy loading
HEADER_FORMAT = "<6sBBHBIIIbbII"
HEADER_SIZE = 33  # 6+1+1+2+1+4+4+4+1+1+4+4 = 33 bytes

# Palette entry format: 8 RGB565 values (16 bytes)
PALETTE_FORMAT = "<8H"
PALETTE_SIZE = 16

# Tile index entry format (11 bytes per tile)
# zoom(1) + x(2) + y(2) + offset(4) + size(2) = 11 bytes
INDEX_ENTRY_FORMAT = "<BHHIH"  # zoom, x, y, offset, compressed_size
INDEX_ENTRY_SIZE = 11

# Label entry format v2 (variable size) - stored in one big array
# zoom_min(1) + zoom_max(1) + tile_x(2) + tile_y(2) + pixel_x(1) + pixel_y(1) +
# label_type(1) + text_len(1) + text(variable) = 10 + text_len bytes
LABEL_HEADER_FORMAT_V2 = "<BBHHBBB"
LABEL_HEADER_SIZE_V2 = 9  # Fixed part before text_len

# Label entry format v3 (variable size) - stored per-tile, no tile coords needed
# pixel_x(1) + pixel_y(1) + zoom_min(1) + zoom_max(1) + label_type(1) + text_len(1) + text(variable)
# = 6 + text_len bytes
# NOTE: zoom_min is visibility threshold (when to start showing), stored per-label
# The index uses extraction_zoom (tile coordinate level), not zoom_min
LABEL_FORMAT_V3 = "<BBBBB"  # pixel_x, pixel_y, zoom_min, zoom_max, label_type
LABEL_SIZE_V3 = 5  # Fixed part before text_len

# Tile-label index entry format v3 (11 bytes per entry, same as tile index)
# zoom(1) + tile_x(2) + tile_y(2) + offset(4) + count(2) = 11 bytes
# NOTE: 'zoom' is the extraction zoom (tile coordinate level), NOT zoom_min (visibility)
# Sorted by (zoom, tile_x, tile_y) for binary search
LABEL_INDEX_FORMAT = "<BHHIH"
LABEL_INDEX_SIZE = 11


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

    Note: tile_x/tile_y are at extraction_zoom level (or zoom_min for legacy).
    extraction_zoom is the zoom level where the label was extracted from the vector tile.
    zoom_min is the minimum zoom level where the label should be visible.
    """

    def __init__(
        self,
        zoom_min: int,
        zoom_max: int,
        tile_x: int,
        tile_y: int,
        pixel_x: int,
        pixel_y: int,
        label_type: int,
        text: str,
        extraction_zoom: int = None  # Zoom level of tile_x/tile_y coordinates
    ):
        self.zoom_min = zoom_min
        self.zoom_max = zoom_max
        self.tile_x = tile_x
        self.tile_y = tile_y
        self.pixel_x = pixel_x  # Position within tile (0-255)
        self.pixel_y = pixel_y
        self.label_type = label_type
        self.text = text
        # extraction_zoom defaults to zoom_min for backward compatibility
        self.extraction_zoom = extraction_zoom if extraction_zoom is not None else zoom_min

    def pack_v3(self) -> bytes:
        """Pack label to v3 format (per-tile storage, includes zoom_min for visibility)."""
        text_bytes = self.text.encode('utf-8')[:255]
        return struct.pack(
            LABEL_FORMAT_V3,
            self.pixel_x,
            self.pixel_y,
            self.zoom_min,     # Visibility threshold (when to start showing)
            self.zoom_max,     # Visibility ceiling (when to stop showing)
            self.label_type,
        ) + struct.pack('B', len(text_bytes)) + text_bytes

    @classmethod
    def unpack_v3(cls, data: bytes, offset: int, extraction_zoom: int, tile_x: int, tile_y: int) -> Tuple['LabelEntry', int]:
        """Unpack label from v3 format, returns (entry, bytes_consumed).

        Args:
            data: Raw bytes
            offset: Offset into data
            extraction_zoom: Zoom level of tile coordinates (from index)
            tile_x, tile_y: Tile coordinates (from index)
        """
        pixel_x, pixel_y, zoom_min, zoom_max, label_type = struct.unpack_from(LABEL_FORMAT_V3, data, offset)
        text_len = data[offset + LABEL_SIZE_V3]
        text_start = offset + LABEL_SIZE_V3 + 1
        text = data[text_start:text_start + text_len].decode('utf-8', errors='replace')
        entry = cls(zoom_min, zoom_max, tile_x, tile_y, pixel_x, pixel_y, label_type, text, extraction_zoom)
        return entry, LABEL_SIZE_V3 + 1 + text_len

    def pack_v2(self) -> bytes:
        """Pack label to v2 format (legacy, one big array)."""
        text_bytes = self.text.encode('utf-8')[:255]
        header = struct.pack(
            LABEL_HEADER_FORMAT_V2,
            self.zoom_min,
            self.zoom_max,
            self.tile_x,
            self.tile_y,
            self.pixel_x,
            self.pixel_y,
            self.label_type
        )
        return header + struct.pack('B', len(text_bytes)) + text_bytes

    @classmethod
    def unpack_v2(cls, data: bytes, offset: int = 0) -> Tuple['LabelEntry', int]:
        """Unpack label from v2 format, returns (entry, bytes_consumed)."""
        header = struct.unpack_from(LABEL_HEADER_FORMAT_V2, data, offset)
        zoom_min, zoom_max, tile_x, tile_y, pixel_x, pixel_y, label_type = header
        text_len = data[offset + LABEL_HEADER_SIZE_V2]
        text_start = offset + LABEL_HEADER_SIZE_V2 + 1
        text = data[text_start:text_start + text_len].decode('utf-8', errors='replace')
        entry = cls(zoom_min, zoom_max, tile_x, tile_y, pixel_x, pixel_y, label_type, text)
        return entry, LABEL_HEADER_SIZE_V2 + 1 + text_len

    def __repr__(self):
        return f"Label(z={self.zoom_min}-{self.zoom_max}, tile=({self.tile_x},{self.tile_y}), " \
               f"px=({self.pixel_x},{self.pixel_y}), type={self.label_type}, text='{self.text}')"


class TileLabelIndex:
    """Index entry for labels belonging to a specific tile.

    Note: 'zoom' is the extraction zoom (tile coordinate level), NOT zoom_min (visibility threshold).
    Labels store their own zoom_min for visibility filtering.
    """

    def __init__(self, zoom: int, tile_x: int, tile_y: int, offset: int = 0, count: int = 0):
        self.zoom = zoom      # Extraction zoom (tile coordinate level)
        self.tile_x = tile_x
        self.tile_y = tile_y
        self.offset = offset  # Offset in label data section
        self.count = count    # Number of labels for this tile

    def pack(self) -> bytes:
        return struct.pack(LABEL_INDEX_FORMAT, self.zoom, self.tile_x, self.tile_y, self.offset, self.count)

    @classmethod
    def unpack(cls, data: bytes, offset: int = 0) -> 'TileLabelIndex':
        zoom, tile_x, tile_y, lbl_offset, count = struct.unpack_from(LABEL_INDEX_FORMAT, data, offset)
        return cls(zoom, tile_x, tile_y, lbl_offset, count)

    def __repr__(self):
        return f"TileLabelIndex(z={self.zoom}, tile=({self.tile_x},{self.tile_y}), off={self.offset}, cnt={self.count})"


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
        zoom_min: int,
        zoom_max: int,
        tile_x: int,
        tile_y: int,
        pixel_x: int,
        pixel_y: int,
        label_type: int,
        text: str,
        extraction_zoom: int = None
    ):
        """
        Add a text label to the archive.

        Args:
            zoom_min: Minimum zoom level to show label (visibility threshold)
            zoom_max: Maximum zoom level to show label
            tile_x: Tile X coordinate (at extraction_zoom level)
            tile_y: Tile Y coordinate (at extraction_zoom level)
            pixel_x: X position within tile (0-255)
            pixel_y: Y position within tile (0-255)
            label_type: Label type (city, town, road, etc.)
            text: Label text
            extraction_zoom: Zoom level of tile_x/tile_y (defaults to zoom_min for backward compat)
        """
        if not text or not text.strip():
            return
        entry = LabelEntry(
            zoom_min, zoom_max, tile_x, tile_y, pixel_x, pixel_y,
            label_type, text.strip(), extraction_zoom
        )
        self.labels.append(entry)

    def write(self):
        """Write the complete archive to disk."""
        if not self.tiles:
            raise ValueError("No tiles to write")

        # Sort tiles by zoom, then x, then y for efficient binary search
        self.tiles.sort(key=lambda t: (t[0].zoom, t[0].x, t[0].y))

        # Group labels by (extraction_zoom, tile_x, tile_y) for per-tile storage
        # NOTE: We index by extraction_zoom (tile coord level), not zoom_min (visibility)
        from collections import defaultdict
        labels_by_tile = defaultdict(list)
        for label in self.labels:
            key = (label.extraction_zoom, label.tile_x, label.tile_y)
            labels_by_tile[key].append(label)

        # Sort tile keys for binary search on ESP32
        sorted_tile_keys = sorted(labels_by_tile.keys())

        # Calculate offsets
        index_offset = HEADER_SIZE + PALETTE_SIZE
        data_offset = index_offset + len(self.tiles) * INDEX_ENTRY_SIZE

        # Calculate data offsets for each tile
        current_data_offset = data_offset
        for entry, data in self.tiles:
            entry.offset = current_data_offset
            current_data_offset += len(data)

        # Label index comes after tile data
        label_index_offset = current_data_offset
        label_index_count = len(sorted_tile_keys)

        # Label data comes after label index
        label_data_offset = label_index_offset + label_index_count * LABEL_INDEX_SIZE

        # Build label index and pack label data
        label_index_entries = []
        label_data_chunks = []
        current_label_offset = label_data_offset

        for tile_key in sorted_tile_keys:
            extraction_zoom, tile_x, tile_y = tile_key
            tile_labels = labels_by_tile[tile_key]

            # Pack labels for this tile
            tile_label_data = b''.join(label.pack_v3() for label in tile_labels)

            # Create index entry (indexed by extraction_zoom, not zoom_min)
            index_entry = TileLabelIndex(
                extraction_zoom, tile_x, tile_y,
                offset=current_label_offset,
                count=len(tile_labels)
            )
            label_index_entries.append(index_entry)
            label_data_chunks.append(tile_label_data)

            current_label_offset += len(tile_label_data)

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
                label_index_offset,            # label index offset (4 bytes)
                label_index_count,             # label index count (4 bytes)
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

            # Write label index
            for index_entry in label_index_entries:
                f.write(index_entry.pack())

            # Write label data
            for chunk in label_data_chunks:
                f.write(chunk)

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
        self.label_index: List[TileLabelIndex] = []
        self.palette: List[int] = []
        self.min_zoom = 0
        self.max_zoom = 0
        self.tile_size = 256
        self.version = 0
        self.label_index_offset = 0
        self.label_index_count = 0
        self._file: Optional[BinaryIO] = None

        self._read_header()

    def _read_header(self):
        """Read and parse archive header and index."""
        with open(self.archive_path, "rb") as f:
            # Read header
            header_data = f.read(HEADER_SIZE)
            (
                magic, version, compression, tile_size, palette_count,
                tile_count, index_offset, data_offset, min_zoom, max_zoom,
                label_index_offset, label_index_count
            ) = struct.unpack(HEADER_FORMAT, header_data)

            if magic != self.MAGIC:
                raise ValueError(f"Invalid TDMAP magic: {magic}")
            if version not in (1, 2, 3):
                raise ValueError(f"Unsupported TDMAP version: {version}")

            self.version = version
            self.tile_size = tile_size
            self.min_zoom = min_zoom
            self.max_zoom = max_zoom
            self.label_index_offset = label_index_offset if version >= 2 else 0
            self.label_index_count = label_index_count if version >= 2 else 0

            # Read palette
            palette_data = f.read(PALETTE_SIZE)
            self.palette = list(struct.unpack(PALETTE_FORMAT, palette_data))

            # Read tile index
            f.seek(index_offset)
            for _ in range(tile_count):
                entry_data = f.read(INDEX_ENTRY_SIZE)
                zoom, x, y, offset, size = struct.unpack(INDEX_ENTRY_FORMAT, entry_data)
                self.tiles.append(TileEntry(zoom, x, y, offset, size))

            # Read labels based on version
            if version == 2 and self.label_index_count > 0 and self.label_index_offset > 0:
                # v2: labels stored in one big array (legacy)
                f.seek(self.label_index_offset)
                labels_data = f.read()
                offset = 0
                for _ in range(self.label_index_count):
                    if offset >= len(labels_data):
                        break
                    label, consumed = LabelEntry.unpack_v2(labels_data, offset)
                    self.labels.append(label)
                    offset += consumed
            elif version >= 3 and self.label_index_count > 0 and self.label_index_offset > 0:
                # v3: read label index, then load labels per-tile
                f.seek(self.label_index_offset)
                for _ in range(self.label_index_count):
                    entry_data = f.read(LABEL_INDEX_SIZE)
                    if len(entry_data) < LABEL_INDEX_SIZE:
                        break
                    index_entry = TileLabelIndex.unpack(entry_data)
                    self.label_index.append(index_entry)

                # Load all labels (for verification/preview - ESP32 loads lazily)
                for idx_entry in self.label_index:
                    f.seek(idx_entry.offset)
                    for _ in range(idx_entry.count):
                        # Read label data (variable size)
                        label_header = f.read(LABEL_SIZE_V3)
                        if len(label_header) < LABEL_SIZE_V3:
                            break
                        text_len = label_header[5]  # After pixel_x, pixel_y, zoom_min, zoom_max, label_type
                        text_data = f.read(text_len)
                        full_data = label_header + text_data
                        label, _ = LabelEntry.unpack_v3(
                            full_data, 0,
                            idx_entry.zoom, idx_entry.tile_x, idx_entry.tile_y
                        )
                        self.labels.append(label)

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
            "label_index_count": len(self.label_index),
            "min_zoom": self.min_zoom,
            "max_zoom": self.max_zoom,
            "tile_size": self.tile_size,
            "total_data_size": total_size,
            "file_size": self.archive_path.stat().st_size,
        }

    def get_labels_for_tile(self, zoom: int, x: int, y: int) -> List[LabelEntry]:
        """Get all labels that should appear on a specific tile."""
        result = []
        for label in self.labels:
            if zoom < label.zoom_min or zoom > label.zoom_max:
                continue
            # Scale label's tile coordinates to current zoom
            zoom_diff = zoom - label.zoom_min
            scale = 2 ** zoom_diff
            label_x = label.tile_x * scale
            label_y = label.tile_y * scale
            # Check if this label's tile is the requested tile (or contained within)
            if int(label_x) == x and int(label_y) == y:
                result.append(label)
        return result

    def get_labels_for_tile_v3(self, zoom: int, x: int, y: int) -> List[LabelEntry]:
        """
        Get labels for a tile using v3 per-tile index (lazy loading).
        This method reads directly from disk, suitable for ESP32-like lazy loading.

        Labels are indexed by extraction_zoom (tile coordinate level).
        We check all zoom levels from min_zoom to current zoom for parent tiles
        that might contain labels visible at current zoom.
        """
        if self.version < 3:
            return self.get_labels_for_tile(zoom, x, y)

        result = []

        # Check each zoom level from min_zoom to current zoom for labels
        # Labels are indexed by their extraction_zoom (tile coordinate level)
        for check_zoom in range(self.min_zoom, zoom + 1):
            # Calculate which tile at check_zoom contains the current view
            zoom_diff = zoom - check_zoom
            check_x = x >> zoom_diff
            check_y = y >> zoom_diff

            # Binary search for this tile in label index
            idx_entry = self._find_label_index(check_zoom, check_x, check_y)
            if idx_entry is None:
                continue

            # Load labels for this tile from disk
            with open(self.archive_path, "rb") as f:
                f.seek(idx_entry.offset)
                for _ in range(idx_entry.count):
                    label_header = f.read(LABEL_SIZE_V3)
                    if len(label_header) < LABEL_SIZE_V3:
                        break
                    text_len = label_header[5]  # After pixel_x, pixel_y, zoom_min, zoom_max, label_type
                    text_data = f.read(text_len)
                    full_data = label_header + text_data
                    label, _ = LabelEntry.unpack_v3(
                        full_data, 0,
                        idx_entry.zoom, idx_entry.tile_x, idx_entry.tile_y
                    )
                    # Check if label is visible at current zoom (zoom_min <= zoom <= zoom_max)
                    if label.zoom_min <= zoom <= label.zoom_max:
                        result.append(label)

        return result

    def _find_label_index(self, zoom: int, x: int, y: int) -> Optional[TileLabelIndex]:
        """Binary search for a tile in the label index (by extraction_zoom, tile_x, tile_y)."""
        target = (zoom, x, y)
        lo, hi = 0, len(self.label_index) - 1

        while lo <= hi:
            mid = (lo + hi) // 2
            entry = self.label_index[mid]
            current = (entry.zoom, entry.tile_x, entry.tile_y)

            if current == target:
                return entry
            elif current < target:
                lo = mid + 1
            else:
                hi = mid - 1

        return None


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
              f"{info['label_count']} labels ({info['label_index_count']} tile groups), "
              f"zoom {info['min_zoom']}-{info['max_zoom']}, "
              f"size {info['file_size'] / 1024 / 1024:.1f} MB")
        return True
    except Exception as e:
        print(f"Archive verification failed: {e}")
        return False
