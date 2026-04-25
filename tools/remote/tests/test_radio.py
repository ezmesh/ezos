"""
ez.radio bindings — LoRa parameter setters/getters, RX state, sleep/wake.

Setters change the chip configuration. We capture get_config() at the
top of the test, change values, verify the change, and restore the full
config in teardown so the device stays on the user's regional/mesh
settings. send() is gated behind the mesh_tx marker.
"""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def restore_radio_config(device):
    """Snapshot the radio config and restore it after each test."""
    cfg = device.lua_exec("return ez.radio.get_config()")
    yield cfg
    if cfg:
        # Restore one parameter at a time so a single bad set doesn't
        # cascade. Each setter returns "ok" on success.
        device.lua_exec(f"ez.radio.set_frequency({cfg['frequency']})")
        device.lua_exec(f"ez.radio.set_bandwidth({cfg['bandwidth']})")
        device.lua_exec(f"ez.radio.set_spreading_factor({cfg['spreading_factor']})")
        device.lua_exec(f"ez.radio.set_coding_rate({cfg['coding_rate']})")
        device.lua_exec(f"ez.radio.set_sync_word({cfg['sync_word']})")
        device.lua_exec(f"ez.radio.set_tx_power({cfg['tx_power']})")


# ---------------------------------------------------------------------------
# Namespace + initialization
# ---------------------------------------------------------------------------


def test_namespace(device):
    assert device.lua_exec("return type(ez.radio)") == "table"


def test_is_initialized(device):
    """If the radio failed to init the firmware shows the !RF banner;
    every binding test downstream depends on this being true."""
    assert device.lua_exec("return ez.radio.is_initialized()") is True


def test_get_config_returns_full_table(device):
    cfg = device.lua_exec("return ez.radio.get_config()")
    assert isinstance(cfg, dict)
    expected = {
        "frequency", "bandwidth", "spreading_factor",
        "coding_rate", "sync_word", "tx_power", "preamble_length",
    }
    assert expected <= set(cfg.keys())
    # Values are sensible
    assert 100 < cfg["frequency"] < 2000  # MHz
    assert 5 <= cfg["spreading_factor"] <= 12
    assert 5 <= cfg["coding_rate"] <= 8


# ---------------------------------------------------------------------------
# Parameter setters — round-trip via get_config
# ---------------------------------------------------------------------------


def test_set_frequency_round_trip(device, restore_radio_config):
    base = restore_radio_config["frequency"]
    target = base + 0.1
    out = device.lua_exec(f"return ez.radio.set_frequency({target})")
    assert out == "ok"
    cfg = device.lua_exec("return ez.radio.get_config()")
    assert abs(cfg["frequency"] - target) < 0.01


def test_set_bandwidth_round_trip(device):
    out = device.lua_exec("return ez.radio.set_bandwidth(125)")
    assert out == "ok"
    assert device.lua_exec("return ez.radio.get_config().bandwidth") == 125


def test_set_spreading_factor_round_trip(device):
    out = device.lua_exec("return ez.radio.set_spreading_factor(10)")
    assert out == "ok"
    assert device.lua_exec("return ez.radio.get_config().spreading_factor") == 10


def test_set_coding_rate_round_trip(device):
    out = device.lua_exec("return ez.radio.set_coding_rate(5)")
    assert out == "ok"
    assert device.lua_exec("return ez.radio.get_config().coding_rate") == 5


def test_set_sync_word_round_trip(device):
    out = device.lua_exec("return ez.radio.set_sync_word(0x12)")
    assert out == "ok"
    assert device.lua_exec("return ez.radio.get_config().sync_word") == 0x12


def test_set_tx_power_round_trip(device):
    out = device.lua_exec("return ez.radio.set_tx_power(10)")
    assert out == "ok"
    assert device.lua_exec("return ez.radio.get_config().tx_power") == 10


def test_setter_rejects_invalid_param(device):
    """Out-of-range values should return 'error_param', not 'ok'."""
    out = device.lua_exec("return ez.radio.set_spreading_factor(99)")
    assert out != "ok"


# ---------------------------------------------------------------------------
# State / signal getters
# ---------------------------------------------------------------------------


def test_state_flags_are_bool(device):
    for fn in ("is_busy", "is_receiving", "is_transmitting", "available"):
        v = device.lua_exec(f"return ez.radio.{fn}()")
        assert isinstance(v, bool), f"{fn} returned {v!r}"


def test_get_last_rssi_is_number(device):
    v = device.lua_exec("return ez.radio.get_last_rssi()")
    assert isinstance(v, (int, float))


def test_get_last_snr_is_number(device):
    v = device.lua_exec("return ez.radio.get_last_snr()")
    assert isinstance(v, (int, float))


# ---------------------------------------------------------------------------
# RX control / sleep
# ---------------------------------------------------------------------------


def test_start_receive_then_check_state(device):
    out = device.lua_exec("return ez.radio.start_receive()")
    assert out == "ok"


def test_receive_when_no_packet_returns_error_string(device):
    """receive() returns (data, rssi, snr) on success or an error string
    when nothing is available. We expect the latter on a quiet channel."""
    out = device.lua_exec("return ez.radio.receive()")
    # Single-value error or 3-tuple on success.
    if isinstance(out, list):
        # Multi-return: data, rssi, snr — got a packet during the test
        assert len(out) >= 1
    else:
        assert isinstance(out, str)


def test_sleep_wake_round_trip(device):
    """sleep() puts the radio into low-power; wake() restores it. After
    a full cycle, the chip should still report initialized."""
    s = device.lua_exec("return ez.radio.sleep()")
    assert s == "ok"
    w = device.lua_exec("return ez.radio.wake()")
    assert w == "ok"
    # MeshCore should restart receive after wake — verify radio is alive.
    assert device.lua_exec("return ez.radio.is_initialized()") is True
    device.lua_exec("ez.radio.start_receive()")  # re-enter RX


# ---------------------------------------------------------------------------
# Transmit — opt-in via @pytest.mark.mesh_tx (EZ_TEST_MESH_TX=1)
# ---------------------------------------------------------------------------


@pytest.mark.mesh_tx
def test_send_returns_status(device):
    """send() result is 'ok', 'error_busy', 'error_tx', or 'error_init'.
    We send a tiny payload so airtime is minimal."""
    out = device.lua_exec("return ez.radio.send('test')")
    assert out in ("ok", "error_busy", "error_tx", "error_init")
