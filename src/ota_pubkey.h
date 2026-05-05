// OTA firmware-update signing public key.
//
// The on-device firmware-update flow downloads a manifest.json describing
// the latest rolling-main release alongside an Ed25519 signature in
// manifest.sig. The signature is verified against the 32-byte public key
// declared here before the device commits to any URL/hash from that
// manifest.
//
// Default value is all zeros, which the runtime treats as "OTA signing
// not configured on this device" and refuses to install. To enable
// signed updates:
//
//   1. Run `python tools/ota/gen_signing_key.py` once. It prints both
//      a private key (base64; goes into the GitHub Actions secret
//      OTA_SIGNING_PRIVKEY) and a public key (32 bytes hex).
//   2. Paste the public key bytes into kOtaSigningPubkey below, then
//      flash the new firmware to every device that should accept
//      rolling-main updates.
//
// Treat the private key like any other release signing key: store it
// only in GitHub secrets, rotate by burning a new firmware containing
// the new pubkey to all devices in the field.

#pragma once

#include <stdint.h>
#include <stddef.h>

constexpr size_t OTA_SIGNING_PUBKEY_SIZE = 32;

extern const uint8_t kOtaSigningPubkey[OTA_SIGNING_PUBKEY_SIZE];

// Returns true once kOtaSigningPubkey has been populated with a real
// key (i.e. is not all zero). Both the apply_url binding and the
// firmware-update screen short-circuit when this is false.
bool ota_signing_configured();
