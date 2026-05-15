#!/usr/bin/env python3
"""make_map.py - one-command TDMAP v7 archive builder.

Reads an OpenStreetMap PBF directly via pyosmium and writes a TDMAP v7
archive the device renders as vectors. No Planetiler, no Docker, no
per-tile MVT decode round-trip: each OSM feature is read once and emitted
as canonical geometry.

Usage:
    make_map.py <region>                 # build a preset (auto-fetches PBF)
    make_map.py custom <file.osm.pbf> --bounds W,S,E,N --zoom MIN,MAX
    make_map.py --list                   # show preset catalogue

If the preset's PBF is missing under tools/maps/data/, the script
downloads it from Geofabrik on the fly. Cache survives reruns.

Failure surfaces (loud, with hints, not silent empty maps):
  * empty bounds              -> "no ways extracted within bounds"
  * missing PBF + offline     -> "PBF not found and download failed: ..."
  * zoom out of sensible range-> "zoom range MIN..MAX outside 0..18"
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import time
import urllib.request
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

try:
    import osmium
except ImportError:
    sys.exit(
        "Missing dependency: osmium (pyosmium).\n"
        "Install with: pip install -r tools/maps/requirements.txt"
    )

import regions as region_presets
from tdmap import (
    F_LAND, F_WATER, F_PARK, F_BUILDING,
    F_ROAD_MINOR, F_ROAD_MAJOR, F_HIGHWAY, F_RAILWAY,
    G_POLYLINE, G_POLYGON,
    LABEL_CITY, LABEL_TOWN, LABEL_VILLAGE, LABEL_SUBURB,
    LABEL_WATER, LABEL_MIN_ZOOM,
    Geometry, Label, TDMAPWriter,
    simplify,
    verify,
)


# ---------------------------------------------------------------------------
# Zoom-dependent simplification tolerance (degrees).
# Each zoom step doubles tile resolution, so the tolerance halves. Anchored
# at z=14 ~= 1 px per 2e-5 degrees: anything coarser collapses below display
# resolution.
# ---------------------------------------------------------------------------

_BASE_TOLERANCE_AT_Z14 = 2e-5


def tolerance_for_zoom(z: int) -> float:
    return _BASE_TOLERANCE_AT_Z14 * (2 ** (14 - z))


# ---------------------------------------------------------------------------
# OSM tag -> our 8-class semantic schema. Returns (feature_class, geom_type,
# min_zoom, max_zoom) or None to drop the feature.
#
# The classification is intentionally coarse — the device renders 8 colors,
# so any further granularity is wasted geometry. Tags taken from the OSM
# wiki and matched against what shows up in Geofabrik PBFs.
# ---------------------------------------------------------------------------

_PARK_LANDUSE = {"forest", "wood", "grass", "meadow", "village_green",
                 "recreation_ground", "cemetery", "allotments"}
_PARK_LEISURE = {"park", "garden", "nature_reserve", "pitch", "playground",
                 "common"}
_PARK_NATURAL = {"wood", "scrub", "heath", "grassland", "fell"}

# Highway class -> feature_class + min_zoom. We pick "the smallest zoom at
# which this road's worth drawing" to avoid blowing the geometry budget at
# low zooms where you can't see the difference between residential and
# tertiary anyway.
_HIGHWAY_CLASS = {
    "motorway":       (F_HIGHWAY,    8),
    "motorway_link":  (F_HIGHWAY,    11),
    "trunk":          (F_HIGHWAY,    9),
    "trunk_link":     (F_HIGHWAY,    12),
    "primary":        (F_ROAD_MAJOR, 9),
    "primary_link":   (F_ROAD_MAJOR, 12),
    "secondary":      (F_ROAD_MAJOR, 10),
    "secondary_link": (F_ROAD_MAJOR, 12),
    "tertiary":       (F_ROAD_MINOR, 11),
    "tertiary_link":  (F_ROAD_MINOR, 13),
    "unclassified":   (F_ROAD_MINOR, 12),
    "residential":    (F_ROAD_MINOR, 12),
    "living_street":  (F_ROAD_MINOR, 13),
    # service / track / path / footway / cycleway are deliberately omitted —
    # they swamp dense urban areas with low-value lines and blow render
    # budget. Add them here if a use case wants pedestrian / cycling detail.
}

# Place class -> label type + min zoom
_PLACE_CLASS = {
    "city":          (LABEL_CITY,    6),
    "town":          (LABEL_TOWN,    9),
    "village":       (LABEL_VILLAGE, 11),
    "hamlet":        (LABEL_VILLAGE, 12),
    "suburb":        (LABEL_SUBURB,  13),
    "neighbourhood": (LABEL_SUBURB,  13),
}


def _classify_polygon(tags) -> Optional[Tuple[int, int, int]]:
    """For an Area, decide whether to keep it and as what.

    Returns (feature_class, min_zoom, max_zoom) or None to drop.
    """
    # Buildings: only render close-up to keep urban tiles tractable.
    if "building" in tags:
        return F_BUILDING, 13, 18

    # Water bodies: lakes, reservoirs, basins.
    if tags.get("natural") in ("water", "bay"):
        return F_WATER, 9, 18
    if tags.get("waterway") in ("riverbank",):
        return F_WATER, 10, 18
    if tags.get("water") in ("lake", "reservoir", "pond", "basin"):
        return F_WATER, 9, 18

    # Land vs the implicit ocean background: explicit land polygons help
    # the renderer fill coastal tiles correctly.
    if tags.get("natural") == "coastline":
        # Coastline is normally a LineString in OSM, not a polygon. Polygons
        # tagged this way are rare but we keep them as land for sanity.
        return F_LAND, 7, 18

    # Parks / green: a handful of common tag families.
    if tags.get("landuse") in _PARK_LANDUSE:
        return F_PARK, 10, 18
    if tags.get("leisure") in _PARK_LEISURE:
        return F_PARK, 11, 18
    if tags.get("natural") in _PARK_NATURAL:
        return F_PARK, 10, 18

    return None


def _classify_way(tags) -> Optional[Tuple[int, int, int]]:
    """For a non-area way, decide whether to keep it and as what.

    Returns (feature_class, min_zoom, max_zoom) or None to drop.
    """
    highway = tags.get("highway")
    if highway:
        spec = _HIGHWAY_CLASS.get(highway)
        if spec:
            fc, zmin = spec
            return fc, zmin, 18
        return None

    if tags.get("railway") in ("rail", "light_rail", "subway", "tram"):
        return F_RAILWAY, 11, 18

    waterway = tags.get("waterway")
    if waterway in ("river", "canal"):
        return F_WATER, 10, 18
    if waterway in ("stream",):
        return F_WATER, 13, 18

    if tags.get("natural") == "coastline":
        return F_LAND, 7, 18  # coastlines drawn as polylines

    return None


# ---------------------------------------------------------------------------
# Geofabrik auto-fetch
# ---------------------------------------------------------------------------

def _download(url: str, dest: Path) -> None:
    """Stream a PBF download to `dest` with progress reporting."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    print(f"Fetching {url}")
    start = time.time()
    last = start
    with urllib.request.urlopen(url) as resp, open(tmp, "wb") as f:
        total = int(resp.headers.get("Content-Length") or 0)
        read = 0
        chunk_size = 1024 * 1024
        while True:
            chunk = resp.read(chunk_size)
            if not chunk:
                break
            f.write(chunk)
            read += len(chunk)
            now = time.time()
            if now - last >= 1.0:
                last = now
                pct = (read / total * 100) if total else 0
                mb = read / (1024 * 1024)
                rate = read / (now - start) / (1024 * 1024)
                sys.stdout.write(
                    f"\r  {mb:.1f} MB ({pct:.0f}%)  {rate:.1f} MB/s")
                sys.stdout.flush()
    print()
    tmp.rename(dest)


