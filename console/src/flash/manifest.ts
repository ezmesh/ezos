// Manifest fetch + Ed25519 signature verify + SHA-256 firmware verify.
//
// Mirrors the on-device update path (lua/screens/settings/firmware_update.lua):
// every rolling-main / rolling-test release ships manifest.json plus a
// detached manifest.json.sig built by tools/ota/sign_manifest.py. The
// signature is over the raw bytes of manifest.json, by the Ed25519 key
// whose public half is hard-coded in src/ota_pubkey.cpp.
//
// The console refuses to flash a release that doesn't pass this check, so
// the threat model is the same whether the user flashes from a browser
// or from the on-device menu -- TLS is not the root of trust, the
// signing key is.

import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha2.js";
import type { Release } from "../github/releases";

// @noble/ed25519 v3 needs sha512 plumbed in for synchronous + bundle-size
// reasons; install it once at module load.
ed.hashes.sha512 = (msg: Uint8Array) => sha512(msg);

// Vendored from src/ota_pubkey.cpp:kOtaSigningPubkey. If the C source
// rotates this key (a bigger ceremony -- requires reflashing every
// device), bump this constant too. See CLAUDE.md -> "Rolling OTA
// updates" for the rotation procedure.
const OTA_PUBKEY_HEX =
    "c26f48111f40e2c5e87829a0d4a925b6aff3555bb80eebb5f4c254db34f81457";

function hexToBytes(hex: string): Uint8Array {
    const out = new Uint8Array(hex.length / 2);
    for (let i = 0; i < out.length; i++) {
        out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    }
    return out;
}

function bytesToHex(buf: Uint8Array): string {
    let out = "";
    for (let i = 0; i < buf.length; i++) {
        out += buf[i].toString(16).padStart(2, "0");
    }
    return out;
}

export interface Manifest {
    tag: string;
    sha: string;
    short_sha: string;
    version: string;
    built_at: string;
    size: number;
    sha256: string;
    bin_url: string;
    full_size: number;
    full_sha256: string;
    full_bin_url: string;
}

export class ManifestError extends Error {
    constructor(message: string, readonly hint?: string) {
        super(message);
        this.name = "ManifestError";
    }
}

/**
 * Pull the manifest + detached signature out of a release's asset list.
 * Returns null when either is missing (tagged releases from build-release.yml
 * currently don't carry one -- the console rejects those, see runFlash).
 */
export function findManifestAssets(
    release: Release,
): { manifestUrl: string; sigUrl: string } | null {
    const manifest = release.assets.find((a) => a.name === "manifest.json");
    const sig = release.assets.find((a) => a.name === "manifest.json.sig");
    if (!manifest || !sig) return null;
    return { manifestUrl: manifest.browser_download_url, sigUrl: sig.browser_download_url };
}

/**
 * Fetch the manifest + signature, verify the signature against the embedded
 * pubkey, and return the parsed manifest. Throws ManifestError if any step
 * fails -- callers should refuse to flash in that case.
 */
export async function fetchAndVerifyManifest(release: Release): Promise<Manifest> {
    const urls = findManifestAssets(release);
    if (!urls) {
        throw new ManifestError(
            `Release ${release.tag_name} has no manifest.json + manifest.json.sig.`,
            "Pick a rolling-main or rolling-test release; only those are signed.",
        );
    }

    const [manifestRes, sigRes] = await Promise.all([
        fetch(urls.manifestUrl),
        fetch(urls.sigUrl),
    ]);
    if (!manifestRes.ok) {
        throw new ManifestError(`Couldn't download manifest.json (${manifestRes.status}).`);
    }
    if (!sigRes.ok) {
        throw new ManifestError(`Couldn't download manifest.json.sig (${sigRes.status}).`);
    }
    const manifestBytes = new Uint8Array(await manifestRes.arrayBuffer());
    const sigBytes = new Uint8Array(await sigRes.arrayBuffer());

    if (sigBytes.length !== 64) {
        throw new ManifestError(
            `manifest.json.sig is ${sigBytes.length} bytes, expected 64 (Ed25519).`,
        );
    }

    const pubkey = hexToBytes(OTA_PUBKEY_HEX);
    let valid = false;
    try {
        valid = await ed.verifyAsync(sigBytes, manifestBytes, pubkey);
    } catch (err) {
        throw new ManifestError(
            "Signature verification crashed: " +
                (err instanceof Error ? err.message : String(err)),
        );
    }
    if (!valid) {
        throw new ManifestError(
            `Signature on manifest.json does not match the embedded OTA pubkey.`,
            "This release was either signed with a different key or has been tampered with. Refusing to flash.",
        );
    }

    let parsed: Manifest;
    try {
        parsed = JSON.parse(new TextDecoder().decode(manifestBytes));
    } catch (err) {
        throw new ManifestError(
            "manifest.json passed signature check but isn't valid JSON: " +
                (err instanceof Error ? err.message : String(err)),
        );
    }
    return parsed;
}

/**
 * Verify that `bytes` hashes to the SHA-256 hex digest `expectedHex`.
 * Uses WebCrypto, which is available in every browser that has Web Serial.
 */
export async function verifySha256(
    bytes: Uint8Array,
    expectedHex: string,
    label: string,
): Promise<void> {
    // Copy into a fresh ArrayBuffer so the typed-array `.buffer` is
    // definitely ArrayBuffer, not SharedArrayBuffer -- which TS 5.6+
    // distinguishes in the WebCrypto signature.
    const ab = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(ab).set(bytes);
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", ab));
    const got = bytesToHex(digest);
    const want = expectedHex.toLowerCase();
    if (got !== want) {
        throw new ManifestError(
            `${label} SHA-256 mismatch (expected ${want}, got ${got}).`,
            "Download is corrupt or the manifest doesn't match the published binary.",
        );
    }
}
