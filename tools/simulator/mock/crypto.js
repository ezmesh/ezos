/**
 * Crypto mock module
 * Simple synchronous implementations for simulator
 */

// Helper: convert string to ArrayBuffer
function str2ab(str) {
    const buf = new ArrayBuffer(str.length);
    const bufView = new Uint8Array(buf);
    for (let i = 0; i < str.length; i++) {
        bufView[i] = str.charCodeAt(i);
    }
    return buf;
}

// Helper: convert ArrayBuffer to string
function ab2str(buf) {
    return String.fromCharCode.apply(null, new Uint8Array(buf));
}

// Helper: convert ArrayBuffer to hex
function ab2hex(buf) {
    return Array.from(new Uint8Array(buf))
        .map(b => b.toString(16).padStart(2, '0'))
        .join('');
}

// Helper: convert hex to ArrayBuffer
function hex2ab(hex) {
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < bytes.length; i++) {
        bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
    }
    return bytes.buffer;
}

// Simple hash function for mocking
function simpleHash(data, length) {
    let hash = 0x811c9dc5; // FNV offset basis
    for (let i = 0; i < data.length; i++) {
        hash ^= data.charCodeAt(i);
        hash = Math.imul(hash, 0x01000193); // FNV prime
    }

    // Generate required number of bytes
    let result = '';
    for (let i = 0; i < length; i++) {
        hash = Math.imul(hash, 0x01000193) ^ i;
        result += String.fromCharCode(Math.abs(hash) & 0xFF);
    }
    return result;
}

export function createCryptoModule() {
    const module = {
        // SHA-256 hash (mock - returns 32 bytes)
        sha256(data) {
            return simpleHash(data, 32);
        },

        // SHA-512 hash (mock - returns 64 bytes)
        sha512(data) {
            return simpleHash(data, 64);
        },

        // Generate random bytes
        random_bytes(length) {
            const array = new Uint8Array(length);
            crypto.getRandomValues(array);
            return ab2str(array.buffer);
        },

        // Convert bytes to hex string
        bytes_to_hex(data) {
            return ab2hex(str2ab(data));
        },

        // Convert hex string to bytes
        hex_to_bytes(hex) {
            return ab2str(hex2ab(hex));
        },

        // Base64 encode
        base64_encode(data) {
            try {
                return btoa(data);
            } catch (e) {
                const bytes = new Uint8Array(data.length);
                for (let i = 0; i < data.length; i++) {
                    bytes[i] = data.charCodeAt(i);
                }
                let binary = '';
                for (let i = 0; i < bytes.length; i++) {
                    binary += String.fromCharCode(bytes[i]);
                }
                return btoa(binary);
            }
        },

        // Base64 decode
        base64_decode(str) {
            try {
                return atob(str);
            } catch (e) {
                console.error('[Crypto] Base64 decode error:', e);
                return null;
            }
        },

        // AES-128 ECB encrypt (simple XOR mock for simulator)
        aes128_ecb_encrypt(key, data) {
            try {
                const keyStr = typeof key === 'string' ? key : ab2str(key);
                const dataStr = typeof data === 'string' ? data : ab2str(data);

                // Pad data to 16-byte boundary (PKCS7)
                const padLen = 16 - (dataStr.length % 16);
                const padded = dataStr + String.fromCharCode(padLen).repeat(padLen);

                // Simple XOR with key (mock encryption)
                let result = '';
                for (let i = 0; i < padded.length; i++) {
                    const keyByte = keyStr.charCodeAt(i % keyStr.length);
                    const dataByte = padded.charCodeAt(i);
                    result += String.fromCharCode(dataByte ^ keyByte);
                }
                return result;
            } catch (e) {
                console.error('[Crypto] AES encrypt error:', e);
                return null;
            }
        },

        // AES-128 ECB decrypt (simple XOR mock for simulator)
        aes128_ecb_decrypt(key, data) {
            try {
                const keyStr = typeof key === 'string' ? key : ab2str(key);
                const dataStr = typeof data === 'string' ? data : ab2str(data);

                // Simple XOR with key (mock decryption)
                let result = '';
                for (let i = 0; i < dataStr.length; i++) {
                    const keyByte = keyStr.charCodeAt(i % keyStr.length);
                    const dataByte = dataStr.charCodeAt(i);
                    result += String.fromCharCode(dataByte ^ keyByte);
                }

                // Remove PKCS7 padding
                if (result.length > 0) {
                    const padLen = result.charCodeAt(result.length - 1);
                    if (padLen > 0 && padLen <= 16) {
                        result = result.slice(0, -padLen);
                    }
                }
                return result;
            } catch (e) {
                console.error('[Crypto] AES decrypt error:', e);
                return null;
            }
        },

        // HMAC-SHA256 (mock - returns 32 bytes)
        hmac_sha256(key, data) {
            try {
                const keyStr = typeof key === 'string' ? key : ab2str(key);
                const dataStr = typeof data === 'string' ? data : ab2str(data);
                // Combine key and data for hash
                return simpleHash(keyStr + dataStr, 32);
            } catch (e) {
                console.error('[Crypto] HMAC error:', e);
                return null;
            }
        },

        // Generate UUID
        uuid() {
            return crypto.randomUUID();
        },

        // CRC32
        crc32(data) {
            let crc = 0xFFFFFFFF;
            const table = [];

            // Build CRC table
            for (let i = 0; i < 256; i++) {
                let c = i;
                for (let j = 0; j < 8; j++) {
                    c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
                }
                table[i] = c;
            }

            // Calculate CRC
            for (let i = 0; i < data.length; i++) {
                crc = table[(crc ^ data.charCodeAt(i)) & 0xFF] ^ (crc >>> 8);
            }

            return (crc ^ 0xFFFFFFFF) >>> 0;
        },

        // Derive 16-byte channel key from password/name using SHA256
        derive_channel_key(input) {
            const hash = simpleHash(input, 32);
            return hash.substring(0, 16); // First 16 bytes
        },

        // Compute channel hash from key (SHA256(key)[0])
        channel_hash(key) {
            const hash = simpleHash(key, 32);
            return hash.charCodeAt(0);
        },

        // Get the well-known #Public channel key (mock - returns 16 bytes)
        public_channel_key() {
            // This is the SHA256 of "#Public" truncated to 16 bytes
            return simpleHash('#Public', 16);
        },
    };

    return module;
}