def _resolve_source(source: str) -> Path:
    """Region preset source -> on-disk path. Relative names map under data/."""
    p = Path(source)
    if p.is_absolute() or source.startswith(("./", "../")):
        return p
    return region_presets.DATA_DIR / source


def _ensure_pbf(preset) -> Path:
    """Return the local PBF path for a preset, downloading from Geofabrik
    if it's missing."""
    local = _resolve_source(preset.source)
    if local.exists():
        return local
    if not preset.geofabrik_url:
        raise SystemExit(
            f"PBF not found: {local}\n"
            f"Region '{preset.name}' has no Geofabrik URL; place the PBF "
            f"manually under tools/maps/data/."
        )
    try:
        _download(preset.geofabrik_url, local)
    except Exception as exc:
        raise SystemExit(
            f"PBF not found and download failed: {exc}\n"
            f"Tried: {preset.geofabrik_url}\n"
            f"Drop a copy at {local} manually if Geofabrik is unreachable."
        )
    return local


# ---------------------------------------------------------------------------
# pyosmium handler-free extraction.
#
# pyosmium 4.x exposes a `FileProcessor` iterator. We make two passes:
#   1) NODE | WAY     with locations + KeyFilter — fast, gets linear features.
#   2) AREA           with .with_areas() — gets polygon features (buildings,
#                     water, parks). pyosmium assembles multipolygon relations
#                     for us.
# A second pass through the file is cheap (osmium reads PBF natively).
# ---------------------------------------------------------------------------

