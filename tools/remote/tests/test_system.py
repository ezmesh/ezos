"""
ez.system bindings — clocks, memory, sleep/restart, timers, prefs.

We exercise every safe binding. Restart/deep_sleep/light_sleep/reload_scripts
are intentionally not invoked: they'd kill the test session. set_time and
set_timezone save the previous value and restore it.
"""

from __future__ import annotations

import time

import pytest


# ---------------------------------------------------------------------------
# Counters and clocks
# ---------------------------------------------------------------------------


def test_namespace(device):
    assert device.lua_exec("return type(ez.system)") == "table"


def test_millis_monotonic(device):
    a = device.lua_exec("return ez.system.millis()")
    time.sleep(0.05)
    b = device.lua_exec("return ez.system.millis()")
    assert isinstance(a, int) and isinstance(b, int)
    assert b >= a


def test_uptime_positive(device):
    u = device.lua_exec("return ez.system.uptime()")
    assert isinstance(u, int) and u > 0


def test_delay_blocks_about_50ms(device):
    code = """
        local t0 = ez.system.millis()
        ez.system.delay(50)
        return ez.system.millis() - t0
    """
    elapsed = device.lua_exec(code)
    assert 40 <= elapsed <= 200, f"delay(50) produced {elapsed} ms"


def test_yield_returns_promptly(device):
    code = """
        local t0 = ez.system.millis()
        ez.system.yield(10)
        return ez.system.millis() - t0
    """
    elapsed = device.lua_exec(code)
    assert elapsed < 200


# ---------------------------------------------------------------------------
# Time / timezone
# ---------------------------------------------------------------------------


def test_get_time_shape(device):
    t = device.lua_exec("return ez.system.get_time()")
    assert isinstance(t, dict)
    assert {"year", "month", "day", "hour", "minute", "second"} <= set(t.keys())


def test_get_time_unix(device):
    t = device.lua_exec("return ez.system.get_time_unix()")
    assert isinstance(t, int) and t >= 0


def test_set_time_unix_round_trip(device):
    """Save current time, set to a known value, restore."""
    original = device.lua_exec("return ez.system.get_time_unix()")
    target = 1_700_000_000  # 2023-11-14
    try:
        ok = device.lua_exec(f"return ez.system.set_time_unix({target})")
        assert ok is True
        t = device.lua_exec("return ez.system.get_time_unix()")
        # Some drift between set and get is expected; allow ±5s.
        assert abs(t - target) < 5
    finally:
        # Restore. The original may be slightly stale by now; use it as-is.
        device.lua_exec(f"ez.system.set_time_unix({original + 2})")


def test_set_time_field_round_trip(device):
    original = device.lua_exec("return ez.system.get_time_unix()")
    try:
        ok = device.lua_exec("return ez.system.set_time(2024, 6, 1, 12, 0, 0)")
        assert ok is True
        t = device.lua_exec("return ez.system.get_time()")
        assert t["year"] == 2024 and t["month"] == 6 and t["day"] == 1
    finally:
        device.lua_exec(f"ez.system.set_time_unix({original + 5})")


def test_timezone_round_trip(device):
    """Save current timezone, set Europe/Amsterdam, restore. Returns
    integer offset; just check the call shape."""
    original = device.lua_exec("return ez.system.get_timezone()")
    try:
        ok = device.lua_exec("return ez.system.set_timezone('CET-1CEST,M3.5.0,M10.5.0/3')")
        assert ok is True
        tz = device.lua_exec("return ez.system.get_timezone()")
        assert isinstance(tz, int)
    finally:
        # Restore by setting the offset string back is awkward (we only have
        # the integer). Reset to UTC so the device is in a known good state.
        device.lua_exec("ez.system.set_timezone('UTC0')")


# ---------------------------------------------------------------------------
# Memory
# ---------------------------------------------------------------------------


def test_get_free_heap(device):
    n = device.lua_exec("return ez.system.get_free_heap()")
    assert isinstance(n, int) and n > 0


def test_get_total_heap(device):
    n = device.lua_exec("return ez.system.get_total_heap()")
    assert isinstance(n, int) and n > 0


def test_get_free_psram(device):
    n = device.lua_exec("return ez.system.get_free_psram()")
    assert isinstance(n, int) and n >= 0


def test_get_total_psram(device):
    n = device.lua_exec("return ez.system.get_total_psram()")
    assert isinstance(n, int) and n > 0


def test_get_lua_memory(device):
    n = device.lua_exec("return ez.system.get_lua_memory()")
    assert isinstance(n, (int, float)) and n > 0


def test_is_low_memory(device):
    assert isinstance(device.lua_exec("return ez.system.is_low_memory()"), bool)


def test_gc_runs_without_error(device):
    device.lua_exec("ez.system.gc()")
    n = device.lua_exec("return ez.system.gc_step(8)")
    assert isinstance(n, int)


