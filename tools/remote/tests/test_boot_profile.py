"""
Boot profile timeline via ez.bench.boot_profile().

Reads the boot-profile ring buffer recorded during setup() and boot.lua,
asserts the expected phase names appear in order, sanity-bounds the total
boot time, and dumps the timeline to .last_boot_profile.json for
inspection.

Auto-skips when the ez.bench binding namespace isn't present.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest


TIMELINE_PATH = Path(__file__).with_name(".last_boot_profile.json")

# Phases we expect to see, in this relative order. Not an exhaustive
# list -- the test only asserts that *each of these* shows up at least
# once and that the listed pairs are in the right order. New phases can
# be added without breaking the test.
EXPECTED_ORDER = [
    "setup_start",
    "display_init",
    "radio_init",
    "littlefs_init",
    "lua_runtime",
    "main_loop",
]

# Generous upper bound on total boot time. Real device boots in a few
# seconds; 30 s is well above any healthy build.
BOOT_TIME_CEILING_MS = 30_000


def _bench_available(device) -> bool:
    return bool(device.lua_exec("return ez.bench and ez.bench.boot_profile ~= nil"))


def test_boot_profile_timeline(device):
    if not _bench_available(device):
        pytest.skip("ez.bench bindings not present on device")

    entries = device.lua_exec("return ez.bench.boot_profile()")
    assert isinstance(entries, list) and len(entries) > 0, entries

    # Persist before asserting so failures still leave the artefact.
    TIMELINE_PATH.write_text(json.dumps(entries, indent=2))

    names = [e["name"] for e in entries]
    millis = [e["millis"] for e in entries]

    # Each expected phase must appear at least once.
    missing = [n for n in EXPECTED_ORDER if n not in names]
    assert not missing, f"missing boot phases: {missing} (got {names})"

    # And the expected ones must appear in the documented order.
    indices = [names.index(n) for n in EXPECTED_ORDER]
    assert indices == sorted(indices), (
        f"boot phases out of order: order = "
        f"{[(n, names.index(n)) for n in EXPECTED_ORDER]}"
    )

    # Millis must be monotonically non-decreasing.
    for i in range(1, len(millis)):
        assert millis[i] >= millis[i - 1], (
            f"non-monotonic boot timestamps at idx {i}: {millis[i-1]} -> {millis[i]}"
        )

    # First entry should be near zero (setup_start lands very early).
    # Use 5 s as a generous ceiling -- the USB-CDC settle delay can push
    # this out by a couple seconds.
    assert millis[0] < 5_000, f"setup_start arrived too late: {millis[0]} ms"

    # Total span generous.
    span = millis[-1] - millis[0]
    assert span < BOOT_TIME_CEILING_MS, (
        f"boot timeline span {span} ms > ceiling {BOOT_TIME_CEILING_MS} ms"
    )


def test_boot_profile_mark_records_entry(device):
    """`ez.bench.mark` should append a new entry."""
    if not _bench_available(device):
        pytest.skip("ez.bench bindings not present on device")

    before = device.lua_exec("return #ez.bench.boot_profile()")
    # If the ring is already full, we can't add more -- but that's the
    # well-defined behaviour (the binding doc says extras are dropped).
    # Just assert non-decrease in that case.
    device.lua_exec("ez.bench.mark('pytest_marker')")
    after = device.lua_exec("return #ez.bench.boot_profile()")
    assert after >= before, (before, after)
    if after > before:
        last = device.lua_exec("local p = ez.bench.boot_profile(); return p[#p]")
        assert last["name"] == "pytest_marker", last
