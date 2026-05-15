#!/usr/bin/env python3
"""make_map.py — one-command TDMAP archive builder.

Usage:
    make_map.py <region>                 # build a preset
    make_map.py custom <pmtiles> --bounds W,S,E,N --zoom MIN,MAX -o foo.tdmap
    make_map.py --list                   # show preset catalogue

The script reads vector tiles from a PMTiles source, extracts geometry
(coastlines, water, parks, buildings, roads, railways) per zoom level,
applies Douglas-Peucker simplification at a zoom-appropriate tolerance,
then writes a TDMAP v7 archive that the device renders directly from
vectors.

No rasterization. No land mask download. No multi-stage tower. One file
in, one file out.

Failure surfaces:
  * empty bounds              → "no tiles in bounds at z<MIN>..z<MAX>"
  * source missing            → "PMTiles not found: <path>"
  * zoom out of source range  → "source covers z<a>..z<b>, asked for z<c>..z<d>"
"""

from __future__ import annotations

import argparse
import hashlib
import math
import multiprocessing as mp
import os
import sys
import time
from pathlib import Path
from typing import (
    Any, Dict, Iterator, List, Optional, Sequence, Tuple,
)

# Local modules — single tdmap unit owns the format + writer, regions owns
# the preset catalogue.
import regions as region_presets
from tdmap import (
    F_LAND, F_WATER, F_PARK, F_BUILDING,
    F_ROAD_MINOR, F_ROAD_MAJOR, F_HIGHWAY, F_RAILWAY,
    G_POLYLINE, G_POLYGON,
    LABEL_CITY, LABEL_TOWN, LABEL_VILLAGE, LABEL_SUBURB,
    LABEL_ROAD, LABEL_WATER, LABEL_MIN_ZOOM,
    Geometry, Label, TDMAPWriter,
    decompress_mvt, mvt_layer, simplify,
    lat_lon_to_tile, tile_to_lat_lon, tile_pixel_to_lat_lon,
    verify,
)

# ---------------------------------------------------------------------------
# Zoom-dependent simplification tolerance (in degrees).
#
# Each successive zoom level doubles tile resolution, so the tolerance halves
# at each step. Anchored at z=14 ≈ 1 px per ~2e-5°: anything coarser collapses
# below display resolution and is safe to drop. A single multiplier sets the
# whole ladder, so it's easy to retune in one place if the on-device renderer
# starts struggling with the geometry budget.
# ---------------------------------------------------------------------------

_BASE_TOLERANCE_AT_Z14 = 2e-5

def tolerance_for_zoom(z: int) -> float:
    return _BASE_TOLERANCE_AT_Z14 * (2 ** (14 - z))


# ---------------------------------------------------------------------------
# OSM landuse classes we treat as "park" so the renderer can paint them green
# ---------------------------------------------------------------------------

_PARK_CLASSES = {"park", "grass", "forest", "wood", "meadow", "nature_reserve"}


# ---------------------------------------------------------------------------
# Road class → feature index. Returns None for things we don't draw.
# ---------------------------------------------------------------------------

def road_feature(props: Dict[str, Any]) -> Optional[int]:
    road_class = props.get("class") or props.get("highway") or ""
    if not road_class:
        return None
    rc = road_class.lower()
    if "motorway" in rc or "trunk" in rc:
        return F_HIGHWAY
    if "primary" in rc or "secondary" in rc:
        return F_ROAD_MAJOR
    if "tertiary" in rc or "residential" in rc or "street" in rc:
        return F_ROAD_MINOR
    if "service" in rc or "path" in rc or "track" in rc:
        return None  # too low-importance to draw
    return F_ROAD_MINOR


# ---------------------------------------------------------------------------
# PMTiles iteration
# ---------------------------------------------------------------------------

def _import_pmtiles():
    try:
        from pmtiles.reader import Reader, MmapSource  # type: ignore
        import mapbox_vector_tile as mvt  # type: ignore
    except ImportError as exc:
        sys.exit(
            "Missing dependency: " + str(exc) + "\n"
            "Install with: pip install -r tools/maps/requirements.txt"
        )
    return Reader, MmapSource, mvt


