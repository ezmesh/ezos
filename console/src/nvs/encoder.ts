// Pure-JS encoder for ESP-IDF NVS partition images.
//
// Output is a 20480-byte (5 × 4096) blob suitable for flashing to the `nvs`
// partition at offset 0x9000 (see partitions_16MB.csv).
//
// References:
//   - https://docs.espressif.com/projects/esp-idf/en/latest/esp32/api-reference/storage/nvs_flash.html
//   - ESP-IDF components/nvs_flash/src/nvs_page.{hpp,cpp}
//   - tools/nvs_partition_generator/nvs_partition_gen.py (Python reference)
//
// Layout per page (4096 bytes):
//   [0..31]    header
//   [32..63]   entry state bitmap (2 bits × 126 entries)
//   [64..4095] entry table (126 × 32-byte slots)
//
// Header layout:
//   [0..3]   state (u32 LE)  -- 0xfffffffe = ACTIVE, 0xffffffff = UNINITIALIZED
//   [4..7]   seq_no (u32 LE)
//   [8]      version (u8)    -- 0xfe for v2 (current)
//   [9..27]  reserved (filled with 0xff)
//   [28..31] crc32 (u32 LE) over bytes [4..27]
//
// Entry state values (2 bits each, packed LSB-first within each byte):
//   0b11 (3) = EMPTY (uninitialised)
//   0b10 (2) = WRITTEN
//
// Entry slot (32 bytes):
//   [0]      namespace_index (u8)
//   [1]      datatype (u8)
//   [2]      span (u8)
//   [3]      chunk_index (u8) -- 0xff for primitives
//   [4..7]   entry crc32 (u32 LE) over slot bytes excluding [4..7]
//   [8..23]  key (zero-padded, max 15 chars + null)
//   [24..31] data union
//
// For STR / BLOB the data union is:
//   [24..25] dataSize (u16 LE), includes trailing null for STR
//   [26..27] reserved (0xffff)
//   [28..31] dataCrc32 of the raw variable bytes (no padding included)
// followed by ceil(dataSize / 32) data slots holding the raw bytes,
// padded with 0xff to a 32-byte boundary.

import { crc32 } from "./crc32";
import {
    PREF_BY_KEY,
    type PrefDef,
    type PrefType,
} from "./schema";

const PARTITION_SIZE = 20480; // 5 pages × 4096
const PAGE_SIZE = 4096;
const ENTRY_SIZE = 32;
const ENTRIES_PER_PAGE = 126;
const HEADER_SIZE = 32;
const BITMAP_SIZE = 32;

const PAGE_STATE_ACTIVE = 0xfffffffe;
const PAGE_VERSION_V2 = 0xfe;

// ESP-IDF ItemType enum values.
const T_U8 = 0x01;
const T_I8 = 0x11;
const T_U16 = 0x02;
const T_I16 = 0x12;
const T_U32 = 0x04;
const T_I32 = 0x14;
const T_U64 = 0x08;
const T_I64 = 0x18;
const T_SZ = 0x21;

const TYPE_FOR: Record<PrefType, number> = {
    uint8: T_U8,
    int8: T_I8,
    uint16: T_U16,
    int16: T_I16,
    uint32: T_U32,
    int32: T_I32,
    uint64: T_U64,
    int64: T_I64,
    string: T_SZ,
    blob: T_SZ,
};

// Namespaces are written as U8 entries in namespace index 0; their value is
// the index every other entry references. The order they're written in is
// the order indices get assigned.
//   1 = lua_storage  (Lua's ez.storage prefs -- see storage_bindings.cpp:70)
//   2 = meshcore     (identity / nodename     -- see src/mesh/identity.cpp:12)
export const NS_LUA_STORAGE = "lua_storage";
export const NS_MESHCORE = "meshcore";
const NAMESPACES = [NS_LUA_STORAGE, NS_MESHCORE] as const;