def _within(bounds, lat, lon) -> bool:
    if not bounds:
        return True
    w, s, e, n = bounds
    return w <= lon <= e and s <= lat <= n


def _way_to_latlon(nodes) -> List[Tuple[float, float]]:
    """Pyosmium way nodes -> [(lat, lon), ...]."""
    out: List[Tuple[float, float]] = []
    for n in nodes:
        if not n.location.valid():
            continue
        out.append((n.location.lat, n.location.lon))
    return out


def _ring_to_latlon(ring) -> List[Tuple[float, float]]:
    """Pyosmium outer ring -> [(lat, lon), ...]. Skips duplicate closing
    vertex; the writer reads polygons as implicitly closed."""
    out: List[Tuple[float, float]] = []
    for n in ring:
        out.append((n.lat, n.lon))
    if len(out) > 1 and out[0] == out[-1]:
        out = out[:-1]
    return out


def _bbox_of(verts: Iterable[Tuple[float, float]]) -> Tuple[float, float, float, float]:
    lats = [v[0] for v in verts]
    lons = [v[1] for v in verts]
    return min(lats), min(lons), max(lats), max(lons)


def _intersects_bounds(geom_bbox, bounds) -> bool:
    if not bounds:
        return True
    g_min_lat, g_min_lon, g_max_lat, g_max_lon = geom_bbox
    w, s, e, n = bounds
    return not (g_max_lon < w or g_min_lon > e
                or g_max_lat < s or g_min_lat > n)


