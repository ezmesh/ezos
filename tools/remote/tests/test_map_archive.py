"""
Map archive panic-bisect suite (issue #52).

The Map screen panics ~1.3s after opening /sd/maps/amsterdam.tdmap. Archive
corruption is already ruled out (regenerated copy reproduces). This suite
exercises the layers below the map screen — open, sync index read, async
tile reads, decode, repeated open/close, post-MSC-remount — so we can
identify which layer triggers the crash without needing to push the screen
or extract a coredump.

Each case follows the same pattern:
    1. Clear any prior coredump so we attribute it to *this* case.
    2. Drive the suspect Lua surface via device.lua_exec.
    3. Wait for AsyncIO in_flight to drain.
    4. Assert ez.debug.last_panic().coredump_present is false.
    5. If serial timed out, assume crash, reconnect, fail loudly.

The archive path is configurable via EZ_MAP_TEST_ARCHIVE so this can be
re-pointed at any future repro file. Default matches the issue.
"""

from __future__ import annotations

import os
import time

import pytest

ARCHIVE = os.environ.get("EZ_MAP_TEST_ARCHIVE", "/sd/maps/amsterdam.tdmap")
DRAIN_TIMEOUT_S = 8.0
DRAIN_POLL_S = 0.1


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _archive_present(device) -> bool:
    """Skip the suite if the archive isn't on the SD card. We don't bake an
    archive into the firmware — copy one to /sd/maps/ before running."""
    return bool(device.lua_exec(
        f"return (ez.storage.file_size('{ARCHIVE}') or 0) > 0"
    ))


def _clear_panic_state(device) -> None:
    """Reset coredump partition so any panic we observe afterwards is
    attributable to the case we just ran, not a leftover from a previous
    run or a different test."""
    device.lua_exec("return ez.system.clear_coredump()")


def _assert_no_panic(device, case: str) -> None:
    p = device.lua_exec("return ez.debug.last_panic()")
    assert isinstance(p, dict), f"{case}: last_panic() returned {p!r}"
    if p.get("coredump_present"):
        # The reset_reason on this build path tends to come back as
        # "unknown" right after a reflash; the coredump_present bit is
        # the authoritative crash indicator.
        pytest.fail(
            f"{case}: panic detected — coredump_size={p.get('coredump_size')}, "
            f"reset_reason={p.get('reset_reason')!r}"
        )


def _drain(device, timeout_s: float = DRAIN_TIMEOUT_S) -> dict:
    """Wait for the AsyncIO worker to finish all queued work. Returns the
    final stats snapshot. Fails the test if it doesn't drain in time —
    that itself is a useful signal (worker stuck = bug)."""
    deadline = time.monotonic() + timeout_s
    last = {}
    while time.monotonic() < deadline:
        last = device.lua_exec("return ez.debug.asyncio_stats()")
        if isinstance(last, dict) and last.get("in_flight", 1) == 0 \
                                  and last.get("queue_depth", 1) == 0:
            return last
        time.sleep(DRAIN_POLL_S)
    pytest.fail(f"AsyncIO did not drain within {timeout_s}s; last stats={last}")


def _safe_exec(device, code: str, case: str):
    """lua_exec wrapper that converts a serial timeout (almost always a
    crash) into a definitive 'panicked here' failure rather than a flaky
    timeout."""
    try:
        return device.lua_exec(code)
    except TimeoutError as e:
        pytest.fail(
            f"{case}: serial timeout — device likely panicked mid-call. {e}"
        )


@pytest.fixture(autouse=True)
def require_archive(device):
    if not _archive_present(device):
        pytest.skip(
            f"No archive at {ARCHIVE}. Set EZ_MAP_TEST_ARCHIVE or copy a "
            f".tdmap onto the SD card."
        )
    _clear_panic_state(device)
    yield
    # Don't clear after — leaving the coredump for inspection if a case
    # actually crashed lets the developer rerun with --pdb / extract it.


# ---------------------------------------------------------------------------
# Case 1: Open + close. Touches the synchronous header / metadata / index /
# label-block reads, but no tiles. If this panics, the bug is in open().
# ---------------------------------------------------------------------------


