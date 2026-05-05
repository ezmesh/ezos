#!/usr/bin/env python3
"""Generate an Ed25519 keypair for signing rolling-main OTA manifests.

Run once during the OTA setup ceremony:

  $ pip install pynacl
  $ python tools/ota/gen_signing_key.py

The script prints:
  - PRIVATE KEY (base64): paste into the GitHub Actions secret
                          OTA_SIGNING_PRIVKEY
  - PUBLIC KEY  (hex):    paste into src/ota_pubkey.cpp's
                          kOtaSigningPubkey array, then rebuild +
                          flash every device that should accept
                          rolling-main updates.

The private key never needs to live anywhere else. Treat it like any
other release-signing key.
"""

import base64
import sys

try:
    from nacl.signing import SigningKey
except ImportError:
    sys.stderr.write("This script needs PyNaCl. Install it with:\n  pip install pynacl\n")
    sys.exit(1)


def main():
    sk = SigningKey.generate()
    privkey_b64 = base64.b64encode(bytes(sk)).decode()
    pubkey = bytes(sk.verify_key)

    print("=== ezOS OTA signing keypair ===")
    print()
    print("PRIVATE KEY (base64) -- paste into GitHub Actions secret OTA_SIGNING_PRIVKEY:")
    print(privkey_b64)
    print()
    print("PUBLIC KEY (hex) -- 32 bytes for src/ota_pubkey.cpp:")
    print("".join(f"{b:02x}" for b in pubkey))
    print()
    print("PUBLIC KEY (C array form) -- copy/paste into kOtaSigningPubkey:")
    rows = []
    for i in range(0, 32, 8):
        row = ", ".join(f"0x{b:02x}" for b in pubkey[i:i + 8])
        rows.append("    " + row + ",")
    print("\n".join(rows))


if __name__ == "__main__":
    main()
