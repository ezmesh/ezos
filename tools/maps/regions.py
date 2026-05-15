"""Region presets for one-command map generation.

A region preset bundles everything ``make_map.py`` needs: where to find
the source PMTiles, what geographic bounds to clip to, and which zoom
range to extract. Add a new entry here and ``make_map.py <name>`` Just
Works.

Bounds: (west, south, east, north) in degrees.
Zoom:   (min_zoom, max_zoom) — both inclusive.

The ``source`` field is either:
  * a Path to a local .pmtiles file (relative to repo root or absolute), or
  * a URL — make_map.py will download and cache it under tools/maps/data/.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple


@dataclass
class Region:
    name: str
    description: str
    bounds: Optional[Tuple[float, float, float, float]]  # None = entire source
    zoom: Tuple[int, int]
    source: str  # path or URL


# Default data directory for downloaded PMTiles. Keeps the working tree
# clean while letting expensive downloads survive ``make_map.py`` reruns.
DATA_DIR = Path(__file__).parent / "data"

# Source convention: every region references a PMTiles file by its filename
# under DATA_DIR. Add new regions by dropping the PMTiles in tools/maps/data/
# and pointing source at it. (Curating the catalogue of sources by URL is
# explicitly out of scope here — there's no single PMTiles registry, and the
# user is expected to bring their own.)

REGIONS = {
    "global": Region(
        name="global",
        description="Global low-detail overview",
        bounds=None,
        zoom=(0, 6),
        source="planet-z0-6.pmtiles",
    ),
    "europe": Region(
        name="europe",
        description="Western Europe to the Urals at regional detail",
        bounds=(-12.0, 34.0, 45.0, 72.0),
        zoom=(7, 10),
        source="europe.pmtiles",
    ),
    "netherlands": Region(
        name="netherlands",
        description="Netherlands + border at street-level detail",
        bounds=(3.2, 50.7, 7.3, 53.7),
        zoom=(11, 14),
        source="netherlands.pmtiles",
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
    """Look up a region by name. Raises KeyError with helpful message."""
    if name not in REGIONS:
        raise KeyError(
            f"unknown region '{name}'.\n"
            f"Available presets:\n{list_regions()}\n\n"
            f"To use a custom region: make_map.py custom <pmtiles> "
            f"--bounds W,S,E,N --zoom MIN,MAX"
        )
    return REGIONS[name]
