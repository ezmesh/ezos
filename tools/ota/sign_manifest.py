#!/usr/bin/env python3
"""Sign a rolling-main OTA manifest with the Ed25519 release key.

Reads the manifest path as the first argument, signs its raw bytes,
and writes the 64-byte detached signature next to it as
`<manifest>.sig`. The private key is read from the
OTA_SIGNING_PRIVKEY environment variable as base64-encoded 32-byte
seed material (the format printed by gen_signing_key.py).

Used by `.github/workflows/main-artifacts.yml` after the firmware
build, before publishing the rolling-main release.
"""

import base64
import os
import sys

try:
    from nacl.signing import SigningKey
except ImportError:
    sys.stderr.write("This script needs PyNaCl. Install it with:\n  pip install pynacl\n")
    sys.exit(1)


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: sign_manifest.py <path-to-manifest.json>\n")
        sys.exit(2)

    manifest_path = argv[1]
    sig_path = manifest_path + ".sig"

    privkey_b64 = os.environ.get("OTA_SIGNING_PRIVKEY")
    if not privkey_b64:
        sys.stderr.write("OTA_SIGNING_PRIVKEY env var not set\n")
        sys.exit(3)

    seed = base64.b64decode(privkey_b64)
    if len(seed) != 32:
        sys.stderr.write(f"OTA_SIGNING_PRIVKEY must decode to 32 bytes, got {len(seed)}\n")
        sys.exit(4)

    sk = SigningKey(seed)
    with open(manifest_path, "rb") as f:
        manifest_bytes = f.read()

    signed = sk.sign(manifest_bytes)
    signature = signed.signature  # 64 bytes, detached
    if len(signature) != 64:
        sys.stderr.write(f"unexpected signature length {len(signature)}\n")
        sys.exit(5)

    with open(sig_path, "wb") as f:
        f.write(signature)

    print(f"signed: {manifest_path} -> {sig_path} ({len(manifest_bytes)} bytes)")


if __name__ == "__main__":
    main(sys.argv)
