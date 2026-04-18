/**
 * Map archive uploader for the simulator.
 *
 * Lets the user drop a `.tdmap` file onto the page (or pick one via a file input)
 * and registers it as an in-memory SD file at `/sd/maps/<filename>`. The forthcoming
 * `lua/services/map_archive.lua` reads through `ez.storage.read_bytes`, so no Lua
 * code needs to know this path exists — dropped archives shadow the default
 * `/sd/maps/world.tdmap` mapping automatically.
 */

import { registerUploadedFile } from './storage.js';

// Minimal v4 header sniff so we can reject obviously-broken drops early.
const TDMAP_MAGIC = new Uint8Array([0x54, 0x44, 0x4D, 0x41, 0x50, 0x00]);
const TDMAP_VERSION = 4;

function looksLikeTdmap(bytes) {
    if (bytes.length < 7) return false;
    for (let i = 0; i < TDMAP_MAGIC.length; i++) {
        if (bytes[i] !== TDMAP_MAGIC[i]) return false;
    }
    return bytes[6] === TDMAP_VERSION;
}

function defaultMountPath(filename) {
    const base = filename.replace(/^.*[\\/]/, '').replace(/\s+/g, '_');
    return `/sd/maps/${base}`;
}

/**
 * Attach drop-zone + file-picker handlers.
 *
 * @param {Object} opts
 * @param {HTMLElement} opts.dropTarget   Element that receives dragover/drop (usually document.body).
 * @param {HTMLInputElement} [opts.fileInput]  Optional <input type="file"> for click-to-upload.
 * @param {string} [opts.mountPath]  Override mount path (defaults to `/sd/maps/<filename>`).
 *                                   Also controls which archive the Lua side sees — pass
 *                                   `/sd/maps/world.tdmap` to shadow the default.
 * @param {(path: string, bytes: Uint8Array) => void} [opts.onLoaded]
 * @param {(message: string) => void} [opts.onError]
 */
export function attachMapUploader(opts) {
    const {
        dropTarget,
        fileInput,
        mountPath,
        onLoaded,
        onError,
    } = opts;

    if (!dropTarget) throw new Error('attachMapUploader: dropTarget is required');

    async function handleFile(file) {
        if (!file) return;
        if (!file.name.toLowerCase().endsWith('.tdmap')) {
            onError?.(`Ignored ${file.name}: not a .tdmap file`);
            return;
        }
        try {
            const buf = await file.arrayBuffer();
            const bytes = new Uint8Array(buf);
            if (!looksLikeTdmap(bytes)) {
                onError?.(`${file.name} is not a valid TDMAP v${TDMAP_VERSION} archive`);
                return;
            }
            // Default mount path shadows world.tdmap so screens pick it up without hints.
            const path = mountPath || '/sd/maps/world.tdmap';
            registerUploadedFile(path, bytes);
            // Also register under the original filename so code that opens by name works.
            const namedPath = defaultMountPath(file.name);
            if (namedPath !== path) {
                registerUploadedFile(namedPath, bytes);
            }
            onLoaded?.(path, bytes);
        } catch (e) {
            onError?.(`Failed to read ${file.name}: ${e.message}`);
        }
    }

    dropTarget.addEventListener('dragover', (e) => {
        e.preventDefault();
        e.dataTransfer.dropEffect = 'copy';
    });

    dropTarget.addEventListener('drop', async (e) => {
        e.preventDefault();
        const file = e.dataTransfer?.files?.[0];
        if (file) await handleFile(file);
    });

    if (fileInput) {
        fileInput.addEventListener('change', async (e) => {
            const file = e.target.files?.[0];
            if (file) await handleFile(file);
        });
    }
}