def tiles_in_bounds(
    bounds: Optional[Tuple[float, float, float, float]], zoom: int
) -> Iterator[Tuple[int, int]]:
    n = 2 ** zoom
    if bounds is None:
        for x in range(n):
            for y in range(n):
                yield x, y
        return
    west, south, east, north = bounds
    x_min, y_max = lat_lon_to_tile(south, west, zoom)
    x_max, y_min = lat_lon_to_tile(north, east, zoom)
    x_min = max(0, x_min)
    x_max = min(n - 1, x_max)
    y_min = max(0, y_min)
    y_max = min(n - 1, y_max)
    for x in range(x_min, x_max + 1):
        for y in range(y_min, y_max + 1):
            yield x, y


def count_tiles_in_bounds(
    bounds: Optional[Tuple[float, float, float, float]], zoom: int
) -> int:
    return sum(1 for _ in tiles_in_bounds(bounds, zoom))


# ---------------------------------------------------------------------------
# Geometry extraction from a single MVT tile
# ---------------------------------------------------------------------------

def _tile_extent(decoded) -> int:
    """MVT extent (almost always 4096)."""
    if isinstance(decoded, dict):
        layers = decoded.values()
    else:
        layers = decoded
    for layer in layers:
        if isinstance(layer, dict) and "extent" in layer:
            return layer["extent"]
    return 4096


def _coords_to_lat_lon(
    coords: Sequence[Sequence[float]],
    zoom: int, tile_x: int, tile_y: int, extent: int,
) -> List[Tuple[float, float]]:
    return [
        tile_pixel_to_lat_lon(zoom, tile_x, tile_y, c[0], c[1], extent)
        for c in coords if len(c) >= 2
    ]


def _emit_polylines(
    geom: dict, feature_class: int, min_z: int, max_z: int,
    zoom: int, tile_x: int, tile_y: int, extent: int,
    out: List[Geometry],
) -> None:
    """Push polyline geometry from a feature into ``out``."""
    gtype = geom.get("type")
    coords = geom.get("coordinates", [])
    if gtype == "LineString":
        latlon = _coords_to_lat_lon(coords, zoom, tile_x, tile_y, extent)
        if len(latlon) >= 2:
            out.append(Geometry(
                feature_class=feature_class,
                geom_type=G_POLYLINE,
                min_zoom=min_z,
                max_zoom=max_z,
                vertices=simplify(latlon, tolerance_for_zoom(zoom)),
            ))
    elif gtype == "MultiLineString":
        for sub in coords:
            latlon = _coords_to_lat_lon(sub, zoom, tile_x, tile_y, extent)
            if len(latlon) >= 2:
                out.append(Geometry(
                    feature_class=feature_class,
                    geom_type=G_POLYLINE,
                    min_zoom=min_z,
                    max_zoom=max_z,
                    vertices=simplify(latlon, tolerance_for_zoom(zoom)),
                ))


def _emit_polygons(
    geom: dict, feature_class: int, min_z: int, max_z: int,
    zoom: int, tile_x: int, tile_y: int, extent: int,
    out: List[Geometry],
) -> None:
    """Push polygon geometry. Inner rings (holes) are dropped — the on-device
    renderer doesn't do holes, and at the zoom levels we ship this is rarely
    visible (a lake's island gets painted-over the lake's blue, which is
    actually the visually correct outcome for our flat palette anyway)."""
    gtype = geom.get("type")
    coords = geom.get("coordinates", [])

    def emit_ring(ring):
        latlon = _coords_to_lat_lon(ring, zoom, tile_x, tile_y, extent)
        if len(latlon) >= 3:
            # Polygons close on themselves; drop the duplicated last point
            # if the writer would re-emit it.
            if latlon[0] == latlon[-1]:
                latlon = latlon[:-1]
            simplified = simplify(latlon, tolerance_for_zoom(zoom))
            if len(simplified) >= 3:
                out.append(Geometry(
                    feature_class=feature_class,
                    geom_type=G_POLYGON,
                    min_zoom=min_z,
                    max_zoom=max_z,
                    vertices=simplified,
                ))

    if gtype == "Polygon":
        if coords:
            emit_ring(coords[0])
    elif gtype == "MultiPolygon":
        for poly in coords:
            if poly:
                emit_ring(poly[0])


