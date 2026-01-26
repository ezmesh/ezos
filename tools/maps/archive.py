"""
TDMAP archive format writer and reader.
Custom format optimized for ESP32 reading of map tiles from SD card.
"""

import struct
from pathlib import Path
from typing import List, Tuple, BinaryIO, Optional

from config import PALETTE_RGB565, TILE_SIZE, TDMAP_VERSION, COMPRESSION_RLE


# Archive header format (32 bytes total)
# All multi-byte integers are little-endian
HEADER_FORMAT = "<6sBBHBIIIbbxxxxxxx"
HEADER_SIZE = 32

# Palette entry format: 8 RGB565 values (16 bytes)
PALETTE_FORMAT = "<8H"
PALETTE_SIZE = 16

# Tile index entry format (10 bytes per tile)
# zoom(1) + x(2) + y(2) + offset(4) + size(2) = 11 bytes, but we use 10
# Actually: zoom(1) + x(2) + y(2) + offset(4) + size(2) = 11 bytes
# Let's use a simpler format: pack x and y with zoom encoded differently
INDEX_ENTRY_FORMAT = "<BHHIH"  # zoom, x, y, offset, compressed_size
INDEX_ENTRY_SIZE = 11


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

    def write(self):
        """Write the complete archive to disk."""
        if not self.tiles:
            raise ValueError("No tiles to write")

        # Sort tiles by zoom, then x, then y for efficient binary search
        self.tiles.sort(key=lambda t: (t[0].zoom, t[0].x, t[0].y))

        # Calculate offsets
        index_offset = HEADER_SIZE + PALETTE_SIZE
        data_offset = index_offset + len(self.tiles) * INDEX_ENTRY_SIZE

        # Calculate data offsets for each tile
        current_data_offset = data_offset
        for entry, data in self.tiles:
            entry.offset = current_data_offset
            current_data_offset += len(data)

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
                # 7 bytes reserved (padding)
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
        self.palette: List[int] = []
        self.min_zoom = 0
        self.max_zoom = 0
        self.tile_size = 256
        self._file: Optional[BinaryIO] = None

        self._read_header()

    def _read_header(self):
        """Read and parse archive header and index."""
        with open(self.archive_path, "rb") as f:
            # Read header
            header_data = f.read(HEADER_SIZE)
            (
                magic, version, compression, tile_size, palette_count,
                tile_count, index_offset, data_offset, min_zoom, max_zoom
            ) = struct.unpack(HEADER_FORMAT, header_data)

            if magic != self.MAGIC:
                raise ValueError(f"Invalid TDMAP magic: {magic}")
            if version != TDMAP_VERSION:
                raise ValueError(f"Unsupported TDMAP version: {version}")

            self.tile_size = tile_size
            self.min_zoom = min_zoom
            self.max_zoom = max_zoom

            # Read palette
            palette_data = f.read(PALETTE_SIZE)
            self.palette = list(struct.unpack(PALETTE_FORMAT, palette_data))

            # Read tile index
            f.seek(index_offset)
            for _ in range(tile_count):
                entry_data = f.read(INDEX_ENTRY_SIZE)
                zoom, x, y, offset, size = struct.unpack(INDEX_ENTRY_FORMAT, entry_data)
                self.tiles.append(TileEntry(zoom, x, y, offset, size))

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
            "tile_count": len(self.tiles),
            "min_zoom": self.min_zoom,
            "max_zoom": self.max_zoom,
            "tile_size": self.tile_size,
            "total_data_size": total_size,
            "file_size": self.archive_path.stat().st_size,
        }


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
        print(f"Archive verified: {info['tile_count']} tiles, "
              f"zoom {info['min_zoom']}-{info['max_zoom']}, "
              f"size {info['file_size'] / 1024 / 1024:.1f} MB")
        return True
    except Exception as e:
        print(f"Archive verification failed: {e}")
        return False
