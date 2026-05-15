// Run with: npx tsx src/flash/manifest.test.ts
//
// Round-trip Ed25519 sign/verify and a tampering check, using a freshly
// generated keypair (NOT the production OTA pubkey -- that would require
// access to the OTA_SIGNING_PRIVKEY secret). This proves the verification
// plumbing works end-to-end; the on-network call against the real release
// is exercised manually via the wizard.

import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha2.js";

ed.hashes.sha512 = (msg: Uint8Array) => sha512(msg);

let failures = 0;
function assert(cond: unknown, msg: string) {
    if (cond) {
        console.log("ok  :", msg);
    } else {
        console.error("FAIL:", msg);
        failures++;
    }
}

async function main() {
    const seed = new Uint8Array(32).fill(7);
    const pubkey = await ed.getPublicKeyAsync(seed);
    const manifest = new TextEncoder().encode(JSON.stringify({ tag: "rolling-main" }));

    const sig = await ed.signAsync(manifest, seed);
    assert(sig.length === 64, "signature is 64 bytes");

    const good = await ed.verifyAsync(sig, manifest, pubkey);
    assert(good === true, "valid signature verifies");

    const tampered = new Uint8Array(manifest);
    tampered[5] ^= 0xff;
    const bad = await ed.verifyAsync(sig, tampered, pubkey);
    assert(bad === false, "tampered manifest fails verification");

    // SHA-256 round trip via WebCrypto.
    const data = new TextEncoder().encode("hello");
    const ab = new ArrayBuffer(data.byteLength);
    new Uint8Array(ab).set(data);
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", ab));
    let hex = "";
    for (let i = 0; i < digest.length; i++) {
        hex += digest[i].toString(16).padStart(2, "0");
    }
    assert(
        hex === "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "WebCrypto SHA-256 of 'hello' matches known digest",
    );

    if (failures > 0) {
        console.error(`\n${failures} failure(s)`);
        process.exit(1);
    }
    console.log("\nall good");
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
