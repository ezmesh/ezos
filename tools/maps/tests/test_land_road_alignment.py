"""
Regression test for the land/road coordinate desync bug (commit 48ad897).

The bug: `render_vector_tile` used Y-down screen coords for MVT geometry but
Y-up geographic coords for the land mask. On coastal tiles this shifted roads
away from land and painted land where water should have been. The fixture is a
Dutch North Sea coast tile where a Y-flip regression would visibly misalign the
drawn roads from the underlying land mask.

How to re-generate the fixture (only do this when the renderer intentionally
changes output):

    python -m pytest tools/maps/tests/test_land_road_alignment.py --regen

which rewrites `coastal_z11_1051_667.npy` with the current renderer's output.
"""

from pathlib import Path
import sys

import numpy as np
import pytest

FIXTURES = Path(__file__).parent / "fixtures"
MVT_PATH = FIXTURES / "coastal_z11_1051_667.mvt"
GOLDEN_PATH = FIXTURES / "coastal_z11_1051_667.npy"

TILE_Z, TILE_X, TILE_Y = 11, 1051, 667


@pytest.fixture(scope="module")
def render():
    # Import lazily so collection doesn't fail if the deps aren't installed.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from pmtiles_to_tdmap import render_vector_tile
    from land_mask import get_land_mask
    return render_vector_tile, get_land_mask()


def test_coastal_tile_matches_golden(render, request):
    render_fn, land_mask = render
    mvt_bytes = MVT_PATH.read_bytes()

    img = render_fn(mvt_bytes, TILE_Z, TILE_X, TILE_Y, land_mask)
    actual = np.array(img, dtype=np.uint8)

    if request.config.getoption("--regen", default=False):
        np.save(GOLDEN_PATH, actual)
        pytest.skip("regenerated golden")

    expected = np.load(GOLDEN_PATH)

    assert actual.shape == expected.shape, (
        f"tile shape changed: got {actual.shape}, expected {expected.shape}")

    # Allow a tiny amount of drift for unrelated refactors (antialiasing, etc.)
    # while still catching the specific bug this guards against. The original
    # Y-flip regression shifted ~30% of pixels — well above this threshold.
    mismatch_fraction = float(np.mean(actual != expected))
    assert mismatch_fraction < 0.005, (
        f"tile output drifted from golden by {mismatch_fraction:.2%} of pixels — "
        f"if this change is intentional, regenerate with --regen")
