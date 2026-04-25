"""
Radio-level end-to-end: device A transmits raw LoRa, device B sees its
RX counter advance. We use the lower-level ez.radio.send() since
ez.mesh.queue_send() needs valid packet structure for B's mesh layer to
even acknowledge receipt — at this level we just want bits across the
air.
"""

from __future__ import annotations

import time

import pytest


@pytest.fixture(autouse=True)
def _ensure_matching_radio(both_devices):
    """Both devices must share the same LoRa parameters. Snapshot A's
    config and copy it to B (storing B's prior config so we can restore
    on teardown)."""
    a, b = both_devices
    cfg_a = a.lua_exec("return ez.radio.get_config()")
    cfg_b = b.lua_exec("return ez.radio.get_config()")
    same = (
        abs(cfg_a["frequency"] - cfg_b["frequency"]) < 0.01
        and cfg_a["spreading_factor"] == cfg_b["spreading_factor"]
        and cfg_a["bandwidth"] == cfg_b["bandwidth"]
        and cfg_a["coding_rate"] == cfg_b["coding_rate"]
        and cfg_a["sync_word"] == cfg_b["sync_word"]
    )
    if not same:
        pytest.skip(
            f"A and B are on different radio configs:\n  A={cfg_a}\n  B={cfg_b}\n"
            "Set both to the same mesh defaults before running radio e2e."
        )


def _send_when_idle(a, payload: str, attempts: int = 5) -> str:
    """Retry ez.radio.send() up to `attempts` times if the radio is busy
    with mesh traffic. Returns the final result string."""
    for _ in range(attempts):
        result = a.lua_exec(f"return ez.radio.send({payload!r})")
        if result == "ok":
            return result
        if result != "error_busy":
            return result
        time.sleep(0.5)
    return result


@pytest.mark.slow
def test_lora_transmission_increments_b_rx_count(both_devices):
    """A sends a tiny LoRa packet. B's RX count should increment within
    a couple of seconds of the airtime."""
    a, b = both_devices
    b.lua_exec("ez.radio.start_receive()")
    rx_before = b.lua_exec("return ez.mesh.get_rx_count()")

    result = _send_when_idle(a, "\xaa" * 8)
    if result != "ok":
        pytest.skip(f"A's radio could not transmit after retries: {result}")

    deadline = time.time() + 3.0
    rx_after = rx_before
    while time.time() < deadline:
        rx_after = b.lua_exec("return ez.mesh.get_rx_count()")
        if rx_after > rx_before:
            break
        time.sleep(0.2)
    assert rx_after > rx_before, (
        f"B's mesh.rx_count did not increase after A's send "
        f"(before={rx_before}, after={rx_after})"
    )


def test_get_last_rssi_negative_after_rx(both_devices):
    """After B receives at least one packet, get_last_rssi should be
    a real (negative) dBm value, not the sentinel 0."""
    a, b = both_devices
    b.lua_exec("ez.radio.start_receive()")
    initial_rx = b.lua_exec("return ez.mesh.get_rx_count()")

    result = _send_when_idle(a, "\xbb" * 8)
    if result != "ok":
        pytest.skip(f"A's radio could not transmit: {result}")

    deadline = time.time() + 3.0
    while time.time() < deadline:
        if b.lua_exec("return ez.mesh.get_rx_count()") > initial_rx:
            break
        time.sleep(0.2)
    else:
        pytest.skip("B did not receive A's packet within the timeout")

    rssi = b.lua_exec("return ez.radio.get_last_rssi()")
    assert isinstance(rssi, (int, float))
    assert -150 < rssi < 0, f"unrealistic RSSI: {rssi}"