def extract_tile_geometry(
    tile_data: bytes, zoom: int, tile_x: int, tile_y: int,
) -> Tuple[List[Geometry], List[Label]]:
    """Decode one MVT tile into (geometries, labels). Geometry zoom range is
    [zoom, max_zoom_seen]; the writer will keep the widest [min, max] across
    duplicates so a coastline that appears in z=10 and z=11 tiles renders
    across that range."""
    _Reader, _Source, mvt = _import_pmtiles()
    try:
        raw = decompress_mvt(tile_data)
        decoded = mvt.decode(raw, default_options={"y_coord_down": True})
    except Exception:
        return [], []

    extent = _tile_extent(decoded)
    geoms: List[Geometry] = []
    labels: List[Label] = []

    # Land / earth polygons → F_LAND. Drawn underneath everything.
    for layer_name in ("land", "earth"):
        layer = mvt_layer(decoded, layer_name)
        if not layer:
            continue
        for feat in layer.get("features", []):
            _emit_polygons(feat.get("geometry", {}), F_LAND,
                           zoom, zoom, zoom, tile_x, tile_y, extent, geoms)

    # Water polygons → F_WATER. Lakes, rivers, ocean.
    for layer_name in ("water", "ocean"):
        layer = mvt_layer(decoded, layer_name)
        if not layer:
            continue
        for feat in layer.get("features", []):
            _emit_polygons(feat.get("geometry", {}), F_WATER,
                           zoom, zoom, zoom, tile_x, tile_y, extent, geoms)

    # Landuse → F_PARK for the subset of classes we paint green.
    layer = mvt_layer(decoded, "landuse")
    if layer:
        for feat in layer.get("features", []):
            props = feat.get("properties", {})
            klass = props.get("class") or props.get("landuse") or ""
            if klass in _PARK_CLASSES:
                _emit_polygons(feat.get("geometry", {}), F_PARK,
                               zoom, zoom, zoom, tile_x, tile_y, extent, geoms)

    # Buildings: only emit at z >= 13. Below that, footprints aren't visible
    # and they dominate the geometry budget for nothing.
    if zoom >= 13:
        layer = mvt_layer(decoded, "building")
        if layer:
            for feat in layer.get("features", []):
                _emit_polygons(feat.get("geometry", {}), F_BUILDING,
                               zoom, zoom, zoom, tile_x, tile_y, extent, geoms)

    # Waterways (rivers as polylines).
    layer = mvt_layer(decoded, "waterway")
    if layer:
        for feat in layer.get("features", []):
            _emit_polylines(feat.get("geometry", {}), F_WATER,
                            zoom, zoom, zoom, tile_x, tile_y, extent, geoms)

    # Railways + roads share the "transportation" layer in most schemas.
    layer = mvt_layer(decoded, "transportation")
    if layer:
        for feat in layer.get("features", []):
            props = feat.get("properties", {})
            geom = feat.get("geometry", {})
            if props.get("class") == "rail":
                _emit_polylines(geom, F_RAILWAY,
                                zoom, zoom, zoom, tile_x, tile_y, extent, geoms)
                continue
            fc = road_feature(props)
            if fc is not None:
                _emit_polylines(geom, fc,
                                zoom, zoom, zoom, tile_x, tile_y, extent, geoms)

    # Labels (places + water names).
    for layer_name in ("place", "place_name", "place_label"):
        layer = mvt_layer(decoded, layer_name)
        if not layer:
            continue
        for feat in layer.get("features", []):
            props = feat.get("properties", {})
            geom = feat.get("geometry", {})
            name = props.get("name") or props.get("name:en") or props.get("name:latin")
            if not name:
                continue
            klass = (props.get("class") or props.get("place")
                     or props.get("type", ""))
            lt = None
            if klass in ("city", "metropolis"):
                lt = LABEL_CITY
            elif klass == "town":
                lt = LABEL_TOWN
            elif klass in ("village", "hamlet"):
                lt = LABEL_VILLAGE
            elif klass in ("suburb", "neighbourhood", "neighborhood", "quarter"):
                lt = LABEL_SUBURB
            if lt is None:
                continue
            coords = geom.get("coordinates", [])
            if geom.get("type") == "Point" and len(coords) >= 2:
                lat, lon = tile_pixel_to_lat_lon(
                    zoom, tile_x, tile_y, coords[0], coords[1], extent)
                labels.append(Label(
                    lat=lat, lon=lon,
                    zoom_min=LABEL_MIN_ZOOM.get(lt, zoom),
                    zoom_max=14,
                    label_type=lt,
                    text=name[:50],
                ))

    for layer_name in ("water_name", "waterway_label"):
        layer = mvt_layer(decoded, layer_name)
        if not layer:
            continue
        for feat in layer.get("features", []):
            props = feat.get("properties", {})
            geom = feat.get("geometry", {})
            name = props.get("name") or props.get("name:en")
            if not name:
                continue
            coords = geom.get("coordinates", [])
            px, py = None, None
            if geom.get("type") == "Point" and len(coords) >= 2:
                px, py = coords[0], coords[1]
            elif geom.get("type") in ("LineString", "MultiLineString"):
                if coords and isinstance(coords[0][0], (list, tuple)):
                    coords = coords[0]
                if len(coords) >= 2:
                    mid = len(coords) // 2
                    px, py = coords[mid][0], coords[mid][1]
            if px is None:
                continue
            lat, lon = tile_pixel_to_lat_lon(
                zoom, tile_x, tile_y, px, py, extent)
            labels.append(Label(
                lat=lat, lon=lon,
                zoom_min=LABEL_MIN_ZOOM[LABEL_WATER],
                zoom_max=14,
                label_type=LABEL_WATER,
                text=name[:50],
            ))

    return geoms, labels