# ---------------------------------------------------------------------------
# Hardware identity
# ---------------------------------------------------------------------------


def test_chip_model(device):
    s = device.lua_exec("return ez.system.chip_model()")
    assert isinstance(s, str) and "ESP32" in s.upper()


def test_cpu_freq(device):
    f = device.lua_exec("return ez.system.cpu_freq()")
    assert isinstance(f, int) and f >= 80


def test_get_mac_address(device):
    mac = device.lua_exec("return ez.system.get_mac_address()")
    assert isinstance(mac, str)
    # Either bare hex (12 chars) or colon-delimited (17). Accept both.
    stripped = mac.replace(":", "").replace("-", "")
    assert len(stripped) == 12
    int(stripped, 16)  # raises if not hex


def test_get_firmware_info(device):
    info = device.lua_exec("return ez.system.get_firmware_info()")
    assert isinstance(info, dict)
    # Reports flash partition layout — exposed for the About / firmware
    # screens. The C++ binding picks these field names; tests track them
    # so a renamed field surfaces the breaking change.
    assert {
        "free_bytes", "partition_label", "partition_size",
        "app_size", "flash_chip_size",
    } <= set(info.keys())


def test_get_wake_reason(device):
    s = device.lua_exec("return ez.system.get_wake_reason()")
    assert isinstance(s, str)


# ---------------------------------------------------------------------------
# Battery
# ---------------------------------------------------------------------------


def test_get_battery_percent(device):
    p = device.lua_exec("return ez.system.get_battery_percent()")
    assert isinstance(p, int)
    assert 0 <= p <= 100 or p == -1  # -1 if no battery


def test_get_battery_voltage(device):
    v = device.lua_exec("return ez.system.get_battery_voltage()")
    assert isinstance(v, (int, float))


# ---------------------------------------------------------------------------
# USB MSC / SD probes (read-only checks — don't toggle MSC)
# ---------------------------------------------------------------------------


def test_is_usb_msc_active(device):
    assert isinstance(device.lua_exec("return ez.system.is_usb_msc_active()"), bool)


def test_is_sd_available(device):
    assert isinstance(device.lua_exec("return ez.system.is_sd_available()"), bool)


# ---------------------------------------------------------------------------
# Loop / errors / log
# ---------------------------------------------------------------------------


def test_loop_delay_round_trip(device):
    original = device.lua_exec("return ez.system.get_loop_delay()")
    try:
        device.lua_exec("ez.system.set_loop_delay(20)")
        assert device.lua_exec("return ez.system.get_loop_delay()") == 20
    finally:
        device.lua_exec(f"ez.system.set_loop_delay({original})")


def test_get_last_error(device):
    """Returns nil when no error has been recorded; a string otherwise."""
    s = device.lua_exec("return ez.system.get_last_error()")
    assert s is None or isinstance(s, str)


def test_ez_log_does_not_throw(device):
    """Logger is exposed as the ez.log global, not under ez.system."""
    device.lua_exec("ez.log('test_system: hello from harness')")


# ---------------------------------------------------------------------------
# Timers
# ---------------------------------------------------------------------------


def test_set_timer_fires_once(device):
    """Schedule a one-shot 50 ms timer and observe the side effect."""
    code = """
        _G._test_timer_fired = false
        local id = ez.system.set_timer(50, function()
            _G._test_timer_fired = true
        end)
        return id
    """
    timer_id = device.lua_exec(code)
    assert isinstance(timer_id, int) and timer_id > 0
    time.sleep(0.25)
    fired = device.lua_exec("return _G._test_timer_fired")
    assert fired is True
    device.lua_exec("_G._test_timer_fired = nil")


def test_set_interval_fires_repeatedly_then_cancel(device):
    code = """
        _G._test_interval_count = 0
        local id = ez.system.set_interval(50, function()
            _G._test_interval_count = _G._test_interval_count + 1
        end)
        return id
    """
    timer_id = device.lua_exec(code)
    assert isinstance(timer_id, int) and timer_id > 0
    try:
        time.sleep(0.3)
        n = device.lua_exec("return _G._test_interval_count")
        assert isinstance(n, int) and n >= 2, f"interval fired only {n} time(s)"
    finally:
        device.lua_exec(f"ez.system.cancel_timer({timer_id})")
        device.lua_exec("_G._test_interval_count = nil")


def test_cancel_unknown_timer_is_safe(device):
    """cancel_timer with a never-registered id must not crash."""
    device.lua_exec("ez.system.cancel_timer(999999)")


# ---------------------------------------------------------------------------
# Bindings deliberately not exercised
# ---------------------------------------------------------------------------
# restart, deep_sleep, light_sleep, reload_scripts, start_usb_msc, stop_usb_msc
# would terminate or destabilise the test session. They're left untested by
# design; their wiring is exercised manually during release smoke checks.
