#!/usr/bin/env python3
"""
T-Deck Offline Map Tile Generator

Downloads, processes, and archives map tiles for offline viewing on T-Deck.
Produces .tdmap files optimized for ESP32 reading from SD card.

Usage:
    python generate.py --output maps/world.tdmap
    python generate.py --region netherlands --output maps/nl.tdmap
    python generate.py --bounds 4.0,52.0,5.0,52.5 --zoom 12,14 --output test.tdmap
"""

import argparse
import sys
from pathlib import Path
from typing import List, Tuple, Optional

from config import REGIONS, TILE_SOURCE
from download import TileDownloader, get_tiles_in_bounds, count_tiles_in_bounds
from process import process_tile
from archive import TDMAPWriter, verify_archive


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


def estimate_tiles(regions: List[str], custom_bounds: Optional[Tuple], custom_zoom: Optional[Tuple]) -> int:
    """Estimate total tile count for given regions/bounds."""
    total = 0

    if custom_bounds and custom_zoom:
        for z in range(custom_zoom[0], custom_zoom[1] + 1):
            total += count_tiles_in_bounds(custom_bounds, z)
    else:
        for region_name in regions:
            region = REGIONS[region_name]
            for z in range(region["zoom"][0], region["zoom"][1] + 1):
                total += count_tiles_in_bounds(region["bounds"], z)

    return total


def generate_archive(
    output_path: Path,
    regions: List[str],
    custom_bounds: Optional[Tuple] = None,
    custom_zoom: Optional[Tuple] = None,
    dry_run: bool = False
):
    """
    Generate TDMAP archive from specified regions.

    Args:
        output_path: Path to output .tdmap file
        regions: List of region names from config
        custom_bounds: Optional custom bounds (west, south, east, north)
        custom_zoom: Optional custom zoom range (min, max)
        dry_run: If True, only count tiles without downloading
    """
    # Estimate tile count
    total_tiles = estimate_tiles(regions, custom_bounds, custom_zoom)
    print(f"Estimated tiles: {total_tiles:,}")

    if dry_run:
        # Rough size estimate: ~5KB average per compressed tile
        estimated_size_mb = total_tiles * 5 / 1024
        print(f"Estimated archive size: ~{estimated_size_mb:.0f} MB")
        return

    # Initialize components
    downloader = TileDownloader()
    writer = TDMAPWriter(output_path)

    processed = 0
    failed = 0

    def process_region(bounds, zoom_range, region_name="custom"):
        nonlocal processed, failed

        for z in range(zoom_range[0], zoom_range[1] + 1):
            tile_count = count_tiles_in_bounds(bounds, z)
            print(f"\nProcessing {region_name} zoom {z}: {tile_count:,} tiles")

            for x, y in get_tiles_in_bounds(bounds, z):
                # Progress indicator
                if processed % 100 == 0:
                    stats = downloader.get_stats()
                    print(f"\r  Progress: {processed:,}/{total_tiles:,} "
                          f"(downloaded: {stats['downloaded']}, cached: {stats['cached']}, "
                          f"failed: {failed})", end="", flush=True)

                # Download tile
                png_data = downloader.get_tile(z, x, y)
                if png_data is None:
                    failed += 1
                    continue

                # Process tile (dither, compress)
                try:
                    compressed = process_tile(png_data)
                    writer.add_tile(z, x, y, compressed)
                except Exception as e:
                    print(f"\nFailed to process tile z={z} x={x} y={y}: {e}")
                    failed += 1
                    continue

                processed += 1

            print()  # Newline after progress

    # Process regions
    if custom_bounds and custom_zoom:
        process_region(custom_bounds, custom_zoom, "custom")
    else:
        for region_name in regions:
            region = REGIONS[region_name]
            process_region(region["bounds"], region["zoom"], region_name)

    # Write archive
    print(f"\nWriting archive to {output_path}...")
    writer.write()

    # Verify
    print("\nVerifying archive...")
    verify_archive(output_path)

    # Final stats
    stats = downloader.get_stats()
    print(f"\nComplete!")
    print(f"  Tiles processed: {processed:,}")
    print(f"  Tiles failed: {failed}")
    print(f"  Downloaded: {stats['downloaded']:,} ({stats['bytes'] / 1024 / 1024:.1f} MB)")
    print(f"  From cache: {stats['cached']:,}")


def main():
    parser = argparse.ArgumentParser(
        description="Generate offline map tiles for T-Deck OS",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --output world.tdmap
      Generate all regions (global + europe + netherlands)

  %(prog)s --region netherlands --output nl.tdmap
      Generate only Netherlands tiles

  %(prog)s --bounds 4.8,52.3,5.0,52.4 --zoom 14,16 --output amsterdam.tdmap
      Generate custom area (Amsterdam center)

  %(prog)s --region europe --dry-run
      Estimate tile count without downloading
"""
    )

    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=Path("map.tdmap"),
        help="Output .tdmap file path (default: map.tdmap)"
    )

    parser.add_argument(
        "--region", "-r",
        action="append",
        choices=list(REGIONS.keys()),
        help="Region to include (can specify multiple, default: all)"
    )

    parser.add_argument(
        "--bounds", "-b",
        type=str,
        help="Custom bounds: west,south,east,north (degrees)"
    )

    parser.add_argument(
        "--zoom", "-z",
        type=str,
        help="Zoom range: min,max (e.g., '12,14')"
    )

    parser.add_argument(
        "--dry-run", "-n",
        action="store_true",
        help="Only estimate tile count, don't download"
    )

    parser.add_argument(
        "--verify",
        type=Path,
        help="Verify existing archive instead of generating"
    )

    args = parser.parse_args()

    # Verify mode
    if args.verify:
        if verify_archive(args.verify):
            sys.exit(0)
        else:
            sys.exit(1)

    # Determine regions/bounds
    custom_bounds = None
    custom_zoom = None

    if args.bounds:
        custom_bounds = parse_bounds(args.bounds)
        if not args.zoom:
            parser.error("--zoom is required when using --bounds")
        custom_zoom = parse_zoom(args.zoom)
        regions = []
    else:
        regions = args.region if args.region else list(REGIONS.keys())

    # Print configuration
    print("T-Deck Offline Map Generator")
    print("=" * 40)
    print(f"Tile source: {TILE_SOURCE['url']}")

    if custom_bounds:
        print(f"Custom bounds: {custom_bounds}")
        print(f"Zoom range: {custom_zoom}")
    else:
        print(f"Regions: {', '.join(regions)}")
        for r in regions:
            region = REGIONS[r]
            print(f"  {r}: bounds={region['bounds']}, zoom={region['zoom']}")

    print(f"Output: {args.output}")
    print()

    # Generate
    generate_archive(
        args.output,
        regions,
        custom_bounds,
        custom_zoom,
        args.dry_run
    )


if __name__ == "__main__":
    main()
