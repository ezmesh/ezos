"""
Mesh-protocol end-to-end: announce visibility, packet capture, header
build/parse via the wire.

These tests transmit on the mesh radio. They use the per-device announce
mechanism (which broadcasts the device's own identity) rather than
addressed traffic on #Public, so they don't pollute the public channel
with test chatter. Still: only run with the two devices physically
nearby — not at scale.
"""

from __future__ import annotations

import time

import pytest


# ---------------------------------------------------------------------------
# Identity discovery — A's announce should land in B's node list
# ---------------------------------------------------------------------------


def _node_ids_in(device) -> set[str]:
    """Return set of node id strings B currently knows about."""
    code = """
        local nodes = ez.mesh.get_nodes()
        local ids = {}
        for _, n in ipairs(nodes) do
            local id = n.id or n.node_id or n.pub_key_hex
            if id then ids[#ids + 1] = id end
        end
        return ids
    """
    out = device.lua_exec(code)
    if isinstance(out, list):
        return set(out)
    return set()


def _b_knows_a(b, id_a: str) -> bool:
    """B knows A iff A's short node id appears as a prefix or full match
    of any entry in B's node list. Different installs report ids as
    short id (6 bytes hex) or full pubkey (32 bytes hex)."""
    needle = id_a.lower()
    for s in _node_ids_in(b):
        s = s.lower()
        if s == needle or s.startswith(needle) or needle.startswith(s):
            return True
    return False


@pytest.mark.slow
def test_b_lists_a_after_announce(both_devices):
    """A sends an announce; B's node list contains A. A may already be
    known from a prior boot's traffic, so we don't require this to be
    a new entry — only that A is present after the announce."""
    a, b = both_devices
    id_a = a.lua_exec("return ez.mesh.get_node_id()")

    sent = a.lua_exec("return ez.mesh.send_announce()")
    assert sent is True, "A's send_announce returned false"

    deadline = time.time() + 5.0
    while time.time() < deadline:
        if _b_knows_a(b, id_a):
            return
        time.sleep(0.3)
    pytest.fail(
        f"B's node list does not include A (id={id_a!r}). Known: "
        f"{sorted(_node_ids_in(b))!r}"
    )


# ---------------------------------------------------------------------------
# Packet capture — A's announce should also surface in B's packet queue
# when the queue is enabled
# ---------------------------------------------------------------------------


@pytest.mark.slow
def test_b_receives_a_announce_via_packet_queue(both_devices):
    """Enable B's packet capture queue, send announce from A, drain B's
    queue and verify at least one ADVERT-type packet arrived. Binary
    fields (path, payload) are hex-encoded on the device side so the
    JSON response is UTF-8 clean."""
    a, b = both_devices

    advert_payload_type = b.lua_exec("return ez.mesh.PAYLOAD.ADVERT")

    pop_safe = """
        local p = ez.mesh.pop_packet()
        if not p then return nil end
        local out = {}
        for k, v in pairs(p) do
            if type(v) == 'string' then
                out[k] = ez.crypto.bytes_to_hex(v)
            else
                out[k] = v
            end
        end
        return out
    """

    b.lua_exec("ez.mesh.clear_packet_queue(); ez.mesh.enable_packet_queue(true)")
    try:
        a.lua_exec("ez.mesh.send_announce()")

        deadline = time.time() + 5.0
        found_advert = False
        while time.time() < deadline and not found_advert:
            time.sleep(0.3)
            while True:
                pkt = b.lua_exec(pop_safe)
                if pkt is None:
                    break
                if isinstance(pkt, dict) and pkt.get("payload_type") == advert_payload_type:
                    found_advert = True
                    break
        assert found_advert, "B did not receive any ADVERT packet from A"
    finally:
        b.lua_exec("ez.mesh.enable_packet_queue(false); ez.mesh.clear_packet_queue()")


# ---------------------------------------------------------------------------
# Counter sanity — both devices' tx/rx counters move when traffic flows
# ---------------------------------------------------------------------------


@pytest.mark.slow
def test_a_tx_count_advances_when_a_sends(both_devices):
    a, _b = both_devices
    before = a.lua_exec("return ez.mesh.get_tx_count()")
    sent = a.lua_exec("return ez.mesh.send_announce()")
    assert sent is True
    deadline = time.time() + 3.0
    while time.time() < deadline:
        after = a.lua_exec("return ez.mesh.get_tx_count()")
        if after > before:
            return
        time.sleep(0.2)
    pytest.fail("A's tx_count did not advance after send_announce")


# ---------------------------------------------------------------------------
# Shared-secret cross-check — A's secret with B's pubkey must match B's
# secret with A's pubkey (X25519 is symmetric).
# ---------------------------------------------------------------------------


def test_x25519_shared_secret_symmetric(both_devices):
    a, b = both_devices
    pub_a = a.lua_exec("return ez.crypto.bytes_to_hex(ez.mesh.get_public_key())")
    pub_b = b.lua_exec("return ez.crypto.bytes_to_hex(ez.mesh.get_public_key())")

    secret_a = a.lua_exec(
        f"return ez.crypto.bytes_to_hex(ez.mesh.calc_shared_secret(ez.crypto.hex_to_bytes('{pub_b}')))"
    )
    secret_b = b.lua_exec(
        f"return ez.crypto.bytes_to_hex(ez.mesh.calc_shared_secret(ez.crypto.hex_to_bytes('{pub_a}')))"
    )

    assert secret_a == secret_b, (
        f"X25519 shared secret asymmetric:\n  A→B: {secret_a}\n  B→A: {secret_b}"
    )
    assert len(secret_a) == 64  # 32 bytes hex


# ---------------------------------------------------------------------------
# Cross-verify ed25519 signatures across devices
# ---------------------------------------------------------------------------


def test_b_can_verify_a_signature(both_devices):
    """A signs a message with its private key. B verifies with A's
    public key — should succeed. Same message, tampered version — must
    fail."""
    a, b = both_devices

    code_sign = """
        local data = 'meshcore-cross-verify-vector'
        return ez.crypto.bytes_to_hex(ez.mesh.ed25519_sign(data)),
               ez.crypto.bytes_to_hex(ez.mesh.get_public_key())
    """
    sig_hex, pub_hex = a.lua_exec(code_sign)

    ok = b.lua_exec(
        f"return ez.mesh.ed25519_verify('meshcore-cross-verify-vector', "
        f"ez.crypto.hex_to_bytes('{sig_hex}'), "
        f"ez.crypto.hex_to_bytes('{pub_hex}'))"
    )
    assert ok is True

    bad = b.lua_exec(
        f"return ez.mesh.ed25519_verify('tampered-data', "
        f"ez.crypto.hex_to_bytes('{sig_hex}'), "
        f"ez.crypto.hex_to_bytes('{pub_hex}'))"
    )
    assert bad is False