const NS_INDEX: Record<string, number> = Object.fromEntries(
    NAMESPACES.map((n, i) => [n, i + 1]),
);

// Ad-hoc prefs not in PREFS but written by the seeder. Each entry includes
// its target namespace so we can split prefs across the meshcore /
// lua_storage namespaces.
interface AdHocDef extends PrefDef {
    namespace: string;
}

const AD_HOC: AdHocDef[] = [
    // Onboarding sentinel: lua_storage::onboarded = "1" makes the device
    // skip the on-device onboarding wizard.
    { namespace: NS_LUA_STORAGE, key: "onboarded", type: "string", default: "1",
      description: "Onboarding-completion sentinel" },
    // Timezone string (POSIX TZ). Boot reads tz_posix on every boot
    // (lua/boot.lua:103) and calls ez.system.set_timezone.
    { namespace: NS_LUA_STORAGE, key: "tz_posix", type: "string", default: "UTC0",
      description: "POSIX TZ string applied at boot" },
    // Suppresses on-device migration replays for a known-fresh install.
    { namespace: NS_LUA_STORAGE, key: "migrated_ver", type: "string", default: "",
      description: "Last-migrated firmware version" },
    // Node display name, persisted by identity.cpp as meshcore::nodename.
    { namespace: NS_MESHCORE, key: "nodename", type: "string", default: "",
      description: "Mesh node display name" },
];

const AD_HOC_BY_KEY: Map<string, AdHocDef> = new Map(
    AD_HOC.map((p) => [p.key, p]),
);

export type SeedValues = Record<string, string | number>;

export interface EncodeOptions {
    strict?: boolean;
}

interface PendingEntry {
    namespace: string;
    key: string;
    type: PrefType;
    value: string | number;
}

class PageWriter {
    readonly buf: Uint8Array;
    readonly view: DataView;
    readonly stateBits = new Uint8Array(BITMAP_SIZE).fill(0xff);
    private next = 0;
    private full = false;

    constructor(buf: Uint8Array, offset: number, readonly seq: number) {
        this.buf = buf.subarray(offset, offset + PAGE_SIZE);
        this.view = new DataView(
            this.buf.buffer,
            this.buf.byteOffset,
            this.buf.byteLength,
        );
    }

    remaining(): number {
        return this.full ? 0 : ENTRIES_PER_PAGE - this.next;
    }

    reserve(count: number): number {
        if (this.full || this.next + count > ENTRIES_PER_PAGE) {
            throw new Error("page full");
        }
        const start = this.next;
        this.next += count;
        for (let i = 0; i < count; i++) {
            const idx = start + i;
            const byte = idx >> 2;
            const bitOffset = (idx & 3) * 2;
            // Default state is 11 (EMPTY); set bit pair to 10 (WRITTEN) by
            // clearing the low bit of the pair.
            this.stateBits[byte] &= ~(1 << bitOffset) & 0xff;
        }
        return start;
    }

    entryOffset(slot: number): number {
        return HEADER_SIZE + BITMAP_SIZE + slot * ENTRY_SIZE;
    }

    finalize() {
        this.full = true;
        for (let i = 0; i < BITMAP_SIZE; i++) {
            this.buf[HEADER_SIZE + i] = this.stateBits[i];
        }
        this.view.setUint32(0, PAGE_STATE_ACTIVE, true);
        this.view.setUint32(4, this.seq, true);
        this.buf[8] = PAGE_VERSION_V2;
        for (let i = 9; i < 28; i++) this.buf[i] = 0xff;
        const headerCrc = crc32(this.buf.subarray(4, 28));
        this.view.setUint32(28, headerCrc, true);
    }
}

function writeKey(out: Uint8Array, offset: number, key: string) {
    if (key.length > 15) throw new Error(`NVS key too long: ${key}`);
    for (let i = 0; i < 16; i++) out[offset + i] = 0;
    for (let i = 0; i < key.length; i++) {
        const code = key.charCodeAt(i);
        if (code > 0x7f) throw new Error(`NVS key must be ASCII: ${key}`);
        out[offset + i] = code;
    }
}