def test_01_open_close_archive(device):
    code = f"""
        local ma = require('services.map_archive')
        local arc, err = ma.open('{ARCHIVE}')
        if not arc then return {{ ok = false, err = err }} end
        local h = arc.header
        arc:close()
        return {{
            ok = true,
            version = h.version,
            tile_count = h.tile_count,
            label_count = h.label_count,
            min_zoom = h.min_zoom, max_zoom = h.max_zoom,
        }}
    """
    out = _safe_exec(device, code, "01_open_close")
    _drain(device)
    _assert_no_panic(device, "01_open_close")
    assert out["ok"], f"open failed: {out.get('err')}"
    assert out["version"] == 6
    assert out["tile_count"] > 0
    assert out["min_zoom"] <= out["max_zoom"]


# ---------------------------------------------------------------------------
# Case 2: Sequential synchronous tile reads. Bypasses get_tile's async path
# and reads each tile's compressed bytes directly via ez.storage.read_bytes,
# so we're testing the SD/read layer, not decompression. If this panics,
# the bug is in synchronous SD reads (likely SD lifecycle / FATFS).
# ---------------------------------------------------------------------------


def test_02_sequential_sync_reads(device):
    # Tile-index entry layout is 11 bytes (matches map_archive.lua):
    #   z: 1 byte
    #   x: 2 bytes (LE)
    #   y: 2 bytes (LE)
    #   offset: 4 bytes (LE)
    #   size: 2 bytes (LE)
    code = f"""
        local ma = require('services.map_archive')
        local arc, err = ma.open('{ARCHIVE}')
        if not arc then return {{ ok = false, err = err }} end
        local INDEX_ENTRY_SIZE = 11
        local idx = arc.idx_bytes
        local function u16(s, off)
            local b1, b2 = s:byte(off, off + 1)
            return b1 + b2 * 256
        end
        local function u32(s, off)
            local b1, b2, b3, b4 = s:byte(off, off + 3)
            return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        end
        local n = 0
        local total = 0
        for i = 0, arc.header.tile_count - 1 do
            local p = i * INDEX_ENTRY_SIZE + 1
            local off = u32(idx, p + 5)
            local sz  = u16(idx, p + 9)
            local data = ez.storage.read_bytes('{ARCHIVE}', off, sz)
            if data then
                n = n + 1
                total = total + #data
            end
        end
        arc:close()
        return {{ ok = true, n = n, total = total }}
    """
    out = _safe_exec(device, code, "02_sync_reads")
    _drain(device)
    _assert_no_panic(device, "02_sync_reads")
    assert out["ok"]
    assert out["n"] > 0


# ---------------------------------------------------------------------------
# Case 3: Decode every tile via the async path (matches what map_view does
# in production: get_tile -> async_read_bytes -> zlib decompress -> 3-bit
# unpack). Sequential — one tile's async resolves before the next starts.
# If this panics, decode is implicated.
# ---------------------------------------------------------------------------


def test_03_decode_every_tile_sequential(device):
    # See test_02 for the 11-byte index entry layout.
    code = f"""
        local ma = require('services.map_archive')
        local arc, err = ma.open('{ARCHIVE}')
        if not arc then return {{ ok = false, err = err }} end
        local INDEX_ENTRY_SIZE = 11
        local idx = arc.idx_bytes
        local function u16(s, off)
            local b1, b2 = s:byte(off, off + 1)
            return b1 + b2 * 256
        end
        local tiles = {{}}
        for i = 0, arc.header.tile_count - 1 do
            local p = i * INDEX_ENTRY_SIZE + 1
            tiles[#tiles + 1] = {{
                z = idx:byte(p),
                x = u16(idx, p + 1),
                y = u16(idx, p + 3),
            }}
        end
        _G._test_arc = arc
        _G._test_tiles = tiles
        return {{ ok = true, tile_count = #tiles }}
    """
    out = _safe_exec(device, code, "03_decode_setup")
    _assert_no_panic(device, "03_decode_setup")
    assert out["ok"]
    n = out["tile_count"]

    # Drive one tile per round-trip so async.task can resolve between calls.
    for i in range(n):
        step = f"""
            local arc = _G._test_arc
            local t = _G._test_tiles[{i + 1}]
            -- Returns "pending" the first time; the async coroutine fills
            -- the cache. We don't block on the result here -- the next
            -- iteration's drain handles it.
            local r = arc:get_tile(t.z, t.x, t.y)
            return type(r)
        """
        _safe_exec(device, step, f"03_decode[{i}]")
        _drain(device)
        _assert_no_panic(device, f"03_decode[{i}]")

    # Cleanup
    device.lua_exec("if _G._test_arc then _G._test_arc:close() end "
                    "_G._test_arc = nil _G._test_tiles = nil")


