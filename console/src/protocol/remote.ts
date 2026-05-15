// Tiny client for the ezOS remote-control protocol (cmds 0x01-0x0B).
// Mirrors tools/remote/ez_remote.py; only the commands we actually call from
// the console are implemented. Used for optional post-flash verification
// (e.g. "read the firmware version we just installed"); the main config
// path goes through the NVS image, not this protocol.
//
// Frame format:
//   request:  [CMD:1][LEN:2 LE][PAYLOAD]
//   response: [STATUS:1][LEN:4 LE][DATA]

const STATUS_OK = 0x00;

const CMD_PING = 0x01;
const CMD_LUA_EXEC = 0x07;

export class RemoteClient {
    constructor(
        private readonly writer: WritableStreamDefaultWriter<Uint8Array>,
        private readonly reader: ReadableStreamDefaultReader<Uint8Array>,
    ) {}

    async ping(timeoutMs = 1000): Promise<boolean> {
        try {
            const res = await this.send(CMD_PING, new Uint8Array(0), timeoutMs);
            return new TextDecoder().decode(res).trim() === "PONG";
        } catch {
            return false;
        }
    }

    async luaExec(code: string, timeoutMs = 5000): Promise<string> {
        const payload = new TextEncoder().encode(code);
        const res = await this.send(CMD_LUA_EXEC, payload, timeoutMs);
        return new TextDecoder().decode(res);
    }

    private async send(
        cmd: number,
        payload: Uint8Array,
        timeoutMs: number,
    ): Promise<Uint8Array> {
        const frame = new Uint8Array(3 + payload.length);
        frame[0] = cmd;
        frame[1] = payload.length & 0xff;
        frame[2] = (payload.length >> 8) & 0xff;
        frame.set(payload, 3);
        await this.writer.write(frame);

        const header = await this.readExactly(5, timeoutMs);
        const status = header[0];
        const len =
            header[1] | (header[2] << 8) | (header[3] << 16) | (header[4] << 24);
        const data = len > 0 ? await this.readExactly(len, timeoutMs) : new Uint8Array(0);
        if (status !== STATUS_OK) {
            throw new Error(
                `remote returned status ${status}: ${new TextDecoder().decode(data)}`,
            );
        }
        return data;
    }

    private readBuffer = new Uint8Array(0);

    private async readExactly(n: number, timeoutMs: number): Promise<Uint8Array> {
        const deadline = Date.now() + timeoutMs;
        while (this.readBuffer.length < n) {
            const remaining = deadline - Date.now();
            if (remaining <= 0) throw new Error("read timeout");
            const { value, done } = await this.readWithTimeout(remaining);
            if (done) throw new Error("stream closed");
            if (value) {
                const merged = new Uint8Array(this.readBuffer.length + value.length);
                merged.set(this.readBuffer, 0);
                merged.set(value, this.readBuffer.length);
                this.readBuffer = merged;
            }
        }
        const out = this.readBuffer.subarray(0, n);
        this.readBuffer = this.readBuffer.subarray(n);
        return out;
    }

    private async readWithTimeout(timeoutMs: number) {
        return await Promise.race([
            this.reader.read(),
            new Promise<{ value?: Uint8Array; done: boolean }>((_, rej) =>
                setTimeout(() => rej(new Error("read timeout")), timeoutMs),
            ),
        ]);
    }
}
