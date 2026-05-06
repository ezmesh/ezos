#include "ota_pubkey.h"

// Ed25519 public half of the rolling-main signing keypair. Minted
// 2026-05-06 by tools/ota/gen_signing_key.py; the matching private
// key lives only in the OTA_SIGNING_PRIVKEY GitHub Actions secret
// and was never written to disk during the ceremony. CI signs each
// release manifest with that private key, and the on-device
// firmware-update screen verifies against this public key before
// allowing apply_url() to start. See ota_pubkey.h for the full
// ceremony notes; rotating this key requires reflashing every
// device in the field.
const uint8_t kOtaSigningPubkey[OTA_SIGNING_PUBKEY_SIZE] = {
    0xc2, 0x6f, 0x48, 0x11, 0x1f, 0x40, 0xe2, 0xc5,
    0xe8, 0x78, 0x29, 0xa0, 0xd4, 0xa9, 0x25, 0xb6,
    0xaf, 0xf3, 0x55, 0x5b, 0xb8, 0x0e, 0xeb, 0xb5,
    0xf4, 0xc2, 0x54, 0xdb, 0x34, 0xf8, 0x14, 0x57,
};

bool ota_signing_configured() {
    for (size_t i = 0; i < OTA_SIGNING_PUBKEY_SIZE; ++i) {
        if (kOtaSigningPubkey[i] != 0) return true;
    }
    return false;
}