function fillEntryHeader(
    out: Uint8Array,
    slotOffset: number,
    nsIndex: number,
    type: number,
    span: number,
    chunkIndex: number,
    key: string,
) {
    out[slotOffset + 0] = nsIndex;
    out[slotOffset + 1] = type;
    out[slotOffset + 2] = span;
    out[slotOffset + 3] = chunkIndex;
    writeKey(out, slotOffset + 8, key);
}

function computeAndWriteEntryCrc(out: Uint8Array, slotOffset: number) {
    const prefix = out.subarray(slotOffset, slotOffset + 4);
    const tail = out.subarray(slotOffset + 8, slotOffset + ENTRY_SIZE);
    const buf = new Uint8Array(prefix.length + tail.length);
    buf.set(prefix, 0);
    buf.set(tail, prefix.length);
    const c = crc32(buf);
    const view = new DataView(out.buffer, out.byteOffset + slotOffset + 4, 4);
    view.setUint32(0, c, true);
}

function setIntegerData(
    out: Uint8Array,
    dataOffset: number,
    type: PrefType,
    value: number,
) {
    for (let i = 0; i < 8; i++) out[dataOffset + i] = 0;
    const view = new DataView(out.buffer, out.byteOffset + dataOffset, 8);
    switch (type) {
        case "int8":   view.setInt8(0, value); break;
        case "uint8":  view.setUint8(0, value); break;
        case "int16":  view.setInt16(0, value, true); break;
        case "uint16": view.setUint16(0, value, true); break;
        case "int32":  view.setInt32(0, value, true); break;
        case "uint32": view.setUint32(0, value, true); break;
        case "int64":  view.setBigInt64(0, BigInt(value), true); break;
        case "uint64": view.setBigUint64(0, BigInt(value), true); break;
        default:
            throw new Error(`not an integer type: ${type}`);
    }
}

function asciiBytesWithNull(s: string): Uint8Array {
    const bytes = new Uint8Array(s.length + 1);
    for (let i = 0; i < s.length; i++) {
        const code = s.charCodeAt(i);
        if (code > 0xff) {
            throw new Error(
                `NVS string must be 8-bit (Latin-1); got U+${code.toString(16)}`,
            );
        }
        bytes[i] = code;
    }
    bytes[s.length] = 0;
    return bytes;
}

function writeNamespaceEntry(page: PageWriter, name: string, index: number) {
    const slot = page.reserve(1);
    const off = page.entryOffset(slot);
    fillEntryHeader(page.buf, off, 0, T_U8, 1, 0xff, name);
    setIntegerData(page.buf, off + 24, "uint8", index);
    computeAndWriteEntryCrc(page.buf, off);
}

function writePrimitiveEntry(
    page: PageWriter,
    nsIndex: number,
    key: string,
    type: PrefType,
    value: number,
) {
    const slot = page.reserve(1);
    const off = page.entryOffset(slot);
    fillEntryHeader(page.buf, off, nsIndex, TYPE_FOR[type], 1, 0xff, key);
    setIntegerData(page.buf, off + 24, type, value);
    computeAndWriteEntryCrc(page.buf, off);
}

