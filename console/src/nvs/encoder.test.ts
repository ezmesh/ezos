// Run with: npx tsx src/nvs/encoder.test.ts
//
// This is a smoke test, not a parity check against nvs_partition_gen.py.
// It validates the structural invariants of the produced image:
//   - 20480 bytes
//   - First page has ACTIVE state and a valid header CRC
//   - The expected entries are present at decodable offsets with valid
//     per-entry CRCs
// Run it from the console/ directory.

import { encodeNvsImage, __internal } from "./encoder";
import { crc32 } from "./crc32";

let failures = 0;
function assert(cond: unknown, msg: string) {
    if (!cond) {
        console.error("FAIL:", msg);
        failures++;
    } else {
        console.log("ok  :", msg);
    }
}

function u32le(buf: Uint8Array, off: number): number {
    return (
        buf[off] |
        (buf[off + 1] << 8) |
        (buf[off + 2] << 16) |
        (buf[off + 3] << 24)
    ) >>> 0;
}

function readKey(buf: Uint8Array, off: number): string {
    let end = off;
    while (end < off + 16 && buf[end] !== 0) end++;
    return new TextDecoder().decode(buf.subarray(off, end));
}

const img = encodeNvsImage({
    onboarded: "1",
    nodename: "Alice",
    radio_freq_mhz: "869.525",
    tx_throttle_ms: 400,
    wifi_ssid: "Home",
    wifi_password: "secret123",
    tz_posix: "CET-1CEST,M3.5.0,M10.5.0/3",
    screen_bright: 200,
    ui_sounds_on: 1,
    accent_color: 0x07ff,
});

assert(img.length === __internal.PARTITION_SIZE, `size = ${img.length}`);
assert(u32le(img, 0) === 0xfffffffe, "first page state ACTIVE");
assert(img[8] === 0xfe, "page version = v2");

// Walk entries -- header is at [0..31], bitmap [32..63], entries from 64.
const seen = new Map<string, { ns: number; type: number }>();
const ENTRY = 32;
let slot = 0;
while (slot < 126) {
    const off = 64 + slot * ENTRY;
    const ns = img[off];
    if (ns === 0xff) break; // unwritten
    const type = img[off + 1];
    const span = img[off + 2];
    const key = readKey(img, off + 8);
    // Verify per-entry CRC.
    const prefix = img.subarray(off, off + 4);
    const tail = img.subarray(off + 8, off + ENTRY);
    const concat = new Uint8Array(prefix.length + tail.length);
    concat.set(prefix, 0);
    concat.set(tail, prefix.length);
    const expected = crc32(concat);
    const got = u32le(img, off + 4);
    assert(
        expected === got,
        `entry crc ok @slot=${slot} ns=${ns} key="${key}" want=${expected.toString(16)} got=${got.toString(16)}`,
    );
    seen.set(key, { ns, type });
    slot += Math.max(1, span);
}

// Expect both namespaces to be declared.
assert(seen.get("lua_storage")?.ns === 0, "lua_storage namespace declaration");
assert(seen.get("meshcore")?.ns === 0, "meshcore namespace declaration");

// Expect specific keys to appear in the right namespace.
const NS_LUA = __internal.NS_INDEX.lua_storage;
const NS_MC = __internal.NS_INDEX.meshcore;

assert(seen.get("onboarded")?.ns === NS_LUA, "onboarded in lua_storage");
assert(seen.get("tz_posix")?.ns === NS_LUA, "tz_posix in lua_storage");
assert(seen.get("wifi_ssid")?.ns === NS_LUA, "wifi_ssid in lua_storage");
assert(seen.get("wifi_password")?.ns === NS_LUA, "wifi_password in lua_storage");
assert(seen.get("nodename")?.ns === NS_MC, "nodename in meshcore");

// Primitive types should match.
assert(seen.get("screen_bright")?.type === 0x14, "screen_bright is I32");
assert(seen.get("ui_sounds_on")?.type === 0x11, "ui_sounds_on is I8");
assert(seen.get("accent_color")?.type === 0x14, "accent_color is I32");

// String entry data CRC -- spot-check on wifi_password.
function findEntry(key: string): number {
    let s = 0;
    while (s < 126) {
        const off = 64 + s * ENTRY;
        if (img[off] === 0xff) break;
        if (readKey(img, off + 8) === key) return off;
        s += Math.max(1, img[off + 2]);
    }
    return -1;
}

const pwOff = findEntry("wifi_password");
assert(pwOff > 0, "found wifi_password entry");
if (pwOff > 0) {
    const dataSize = img[pwOff + 24] | (img[pwOff + 25] << 8);
    assert(dataSize === "secret123".length + 1, `wifi_password size = ${dataSize}`);
    const dataCrc = u32le(img, pwOff + 28);
    const bytes = new Uint8Array(dataSize);
    for (let i = 0; i < "secret123".length; i++) {
        bytes[i] = "secret123".charCodeAt(i);
    }
    bytes[dataSize - 1] = 0;
    assert(crc32(bytes) === dataCrc, "wifi_password data crc matches");
}

// Empty strings should be skipped, not emitted as zero-length entries.
// Walk the entry table directly -- byte-scanning for 'w' (0x77) used to
// pass trivially because the header CRC / bitmap area happens to be
// before offset 64, and the lookup never actually checked the key.
function findEntryIn(img: Uint8Array, key: string): number {
    let s = 0;
    while (s < 126) {
        const off = 64 + s * ENTRY;
        if (img[off] === 0xff) break;
        if (readKey(img, off + 8) === key) return off;
        s += Math.max(1, img[off + 2]);
    }
    return -1;
}
const imgNoSsid = encodeNvsImage({ onboarded: "1", wifi_ssid: "" });
assert(findEntryIn(imgNoSsid, "wifi_ssid") === -1, "empty wifi_ssid is omitted");

// Header CRC.
const headerCrc = u32le(img, 28);
assert(crc32(img.subarray(4, 28)) === headerCrc, "page header crc");

if (failures > 0) {
    console.error(`\n${failures} failure(s)`);
    process.exit(1);
}
console.log("\nall good");
