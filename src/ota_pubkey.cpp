#include "ota_pubkey.h"

// Default: 32 zero bytes. Treated by the runtime as "signing not
// configured". Replace with the real Ed25519 public key minted by
// tools/ota/gen_signing_key.py before deploying signed-update
// firmware to the field. See ota_pubkey.h for the full ceremony.
const uint8_t kOtaSigningPubkey[OTA_SIGNING_PUBKEY_SIZE] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

bool ota_signing_configured() {
    for (size_t i = 0; i < OTA_SIGNING_PUBKEY_SIZE; ++i) {
        if (kOtaSigningPubkey[i] != 0) return true;
    }
    return false;
}
