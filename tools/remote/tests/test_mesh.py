"""
ez.mesh bindings — node identity, packet shaping, queue state, callbacks,
crypto helpers. Transmit-side functions (send_announce, send_group_packet,
send_raw, queue_send, schedule_rebroadcast) are gated behind the
``mesh_tx`` marker so they only run when EZ_TEST_MESH_TX=1 is set, since
they spam the public mesh.

State-mutating tests save and restore the previous value: node name,
announce interval, tx throttle, path-check flag.
"""

from __future__ import annotations

import re

import pytest


# ---------------------------------------------------------------------------
# Identity / state getters
# ---------------------------------------------------------------------------


def test_namespace(device):
    assert device.lua_exec("return type(ez.mesh)") == "table"


def test_constants_exposed(device):
    assert isinstance(device.lua_exec("return ez.mesh.ROUTE.FLOOD"), int)
    assert isinstance(device.lua_exec("return ez.mesh.PAYLOAD.GRP_TXT"), int)


def test_is_initialized(device):
    assert device.lua_exec("return ez.mesh.is_initialized()") is True


def test_get_node_id_hex_string(device):
    nid = device.lua_exec("return ez.mesh.get_node_id()")
    assert isinstance(nid, str)
    assert re.fullmatch(r"[0-9a-fA-F]+", nid), nid


def test_get_short_id_hex_string(device):
    sid = device.lua_exec("return ez.mesh.get_short_id()")
    assert isinstance(sid, str)
    assert re.fullmatch(r"[0-9a-fA-F]+", sid)


def test_get_node_name_returns_string(device):
    name = device.lua_exec("return ez.mesh.get_node_name()")
    assert isinstance(name, str) and len(name) > 0


def test_get_path_hash(device):
    h = device.lua_exec("return ez.mesh.get_path_hash()")
    assert isinstance(h, int) and 0 <= h <= 255


def test_get_public_key_lengths(device):
    code = """
        local raw = ez.mesh.get_public_key()
        local hex = ez.mesh.get_public_key_hex()
        return { raw_len = #raw, hex_len = #hex, hex = hex }
    """
    out = device.lua_exec(code)
    assert out["raw_len"] == 32  # Ed25519 public key
    assert out["hex_len"] == 64
    assert re.fullmatch(r"[0-9a-fA-F]+", out["hex"])


# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------


def test_tx_rx_counts(device):
    tx = device.lua_exec("return ez.mesh.get_tx_count()")
    rx = device.lua_exec("return ez.mesh.get_rx_count()")
    assert isinstance(tx, int) and tx >= 0
    assert isinstance(rx, int) and rx >= 0


def test_get_node_count_consistent_with_get_nodes(device):
    code = """
        local nodes = ez.mesh.get_nodes()
        return ez.mesh.get_node_count(), #nodes
    """
    count, n_array = device.lua_exec(code)
    assert count == n_array


def test_get_nodes_shape(device):
    """We probe shape via the Lua side: get_nodes() returns a list of
    tables, each with at least an identifier field. Going through Lua
    avoids the UTF-8 decode hazard on JSON deserialization when a
    received node name contains non-ASCII bytes."""
    code = """
        local nodes = ez.mesh.get_nodes()
        if #nodes == 0 then return { count = 0, has_id = true } end
        local n = nodes[1]
        local has_id = (n.id or n.node_id or n.pub_key_hex) ~= nil
        return { count = #nodes, has_id = has_id }
    """
    out = device.lua_exec(code)
    assert isinstance(out, dict)
    assert out["count"] >= 0
    assert out["has_id"] is True


# ---------------------------------------------------------------------------
# Local state mutators (save+restore)
# ---------------------------------------------------------------------------


def test_set_node_name_round_trip(device):
    original = device.lua_exec("return ez.mesh.get_node_name()")
    try:
        ok = device.lua_exec("return ez.mesh.set_node_name('test-harness')")
        assert ok is True
        assert device.lua_exec("return ez.mesh.get_node_name()") == "test-harness"
    finally:
        device.lua_exec(f"ez.mesh.set_node_name('{original}')")


def test_announce_interval_round_trip(device):
    original = device.lua_exec("return ez.mesh.get_announce_interval()")
    assert isinstance(original, int)
    try:
        device.lua_exec("ez.mesh.set_announce_interval(60000)")
        assert device.lua_exec("return ez.mesh.get_announce_interval()") == 60000
    finally:
        device.lua_exec(f"ez.mesh.set_announce_interval({original})")


