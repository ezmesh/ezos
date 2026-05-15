"""Region presets for one-command map generation.

A region preset bundles the geographic bounds, zoom range, and the local
.pmtiles filename make_map.py expects to find under ``data/``. If the source
file is missing, make_map.py prints the exact ``planetiler.sh`` invocation
that would produce it -- the source generation is a separate (one-time,
Docker-based) step the user runs manually.

Bounds: (west, south, east, north) in degrees.
Zoom:   (min_zoom, max_zoom) -- both inclusive.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple


@dataclass(frozen=True)
class Region:
    name: str
    description: str
    bounds: Optional[Tuple[float, float, float, float]]
    zoom: Tuple[int, int]
    # Local source filename under DATA_DIR. The convention follows
    # planetiler.sh's output naming so a fresh `./planetiler.sh <area> <maxz>`
    # drops the file straight into the expected slot.
    source: str
    # Geofabrik area name passed to planetiler.sh (or, equivalently, the OSM
    # PBF basename if the user has one already). None means the user is on
    # their own for source preparation.
    planetiler_area: Optional[str] = None


# Default location for source PMTiles. Kept out of the working tree
# (tools/maps/.gitignore covers *.pmtiles) so multi-GB downloads survive
# reruns but don't bloat the repo.
DATA_DIR = Path(__file__).parent / "data"


REGIONS = {
    "monaco": Region(
        name="monaco",
        description="Monaco (tiny -- handy for testing the pipeline)",
        bounds=(7.40, 43.72, 7.45, 43.76),
        zoom=(11, 16),
        source="monaco-z16.pmtiles",
        planetiler_area="monaco",
    ),
    "amsterdam": Region(
        name="amsterdam",
        description="Greater Amsterdam at street-level detail",
        bounds=(4.7, 52.30, 5.05, 52.45),
        zoom=(11, 14),
        source="netherlands-z14.pmtiles",
        planetiler_area="netherlands",
    ),
    "netherlands": Region(
        name="netherlands",
        description="Netherlands + border at street-level detail",
        bounds=(3.2, 50.7, 7.3, 53.7),
        zoom=(11, 14),
        source="netherlands-z14.pmtiles",
        planetiler_area="netherlands",
    ),
    "europe": Region(
        name="europe",
        description="Western Europe to Urals (regional overview)",
        bounds=(-12.0, 34.0, 45.0, 72.0),
        zoom=(7, 10),
        source="europe-z10.pmtiles",
        planetiler_area="europe",
    ),
}


def list_regions() -> str:
    """Pretty-printed list of presets for use in --help / error messages."""
    rows = []
    for r in REGIONS.values():
        b = ", ".join(f"{x:+.2f}" for x in r.bounds) if r.bounds else "world"
        rows.append(
            f"  {r.name:<14} z{r.zoom[0]:>2}-{r.zoom[1]:<2}  {b}\n"
            f"                   {r.description}"
        )
    return "\n".join(rows)


def get(name: str) -> Region:
    if name not in REGIONS:
        raise KeyError(
            f"unknown region '{name}'.\n"
            f"Available presets:\n{list_regions()}\n\n"
            f"To use a custom PMTiles + bounds:\n"
            f"  make_map.py custom <input.pmtiles> --bounds W,S,E,N --zoom MIN,MAX"
        )
    return REGIONS[name]


def source_path(region: Region) -> Path:
    """Resolved local path for a region's source .pmtiles."""
    return DATA_DIR / region.source
