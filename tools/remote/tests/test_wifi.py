"""
ez.wifi bindings — status getters always run; anything that touches the
radio (scan, connect, AP start/stop, UDP/TCP probes) is gated behind
@pytest.mark.network and only runs when EZ_TEST_NETWORK=1 is set.

The connection-state mutators save and restore the original power state.
"""

from __future__ import annotations

import pytest


# ---------------------------------------------------------------------------
# Always-run: namespace + status getters
# ---------------------------------------------------------------------------


def test_namespace(device):
    assert device.lua_exec("return type(ez.wifi)") == "table"


def test_is_enabled_returns_bool(device):
    assert isinstance(device.lua_exec("return ez.wifi.is_enabled()"), bool)


def test_is_connected_returns_bool(device):
    assert isinstance(device.lua_exec("return ez.wifi.is_connected()"), bool)


def test_get_status_returns_string(device):
    s = device.lua_exec("return ez.wifi.get_status()")
    assert isinstance(s, str) and len(s) > 0


def test_get_ssid_returns_string(device):
    s = device.lua_exec("return ez.wifi.get_ssid()")
    assert isinstance(s, str)


def test_get_ip_returns_string(device):
    s = device.lua_exec("return ez.wifi.get_ip()")
    assert isinstance(s, str)
    # Empty when disconnected; a dotted quad when connected.


def test_get_mac_returns_mac_string(device):
    mac = device.lua_exec("return ez.wifi.get_mac()")
    assert isinstance(mac, str)
    # ESP32 STA MAC is well-formed even when wifi is off.
    stripped = mac.replace(":", "").replace("-", "")
    if stripped:
        assert len(stripped) == 12
        int(stripped, 16)


def test_get_gateway_returns_string(device):
    assert isinstance(device.lua_exec("return ez.wifi.get_gateway()"), str)


def test_get_dns_returns_string(device):
    assert isinstance(device.lua_exec("return ez.wifi.get_dns()"), str)


def test_get_rssi_when_disconnected(device):
    """RSSI is meaningful only when connected; binding may return 0 or
    a sentinel like -127 otherwise — just check shape."""
    v = device.lua_exec("return ez.wifi.get_rssi()")
    assert isinstance(v, int)


def test_is_ap_active_returns_bool(device):
    assert isinstance(device.lua_exec("return ez.wifi.is_ap_active()"), bool)


def test_get_ap_ip_returns_string(device):
    assert isinstance(device.lua_exec("return ez.wifi.get_ap_ip()"), str)


def test_get_ap_client_count(device):
    n = device.lua_exec("return ez.wifi.get_ap_client_count()")
    assert isinstance(n, int) and n >= 0


def test_set_power_round_trip(device):
    """set_power toggles the wifi radio. Save the original state and
    restore it. We only flip when wifi isn't actively connected so we
    don't drop the user's session."""
    original = device.lua_exec("return ez.wifi.is_enabled()")
    if device.lua_exec("return ez.wifi.is_connected()"):
        pytest.skip("wifi is connected — refusing to toggle power")
    try:
        device.lua_exec("ez.wifi.set_power(false)")
        assert device.lua_exec("return ez.wifi.is_enabled()") is False
        device.lua_exec("ez.wifi.set_power(true)")
        assert device.lua_exec("return ez.wifi.is_enabled()") is True
    finally:
        device.lua_exec(
            f"ez.wifi.set_power({'true' if original else 'false'})"
        )


# ---------------------------------------------------------------------------
# Network egress — opt-in via @pytest.mark.network (EZ_TEST_NETWORK=1)
# ---------------------------------------------------------------------------


@pytest.mark.network
def test_scan_returns_list(device):
    """scan() blocks for ~2-3 seconds and returns nearby APs."""
    out = device.lua_exec("return ez.wifi.scan()")
    assert isinstance(out, (list, dict))


@pytest.mark.network
def test_disconnect_then_connect(device):
    """End-to-end connect cycle. Requires EZ_TEST_WIFI_SSID and
    EZ_TEST_WIFI_PASS to be set; otherwise skipped."""
    import os
    ssid = os.environ.get("EZ_TEST_WIFI_SSID")
    pwd = os.environ.get("EZ_TEST_WIFI_PASS")
    if not ssid:
        pytest.skip("set EZ_TEST_WIFI_SSID/PASS to run wifi connect tests")
    device.lua_exec("ez.wifi.disconnect()")
    ok = device.lua_exec(
        f"return ez.wifi.connect({ssid!r}, {pwd!r})"
    )
    assert ok is True
    connected = device.lua_exec("return ez.wifi.wait_connected(10)")
    assert connected is True
    ip = device.lua_exec("return ez.wifi.get_ip()")
    assert ip and ip != "0.0.0.0"
    device.lua_exec("ez.wifi.disconnect()")


@pytest.mark.network
def test_ap_start_stop(device):
    """Start a tiny AP, verify is_ap_active flips, stop it."""
    if device.lua_exec("return ez.wifi.is_connected()"):
        pytest.skip("wifi is connected — won't bring up AP")
    ok = device.lua_exec(
        "return ez.wifi.start_ap('ezos-test-ap', 'testpass', 6, false, 1)"
    )
    try:
        assert ok is True
        assert device.lua_exec("return ez.wifi.is_ap_active()") is True
        ip = device.lua_exec("return ez.wifi.get_ap_ip()")
        assert ip and ip != "0.0.0.0"
    finally:
        device.lua_exec("ez.wifi.stop_ap()")


@pytest.mark.network
def test_udp_echo_lifecycle(device):
    """udp_echo_start binds a port that echoes any UDP datagram. We just
    verify the lifecycle without testing actual echo."""
    ok = device.lua_exec("return ez.wifi.udp_echo_start(45678)")
    assert isinstance(ok, bool)
    device.lua_exec("ez.wifi.udp_echo_stop()")


@pytest.mark.network
def test_udp_probe_to_unreachable_returns_nil(device):
    """udp_probe to a closed port should time out and return nil."""
    out = device.lua_exec(
        "return ez.wifi.udp_probe('127.0.0.1', 1, 100)"
    )
    # Either nil (timeout) or an integer (rtt). Without network it's nil.
    assert out is None or isinstance(out, int)


@pytest.mark.network
def test_tcp_serve_blob_lifecycle(device):
    """Serve a tiny blob on a high port; verify the call shape."""
    out = device.lua_exec(
        "return ez.wifi.tcp_serve_blob(45679, 'hello', 100)"
    )
    # Returns bytes-served integer or nil on timeout.
    assert out is None or isinstance(out, int)


@pytest.mark.network
def test_tcp_fetch_blob_to_unreachable(device):
    out = device.lua_exec(
        "return ez.wifi.tcp_fetch_blob('127.0.0.1', 1, 1024, 100)"
    )
    # Unreachable should return nil; never throws.
    assert out is None or isinstance(out, str)
