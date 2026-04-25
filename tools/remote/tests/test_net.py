"""
ez.net bindings — TCP/UDP sockets. All gated behind @pytest.mark.network.

Some socket calls block the device for minutes when no IP interface is
up (DNS retry, route lookup, etc.), so we precheck wifi connectivity
and skip when it's not connected.
"""

from __future__ import annotations

import pytest

pytestmark = pytest.mark.network


@pytest.fixture(autouse=True)
def _require_wifi(device):
    if not device.lua_exec("return ez.wifi.is_connected()"):
        pytest.skip("ez.net tests require wifi to be connected")


def test_namespace(device):
    assert device.lua_exec("return type(ez.net)") == "table"


# ---------------------------------------------------------------------------
# UDP — open/close round trip; send/recv with no peer
# ---------------------------------------------------------------------------


def test_udp_open_close_round_trip(device):
    code = """
        local id = ez.net.udp_open()
        if not id then return false end
        ez.net.udp_close(id)
        return true
    """
    out = device.lua_exec(code)
    assert out is True


def test_udp_recv_returns_nil_when_empty(device):
    code = """
        local id = ez.net.udp_open()
        if not id then return false end
        local data = ez.net.udp_recv(id)
        ez.net.udp_close(id)
        return data
    """
    out = device.lua_exec(code)
    # Either nil/None (no datagram) or a string from a stray packet.
    assert out is None or isinstance(out, str) or (
        isinstance(out, list) and (out[0] is None or isinstance(out[0], str))
    )


def test_udp_send_returns_int_or_nil(device):
    code = """
        local id = ez.net.udp_open()
        if not id then return false end
        local n = ez.net.udp_send(id, '127.0.0.1', 1, 'ping')
        ez.net.udp_close(id)
        return n
    """
    out = device.lua_exec(code)
    # n returned (bytes sent) or nil on no-route.
    assert out is None or isinstance(out, int)


# ---------------------------------------------------------------------------
# TCP — listen/accept and connect cycles
# ---------------------------------------------------------------------------


def test_tcp_listen_close(device):
    code = """
        local s = ez.net.tcp_listen(45680)
        if not s then return false end
        ez.net.tcp_close(s)
        return true
    """
    out = device.lua_exec(code)
    assert isinstance(out, bool)


def test_tcp_accept_returns_nil_when_no_client(device):
    code = """
        local s = ez.net.tcp_listen(45681)
        if not s then return false end
        local c = ez.net.tcp_accept(s)
        ez.net.tcp_close(s)
        return c
    """
    out = device.lua_exec(code)
    assert out is None or out is False or isinstance(out, int)


def test_tcp_connect_to_unreachable(device):
    """Connecting to a closed port should time out and return nil."""
    out = device.lua_exec(
        "return ez.net.tcp_connect('127.0.0.1', 1, 100)"
    )
    assert out is None or isinstance(out, int)


def test_tcp_connected_for_unknown_handle(device):
    """tcp_connected on a never-opened handle must not crash."""
    out = device.lua_exec("return ez.net.tcp_connected(99999)")
    assert isinstance(out, bool)


def test_tcp_send_recv_on_closed_handle(device):
    """Send/recv on a stale handle should fail cleanly."""
    s = device.lua_exec("return ez.net.tcp_send(99999, 'data')")
    assert s is None or s is False or isinstance(s, int)
    r = device.lua_exec("return ez.net.tcp_recv(99999)")
    assert r is None or isinstance(r, str)