# ---------------------------------------------------------------------------
# Case 4: Parallel async tile reads. Mirrors what map_view does on a
# viewport change: fires N async reads back-to-back and lets them resolve
# concurrently. The Core 0 worker serialises them, but the queue + result
# loop is the most concurrency-sensitive part. Highest-likelihood panic
# trigger given the shared SPI bus.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("burst", [4, 8])
def test_04_parallel_tile_reads(device, burst):
    # See test_02 for the 11-byte index entry layout.
    code = f"""
        local ma = require('services.map_archive')
        local arc, err = ma.open('{ARCHIVE}')
        if not arc then return {{ ok = false, err = err }} end
        local INDEX_ENTRY_SIZE = 11
        local idx = arc.idx_bytes
        local function u16(s, off)
            local b1, b2 = s:byte(off, off + 1)
            return b1 + b2 * 256
        end
        local fired = 0
        for i = 0, math.min({burst}, arc.header.tile_count) - 1 do
            local p = i * INDEX_ENTRY_SIZE + 1
            local z = idx:byte(p)
            local x = u16(idx, p + 1)
            local y = u16(idx, p + 3)
            local r = arc:get_tile(z, x, y)
            -- "pending" means the async path was kicked; other values
            -- mean the tile already cached or absent (no async work).
            if r == "pending" then fired = fired + 1 end
        end
        _G._test_arc = arc
        return {{ ok = true, fired = fired }}
    """
    out = _safe_exec(device, code, f"04_parallel[{burst}]")
    _assert_no_panic(device, f"04_parallel[{burst}]")
    assert out["ok"]
    # Drain — this is where a race in the worker would surface.
    _drain(device)
    _assert_no_panic(device, f"04_parallel[{burst}]_after_drain")
    device.lua_exec("if _G._test_arc then _G._test_arc:close() end "
                    "_G._test_arc = nil")


# ---------------------------------------------------------------------------
# Case 5: Repeated open/close cycles. Catches SDManager lifecycle leaks,
# unbounded handle accumulation, and "open after close" half-torn-down
# state. 50 iterations is enough to surface anything systematic without
# making the test slow on a healthy device.
# ---------------------------------------------------------------------------


def test_05_repeated_open_close(device):
    code = f"""
        local ma = require('services.map_archive')
        local heap_before = ez.debug.heap()
        for i = 1, 50 do
            local arc, err = ma.open('{ARCHIVE}')
            if not arc then return {{ ok = false, iter = i, err = err }} end
            arc:close()
        end
        local heap_after = ez.debug.heap()
        return {{
            ok = true,
            free_before = heap_before.free,
            free_after = heap_after.free,
            psram_before = heap_before.free_psram,
            psram_after = heap_after.free_psram,
        }}
    """
    out = _safe_exec(device, code, "05_repeated_open_close")
    _drain(device)
    _assert_no_panic(device, "05_repeated_open_close")
    assert out["ok"], f"failed at iter {out.get('iter')}: {out.get('err')}"
    # Allow up to 16 KiB of drift (Lua GC fuzz, string interning).
    leak = out["free_before"] - out["free_after"]
    assert leak < 16 * 1024, (
        f"suspected heap leak across 50 open/close: free dropped "
        f"{leak} bytes ({out['free_before']} -> {out['free_after']})"
    )


# ---------------------------------------------------------------------------
# Case 6: Force an SD remount between opens. Exercises the openWithRetry
# recovery path that runs after USB MSC desyncs the FATFS wrapper. If this
# panics, the SDManager remount path is implicated — the fix in
# fix/sd-remount-after-msc didn't fully cover the case.
# ---------------------------------------------------------------------------


def test_06_open_after_remount(device):
    code = f"""
        local ma = require('services.map_archive')
        local arc1, e1 = ma.open('{ARCHIVE}')
        if not arc1 then return {{ ok = false, stage = 'first_open', err = e1 }} end
        arc1:close()

        local remounted = ez.debug.sd_remount()
        if not remounted then
            return {{ ok = false, stage = 'remount', err = 'remount returned false' }}
        end

        local arc2, e2 = ma.open('{ARCHIVE}')
        if not arc2 then return {{ ok = false, stage = 'second_open', err = e2 }} end
        local tc = arc2.header.tile_count
        arc2:close()
        return {{ ok = true, tile_count = tc }}
    """
    out = _safe_exec(device, code, "06_open_after_remount")
    _drain(device)
    _assert_no_panic(device, "06_open_after_remount")
    assert out["ok"], f"failed at {out.get('stage')}: {out.get('err')}"
    assert out["tile_count"] > 0