def extract_from_pbf(
    pbf_path: Path,
    bounds: Optional[Tuple[float, float, float, float]],
    zoom_range: Tuple[int, int],
) -> Tuple[List[Geometry], List[Label]]:
    """Walk an OSM PBF once and return geometries + labels in our schema."""
    min_zoom, max_zoom = zoom_range
    geoms: List[Geometry] = []
    labels: List[Label] = []

    print(f"Reading {pbf_path}")
    way_count = 0
    area_count = 0
    place_count = 0
    start = time.time()

    # Pass 1: linear features (roads, railways, rivers, coastlines as ways).
    # NODE is needed so .with_locations() can backfill way geometry.
    for obj in (osmium.FileProcessor(
            str(pbf_path),
            osmium.osm.NODE | osmium.osm.WAY,
        ).with_locations()):
        if obj.is_node():
            # Places live on nodes (city/town/village center points).
            place = obj.tags.get("place")
            name = obj.tags.get("name") or obj.tags.get("name:en")
            if place and name and place in _PLACE_CLASS:
                lat = obj.location.lat
                lon = obj.location.lon
                if _within(bounds, lat, lon):
                    ltype, min_z = _PLACE_CLASS[place]
                    labels.append(Label(
                        lat=lat, lon=lon,
                        zoom_min=LABEL_MIN_ZOOM.get(ltype, min_z),
                        zoom_max=14,
                        label_type=ltype,
                        text=name[:50],
                    ))
                    place_count += 1
            continue

        # Skip ways whose tags don't classify as anything we draw.
        spec = _classify_way(obj.tags)
        if not spec:
            continue

        fc, zmin, zmax = spec
        # Clip the feature's zoom range to the requested window. Saves
        # storage on archives that cap below 14.
        zmin = max(zmin, min_zoom)
        zmax = min(zmax, max_zoom)
        if zmin > zmax:
            continue

        try:
            verts = _way_to_latlon(obj.nodes)
        except osmium.InvalidLocationError:
            continue
        if len(verts) < 2:
            continue
        if not _intersects_bounds(_bbox_of(verts), bounds):
            continue

        # Per-zoom geometry: simplify once at the tolerance for the lowest
        # zoom level the feature appears at, then use the same vertex set
        # for higher zooms. (Simplifying per-zoom would duplicate the
        # feature, which is what we're trying to avoid.)
        simplified = simplify(verts, tolerance_for_zoom(zmin))
        if len(simplified) < 2:
            continue

        geoms.append(Geometry(
            feature_class=fc,
            geom_type=G_POLYLINE,
            min_zoom=zmin,
            max_zoom=zmax,
            vertices=simplified,
        ))
        way_count += 1

    print(f"  pass 1 (ways): {way_count:,} drawn, {place_count:,} place labels "
          f"({time.time() - start:.1f}s)")

    # Pass 2: areas (closed polygons + multipolygon relations). pyosmium
    # needs NODE | WAY | RELATION available so it can assemble multipolygon
    # geometry; we only iterate the AREA output but the loader has to see
    # the underlying features.
    pass2_start = time.time()
    area_filter = (osmium.osm.NODE | osmium.osm.WAY
                   | osmium.osm.RELATION | osmium.osm.AREA)
    for obj in (osmium.FileProcessor(str(pbf_path), area_filter)
                .with_areas()):
        if not obj.is_area():
            continue
        spec = _classify_polygon(obj.tags)
        if not spec:
            continue
        fc, zmin, zmax = spec
        zmin = max(zmin, min_zoom)
        zmax = min(zmax, max_zoom)
        if zmin > zmax:
            continue

        # Only the outer rings are drawn — see CLAUDE.md notes; inner holes
        # would render as the wrong color, which is more confusing than
        # over-painting them. Multipolygons emit one Geometry per outer.
        try:
            for outer in obj.outer_rings():
                verts = _ring_to_latlon(outer)
                if len(verts) < 3:
                    continue
                if not _intersects_bounds(_bbox_of(verts), bounds):
                    continue
                simplified = simplify(verts, tolerance_for_zoom(zmin))
                if len(simplified) < 3:
                    continue
                geoms.append(Geometry(
                    feature_class=fc,
                    geom_type=G_POLYGON,
                    min_zoom=zmin,
                    max_zoom=zmax,
                    vertices=simplified,
                ))
                area_count += 1
        except osmium.InvalidLocationError:
            continue

    print(f"  pass 2 (areas): {area_count:,} drawn "
          f"({time.time() - pass2_start:.1f}s)")
    return geoms, labels


# ---------------------------------------------------------------------------
# Top-level driver
# ---------------------------------------------------------------------------

