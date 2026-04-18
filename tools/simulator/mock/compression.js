/**
 * ez.compression mock — mirrors the device's C binding (src/lua/bindings/
 * compression_bindings.cpp) so Lua code that calls ez.compression.inflate
 * works unchanged in the browser simulator.
 *
 * Device uses ROM miniz's tinfl_decompress_mem_to_mem. We use pako, loaded
 * via a <script> tag in index.html. If pako isn't available the module
 * still loads but inflate returns nil so callers get a clear error.
 */

export function createCompressionModule() {
    const pako = (typeof window !== 'undefined') ? window.pako : null;

    return {
        /**
         * @param data {string} Compressed input (binary string).
         * @param outSize {number} Expected decompressed size.
         * @param raw {boolean} True = raw DEFLATE, false/nil = zlib-wrapped.
         * @returns Decompressed binary string, or null on failure.
         */
        inflate(data, outSize, raw) {
            if (!pako) {
                console.warn('[compression] pako not loaded; inflate unavailable');
                return null;
            }
            try {
                // Wasmoon gives us a JS string; convert to a Uint8Array
                // preserving the low byte of each code unit (same trick the
                // simulator's storage mock uses for binary range reads).
                const input = typeof data === 'string'
                    ? Uint8Array.from(data, c => c.charCodeAt(0) & 0xFF)
                    : new Uint8Array(data);

                const out = raw ? pako.inflateRaw(input) : pako.inflate(input);

                if (outSize && out.length !== outSize) {
                    console.warn(
                        `[compression] inflate size mismatch: got ${out.length}, expected ${outSize}`);
                }

                // Back to a binary string for Lua.
                let result = '';
                const chunk = 8192;
                for (let i = 0; i < out.length; i += chunk) {
                    result += String.fromCharCode.apply(null, out.subarray(i, i + chunk));
                }
                return result;
            } catch (e) {
                console.error('[compression] inflate failed:', e.message);
                return null;
            }
        },
    };
}
