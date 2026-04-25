"""
ez.compression — single function: inflate(data, max_size). The on-device
implementation is backed by ROM miniz. We feed it a known zlib payload
produced by Lua's string library + compress, and round-trip it.
"""

from __future__ import annotations

import zlib


def test_namespace(device):
    assert device.lua_exec("return type(ez.compression)") == "table"
    assert device.lua_exec("return type(ez.compression.inflate)") == "function"


def test_inflate_known_payload(device):
    raw = b"the quick brown fox jumps over the lazy dog" * 16
    compressed = zlib.compress(raw, level=9)
    # Hex-pack so the string survives lua_exec's UTF-8 round-trip.
    code = f"""
        local hex = '{compressed.hex()}'
        local data = ez.crypto.hex_to_bytes(hex)
        local out = ez.compression.inflate(data, {len(raw) + 16})
        return out
    """
    out = device.lua_exec(code)
    assert isinstance(out, str)
    assert out.encode("latin-1", errors="replace") == raw or out == raw.decode(
        "latin-1"
    )


def test_inflate_returns_nil_on_garbage(device):
    """inflate returns nil (or nil + error) on non-zlib input."""
    out = device.lua_exec(
        "return ez.compression.inflate('not a zlib stream', 1024)"
    )
    assert out is None or (isinstance(out, list) and out[0] is None)
