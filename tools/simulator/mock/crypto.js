/**
 * Crypto mock module
 * Uses Web Crypto API for cryptographic operations
 */

export function createCryptoModule() {
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

    const module = {
        // SHA-256 hash
        async sha256(data) {
            try {
                const buffer = typeof data === 'string' ? str2ab(data) : data;
                const hashBuffer = await crypto.subtle.digest('SHA-256', buffer);
                return ab2str(hashBuffer);
            } catch (e) {
                console.error('[Crypto] SHA-256 error:', e);
                return null;
            }
        },

        // SHA-512 hash
        async sha512(data) {
            try {
                const buffer = typeof data === 'string' ? str2ab(data) : data;
                const hashBuffer = await crypto.subtle.digest('SHA-512', buffer);
                return ab2str(hashBuffer);
            } catch (e) {
                console.error('[Crypto] SHA-512 error:', e);
                return null;
            }
        },

        // Generate random bytes
        random_bytes(length) {
            const array = new Uint8Array(length);
            crypto.getRandomValues(array);
            return ab2str(array.buffer);
        },

        // Convert bytes to hex string
        bytes_to_hex(data) {
            const buf = typeof data === 'string' ? str2ab(data) : data;
            return ab2hex(buf);
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
                // Handle binary data
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

        // AES-128 ECB encrypt (simplified - Web Crypto doesn't support ECB directly)
        async aes128_ecb_encrypt(key, data) {
            // Note: ECB mode is not recommended and not supported by Web Crypto
            // This is a simplified mock that uses AES-CBC with zero IV instead
            try {
                const keyBuffer = typeof key === 'string' ? str2ab(key) : key;
                const dataBuffer = typeof data === 'string' ? str2ab(data) : data;

                const cryptoKey = await crypto.subtle.importKey(
                    'raw',
                    keyBuffer.slice(0, 16),
                    { name: 'AES-CBC' },
                    false,
                    ['encrypt']
                );

                // Pad data to 16-byte boundary
                const padded = new Uint8Array(Math.ceil(dataBuffer.byteLength / 16) * 16);
                padded.set(new Uint8Array(dataBuffer));

                const iv = new Uint8Array(16); // Zero IV for ECB-like behavior
                const encrypted = await crypto.subtle.encrypt(
                    { name: 'AES-CBC', iv },
                    cryptoKey,
                    padded
                );

                return ab2str(encrypted);
            } catch (e) {
                console.error('[Crypto] AES encrypt error:', e);
                return null;
            }
        },

        // AES-128 ECB decrypt
        async aes128_ecb_decrypt(key, data) {
            try {
                const keyBuffer = typeof key === 'string' ? str2ab(key) : key;
                const dataBuffer = typeof data === 'string' ? str2ab(data) : data;

                const cryptoKey = await crypto.subtle.importKey(
                    'raw',
                    keyBuffer.slice(0, 16),
                    { name: 'AES-CBC' },
                    false,
                    ['decrypt']
                );

                const iv = new Uint8Array(16);
                const decrypted = await crypto.subtle.decrypt(
                    { name: 'AES-CBC', iv },
                    cryptoKey,
                    dataBuffer
                );

                return ab2str(decrypted);
            } catch (e) {
                console.error('[Crypto] AES decrypt error:', e);
                return null;
            }
        },

        // HMAC-SHA256
        async hmac_sha256(key, data) {
            try {
                const keyBuffer = typeof key === 'string' ? str2ab(key) : key;
                const dataBuffer = typeof data === 'string' ? str2ab(data) : data;

                const cryptoKey = await crypto.subtle.importKey(
                    'raw',
                    keyBuffer,
                    { name: 'HMAC', hash: 'SHA-256' },
                    false,
                    ['sign']
                );

                const signature = await crypto.subtle.sign(
                    'HMAC',
                    cryptoKey,
                    dataBuffer
                );

                return ab2str(signature);
            } catch (e) {
                console.error('[Crypto] HMAC error:', e);
                return null;
            }
        },

        // Generate UUID
        uuid() {
            return crypto.randomUUID();
        },

        // CRC32 (simple implementation)
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
    };

    return module;
}