def build_archive(
    pbf_path: Path,
    output_path: Path,
    bounds: Optional[Tuple[float, float, float, float]],
    zoom_range: Tuple[int, int],
    region_name: Optional[str],
) -> Path:
    if not pbf_path.exists():
        raise SystemExit(f"PBF not found: {pbf_path}")

    min_zoom, max_zoom = zoom_range
    if min_zoom > max_zoom:
        raise SystemExit(f"invalid --zoom: min ({min_zoom}) > max ({max_zoom})")
    if min_zoom < 0 or max_zoom > 18:
        raise SystemExit(f"zoom range {min_zoom}..{max_zoom} outside 0..18")

    print(f"Source     : {pbf_path}")
    print(f"Output     : {output_path}")
    if bounds:
        print(f"Bounds     : W={bounds[0]:+.3f} S={bounds[1]:+.3f} "
              f"E={bounds[2]:+.3f} N={bounds[3]:+.3f}")
    else:
        print("Bounds     : entire PBF")
    print(f"Zoom range : {min_zoom}..{max_zoom}")

    start = time.time()
    geoms, labels = extract_from_pbf(pbf_path, bounds, zoom_range)

    if not geoms:
        raise SystemExit(
            "no ways extracted within bounds — check bounds align with the "
            "PBF's coverage, and the source actually contains the layers we "
            "classify (highway/water/landuse).")

    # Compute bounds from geometry if user didn't specify any (handy for
    # raw "convert the whole PBF" runs).
    if not bounds:
        min_lat = min(g.bbox[0] for g in geoms)
        min_lon = min(g.bbox[1] for g in geoms)
        max_lat = max(g.bbox[2] for g in geoms)
        max_lon = max(g.bbox[3] for g in geoms)
        bounds = (min_lon, min_lat, max_lon, max_lat)
        print(f"Inferred bounds: W={bounds[0]:+.3f} S={bounds[1]:+.3f} "
              f"E={bounds[2]:+.3f} N={bounds[3]:+.3f}")

    writer = TDMAPWriter()
    writer.set_bounds(*bounds)
    if region_name:
        writer.set_region_name(region_name)
    writer.set_build_timestamp()
    writer.set_tool_version("make_map.py v7 (pyosmium)")
    try:
        h = hashlib.sha256()
        with open(pbf_path, "rb") as sf:
            h.update(sf.read(1024 * 1024))
        writer.set_source_hash(h.digest())
    except Exception:
        pass

    for g in geoms:
        writer.add_geometry(g)
    for l in labels:
        writer.add_label(l)

    print(f"\nWriting {output_path}...")
    writer.write(output_path)
    verify(output_path)
    print(f"Done in {(time.time() - start) / 60:.1f} min "
          f"({len(geoms):,} geometries, {len(labels):,} labels)")
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


def main() -> int:
    p = argparse.ArgumentParser(
        description="Build a TDMAP v7 archive from an OSM PBF.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  make_map.py netherlands\n"
            "      Build the 'netherlands' preset. Auto-downloads the PBF\n"
            "      from Geofabrik on first run.\n\n"
            "  make_map.py custom my-region.osm.pbf \\\n"
            "                     --bounds 4.7,52.3,5.0,52.5 --zoom 12,14 \\\n"
            "                     -o ams.tdmap\n"
            "      Build from a local PBF you supply.\n"
        ),
    )
    p.add_argument("region", nargs="?",
                   help="Preset name (see --list) or the literal 'custom'.")
    p.add_argument("input", type=Path, nargs="?",
                   help="For 'custom': path to source PBF.")
    p.add_argument("-o", "--output", type=Path, default=None,
                   help="Output .tdmap path (default: <region>.tdmap).")
    p.add_argument("--bounds", type=_parse_bounds, default=None,
                   help="Override bounds (custom mode): 'west,south,east,north'")
    p.add_argument("--zoom", type=_parse_zoom, default=None,
                   help="Override zoom range: 'min,max'.")
    p.add_argument("--region-name", type=str, default=None,
                   help="Human-readable name for the archive metadata.")
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
            sys.exit("custom mode: provide <pbf> as a positional argument")
        if args.bounds is None or args.zoom is None:
            sys.exit("custom mode: --bounds and --zoom are required")
        pbf_path = args.input
        bounds = args.bounds
        zoom = args.zoom
        name = args.region_name
        default_out = args.input.with_suffix("").with_suffix(".tdmap")
    else:
        try:
            preset = region_presets.get(args.region)
        except KeyError as exc:
            sys.exit(str(exc))
        pbf_path = _ensure_pbf(preset)
        bounds = args.bounds or preset.bounds
        zoom = args.zoom or preset.zoom
        name = args.region_name or preset.description
        default_out = Path(f"{preset.name}.tdmap")

    output = args.output or default_out
    build_archive(
        pbf_path=pbf_path,
        output_path=output,
        bounds=bounds,
        zoom_range=zoom,
        region_name=name,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
