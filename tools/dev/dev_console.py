#!/usr/bin/env python3
"""
HTTP dev console for the T-Deck. Mirrors ez_remote.py over WiFi.

Enable the dev server on the device (Settings -> System -> Dev OTA),
note the IP and 6-character token shown there, then:

    python tools/dev/dev_console.py 192.168.1.42 K3F9-2X --info
    python tools/dev/dev_console.py 192.168.1.42 K3F9-2X -s screen.png
    python tools/dev/dev_console.py 192.168.1.42 K3F9-2X -e 'return collectgarbage("count")'
    python tools/dev/dev_console.py 192.168.1.42 K3F9-2X -k a
    python tools/dev/dev_console.py 192.168.1.42 K3F9-2X -k enter
    python tools/dev/dev_console.py 192.168.1.42 K3F9-2X --flash firmware.bin

Stdlib only -- the screenshot endpoint returns BMP, which the script
converts to PNG locally if Pillow is installed (otherwise saved as .bmp).
"""

import argparse
import http.client
import json
import os
import sys
import time

DEFAULT_PORT = 8080
CHUNK = 4096

SPECIAL_KEYS = {
    "up", "down", "left", "right",
    "enter", "escape", "tab", "backspace", "delete",
    "home", "end",
}


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

class DevHTTPError(RuntimeError):
    pass


def _request(host, port, method, path, token, *, body=None, headers=None,
             timeout=30.0):
    h = {"Authorization": f"Bearer {token}"}
    if headers:
        h.update(headers)
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request(method, path, body=body, headers=h)
        resp = conn.getresponse()
        data = resp.read()
        if resp.status == 401:
            raise DevHTTPError(f"401 unauthorized -- bad or missing token")
        return resp.status, dict(resp.getheaders()), data
    finally:
        conn.close()


def _get_json(host, port, path, token):
    status, _, data = _request(host, port, "GET", path, token)
    if status != 200:
        raise DevHTTPError(f"GET {path} -> HTTP {status}: {data!r}")
    return json.loads(data)


def _post_json(host, port, path, token, payload):
    body = json.dumps(payload).encode("utf-8")
    status, _, data = _request(
        host, port, "POST", path, token,
        body=body,
        headers={"Content-Type": "application/json"},
    )
    if status not in (200, 400, 500):
        raise DevHTTPError(f"POST {path} -> HTTP {status}: {data!r}")
    return status, json.loads(data)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_info(args):
    info = _get_json(args.host, args.port, "/info", args.token)
    print(json.dumps(info, indent=2))
    return 0


def cmd_logs(args):
    status, _, data = _request(args.host, args.port, "GET", "/logs",
                               args.token, timeout=15.0)
    if status != 200:
        print(f"error: HTTP {status}: {data!r}", file=sys.stderr)
        return 1
    sys.stdout.write(data.decode("utf-8", errors="replace"))
    if data and not data.endswith(b"\n"):
        sys.stdout.write("\n")
    return 0


def cmd_screenshot(args):
    status, _, data = _request(args.host, args.port, "GET", "/screen.bmp",
                               args.token, timeout=15.0)
    if status != 200:
        print(f"error: HTTP {status}: {data!r}", file=sys.stderr)
        return 1

    out = args.screenshot
    # Try to convert to PNG when Pillow is available -- BMP is fine for
    # debugging but a 230 KB file per snapshot adds up fast.
    try:
        from PIL import Image
        from io import BytesIO
        img = Image.open(BytesIO(data))
        if not out.lower().endswith(".png") and not out.lower().endswith(".bmp"):
            out += ".png"
        img.save(out)
    except ImportError:
        if not out.lower().endswith(".bmp"):
            out += ".bmp"
        with open(out, "wb") as f:
            f.write(data)
    print(f"saved {out} ({len(data):,} bytes)")
    return 0


def cmd_lua(args):
    status, result = _post_json_lua(args.host, args.port, args.token, args.exec)
    if status == 200 and result.get("ok"):
        # The result is whatever ez.storage.json_encode produced;
        # already-decoded into Python values by json.loads.
        r = result.get("result")
        if isinstance(r, (dict, list)):
            print(json.dumps(r, indent=2))
        else:
            print(r)
        return 0
    err = result.get("error", "?") if isinstance(result, dict) else str(result)
    print(f"error: {err}", file=sys.stderr)
    return 1


def _post_json_lua(host, port, token, code):
    # /lua wants the raw Lua snippet as the body; sending text/plain
    # (not form-urlencoded) so it lands in arg("plain") on the device.
    body = code.encode("utf-8")
    status, _, data = _request(
        host, port, "POST", "/lua", token,
        body=body,
        headers={"Content-Type": "text/plain"},
    )
    return status, json.loads(data) if data else {}


def cmd_key(args):
    key = args.key
    payload = {}
    if key.lower() in SPECIAL_KEYS:
        payload["special"] = key.lower()
    elif len(key) == 1:
        payload["char"] = key
    else:
        print(f"error: '{key}' is not a single char or known special key.",
              file=sys.stderr)
        print(f"  Known specials: {', '.join(sorted(SPECIAL_KEYS))}",
              file=sys.stderr)
        return 2

    if args.shift: payload["shift"] = True
    if args.ctrl:  payload["ctrl"]  = True
    if args.alt:   payload["alt"]   = True
    if args.fn:    payload["fn"]    = True

    status, result = _post_json(args.host, args.port, "/key", args.token, payload)
    if status == 200 and result.get("ok"):
        return 0
    print(f"error: {result.get('error', '?')}", file=sys.stderr)
    return 1


def cmd_flash(args):
    # Reuse the multipart upload logic from push_ota.py -- import lazily
    # so a missing path doesn't break the other subcommands.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from push_ota import push
    return push(args.host, args.port, args.token, args.flash, args.timeout)


# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("host", help="device IP")
    ap.add_argument("token", help="bearer token shown on Dev OTA screen")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT,
                    help=f"device port (default {DEFAULT_PORT})")
    ap.add_argument("--timeout", type=float, default=60.0,
                    help="socket timeout seconds (default 60)")

    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--info", action="store_true",
                   help="GET /info -- partition, heap, wifi, screen")
    g.add_argument("--logs", action="store_true",
                   help="GET /logs -- recent in-memory log lines")
    g.add_argument("-s", "--screenshot", metavar="OUT",
                   help="capture current frame; saves PNG (if Pillow) or BMP")
    g.add_argument("-e", "--exec", metavar="CODE",
                   help="execute Lua snippet, print result")
    g.add_argument("-k", "--key", metavar="KEY",
                   help="inject keypress: single char or special name "
                        "(up/down/left/right/enter/escape/tab/backspace/"
                        "delete/home/end)")
    g.add_argument("--flash", metavar="FIRMWARE",
                   help="push firmware.bin via /ota")

    # Modifiers for --key.
    ap.add_argument("--shift", action="store_true")
    ap.add_argument("--ctrl",  action="store_true")
    ap.add_argument("--alt",   action="store_true")
    ap.add_argument("--fn",    action="store_true")

    args = ap.parse_args()

    try:
        if args.info:
            return cmd_info(args)
        if args.logs:
            return cmd_logs(args)
        if args.screenshot:
            return cmd_screenshot(args)
        if args.exec:
            return cmd_lua(args)
        if args.key:
            return cmd_key(args)
        if args.flash:
            return cmd_flash(args)
    except DevHTTPError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except (ConnectionError, OSError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
