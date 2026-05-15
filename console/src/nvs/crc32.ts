// CRC32 (IEEE 802.3 / zlib / ESP-IDF NVS variant).
// Polynomial 0xEDB88320 (reflected 0x04C11DB7), initial value 0xFFFFFFFF,
// final XOR 0xFFFFFFFF. Matches Python's zlib.crc32 and the value the
// firmware computes when validating NVS entries.

const TABLE = (() => {
    const t = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
        let c = i;
        for (let k = 0; k < 8; k++) {
            c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
        }
        t[i] = c >>> 0;
    }
    return t;
})();

export function crc32(buf: Uint8Array, init = 0xffffffff): number {
    let c = init >>> 0;
    for (let i = 0; i < buf.length; i++) {
        c = (TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8)) >>> 0;
    }
    return (c ^ 0xffffffff) >>> 0;
}
