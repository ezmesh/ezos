#!/usr/bin/env python3
"""make_map.py: build a TDMAP archive for the T-Deck.

Three usage modes:

  make_map.py <region>
      Build a preset region. Looks up bounds + zoom + source PMTiles in
      regions.py. The source PMTiles is one-time-prepped via planetiler.sh;
      if it's missing, this script tells you exactly which command to run.

  make_map.py custom <input.pmtiles> --bounds W,S,E,N --zoom MIN,MAX [-o out.tdmap]
      Convert any PMTiles + bounds combination. For one-off / experimental
      regions that don't merit a regions.py preset.

  make_map.py inspect <archive.tdmap>
      Dump the header, tile distribution, and first labels of an archive.
      (Same as `python -m tools.maps.tdmap inspect`, exposed here for
      one-tool-discovery.)

Design notes:
  * Source PMTiles preparation lives in planetiler.sh -- a separate one-time
    Docker step. We don't auto-fetch from the internet; PMTiles regional
    extracts aren't a thing Protomaps publishes.
  * Tile rendering runs through a multiprocessing pool (one PMTiles reader
    + one land mask per worker). Uses every available CPU by default.
  * Resume/checkpoint is invisible: a .checkpoint file appears mid-build,
    is consulted automatically on rerun if present + valid, and is removed
    on successful completion.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import multiprocessing as mp
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from pmtiles.reader import MmapSource, Reader as PMTilesReader

import regions
from regions import Region
import tdmap
from tdmap import (
    TDMAPWriter, count_tiles_in_bounds, extract_labels, get_land_mask,
    inspect_archive, lat_lon_to_tile, process_tile_image, render_vector_tile,
    tiles_in_bounds, verify_archive,
)


TOOL_VERSION = "make_map.py v1 (tdmap.py v6)"


# ============================================================================
# Worker process state
# ============================================================================

_worker_reader = None
_worker_pmtiles_path: Optional[str] = None
_worker_land_mask = None


def _init_worker(pmtiles_path: str):
    """Initialize each worker process: open PMTiles + load land mask."""
    global _worker_reader, _worker_pmtiles_path, _worker_land_mask
    _worker_pmtiles_path = pmtiles_path
    f = open(pmtiles_path, "rb")
    _worker_reader = PMTilesReader(MmapSource(f))
    _worker_land_mask = get_land_mask()


def _safe_get(z: int, x: int, y: int) -> Optional[bytes]:
    if _worker_reader is None:
        return None
    try:
        return _worker_reader.get(z, x, y)
    except Exception:
        return None


def _process_tile(args: Tuple[int, int, int]) -> Dict[str, Any]:
    """Worker: render a single tile + extract its labels."""
    z, x, y = args
    tile_data = _safe_get(z, x, y)
    if tile_data is None:
        return {"status": "missing", "z": z, "x": x, "y": y}

    try:
        # 8 neighbours close the seam at tile boundaries (issue #17).
        neighbours: Dict[Tuple[int, int], bytes] = {}
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                nd = _safe_get(z, x + dx, y + dy)
                if nd is not None:
                    neighbours[(dx, dy)] = nd

        img = render_vector_tile(tile_data, z, x, y, _worker_land_mask,
                                  neighbour_tiles=neighbours)
        return {
            "status": "ok",
            "z": z, "x": x, "y": y,
            "data": process_tile_image(img),
            "labels": extract_labels(tile_data, z, x, y),
        }
    except Exception as e:
        return {"status": "failed", "z": z, "x": x, "y": y, "error": str(e)}


# ============================================================================
# Checkpoint (invisible by default)
# ============================================================================

CHECKPOINT_VERSION = 3


def _render_fingerprint(pmtiles_path: Path) -> str:
    """Hash of inputs that affect tile output bytes. Used to invalidate stale
    checkpoints when the user changes palette / source / zoom thresholds."""
    h = hashlib.sha256()
    h.update(repr(tdmap.PALETTE_RGB).encode())
    h.update(repr(tdmap.TILE_SIZE).encode())
    h.update(repr(tdmap.TDMAP_VERSION).encode())
    h.update(repr(tdmap.DEFAULT_COMPRESSION).encode())
    h.update(repr(sorted(tdmap.LABEL_MIN_ZOOM.items())).encode())
    if pmtiles_path.exists():
        st = pmtiles_path.stat()
        h.update(str(pmtiles_path.resolve()).encode())
        h.update(str(st.st_size).encode())
    return h.hexdigest()


class Checkpoint:
    """Invisible resume support: dropped during a run, removed on success."""

    SAVE_INTERVAL = 500

    def __init__(self, path: Path):
        self.path = path
        self.data: Dict[str, Any] = {
            "version": CHECKPOINT_VERSION,
            "processed_tiles": [],
            "labels": [],
            "seen_label_keys": [],
            "stats": {"processed": 0, "missing": 0, "failed": 0,
                      "labels_extracted": 0},
            "config": {},
            "render_fingerprint": None,
        }
        self.tiles_since_save = 0
        self._processed_set: set = set()

    def matches(self, bounds, zoom_range, fingerprint) -> bool:
        cfg = self.data.get("config", {})
        stored_bounds = tuple(cfg.get("bounds")) if cfg.get("bounds") else None
        stored_zoom   = tuple(cfg.get("zoom_range")) if cfg.get("zoom_range") else None
        return (stored_bounds == bounds
                and stored_zoom == zoom_range
                and self.data.get("render_fingerprint") == fingerprint
                and self.data.get("version", 1) >= 2)

    def load_if_valid(self, bounds, zoom_range, fingerprint) -> bool:
        if not self.path.exists():
            return False
        try:
            with open(self.path, "r") as f:
                self.data = json.load(f)
        except Exception:
            return False
        if not self.matches(bounds, zoom_range, fingerprint):
            return False
        self._processed_set = set(self.data.get("processed_tiles", []))
        return True

    def init_fresh(self, bounds, zoom_range, fingerprint):
        self.data["config"] = {
            "bounds":     list(bounds) if bounds else None,
            "zoom_range": list(zoom_range) if zoom_range else None,
        }
        self.data["render_fingerprint"] = fingerprint
        self._processed_set = set()

    def is_done(self, z: int, x: int, y: int) -> bool:
        return f"{z}/{x}/{y}" in self._processed_set

    def mark_done(self, z: int, x: int, y: int):
        key = f"{z}/{x}/{y}"
        self.data["processed_tiles"].append(key)
        self._processed_set.add(key)
        self.data["stats"]["processed"] += 1
        self.tiles_since_save += 1

    def mark_missing(self):
        self.data["stats"]["missing"] += 1
        self.tiles_since_save += 1

    def mark_failed(self):
        self.data["stats"]["failed"] += 1
        self.tiles_since_save += 1

    def add_label(self, label: dict):
        self.data["labels"].append(label)
        lat_e6 = int(label["lat"] * 1_000_000)
        lon_e6 = int(label["lon"] * 1_000_000)
        self.data["seen_label_keys"].append([label["text"], lat_e6, lon_e6])
        self.data["stats"]["labels_extracted"] += 1

    def seen_labels(self) -> set:
        return {tuple(k) for k in self.data.get("seen_label_keys", [])}

    def save(self):
        self.data["last_saved"] = time.strftime("%Y-%m-%d %H:%M:%S")
        with open(self.path, "w") as f:
            json.dump(self.data, f)
        self.tiles_since_save = 0

    def maybe_save(self):
        if self.tiles_since_save >= self.SAVE_INTERVAL:
            self.save()

    def remove(self):
        if self.path.exists():
            self.path.unlink()


# ============================================================================
# Conversion pipeline
# ============================================================================

def convert_pmtiles(input_path: Path, output_path: Path,
                    bounds: Tuple[float, float, float, float],
                    zoom_range: Tuple[int, int],
                    region_name: Optional[str] = None,
                    workers: Optional[int] = None,
                    dry_run: bool = False) -> int:
    """Build a TDMAP archive from a PMTiles source. Loud on bad inputs.

    Returns 0 on success, non-zero on failure.
    """
    if not input_path.exists():
        print(f"error: source PMTiles not found: {input_path}", file=sys.stderr)
        return 2

    workers = workers or max(1, mp.cpu_count())
    print(f"Source : {input_path}")
    print(f"Output : {output_path}")
    print(f"Bounds : W={bounds[0]:+.3f} S={bounds[1]:+.3f} "
          f"E={bounds[2]:+.3f} N={bounds[3]:+.3f}")
    print(f"Zoom   : {zoom_range[0]}..{zoom_range[1]}")
    print(f"Workers: {workers}")
    print()

    # Land mask up front so the worker init blocks once instead of N times.
    print("Loading land mask...")
    get_land_mask()

    # Validate the requested zoom range against the PMTiles' actual range.
    with open(input_path, "rb") as f:
        header = PMTilesReader(MmapSource(f)).header()
    src_min = header.get("min_zoom", 0)
    src_max = header.get("max_zoom", 14)
    req_min, req_max = zoom_range
    if req_min < src_min or req_max > src_max:
        print(f"error: requested zoom {req_min}..{req_max} is outside the "
              f"source's zoom range {src_min}..{src_max}", file=sys.stderr)
        return 3

    # Total tiles for ETA + zero-tile sanity check.
    total = sum(count_tiles_in_bounds(bounds, z) for z in range(req_min, req_max + 1))
    print(f"Tile count: {total:,}")
    if total == 0:
        print("error: bounds produce zero tiles at the requested zoom range. "
              "Are bounds inside the PMTiles' coverage?", file=sys.stderr)
        return 4

    if dry_run:
        est_mb = total * 3 / 1024
        print(f"Estimated archive size: ~{est_mb:.0f} MB (dry-run)")
        return 0

    # Checkpoint (invisible: present mid-run, removed on success).
    checkpoint_path = output_path.with_suffix(".checkpoint")
    checkpoint = Checkpoint(checkpoint_path)
    fingerprint = _render_fingerprint(input_path)
    resuming = checkpoint.load_if_valid(bounds, zoom_range, fingerprint)
    if resuming:
        print(f"Resuming from checkpoint: "
              f"{checkpoint.data['stats']['processed']:,} tiles already done")
    else:
        if checkpoint_path.exists():
            print("Stale checkpoint (config or source changed) - starting fresh")
        checkpoint.init_fresh(bounds, zoom_range, fingerprint)

    # Build writer + restore prior labels if resuming.
    writer = TDMAPWriter(output_path)
    writer.set_bounds(*bounds)
    if region_name:
        writer.set_region_name(region_name)
    writer.set_build_timestamp()
    writer.set_tool_version(TOOL_VERSION)
    try:
        with open(input_path, "rb") as sf:
            writer.set_source_hash(hashlib.sha256(sf.read(1024 * 1024)).digest())
    except Exception:
        pass

    if resuming:
        for label in checkpoint.data.get("labels", []):
            writer.add_label(label["lat"], label["lon"],
                             label["zoom_min"], label["zoom_max"],
                             label["label_type"], label["text"])
    seen_labels = checkpoint.seen_labels()

    # Build the work queue, skipping tiles already done.
    todo: List[Tuple[int, int, int]] = []
    skipped = 0
    for z in range(req_min, req_max + 1):
        for x, y in tiles_in_bounds(bounds, z):
            if checkpoint.is_done(z, x, y):
                skipped += 1
            else:
                todo.append((z, x, y))
    remaining = len(todo)
    print(f"Tiles to process: {remaining:,} (skipped {skipped:,} already done)")

    if remaining > 0:
        try:
            chunksize = max(1, min(100, remaining // (workers * 4)))
            start = time.time()

            with mp.Pool(processes=workers, initializer=_init_worker,
                         initargs=(str(input_path),)) as pool:
                processed = checkpoint.data["stats"]["processed"]
                missing   = checkpoint.data["stats"]["missing"]
                failed    = checkpoint.data["stats"]["failed"]
                labels_n  = checkpoint.data["stats"]["labels_extracted"]

                for result in pool.imap_unordered(_process_tile, todo, chunksize=chunksize):
                    z, x, y = result["z"], result["x"], result["y"]

                    if result["status"] == "missing":
                        missing += 1
                        checkpoint.mark_missing()
                    elif result["status"] == "failed":
                        print(f"\nFailed tile z={z} x={x} y={y}: "
                              f"{result.get('error', 'unknown')}")
                        failed += 1
                        checkpoint.mark_failed()
                    else:
                        writer.add_tile(z, x, y, result["data"])
                        processed += 1
                        checkpoint.mark_done(z, x, y)
                        for label in result.get("labels", []):
                            lat_e6 = int(label["lat"] * 1_000_000)
                            lon_e6 = int(label["lon"] * 1_000_000)
                            key = (label["text"], lat_e6, lon_e6)
                            if key not in seen_labels:
                                seen_labels.add(key)
                                writer.add_label(
                                    label["lat"], label["lon"],
                                    label["zoom_min"], label["zoom_max"],
                                    label["label_type"], label["text"])
                                labels_n += 1
                                checkpoint.add_label(label)
                        checkpoint.maybe_save()

                    handled = processed + missing + failed
                    if handled % 100 == 0:
                        elapsed = time.time() - start
                        content_rate = (processed + failed) / elapsed if elapsed > 0 else 0
                        eta = (remaining - handled) / content_rate if content_rate > 0 else 0
                        print(f"\r  {handled:,}/{remaining:,} "
                              f"({content_rate:.1f}/s, ETA {eta/60:.0f}m) "
                              f"[empty: {missing}, failed: {failed}, labels: {labels_n}]",
                              end="", flush=True)
                print()
        except KeyboardInterrupt:
            print("\nInterrupted - saving checkpoint and exiting")
            checkpoint.save()
            print(f"Rerun the same command to resume from "
                  f"{checkpoint.data['stats']['processed']:,} tiles")
            return 130

    print(f"\nWriting archive to {output_path}...")
    writer.write()
    print("\nVerifying archive...")
    if not verify_archive(output_path):
        return 5

    checkpoint.remove()  # success: erase invisible state
    return 0


# ============================================================================
# CLI plumbing
# ============================================================================

def _planetiler_help(region: Region) -> str:
    """Exact one-liner for prepping a missing source PMTiles."""
    if region.planetiler_area:
        return (f"./planetiler.sh {region.planetiler_area} {region.zoom[1]}\n"
                f"(produces tools/maps/data/{region.source})")
    return (f"Generate a PMTiles named {region.source!r} under tools/maps/data/. "
            f"Most users do this via planetiler.sh.")


def _parse_bounds(s: str) -> Tuple[float, float, float, float]:
    parts = [float(x.strip()) for x in s.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("bounds must be 'W,S,E,N'")
    return tuple(parts)  # type: ignore


def _parse_zoom(s: str) -> Tuple[int, int]:
    parts = [int(x.strip()) for x in s.split(",")]
    if len(parts) == 1:
        return (parts[0], parts[0])
    if len(parts) == 2:
        return (parts[0], parts[1])
    raise argparse.ArgumentTypeError("zoom must be 'MIN,MAX' or single int")


def _cmd_region(args) -> int:
    try:
        region = regions.get(args.region)
    except KeyError as e:
        print(str(e), file=sys.stderr)
        return 2

    src = regions.source_path(region)
    if not src.exists():
        print(f"error: source PMTiles not found at {src}\n\n"
              f"To prepare it, run:\n  {_planetiler_help(region)}",
              file=sys.stderr)
        return 2

    out = args.output or Path(f"{region.name}.tdmap")
    return convert_pmtiles(
        src, out,
        bounds=region.bounds,
        zoom_range=region.zoom,
        region_name=region.name,
        workers=args.workers,
        dry_run=args.dry_run,
    )


def _cmd_custom(args) -> int:
    if not args.bounds:
        print("error: --bounds W,S,E,N is required for custom builds", file=sys.stderr)
        return 2
    if not args.zoom:
        print("error: --zoom MIN,MAX is required for custom builds", file=sys.stderr)
        return 2

    out = args.output or args.input.with_suffix(".tdmap")
    return convert_pmtiles(
        args.input, out,
        bounds=args.bounds,
        zoom_range=args.zoom,
        region_name=args.region_name,
        workers=args.workers,
        dry_run=args.dry_run,
    )


def _cmd_inspect(args) -> int:
    if not args.path.exists():
        print(f"error: file not found: {args.path}", file=sys.stderr)
        return 2
    try:
        return inspect_archive(args.path, first_n_labels=args.labels)
    except ValueError as e:
        print(f"error: not a TDMAP archive ({e})", file=sys.stderr)
        return 3


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="make_map.py",
        description="Build TDMAP archives for the T-Deck.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Region presets:\n"
            f"{regions.list_regions()}\n\n"
            "Examples:\n"
            "  make_map.py monaco                       # smallest preset, fast\n"
            "  make_map.py netherlands -o nl.tdmap      # full country build\n"
            "  make_map.py custom local.pmtiles \\\n"
            "       --bounds 4.7,52.3,5.1,52.5 --zoom 11,14 -o ams.tdmap\n"
            "  make_map.py inspect netherlands.tdmap\n"
        ),
    )
    sub = parser.add_subparsers(dest="cmd")

    # `make_map.py custom <pmtiles> ...`
    pc = sub.add_parser("custom", help="Build from any PMTiles + bounds + zoom")
    pc.add_argument("input", type=Path)
    pc.add_argument("--bounds", "-b", type=_parse_bounds, metavar="W,S,E,N", required=True)
    pc.add_argument("--zoom", "-z", type=_parse_zoom, metavar="MIN,MAX", required=True)
    pc.add_argument("--output", "-o", type=Path)
    pc.add_argument("--region-name", type=str, default=None,
                    help="Human-readable name written into archive metadata")
    pc.add_argument("--workers", "-j", type=int, default=None)
    pc.add_argument("--dry-run", "-n", action="store_true")
    pc.set_defaults(func=_cmd_custom)

    # `make_map.py inspect <tdmap>`
    pi = sub.add_parser("inspect", help="Dump archive header / tiles / labels")
    pi.add_argument("path", type=Path)
    pi.add_argument("--labels", type=int, default=5)
    pi.set_defaults(func=_cmd_inspect)

    # `make_map.py <region>` — implicit subcommand. Add a positional that
    # competes with `cmd`; argparse can't quite do "subcommand-or-positional"
    # natively, so we sniff argv.
    args = sys.argv[1:]
    if args and args[0] not in {"custom", "inspect", "-h", "--help"}:
        # Treat the first positional as a region name.
        rp = argparse.ArgumentParser(prog="make_map.py <region>", add_help=False)
        rp.add_argument("region", type=str)
        rp.add_argument("--output", "-o", type=Path)
        rp.add_argument("--workers", "-j", type=int, default=None)
        rp.add_argument("--dry-run", "-n", action="store_true")
        rp.add_argument("-h", "--help", action="store_true")
        ns, _extra = rp.parse_known_args(args)
        if ns.help:
            parser.print_help()
            return 0
        return _cmd_region(ns)

    parsed = parser.parse_args()
    if not hasattr(parsed, "func"):
        parser.print_help()
        return 0
    return parsed.func(parsed)


if __name__ == "__main__":
    raise SystemExit(main())
