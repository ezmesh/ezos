#!/usr/bin/env python3
"""
Decode an ezOS channel-invite URL into the channel name + 16-byte AES
key needed by `meshcore-cli add_channel`.

Pulls the recipient's Ed25519 private key from a meshcore-cli node by
running `meshcore-cli -j -s <port> get private_key 2>/dev/null`, derives
the X25519 ECDH secret with the sender, AES-128-ECB-decrypts the
invite token, and prints the result. Optionally also calls
`meshcore-cli add_channel` to install it.

The sender's pubkey can come from either --from <hex> or
--from-contact <name> (looked up against meshcore-cli's contact list).
The 8-byte nonce in the token is consumed but unused -- it's a
uniqueness salt, not a redeem gate.

Requires: cryptography (pip install cryptography)
        : meshcore-cli on PATH

Examples:
    # Use a contact that's already in meshcore-cli
    decode_invite.py "https://ezme.sh/#join/v1?t=ABC..." \\
        --from-contact "Node-A2EF60"

    # Pass the sender's pubkey hex directly
    decode_invite.py "https://ezme.sh/#join/v1?t=ABC..." \\
        --from a2ef60b3...

    # Decode AND immediately add to the local node
    decode_invite.py URL --from-contact NAME --add
"""

import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys

try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import (
        X25519PrivateKey, X25519PublicKey,
    )
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.backends import default_backend
except ImportError:
    sys.exit("error: 'cryptography' is required (pip install cryptography)")


URL_RE = re.compile(r"https://ezme\.sh/#join/v1\?t=([A-Za-z0-9_\-]+)")
NONCE_SIZE = 8
AES_BLOCK_SIZE = 16


def parse_invite_url(url: str) -> bytes:
    # Drop any literal backslashes the shell didn't strip. Zsh keeps
    # `\#` and `\?` intact inside double quotes (or even unquoted),
    # which would otherwise trip the regex; users tend to escape those
    # characters out of habit when pasting URLs.
    cleaned = url.replace("\\", "")
    m = URL_RE.search(cleaned)
    if not m:
        sys.exit(
            "error: not a valid ezme.sh channel-invite URL\n"
            "(tip: wrap the URL in single quotes to avoid shell escaping)"
        )
    b64 = m.group(1).replace("-", "+").replace("_", "/")
    pad = (4 - len(b64) % 4) % 4
    return base64.b64decode(b64 + "=" * pad)


# Birational map from Ed25519 public point (curve25519 y-coord, sign in
# MSB) to X25519 public point (Montgomery u-coord). Mirrors the formula
# in src/mesh/identity.cpp ed25519PubKeyToX25519: u = (1+y) * (1-y)^-1
# mod p, with p = 2^255 - 19. Python's built-in pow(x, -1, m) gives the
# modular inverse so this stays a four-line operation.
def ed25519_pub_to_x25519_pub(ed_pub: bytes) -> bytes:
    if len(ed_pub) != 32:
        raise ValueError(f"Ed25519 pubkey must be 32 bytes, got {len(ed_pub)}")
    y_bytes = bytearray(ed_pub)
    y_bytes[31] &= 0x7F  # clear sign bit
    y = int.from_bytes(y_bytes, "little")
    p = (1 << 255) - 19
    u = ((1 + y) * pow(1 - y, -1, p)) % p
    return u.to_bytes(32, "little")


# Derive the X25519 scalar from a 32-byte Ed25519 seed. Matches
# Identity::calcSharedSecret in firmware: SHA-512 of the seed, take
# the first 32 bytes, then RFC 7748 clamp. Used for --ed25519-seed
# inputs; meshcore-cli's get private_key returns an already-derived
# clamped scalar, which doesn't go through this function.
def ed25519_seed_to_x25519_priv(seed: bytes) -> bytes:
    if len(seed) != 32:
        raise ValueError(f"Ed25519 seed must be 32 bytes, got {len(seed)}")
    h = hashlib.sha512(seed).digest()
    scalar = bytearray(h[:32])
    scalar[0] &= 0xF8
    scalar[31] &= 0x7F
    scalar[31] |= 0x40
    return bytes(scalar)


# Sanity check: an X25519 scalar that's been RFC 7748 clamped has
# byte[0] & 0x07 == 0 and (byte[31] & 0xC0) == 0x40. We don't blindly
# trust this -- callers always say which format they're passing -- but
# we use it to spot common confusions (e.g. someone hex-pasting an
# Ed25519 seed where we expected a clamped scalar). False positives on
# random Ed25519 seeds are ~1/512.
def looks_x25519_clamped(b: bytes) -> bool:
    return len(b) == 32 and (b[0] & 0x07) == 0 and (b[31] & 0xC0) == 0x40


def x25519_shared_secret(priv_scalar: bytes, peer_x_pub: bytes) -> bytes:
    priv = X25519PrivateKey.from_private_bytes(priv_scalar)
    pub = X25519PublicKey.from_public_bytes(peer_x_pub)
    return priv.exchange(pub)


