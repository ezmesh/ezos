// Esptool-js wrapper. Drives the actual flash from inside the browser via
// Web Serial. We do this in a separate file so the rest of the UI never
// has to know the esptool-js types directly.

import { ESPLoader, Transport } from "esptool-js";

// NVS partition offset, per partitions_16MB.csv.
export const NVS_OFFSET = 0x9000;

// Offset of the merged firmware-full.bin (bootloader at 0x0000).
export const FULL_OFFSET = 0x0000;

// Offset of the app-only firmware.bin (app0 partition).
export const APP_OFFSET = 0x10000;

export interface FlashFile {
    /** Byte offset in flash. */
    address: number;
    /** Raw bytes to write. */
    data: Uint8Array;
    /** Human-friendly label for progress reporting. */
    label: string;
}

export interface FlashOptions {
    files: FlashFile[];
    onLog: (line: string) => void;
    onProgress: (label: string, written: number, total: number) => void;
    /**
     * If true, erase the chip before writing. Use this on a fresh device or
     * when the user explicitly asks for a factory reset.
     */
    eraseAll?: boolean;
}

function uint8ToBinaryString(buf: Uint8Array): string {
    // esptool-js expects a string where each char is a byte (0-255).
    // String.fromCharCode in a chunked loop avoids the call-stack limit
    // that the spread operator would hit on big buffers.
    let out = "";
    const CHUNK = 0x8000;
    for (let i = 0; i < buf.length; i += CHUNK) {
        out += String.fromCharCode.apply(
            null,
            Array.from(buf.subarray(i, Math.min(i + CHUNK, buf.length))),
        );
    }
    return out;
}

export async function requestPort(): Promise<SerialPort> {
    if (!("serial" in navigator)) {
        throw new Error(
            "Web Serial is not available in this browser. Open this page in Chrome, Edge, or another Chromium-based browser on desktop.",
        );
    }
    return await navigator.serial.requestPort({ filters: [] });
}

export class Flasher {
    private port: SerialPort | null = null;
    private transport: Transport | null = null;
    private loader: ESPLoader | null = null;

    async connect(opts: { onLog: (s: string) => void }): Promise<{ chip: string }> {
        this.port = await requestPort();
        this.transport = new Transport(this.port, true);

        const terminal = {
            clean() {},
            writeLine: (data: string) => opts.onLog(data),
            write: (data: string) => opts.onLog(data),
        };

        this.loader = new ESPLoader({
            transport: this.transport,
            baudrate: 921600,
            romBaudrate: 115200,
            terminal,
        } as any); // ESPLoader's constructor type drifts between releases.

        const chip = await this.loader.main();
        return { chip };
    }

    async flash(opts: FlashOptions): Promise<void> {
        if (!this.loader) throw new Error("not connected");
        const fileArray = opts.files.map((f) => ({
            data: uint8ToBinaryString(f.data),
            address: f.address,
        }));

        if (opts.eraseAll) {
            opts.onLog("Erasing flash...");
            await this.loader.eraseFlash();
        }

        await this.loader.writeFlash({
            fileArray,
            flashSize: "keep",
            flashMode: "keep",
            flashFreq: "keep",
            eraseAll: false,
            compress: true,
            reportProgress: (fileIndex: number, written: number, total: number) => {
                const label = opts.files[fileIndex]?.label ?? `image #${fileIndex}`;
                opts.onProgress(label, written, total);
            },
            calculateMD5Hash: () => "",
        } as any);
    }

    async hardReset(): Promise<void> {
        if (!this.transport) return;
        await this.transport.setDTR(false);
        await new Promise((r) => setTimeout(r, 100));
        await this.transport.setDTR(true);
    }

    async disconnect(): Promise<void> {
        try {
            await this.transport?.disconnect();
        } catch {
            // ignore
        }
        this.transport = null;
        this.loader = null;
        this.port = null;
    }
}

export async function downloadBinary(
    url: string,
    onProgress?: (received: number, total: number) => void,
): Promise<Uint8Array> {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`download failed: ${res.status} ${res.statusText}`);
    const total = Number(res.headers.get("Content-Length") ?? 0);
    if (!res.body || !onProgress) {
        return new Uint8Array(await res.arrayBuffer());
    }
    const reader = res.body.getReader();
    const chunks: Uint8Array[] = [];
    let received = 0;
    while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        received += value.length;
        onProgress(received, total);
    }
    const out = new Uint8Array(received);
    let off = 0;
    for (const c of chunks) {
        out.set(c, off);
        off += c.length;
    }
    return out;
}