# ---------------------------------------------------------------------------
# Worker pool: each worker opens its own PMTiles reader.
# ---------------------------------------------------------------------------

_worker_reader = None


def _init_worker(pmtiles_path: str) -> None:
    global _worker_reader
    Reader, MmapSource, _mvt = _import_pmtiles()
    f = open(pmtiles_path, "rb")
    _worker_reader = Reader(MmapSource(f))


def _process_tile(args: Tuple[int, int, int]) -> Optional[Dict[str, Any]]:
    z, x, y = args
    try:
        tile_data = _worker_reader.get(z, x, y)
    except Exception:
        return None
    if tile_data is None:
        return None
    try:
        geoms, labels = extract_tile_geometry(tile_data, z, x, y)
        return {"geoms": geoms, "labels": labels}
    except Exception as exc:
        sys.stderr.write(f"\n  failed z={z} x={x} y={y}: {exc}\n")
        return None


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def _expand_bounds_to_tile_grid(
    bounds: Tuple[float, float, float, float], zoom: int
) -> Tuple[float, float, float, float]:
    """Snap the user-supplied bounds outward to tile boundaries at the
    requested max zoom, so the spatial-index grid covers everything we render."""
    west, south, east, north = bounds
    x_min, y_max = lat_lon_to_tile(south, west, zoom)
    x_max, y_min = lat_lon_to_tile(north, east, zoom)
    south_lat, west_lon = tile_to_lat_lon(x_min, y_max + 1, zoom)
    north_lat, east_lon = tile_to_lat_lon(x_max + 1, y_min, zoom)
    return west_lon, south_lat, east_lon, north_lat