def aes128_ecb_decrypt(key: bytes, ciphertext: bytes) -> bytes:
    cipher = Cipher(algorithms.AES(key), modes.ECB(), backend=default_backend())
    return cipher.decryptor().update(ciphertext) + cipher.decryptor().finalize()


def run_meshcore_cli(args: list, port: str) -> str:
    cmd = ["meshcore-cli", "-j", "-s", port] + args
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        msg = proc.stderr.strip() or proc.stdout.strip()
        sys.exit(f"error: meshcore-cli {' '.join(args)} failed: {msg}")
    return proc.stdout


def fetch_private_key(port: str) -> bytes:
    """
    Pull the recipient's already-clamped X25519 scalar from meshcore-cli.
    The meshcore Python lib's `get private_key` returns the same scalar
    the firmware uses for ECDH (RFC 7748 clamped, 32 bytes), NOT the
    Ed25519 seed -- so we use it directly as the X25519 priv with no
    SHA-512 + clamp step on top.
    """
    raw = run_meshcore_cli(["get", "private_key"], port)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(f"error: meshcore-cli get private_key returned non-JSON:\n{raw[:200]}")
    hex_str = data.get("private_key")
    if not hex_str:
        sys.exit(f"error: response missing 'private_key' field: {data}")
    out = bytes.fromhex(hex_str)
    if len(out) == 64:
        # Some exports include the public half too -- scalar is the first 32.
        out = out[:32]
    if len(out) != 32:
        sys.exit(f"error: unexpected private_key length {len(out)} (want 32)")
    if not looks_x25519_clamped(out):
        sys.exit(
            "error: meshcore-cli returned 32 bytes that don't look RFC 7748 clamped\n"
            "(expected an X25519 scalar; script can't tell what you've got)"
        )
    return out


def fetch_contact_pubkey(port: str, name: str) -> bytes:
    raw = run_meshcore_cli(["contacts"], port)
    try:
        contacts = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(f"error: meshcore-cli contacts returned non-JSON:\n{raw[:200]}")
    for k, v in contacts.items():
        if v.get("adv_name") == name or k == name:
            pub_hex = v.get("public_key")
            if not pub_hex:
                sys.exit(f"error: contact {name!r} has no public_key field")
            pub = bytes.fromhex(pub_hex)
            if len(pub) != 32:
                sys.exit(f"error: contact {name!r} pubkey is {len(pub)} bytes (want 32)")
            return pub
    available = ", ".join(sorted({v.get("adv_name", k) for k, v in contacts.items()}))
    sys.exit(f"error: contact {name!r} not found.\nAvailable: {available}")


def parse_token(raw: bytes) -> bytes:
    if len(raw) < NONCE_SIZE + AES_BLOCK_SIZE:
        sys.exit(f"error: token too short ({len(raw)} bytes, need >= {NONCE_SIZE + AES_BLOCK_SIZE})")
    if (len(raw) - NONCE_SIZE) % AES_BLOCK_SIZE != 0:
        sys.exit("error: token misaligned (ciphertext not a multiple of 16)")
    return raw[NONCE_SIZE:]  # nonce is uniqueness salt only, drop it


def parse_plaintext(plaintext: bytes) -> tuple[str, str]:
    if len(plaintext) < 2:
        sys.exit("error: decrypt produced too little data")
    name_len = plaintext[0]
    if name_len == 0 or 1 + name_len + 1 > len(plaintext):
        sys.exit("error: decode failed -- wrong sender pubkey or wrong recipient identity?")
    name = plaintext[1 : 1 + name_len].decode("utf-8", errors="replace")
    pwd_len = plaintext[1 + name_len]
    if pwd_len == 0 or 2 + name_len + pwd_len > len(plaintext):
        sys.exit("error: malformed password block")
    password = plaintext[2 + name_len : 2 + name_len + pwd_len].decode(
        "utf-8", errors="replace"
    )
    return name, password