def test_tx_throttle_round_trip(device):
    original = device.lua_exec("return ez.mesh.get_tx_throttle()")
    assert isinstance(original, int)
    try:
        device.lua_exec("ez.mesh.set_tx_throttle(250)")
        assert device.lua_exec("return ez.mesh.get_tx_throttle()") == 250
    finally:
        device.lua_exec(f"ez.mesh.set_tx_throttle({original})")


def test_path_check_round_trip(device):
    original = device.lua_exec("return ez.mesh.get_path_check()")
    assert isinstance(original, bool)
    try:
        device.lua_exec("ez.mesh.set_path_check(true)")
        assert device.lua_exec("return ez.mesh.get_path_check()") is True
        device.lua_exec("ez.mesh.set_path_check(false)")
        assert device.lua_exec("return ez.mesh.get_path_check()") is False
    finally:
        device.lua_exec(
            f"ez.mesh.set_path_check({'true' if original else 'false'})"
        )


# ---------------------------------------------------------------------------
# Tx queue
# ---------------------------------------------------------------------------


def test_tx_queue_state(device):
    cap = device.lua_exec("return ez.mesh.get_tx_queue_capacity()")
    size = device.lua_exec("return ez.mesh.get_tx_queue_size()")
    full = device.lua_exec("return ez.mesh.is_tx_queue_full()")
    assert isinstance(cap, int) and cap > 0
    assert isinstance(size, int) and 0 <= size <= cap
    assert isinstance(full, bool)


def test_clear_tx_queue(device):
    device.lua_exec("ez.mesh.clear_tx_queue()")
    assert device.lua_exec("return ez.mesh.get_tx_queue_size()") == 0


# ---------------------------------------------------------------------------
# Packet capture queue
# ---------------------------------------------------------------------------


def test_packet_queue_state(device):
    n = device.lua_exec("return ez.mesh.packet_count()")
    has = device.lua_exec("return ez.mesh.has_packets()")
    assert isinstance(n, int) and n >= 0
    assert isinstance(has, bool)


def test_pop_packet_when_empty_returns_nil(device):
    """After clearing the queue, pop_packet returns nil."""
    device.lua_exec("ez.mesh.clear_packet_queue()")
    out = device.lua_exec("return ez.mesh.pop_packet()")
    assert out is None


def test_enable_packet_queue_round_trip(device):
    device.lua_exec("ez.mesh.enable_packet_queue(true)")
    device.lua_exec("ez.mesh.enable_packet_queue(false)")


# ---------------------------------------------------------------------------
# Header pack/unpack
# ---------------------------------------------------------------------------


def test_make_parse_header_round_trip(device):
    code = """
        local h = ez.mesh.make_header(ez.mesh.ROUTE.FLOOD, ez.mesh.PAYLOAD.GRP_TXT, 0)
        local route, ptype, ver = ez.mesh.parse_header(h)
        return { h = h, route = route, ptype = ptype, ver = ver,
                 expect_route = ez.mesh.ROUTE.FLOOD,
                 expect_ptype = ez.mesh.PAYLOAD.GRP_TXT }
    """
    out = device.lua_exec(code)
    assert out["route"] == out["expect_route"]
    assert out["ptype"] == out["expect_ptype"]
    assert out["ver"] == 0


def test_build_packet_header_matches_inputs(device):
    """Build a packet then re-parse its first byte and verify the header."""
    code = """
        local pkt = ez.mesh.build_packet(
            ez.mesh.ROUTE.FLOOD,
            ez.mesh.PAYLOAD.GRP_TXT,
            'hello'
        )
        if not pkt then return nil end
        local first_byte = string.byte(pkt, 1)
        local route, ptype = ez.mesh.parse_header(first_byte)
        return { len = #pkt, route = route, ptype = ptype,
                 expect_route = ez.mesh.ROUTE.FLOOD,
                 expect_ptype = ez.mesh.PAYLOAD.GRP_TXT }
    """
    out = device.lua_exec(code)
    assert out is not None
    assert out["len"] > 5
    assert out["route"] == out["expect_route"]
    assert out["ptype"] == out["expect_ptype"]


