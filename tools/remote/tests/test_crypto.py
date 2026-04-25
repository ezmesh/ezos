"""
ez.crypto bindings — pure compute, no hardware. We hit every function
with valid args, plus a couple of round-trips and a known-vector check.
"""

from __future__ import annotations

import re


def test_namespace(device):
    assert device.lua_exec("return type(ez.crypto)") == "table"


def test_sha256_known_vector(device):
    h = device.lua_exec(
        "return ez.crypto.bytes_to_hex(ez.crypto.sha256('hello world'))"
    )
    assert h == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"


def test_sha512_known_vector(device):
    h = device.lua_exec(
        "return ez.crypto.bytes_to_hex(ez.crypto.sha512('hello world'))"
    )
    # SHA-512("hello world")
    assert h == (
        "309ecc489c12d6eb4cc40f50c902f2b4d0ed77ee511a7c7a9bcd3ca86d4cd86f"
        "989dd35bc5ff499670da34255b45b0cfd830e81f605dcf7dc5542e93ae9cd76f"
    )


def test_hmac_sha256_deterministic(device):
    code = """
        local key = ('a'):rep(32)
        local m1 = ez.crypto.hmac_sha256(key, 'msg')
        local m2 = ez.crypto.hmac_sha256(key, 'msg')
        return m1 == m2 and #m1 or -1
    """
    assert device.lua_exec(code) == 32


def test_aes128_ecb_round_trip(device):
    code = """
        local key = ez.crypto.derive_channel_key('test')
        local pt  = 'hello world!'
        local ct  = ez.crypto.aes128_ecb_encrypt(key, pt)
        local dec = ez.crypto.aes128_ecb_decrypt(key, ct)
        return #ct, (dec:gsub('%z+$', ''))
    """
    ct_len, recovered = device.lua_exec(code)
    assert ct_len == 16  # zero-padded to 1 block
    assert recovered == "hello world!"


def test_random_bytes_length_and_uniqueness(device):
    a = device.lua_exec("return ez.crypto.bytes_to_hex(ez.crypto.random_bytes(32))")
    b = device.lua_exec("return ez.crypto.bytes_to_hex(ez.crypto.random_bytes(32))")
    assert isinstance(a, str) and len(a) == 64 and re.fullmatch(r"[0-9a-f]{64}", a)
    assert a != b, "random_bytes returned the same value twice in a row"


def test_random_bytes_rejects_invalid_count(device):
    """Returns (nil, error) on invalid count; ez_remote surfaces multi-return as a list."""
    out = device.lua_exec("return ez.crypto.random_bytes(0)")
    assert out is None or (isinstance(out, list) and out[0] is None)
    out = device.lua_exec("return ez.crypto.random_bytes(257)")
    assert out is None or (isinstance(out, list) and out[0] is None)


def test_public_channel_key(device):
    h = device.lua_exec(
        "return ez.crypto.bytes_to_hex(ez.crypto.public_channel_key())"
    )
    assert h == "8b3387e9c5cdea6ac9e5edbaa115cd72"


def test_channel_hash_for_public(device):
    code = """
        local k = ez.crypto.public_channel_key()
        return ez.crypto.channel_hash(k)
    """
    h = device.lua_exec(code)
    # First byte of SHA-256(public_key); just check shape — the value is
    # determined by the public key bytes and SHA-256, not pinned here.
    assert isinstance(h, int) and 0 <= h <= 255


def test_derive_channel_key_length(device):
    n = device.lua_exec("return #ez.crypto.derive_channel_key('SecretChannel')")
    assert n == 16


def test_bytes_to_hex_round_trip(device):
    code = """
        local raw = ez.crypto.random_bytes(16)
        local hex = ez.crypto.bytes_to_hex(raw)
        local back = ez.crypto.hex_to_bytes(hex)
        return raw == back, #hex, hex:match('^[0-9a-f]+$') ~= nil
    """
    matches, hex_len, lower_hex = device.lua_exec(code)
    assert matches is True
    assert hex_len == 32
    assert lower_hex is True


def test_hex_to_bytes_rejects_odd_length(device):
    out = device.lua_exec("return ez.crypto.hex_to_bytes('abc')")
    assert isinstance(out, list) and out[0] is None
    assert "even length" in out[1].lower()


def test_hex_to_bytes_rejects_invalid_chars(device):
    out = device.lua_exec("return ez.crypto.hex_to_bytes('zz')")
    assert isinstance(out, list) and out[0] is None
    assert "invalid" in out[1].lower()


def test_base64_round_trip(device):
    code = """
        local s = 'Hello, World!'
        local enc = ez.crypto.base64_encode(s)
        local dec = ez.crypto.base64_decode(enc)
        return enc, dec
    """
    enc, dec = device.lua_exec(code)
    assert enc == "SGVsbG8sIFdvcmxkIQ=="
    assert dec == "Hello, World!"