def main():
    ap = argparse.ArgumentParser(
        description="Decode ezOS channel-invite URL via meshcore-cli."
    )
    ap.add_argument("url", help="ezme.sh channel-invite URL")
    ap.add_argument(
        "-s", "--port", default="/dev/ttyUSB0",
        help="meshcore-cli serial port (default: /dev/ttyUSB0)",
    )
    ap.add_argument(
        "--from", dest="from_pubkey",
        help="Sender Ed25519 pubkey (64 hex chars)",
    )
    ap.add_argument(
        "--from-contact", dest="from_contact",
        help="Sender name as it appears in meshcore-cli contacts",
    )
    ap.add_argument(
        "--privkey",
        help="Recipient X25519 private scalar hex, RFC 7748 clamped "
             "(matches meshcore-cli's get private_key output). Skips the CLI fetch.",
    )
    ap.add_argument(
        "--ed25519-seed", dest="ed25519_seed",
        help="Alternative to --privkey: pass a raw Ed25519 seed (32 bytes, "
             "unclamped); the script will SHA-512 + clamp it to derive the "
             "X25519 scalar internally. Useful for round-trip testing with "
             "Python-generated keypairs.",
    )
    ap.add_argument(
        "--add", action="store_true",
        help="After decoding, run meshcore-cli add_channel automatically",
    )
    ap.add_argument(
        "--debug", action="store_true",
        help="Print intermediate keys + raw plaintext on decode failure",
    )
    args = ap.parse_args()

    if bool(args.from_pubkey) == bool(args.from_contact):
        ap.error("must pass exactly one of --from or --from-contact")

    raw_token = parse_invite_url(args.url)
    ciphertext = parse_token(raw_token)

    if args.from_pubkey:
        sender_ed_pub = bytes.fromhex(args.from_pubkey)
    else:
        sender_ed_pub = fetch_contact_pubkey(args.port, args.from_contact)
    if len(sender_ed_pub) != 32:
        sys.exit(f"error: sender pubkey must be 32 bytes (got {len(sender_ed_pub)})")

    # Resolve recipient X25519 scalar. Three input shapes:
    #   --privkey       : already-clamped X25519 scalar (matches meshcore-cli's
    #                     get private_key output)
    #   --ed25519-seed  : raw Ed25519 seed; we SHA-512 + clamp it to derive
    #                     the X25519 scalar
    #   neither         : pull from meshcore-cli, treat as scalar
    if args.privkey and args.ed25519_seed:
        ap.error("pass either --privkey or --ed25519-seed, not both")
    if args.privkey:
        my_x_priv = bytes.fromhex(args.privkey)
        if len(my_x_priv) == 64:
            my_x_priv = my_x_priv[:32]
        if len(my_x_priv) != 32:
            sys.exit(f"error: --privkey must be 32 or 64 bytes (got {len(my_x_priv)})")
        if not looks_x25519_clamped(my_x_priv):
            sys.exit(
                "error: --privkey doesn't look RFC 7748 clamped; pass --ed25519-seed "
                "instead if this is a raw Ed25519 seed."
            )
        derivation = "supplied (--privkey, used as X25519 scalar)"
    elif args.ed25519_seed:
        seed = bytes.fromhex(args.ed25519_seed)
        if len(seed) == 64:
            seed = seed[:32]
        if len(seed) != 32:
            sys.exit(f"error: --ed25519-seed must be 32 or 64 bytes (got {len(seed)})")
        my_x_priv = ed25519_seed_to_x25519_priv(seed)
        derivation = "supplied (--ed25519-seed, SHA-512 + clamped)"
    else:
        my_x_priv = fetch_private_key(args.port)
        derivation = "fetched from meshcore-cli (X25519 scalar)"

    sender_x_pub = ed25519_pub_to_x25519_pub(sender_ed_pub)
    secret = x25519_shared_secret(my_x_priv, sender_x_pub)
    aes_key = secret[:16]

    plaintext = aes128_ecb_decrypt(aes_key, ciphertext)

    if args.debug:
        print(f"[debug] privkey source     : {derivation}")
        print("[debug] sender Ed25519 pub :", sender_ed_pub.hex())
        print("[debug] my X25519 scalar   :", my_x_priv.hex())
        print("[debug] sender X25519 pub  :", sender_x_pub.hex())
        print("[debug] shared secret      :", secret.hex())
        print("[debug] aes key (first 16) :", aes_key.hex())
        print("[debug] ciphertext bytes   :", ciphertext.hex())
        print("[debug] plaintext bytes    :", plaintext.hex())
        print("[debug] plaintext[0]       :", plaintext[0] if plaintext else "(empty)")
        print()

    try:
        name, password = parse_plaintext(plaintext)
    except SystemExit:
        if not args.debug:
            print(
                "\n(re-run with --debug to see the keys + the raw plaintext bytes;"
                " a wrong pubkey or wrong recipient identity is the usual cause)",
                file=sys.stderr,
            )
        raise

    # Channel key on the wire is SHA-256(passphrase)[:16] -- matches
    # ez.crypto.derive_channel_key in the firmware. meshcore-cli's
    # add_channel takes the hex form of those 16 bytes.
    channel_key_hex = hashlib.sha256(password.encode("utf-8")).digest()[:16].hex()

    print(f"Channel name : {name}")
    print(f"Passphrase   : {password}")
    print(f"Channel key  : {channel_key_hex}")
    print()
    print("Add to meshcore-cli with:")
    print(f'  meshcore-cli -s {args.port} add_channel "{name}" {channel_key_hex}')

    if args.add:
        print()
        print("Adding channel via meshcore-cli...")
        out = run_meshcore_cli(["add_channel", name, channel_key_hex], args.port)
        # meshcore-cli prints either "ok" or a JSON payload on success
        line = out.strip() or "(no output -- assume ok)"
        print(f"  -> {line}")


if __name__ == "__main__":
    main()