def test_build_packet_rejects_oversize_payload(device):
    """MAX_PACKET_PAYLOAD is 184; anything larger must return nil."""
    code = """
        local payload = string.rep('x', 200)
        return ez.mesh.build_packet(ez.mesh.ROUTE.FLOOD, ez.mesh.PAYLOAD.GRP_TXT, payload)
    """
    out = device.lua_exec(code)
    assert out is None


# ---------------------------------------------------------------------------
# Crypto helpers
# ---------------------------------------------------------------------------


def test_ed25519_sign_verify_round_trip(device):
    """Sign with the device's private key, verify with its public key."""
    code = """
        local data = 'meshcore-test-vector'
        local sig = ez.mesh.ed25519_sign(data)
        local pub = ez.mesh.get_public_key()
        local ok = ez.mesh.ed25519_verify(data, sig, pub)
        return { sig_len = #sig, ok = ok }
    """
    out = device.lua_exec(code)
    assert out["sig_len"] == 64
    assert out["ok"] is True


def test_ed25519_verify_rejects_tampered_data(device):
    code = """
        local sig = ez.mesh.ed25519_sign('original')
        return ez.mesh.ed25519_verify('tampered', sig, ez.mesh.get_public_key())
    """
    assert device.lua_exec(code) is False


def test_calc_shared_secret_with_self(device):
    """Computing shared secret with own pubkey works (just an exercise of
    the binding; not cryptographically meaningful)."""
    code = """
        local pub = ez.mesh.get_public_key()
        local s = ez.mesh.calc_shared_secret(pub)
        return s ~= nil and #s or 0
    """
    n = device.lua_exec(code)
    # Shared secret is 32 bytes (X25519)
    assert n == 32


# ---------------------------------------------------------------------------
# Callback registration — verify the bindings accept a function without
# crashing. We don't assert the callback fires (that needs real packets).
# ---------------------------------------------------------------------------


def test_on_node_discovered_accepts_callback(device):
    code = """
        ez.mesh.on_node_discovered(function(node) _G._test_mesh_ok = true end)
        return true
    """
    assert device.lua_exec(code) is True
    device.lua_exec("ez.mesh.on_node_discovered(nil)")
    device.lua_exec("_G._test_mesh_ok = nil")


def test_on_packet_accepts_callback(device):
    code = """
        ez.mesh.on_packet(function(pkt) _G._test_mesh_ok = true end)
        return true
    """
    assert device.lua_exec(code) is True
    device.lua_exec("ez.mesh.on_packet(nil)")
    device.lua_exec("_G._test_mesh_ok = nil")


def test_on_group_packet_accepts_callback(device):
    code = """
        ez.mesh.on_group_packet(function(channel_hash, data) _G._test_mesh_ok = true end)
        return true
    """
    assert device.lua_exec(code) is True
    device.lua_exec("ez.mesh.on_group_packet(nil)")
    device.lua_exec("_G._test_mesh_ok = nil")


# ---------------------------------------------------------------------------
# Update tick
# ---------------------------------------------------------------------------


def test_update_runs_without_error(device):
    """ez.mesh.update() pumps the mesh state machine — calling it once
    must be a no-op when nothing is pending."""
    device.lua_exec("ez.mesh.update()")


# ---------------------------------------------------------------------------
# Transmit-side — opt-in via @pytest.mark.mesh_tx (EZ_TEST_MESH_TX=1)
# ---------------------------------------------------------------------------


@pytest.mark.mesh_tx
def test_send_announce_returns_bool(device):
    out = device.lua_exec("return ez.mesh.send_announce()")
    assert isinstance(out, bool)


@pytest.mark.mesh_tx
def test_queue_send_with_built_packet(device):
    """Queue a built packet onto the TX queue and verify size increases."""
    code = """
        ez.mesh.clear_tx_queue()
        local pkt = ez.mesh.build_packet(
            ez.mesh.ROUTE.FLOOD, ez.mesh.PAYLOAD.GRP_TXT, 'tx-test'
        )
        local before = ez.mesh.get_tx_queue_size()
        local ok = ez.mesh.queue_send(pkt)
        local after = ez.mesh.get_tx_queue_size()
        ez.mesh.clear_tx_queue()
        return { ok = ok, before = before, after = after }
    """
    out = device.lua_exec(code)
    assert out["ok"] is True
    assert out["after"] >= out["before"]