function writeStringEntry(
    page: PageWriter,
    nsIndex: number,
    key: string,
    value: string,
) {
    const bytes = asciiBytesWithNull(value);
    const dataSize = bytes.length;
    const dataSlots = Math.ceil(dataSize / ENTRY_SIZE);
    const totalSpan = 1 + dataSlots;
    if (totalSpan > ENTRIES_PER_PAGE) {
        throw new Error(`string too long for one NVS page: ${key}`);
    }
    if (page.remaining() < totalSpan) {
        throw new Error(`page full while writing string ${key}`);
    }
    const headerSlot = page.reserve(totalSpan);
    const headerOff = page.entryOffset(headerSlot);
    fillEntryHeader(page.buf, headerOff, nsIndex, T_SZ, totalSpan, 0xff, key);
    const view = new DataView(page.buf.buffer, page.buf.byteOffset + headerOff + 24, 8);
    view.setUint16(0, dataSize, true);
    view.setUint16(2, 0xffff, true);
    view.setUint32(4, crc32(bytes), true);
    computeAndWriteEntryCrc(page.buf, headerOff);

    for (let i = 0; i < dataSlots; i++) {
        const slotOff = page.entryOffset(headerSlot + 1 + i);
        for (let j = 0; j < ENTRY_SIZE; j++) page.buf[slotOff + j] = 0xff;
        const start = i * ENTRY_SIZE;
        const chunk = bytes.subarray(start, Math.min(start + ENTRY_SIZE, dataSize));
        for (let j = 0; j < chunk.length; j++) page.buf[slotOff + j] = chunk[j];
    }
}

function lookupDef(key: string): { ns: string; def: PrefDef } | undefined {
    const adHoc = AD_HOC_BY_KEY.get(key);
    if (adHoc) return { ns: adHoc.namespace, def: adHoc };
    const reg = PREF_BY_KEY.get(key);
    if (reg) return { ns: NS_LUA_STORAGE, def: reg };
    return undefined;
}

function coerceValue(def: PrefDef, raw: string | number): string | number {
    if (def.type === "string" || def.type === "blob") {
        return typeof raw === "string" ? raw : String(raw);
    }
    const n = typeof raw === "number" ? raw : Number(raw);
    if (!Number.isFinite(n)) {
        throw new Error(`pref ${def.key}: expected number, got ${JSON.stringify(raw)}`);
    }
    if (def.min !== undefined && n < def.min) {
        throw new Error(`pref ${def.key}: value ${n} below min ${def.min}`);
    }
    if (def.max !== undefined && n > def.max) {
        throw new Error(`pref ${def.key}: value ${n} above max ${def.max}`);
    }
    return Math.trunc(n);
}

/**
 * Encode a 20 KB NVS partition image containing the supplied seed values.
 * Caller passes a flat dict keyed by NVS key. Keys that live in the
 * `meshcore` namespace (e.g. `nodename`) are routed there automatically.
 */
export function encodeNvsImage(
    values: SeedValues,
    opts: EncodeOptions = {},
): Uint8Array {
    const out = new Uint8Array(PARTITION_SIZE);
    out.fill(0xff);

    const page = new PageWriter(out, 0, 0);

    // Declare every namespace up front so per-entry indices are stable
    // regardless of which keys are actually included this run.
    for (const ns of NAMESPACES) {
        writeNamespaceEntry(page, ns, NS_INDEX[ns]);
    }

    const entries: PendingEntry[] = [];
    for (const key of Object.keys(values).sort()) {
        const raw = values[key];
        const found = lookupDef(key);
        if (!found) {
            if (opts.strict !== false) {
                throw new Error(`unknown pref key: ${key}`);
            }
            continue;
        }
        const coerced = coerceValue(found.def, raw);
        // Skip empty strings -- they'd take a slot but the device treats a
        // missing key the same way (get_pref returns the supplied default).
        if (found.def.type === "string" && coerced === "") continue;
        entries.push({
            namespace: found.ns,
            key,
            type: found.def.type,
            value: coerced,
        });
    }

    for (const e of entries) {
        const nsIdx = NS_INDEX[e.namespace];
        if (e.type === "string" || e.type === "blob") {
            writeStringEntry(page, nsIdx, e.key, e.value as string);
        } else {
            writePrimitiveEntry(page, nsIdx, e.key, e.type, e.value as number);
        }
    }

    page.finalize();
    return out;
}

export const __internal = {
    NS_INDEX,
    PAGE_SIZE,
    PARTITION_SIZE,
    AD_HOC,
    NAMESPACES,
};
