"""Region presets for one-command map generation.

A region preset bundles everything ``make_map.py`` needs: where to find
the source OSM PBF, what geographic bounds to clip to, and which zoom
range to extract. Add a new entry here and ``make_map.py <name>`` Just
Works -- including downloading the PBF on first run.

Bounds: (west, south, east, north) in degrees.
Zoom:   (min_zoom, max_zoom) -- both inclusive.

The ``source`` field is the local filename under ``DATA_DIR``. If the
file is missing, ``make_map.py`` fetches ``geofabrik_url`` to populate
it (then caches for reruns).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple


@dataclass
class Region:
    name: str
    description: str
    bounds: Optional[Tuple[float, float, float, float]]
    zoom: Tuple[int, int]
    source: str                # filename under DATA_DIR
    geofabrik_url: Optional[str] = None


# Default data directory for downloaded PBFs. Kept out of the working
# tree (tools/maps/.gitignore covers *.osm.pbf) so expensive downloads
# survive reruns but don't bloat the repo.
DATA_DIR = Path(__file__).parent / "data"

# Geofabrik publishes daily-rebuilt regional extracts at predictable URLs:
#   https://download.geofabrik.de/<continent>/<country>-latest.osm.pbf
# Naming follows their layout exactly so swapping in a different region
# only needs a URL + filename.

REGIONS = {
    "monaco": Region(
        name="monaco",
        description="Monaco (tiny -- handy for testing the pipeline)",
        bounds=(7.40, 43.72, 7.45, 43.76),
        zoom=(11, 16),
        source="monaco-latest.osm.pbf",
        geofabrik_url=(
            "https://download.geofabrik.de/europe/monaco-latest.osm.pbf"
        ),
    ),
    "netherlands": Region(
        name="netherlands",
        description="Netherlands + border at street-level detail",
        bounds=(3.2, 50.7, 7.3, 53.7),
        zoom=(8, 14),
        source="netherlands-latest.osm.pbf",
        geofabrik_url=(
            "https://download.geofabrik.de/europe/netherlands-latest.osm.pbf"
        ),
    ),
    "belgium": Region(
        name="belgium",
        description="Belgium street-level detail",
        bounds=(2.4, 49.4, 6.5, 51.6),
        zoom=(8, 14),
        source="belgium-latest.osm.pbf",
        geofabrik_url=(
            "https://download.geofabrik.de/europe/belgium-latest.osm.pbf"
        ),
    ),
    "germany": Region(
        name="germany",
        description="Germany street-level detail (large -- multi-GB PBF)",
        bounds=(5.5, 47.2, 15.1, 55.1),
        zoom=(8, 13),
        source="germany-latest.osm.pbf",
        geofabrik_url=(
            "https://download.geofabrik.de/europe/germany-latest.osm.pbf"
        ),
    ),
}


def list_regions() -> str:
    """Pretty-printed list of presets for use in --help / error messages."""
    rows = []
    for r in REGIONS.values():
        b = ", ".join(f"{x:+.2f}" for x in r.bounds) if r.bounds else "world"
        rows.append(f"  {r.name:<14} z{r.zoom[0]:>2}-{r.zoom[1]:<2}  {b}\n"
                    f"                   {r.description}")
    return "\n".join(rows)


def get(name: str) -> Region:
    if name not in REGIONS:
        raise KeyError(
            f"unknown region '{name}'.\n"
            f"Available presets:\n{list_regions()}\n\n"
            f"To use a custom region: make_map.py custom <pbf> "
            f"--bounds W,S,E,N --zoom MIN,MAX"
        )
    return REGIONS[name]
