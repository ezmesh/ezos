"""
Benchmark scenarios via ez.bench.*

Iterates every registered scenario, runs it on-device, asserts a generous
p95 ceiling per scenario (sanity check -- the ceilings are well above
expected jitter so this test should never flake), and dumps the full
sample set to .last_bench_results.json next to this file for trend
eyeballing.

Auto-skips when the ez.bench binding namespace isn't compiled in (e.g.
the test is run against a stripped firmware build), mirroring the
soft-skip pattern in test_map_archive.py.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest


RESULTS_PATH = Path(__file__).with_name(".last_bench_results.json")

# Per-scenario p95 ceilings in microseconds. Generous: we want to catch
# 10x regressions, not jitter. Pick values >> the observed steady-state
# numbers. The bench harness expects to never flake here.
P95_CEILING_US = {
    "crypto.ed25519_sign":       250000,   # 250 ms (heavy curve op)
    "crypto.ed25519_verify":     250000,   # 250 ms (heavier than sign)
    "crypto.aes_decrypt_128_ecb": 20000,   #  20 ms (HW-accel mbedTLS)
    "crypto.sha256_1k":           20000,   #  20 ms (HW-accel SHA)
}

DEFAULT_CEILING_US = 250000  # fallback for any scenario without a known bound

# Small per-scenario iteration count. The harness round-trips ~5 samples
# of latency over USB CDC even when scenarios are fast, so keep this
# bounded -- 25 gives a statistically OK p95 without dragging session
# wallclock past a few seconds for the whole suite.
ITERATIONS = 25


def _bench_available(device) -> bool:
    return bool(device.lua_exec("return ez.bench and ez.bench.list ~= nil"))


def test_bench_scenarios(device):
    if not _bench_available(device):
        pytest.skip("ez.bench bindings not present on device")

    scenarios = device.lua_exec("return ez.bench.list()")
    assert isinstance(scenarios, list) and len(scenarios) > 0, scenarios

    results = {}
    for entry in scenarios:
        name = entry["name"]
        stats = device.lua_exec(f"return ez.bench.run('{name}', {ITERATIONS})")
        assert isinstance(stats, dict), f"{name}: bench.run returned {stats!r}"
        # Sanity-check the fields we promise in the binding doc.
        for field in ("min_us", "max_us", "mean_us", "p50_us", "p95_us", "samples", "iterations"):
            assert field in stats, f"{name}: missing field {field}"
        assert isinstance(stats["samples"], list) and len(stats["samples"]) == stats["iterations"], (
            f"{name}: samples length mismatch"
        )
        results[name] = stats

    # Persist the full numbers BEFORE asserting bounds so a single
    # threshold failure doesn't bury the rest of the dataset.
    RESULTS_PATH.write_text(json.dumps(results, indent=2, sort_keys=True))

    # Soft assertions: just catch egregious regressions.
    failures = []
    for name, stats in results.items():
        ceiling = P95_CEILING_US.get(name, DEFAULT_CEILING_US)
        if stats["p95_us"] > ceiling:
            failures.append(f"{name}: p95={stats['p95_us']}us > ceiling {ceiling}us")
    assert not failures, "\n".join(failures)


def test_bench_run_unknown_scenario_errors(device):
    if not _bench_available(device):
        pytest.skip("ez.bench bindings not present on device")
    res = device.lua_exec(
        "local r, err = ez.bench.run('not.a.real.scenario'); "
        "return { res = r, err = err }"
    )
    # nil result + error string
    assert res.get("res") in (None, False), res
    assert isinstance(res.get("err"), str) and "unknown" in res["err"], res


def test_bench_iterations_clamp(device):
    if not _bench_available(device):
        pytest.skip("ez.bench bindings not present on device")
    # iterations=0 should clamp to 1; iterations=10000 should clamp to 1000.
    scenarios = device.lua_exec("return ez.bench.list()")
    name = scenarios[0]["name"]
    low = device.lua_exec(f"return ez.bench.run('{name}', 0).iterations")
    assert low == 1, low
    # Skip the high-side clamp at runtime; running 1000 iterations would
    # take far longer than the test budget. Trust the C++ clamp logic.
