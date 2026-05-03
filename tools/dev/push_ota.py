#!/usr/bin/env python3
"""
Push a firmware.bin to a T-Deck running the dev OTA server.

Usage:
    python tools/dev/push_ota.py <device-ip> <token> [firmware.bin]

Defaults to .pio/build/t-deck-plus/firmware.bin if no path is given.

Enable the server on the device first: Settings -> System -> Dev OTA -> toggle on.
The 6-character token shown there is what you pass on the command line.

The script streams the file to POST /ota with Authorization: Bearer <token>.
The device writes bytes straight into the inactive OTA slot as they arrive,
then validates the image. On success, the slot becomes the boot partition for
the next reboot. The new image is left in "pending verify" state until
boot.lua calls ez.ota.mark_valid() a few seconds after a clean boot --
crash before that happens and the bootloader auto-reverts.

Dependencies: stdlib only (Python 3.6+).
"""

import argparse
import http.client
import os
import sys
import time


# Use a chunk size that fits comfortably in one TCP segment to keep the
# device-side WebServer upload callback firing at a steady cadence
# (defaults to ~1.4 KiB per UPLOAD_FILE_WRITE).
CHUNK = 4096


def push(host: str, port: int, token: str, path: str,
         timeout: float = 60.0, rate_kbps: float = 0.0) -> int:
    if not os.path.exists(path):
        print(f"error: firmware not found: {path}", file=sys.stderr)
        return 2

    size = os.path.getsize(path)
    if size == 0:
        print(f"error: empty file: {path}", file=sys.stderr)
        return 2

    print(f"Pushing {path} ({size:,} bytes) to {host}:{port}")

    # Raw application/octet-stream POST. The device runs ESPAsyncWebServer
    # which routes the body straight to its onRequestBody callback per
    # chunk -- the firmware bytes go directly into Update.write with no
    # multipart envelope and no per-byte parsing.
    content_length = size

    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.putrequest("POST", "/ota")
        conn.putheader("Authorization", f"Bearer {token}")
        conn.putheader("Content-Type", "application/octet-stream")
        conn.putheader("Content-Length", str(content_length))
        # Tell the device exactly how many firmware bytes to expect so
        # it can erase only the sectors it'll write instead of full-
        # partition erasing up front. Saves ~5 s of flash-controller
        # monopolisation that otherwise kills the WiFi link mid-upload.
        conn.putheader("X-Firmware-Size", str(size))
        conn.endheaders()

        sent = 0
        start = time.time()
        last_print = 0.0
        # Throttle: when --rate is set, sleep just enough between
        # chunk sends to keep the average within the cap. Helps when
        # the device's WiFi link is flaky and the radio falls behind
        # at full-speed pushes (manifesting as a watchdog reset
        # mid-upload). 0 means no throttling.
        chunk_interval = (CHUNK / 1024.0) / rate_kbps if rate_kbps > 0 else 0.0
        with open(path, "rb") as f:
            while True:
                buf = f.read(CHUNK)
                if not buf:
                    break
                t_before = time.time()
                conn.send(buf)
                sent += len(buf)
                if chunk_interval > 0:
                    slept = time.time() - t_before
                    if slept < chunk_interval:
                        time.sleep(chunk_interval - slept)

                # Progress on stderr at most ~5x/sec so output stays readable.
                now = time.time()
                if now - last_print > 0.2 or sent == size:
                    last_print = now
                    pct = 100.0 * sent / size
                    elapsed = now - start
                    rate = sent / elapsed if elapsed > 0 else 0
                    eta = (size - sent) / rate if rate > 0 else 0
                    sys.stderr.write(
                        f"\r  {sent:>9,} / {size:,} ({pct:5.1f}%)  "
                        f"{rate / 1024:6.1f} KB/s  ETA {eta:4.1f}s"
                    )
                    sys.stderr.flush()
        sys.stderr.write("\n")

        # Wait for the device to finish writing + validating. The
        # response only comes after Update.end() returns, which can take
        # a few seconds on a 2 MB image as the partition is verified.
        print("Waiting for device to validate...")
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", errors="replace")

        if resp.status == 200:
            print(f"OK: {body}")
            print("Reboot the device to boot into the new firmware.")
            return 0
        elif resp.status == 401:
            print(f"error: auth failed (401). Wrong token?\n{body}", file=sys.stderr)
            return 3
        else:
            print(f"error: HTTP {resp.status}: {body}", file=sys.stderr)
            return 4
    except (http.client.HTTPException, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 5
    finally:
        conn.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host", help="device IP address (shown on the Dev OTA screen)")
    ap.add_argument("token", help="6-character bearer token shown on the Dev OTA screen")
    ap.add_argument("firmware", nargs="?",
                    default=".pio/build/t-deck-plus/firmware.bin",
                    help="path to firmware.bin (default: .pio/build/t-deck-plus/firmware.bin)")
    ap.add_argument("--port", type=int, default=8080,
                    help="device OTA port (default 8080)")
    ap.add_argument("--timeout", type=float, default=60.0,
                    help="socket timeout in seconds (default 60)")
    ap.add_argument("--rate", type=float, default=0.0,
                    metavar="KB/s",
                    help="cap upload rate (e.g. 40). 0 = unthrottled. "
                         "Use when full-speed pushes wedge the device WiFi.")
    args = ap.parse_args()

    sys.exit(push(args.host, args.port, args.token, args.firmware,
                  args.timeout, args.rate))


if __name__ == "__main__":
    main()