def build_archive(
    pmtiles_path: Path,
    output_path: Path,
    bounds: Optional[Tuple[float, float, float, float]],
    zoom_range: Tuple[int, int],
    region_name: Optional[str],
    workers: Optional[int] = None,
) -> Path:
    Reader, MmapSource, _mvt = _import_pmtiles()
    if not pmtiles_path.exists():
        raise SystemExit(f"PMTiles not found: {pmtiles_path}")

    workers = workers or max(1, mp.cpu_count())

    # Sanity-check zoom range against the source header.
    with open(pmtiles_path, "rb") as f:
        header = Reader(MmapSource(f)).header()
        src_min_zoom = header.get("min_zoom", 0)
        src_max_zoom = header.get("max_zoom", 14)
    min_zoom, max_zoom = zoom_range
    if min_zoom > max_zoom:
        raise SystemExit(
            f"invalid --zoom: min ({min_zoom}) > max ({max_zoom})")
    if max_zoom < src_min_zoom or min_zoom > src_max_zoom:
        raise SystemExit(
            f"source covers z{src_min_zoom}..z{src_max_zoom}, "
            f"asked for z{min_zoom}..z{max_zoom}")
    if min_zoom < src_min_zoom:
        sys.stderr.write(
            f"  note: source starts at z{src_min_zoom}; "
            f"raising min_zoom from {min_zoom}\n")
        min_zoom = src_min_zoom
    if max_zoom > src_max_zoom:
        sys.stderr.write(
            f"  note: source caps at z{src_max_zoom}; "
            f"lowering max_zoom from {max_zoom}\n")
        max_zoom = src_max_zoom

    # If bounds is None and the PMTiles header tells us, use that.
    if bounds is None and "min_lon_e7" in header:
        bounds = (
            header.get("min_lon_e7", -1_800_000_000) / 1e7,
            header.get("min_lat_e7", -850_000_000) / 1e7,
            header.get("max_lon_e7", 1_800_000_000) / 1e7,
            header.get("max_lat_e7", 850_000_000) / 1e7,
        )
    if bounds is None:
        bounds = (-180.0, -85.0, 180.0, 85.0)
    bounds = _expand_bounds_to_tile_grid(bounds, max_zoom)

    # Count tiles up front so we can fail loud on empty bounds.
    total = sum(count_tiles_in_bounds(bounds, z)
                for z in range(min_zoom, max_zoom + 1))
    if total == 0:
        raise SystemExit(
            f"no tiles in bounds at z{min_zoom}..z{max_zoom}: bounds={bounds}")

    print(f"Source     : {pmtiles_path}")
    print(f"Output     : {output_path}")
    print(f"Bounds     : W={bounds[0]:+.3f} S={bounds[1]:+.3f} "
          f"E={bounds[2]:+.3f} N={bounds[3]:+.3f}")
    print(f"Zoom range : {min_zoom}..{max_zoom}")
    print(f"Tiles      : {total:,} across {max_zoom - min_zoom + 1} zoom levels")
    print(f"Workers    : {workers}")

    writer = TDMAPWriter()
    writer.set_bounds(*bounds)
    if region_name:
        writer.set_region_name(region_name)
    writer.set_build_timestamp()
    writer.set_tool_version("make_map.py v7")
    # Source hash: SHA-256 of a 1 MB prefix is enough to fingerprint without
    # pulling 600 MB through hashlib.
    try:
        h = hashlib.sha256()
        with open(pmtiles_path, "rb") as sf:
            h.update(sf.read(1024 * 1024))
        writer.set_source_hash(h.digest())
    except Exception:
        pass

    # Walk all (z, x, y) once and parallelize across workers. Each worker
    # returns geometries + labels for one tile; we accumulate in the writer
    # on the main thread.
    tile_list: List[Tuple[int, int, int]] = []
    for z in range(min_zoom, max_zoom + 1):
        for x, y in tiles_in_bounds(bounds, z):
            tile_list.append((z, x, y))

    geom_count = 0
    label_count = 0
    start = time.time()
    last_report = start

    with mp.Pool(processes=workers,
                 initializer=_init_worker,
                 initargs=(str(pmtiles_path),)) as pool:
        chunksize = max(1, min(64, len(tile_list) // (workers * 4)))
        for i, result in enumerate(pool.imap_unordered(
                _process_tile, tile_list, chunksize=chunksize)):
            if result is None:
                continue
            for g in result["geoms"]:
                writer.add_geometry(g)
                geom_count += 1
            for l in result["labels"]:
                writer.add_label(l)
                label_count += 1
            now = time.time()
            if now - last_report >= 1.0 or i == len(tile_list) - 1:
                rate = (i + 1) / (now - start) if now > start else 0
                eta = (len(tile_list) - i - 1) / rate if rate > 0 else 0
                sys.stdout.write(
                    f"\r  {i + 1:,}/{len(tile_list):,} tiles  "
                    f"{geom_count:,} geoms  {label_count:,} labels  "
                    f"({rate:.0f} tiles/s, ETA {eta / 60:.0f}m)")
                sys.stdout.flush()
                last_report = now
    print()

    print(f"\nWriting {output_path}...")
    writer.write(output_path)
    verify(output_path)
    print(f"Done in {(time.time() - start) / 60:.1f} min")
    return output_path


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _parse_bounds(s: str) -> Tuple[float, float, float, float]:
    parts = [float(p.strip()) for p in s.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(
            "bounds must be 'west,south,east,north'")
    return tuple(parts)  # type: ignore[return-value]


def _parse_zoom(s: str) -> Tuple[int, int]:
    parts = [int(p.strip()) for p in s.split(",")]
    if len(parts) == 1:
        return parts[0], parts[0]
    if len(parts) == 2:
        return parts[0], parts[1]
    raise argparse.ArgumentTypeError("zoom must be 'min,max' or a single value")


def _resolve_source(source: str) -> Path:
    """Region preset source → on-disk path. Bare filenames map under data/."""
    p = Path(source)
    if p.is_absolute() or source.startswith(("./", "../")):
        return p
    return region_presets.DATA_DIR / source


def main() -> int:
    p = argparse.ArgumentParser(
        description="Build a TDMAP v7 archive from a PMTiles source.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  make_map.py netherlands\n"
            "      Build the 'netherlands' preset to <preset>.tdmap.\n\n"
            "  make_map.py netherlands -o /sd/maps/nl.tdmap\n"
            "      Same, custom output path.\n\n"
            "  make_map.py custom amsterdam.pmtiles "
            "--bounds 4.7,52.3,5.0,52.5 --zoom 12,14 -o ams.tdmap\n"
            "      Roll your own bounds/zoom without touching the catalogue.\n"
        ),
    )
    p.add_argument("region", nargs="?",
                   help="Preset name (see --list) or the literal 'custom'.")
    p.add_argument("input", type=Path, nargs="?",
                   help="For 'custom': path to source PMTiles.")
    p.add_argument("-o", "--output", type=Path, default=None,
                   help="Output .tdmap path (default: <region>.tdmap).")
    p.add_argument("--bounds", type=_parse_bounds, default=None,
                   help="Override bounds (custom mode): 'west,south,east,north'")
    p.add_argument("--zoom", type=_parse_zoom, default=None,
                   help="Override zoom range: 'min,max'.")
    p.add_argument("--region-name", type=str, default=None,
                   help="Human-readable name for the archive metadata.")
    p.add_argument("-j", "--workers", type=int, default=None,
                   help="Parallel workers (default: CPU count).")
    p.add_argument("--list", action="store_true",
                   help="Print region presets and exit.")
    args = p.parse_args()

    if args.list:
        print("Region presets:\n")
        print(region_presets.list_regions())
        return 0

    if not args.region:
        p.print_help()
        return 2

    if args.region == "custom":
        if args.input is None:
            sys.exit("custom mode: provide <pmtiles> as a positional argument")
        if args.bounds is None or args.zoom is None:
            sys.exit("custom mode: --bounds and --zoom are required")
        source = args.input
        bounds = args.bounds
        zoom = args.zoom
        name = args.region_name
        default_out = args.input.with_suffix(".tdmap")
    else:
        try:
            preset = region_presets.get(args.region)
        except KeyError as exc:
            sys.exit(str(exc))
        source = _resolve_source(preset.source)
        bounds = args.bounds or preset.bounds
        zoom = args.zoom or preset.zoom
        name = args.region_name or preset.description
        default_out = Path(f"{preset.name}.tdmap")

    output = args.output or default_out
    build_archive(
        pmtiles_path=source,
        output_path=output,
        bounds=bounds,
        zoom_range=zoom,
        region_name=name,
        workers=args.workers,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
