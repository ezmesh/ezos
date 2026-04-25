"""
GPS binding tests. The binding surface is pure pull (no Lua callbacks
stored in C++), so these only verify shape and types — they don't depend
on the device having a fix.

If the GPS module isn't initialized on the device (e.g. user pref turned
it off), every getter returns nil; tests that rely on shape skip in that
case rather than fail.
"""

from __future__ import annotations

import pytest


@pytest.fixture(scope="module")
def gps_initialized(device) -> bool:
    """True when ez.gps reports an initialized module."""
    return bool(device.lua_exec("return ez.gps.is_valid() ~= nil and true or false"))


def _require_init(device):
    inited = device.lua_exec(
        "local s = ez.gps.get_stats(); return s and s.initialized or false"
    )
    if not inited:
        pytest.skip("GPS module not initialized on device (check user pref)")


def test_gps_namespace_exists(device):
    assert device.lua_exec("return type(ez.gps)") == "table"


def test_is_valid_is_boolean(device):
    v = device.lua_exec("return ez.gps.is_valid()")
    assert isinstance(v, bool)


def test_get_location_shape(device):
    _require_init(device)
    loc = device.lua_exec("return ez.gps.get_location()")
    assert isinstance(loc, dict)
    assert set(loc.keys()) >= {"lat", "lon", "alt", "valid", "age"}
    assert isinstance(loc["valid"], bool)
    assert isinstance(loc["age"], (int, float))


def test_get_time_shape(device):
    _require_init(device)
    t = device.lua_exec("return ez.gps.get_time()")
    assert isinstance(t, dict)
    assert set(t.keys()) >= {"hour", "min", "sec", "year", "month", "day", "valid", "synced"}
    assert isinstance(t["valid"], bool)
    assert isinstance(t["synced"], bool)


def test_get_movement_shape(device):
    _require_init(device)
    mov = device.lua_exec("return ez.gps.get_movement()")
    assert isinstance(mov, dict)
    assert set(mov.keys()) >= {"speed", "course"}
    assert isinstance(mov["speed"], (int, float))
    assert isinstance(mov["course"], (int, float))


def test_get_satellites_shape(device):
    _require_init(device)
    sat = device.lua_exec("return ez.gps.get_satellites()")
    assert isinstance(sat, dict)
    assert set(sat.keys()) >= {"count", "hdop"}
    assert isinstance(sat["count"], int)
    assert sat["count"] >= 0


def test_get_stats_shape(device):
    _require_init(device)
    s = device.lua_exec("return ez.gps.get_stats()")
    assert isinstance(s, dict)
    expected = {
        "chars", "passed", "sentences", "failed",
        "sats_in_view", "fix_mode", "fix_quality",
        "talkers", "initialized",
    }
    assert expected <= set(s.keys())
    assert isinstance(s["initialized"], bool)
    assert isinstance(s["talkers"], str)
    # last_byte_age is int or nil — accept either
    assert "last_byte_age" in s


def test_reset_stats_clears_counters(device):
    _require_init(device)
    device.lua_exec("ez.gps.reset_stats()")
    s = device.lua_exec("return ez.gps.get_stats()")
    # Right after reset, counters should be zero or near-zero. Allow a tiny
    # delta because NMEA bytes may arrive between the reset call and the
    # stats query.
    assert s["chars"] >= 0 and s["chars"] < 1024
    assert s["passed"] >= 0 and s["passed"] < 16
    assert s["failed"] >= 0 and s["failed"] < 16


def test_get_signal_enabled_returns_bool_or_nil(device):
    """
    get_signal_enabled(key_id) queries a UBX CFG-SIGNAL-* key on the chip
    and returns boolean or nil (timeout). Read-only — we never flip the
    receiver's signal mix. 0x1031001F = enable-GPS key (always present
    on u-blox M10).
    """
    _require_init(device)
    v = device.lua_exec("return ez.gps.get_signal_enabled(0x1031001F, 1500)")
    assert v is None or isinstance(v, bool)


def test_get_chip_info_returns_string_or_nil(device):
    info = device.lua_exec("return ez.gps.get_chip_info()")
    assert info is None or isinstance(info, str)


def test_get_last_info_sentence_returns_string_or_nil(device):
    s = device.lua_exec("return ez.gps.get_last_info_sentence()")
    assert s is None or isinstance(s, str)
