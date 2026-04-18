#!/usr/bin/env python3
"""
ezOS Remote Control Client

A command-line tool for controlling ezOS over USB serial.
Supports screenshot capture, keyboard input injection, screen queries, log access,
and Lua code execution.

Usage:
    python ez_remote.py /dev/ttyACM0                    # Test connection (ping)
    python ez_remote.py /dev/ttyACM0 -s screenshot.png  # Take screenshot
    python ez_remote.py /dev/ttyACM0 -k a               # Send character 'a'
    python ez_remote.py /dev/ttyACM0 -k enter           # Send Enter key
    python ez_remote.py /dev/ttyACM0 --info             # Get screen info
    python ez_remote.py /dev/ttyACM0 --text             # Capture rendered text
    python ez_remote.py /dev/ttyACM0 --primitives       # Capture draw primitives
    python ez_remote.py /dev/ttyACM0 --logs             # Get buffered logs
    python ez_remote.py /dev/ttyACM0 --monitor          # Monitor serial output
    python ez_remote.py /dev/ttyACM0 -e "1+1"           # Execute Lua expression
    python ez_remote.py /dev/ttyACM0 -e "Debug.memory()" # Call debug function
"""

import serial
import struct
import argparse
import sys
import json


class EzRemote:
    """Client for T-Deck remote control protocol."""

    # Command codes
    CMD_PING = 0x01
    CMD_SCREENSHOT = 0x02
    CMD_KEY_CHAR = 0x03
    CMD_KEY_SPECIAL = 0x04
    CMD_SCREEN_INFO = 0x05
    CMD_WAIT_FRAME_TEXT = 0x06
    CMD_LUA_EXEC = 0x07
    CMD_WAIT_FRAME_PRIMITIVES = 0x08
    CMD_FILE_WRITE = 0x09
    CMD_FILE_READ = 0x0A
    CMD_WRITE_AT = 0x0B

    # Response status
    STATUS_OK = 0x00
    STATUS_ERROR = 0x01

    # Special key codes
    SPECIAL_KEYS = {
        'up': 0x01,
        'down': 0x02,
        'left': 0x03,
        'right': 0x04,
        'enter': 0x05,
        'escape': 0x06,
        'esc': 0x06,
        'tab': 0x07,
        'backspace': 0x08,
        'delete': 0x09,
        'home': 0x0A,
        'end': 0x0B,
    }

    # Modifier flags
    MOD_SHIFT = 0x01
    MOD_CTRL = 0x02
    MOD_ALT = 0x04
    MOD_FN = 0x08

    def __init__(self, port, baudrate=921600, timeout=5):
        """Open serial connection to T-Deck."""
        self.ser = serial.Serial(port, baudrate, timeout=timeout)
        # Flush any pending data
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()

    def close(self):
        """Close serial connection."""
        if self.ser and self.ser.is_open:
            self.ser.close()

    def send_command(self, cmd, payload=b''):
        """Send a command with optional payload."""
        # Clear any pending input (log output, noise) that could corrupt response parsing
        self.ser.reset_input_buffer()
        header = struct.pack('<BH', cmd, len(payload))
        data = header + payload
        # Pace large sends to avoid overrunning the ESP32's 256-byte serial RX buffer
        if len(data) > 256:
            import time
            CHUNK = 128
            for i in range(0, len(data), CHUNK):
                self.ser.write(data[i:i + CHUNK])
                time.sleep(0.015)
            self.ser.flush()
        else:
            self.ser.write(data)
            self.ser.flush()

    def read_response(self, max_payload=512 * 1024):
        """Read response from T-Deck, skipping non-protocol serial noise.

        Protocol: [STATUS:1][LEN:4 little-endian][DATA:LEN]

        Mesh traffic and debug prints can leak into the serial stream between
        the command and its response.  We scan byte-by-byte for a valid header
        (status 0x00 or 0x01 followed by a reasonable 4-byte length) while
        discarding everything else.
        """
        MAX_NOISE = 8192  # give up after this many noise bytes
        noise = 0

        while noise < MAX_NOISE:
            b = self.ser.read(1)
            if not b:
                raise TimeoutError("Timeout waiting for response")

            # --- #LOG# lines ------------------------------------------------
            if b == b'#':
                peek = self.ser.read(4)
                if peek == b'LOG#':
                    # consume until newline
                    while True:
                        ch = self.ser.read(1)
                        if not ch or ch == b'\n':
                            break
                    continue
                # Not a log marker — discard the 5 bytes as noise
                noise += 1 + len(peek)
                continue

            # --- Printable ASCII lines (mesh debug output) ------------------
            # Status bytes are 0x00 / 0x01 which are non-printable, so any
            # printable byte (0x20-0x7E) or common whitespace is noise.
            if 0x20 <= b[0] <= 0x7E or b[0] in (0x0A, 0x0D, 0x09):
                noise += 1
                continue

            # --- Potential response header ----------------------------------
            status = b[0]
            if status not in (0x00, 0x01):
                noise += 1
                continue

            len_bytes = self.ser.read(4)
            if len(len_bytes) < 4:
                raise TimeoutError("Timeout reading response length")

            length = struct.unpack('<I', len_bytes)[0]

            if length > max_payload:
                # Implausible length — was noise after all
                noise += 5
                continue

            # --- Read payload -----------------------------------------------
            data = bytearray()
            while len(data) < length:
                remaining = length - len(data)
                chunk = self.ser.read(min(remaining, 4096))
                if not chunk:
                    raise TimeoutError(
                        f"Timeout reading payload (got {len(data)}/{length})"
                    )
                data.extend(chunk)

            return status, bytes(data)

        raise TimeoutError(
            f"No valid response header found (skipped {MAX_NOISE} bytes of noise)"
        )

    def ping(self):
        """Test connection with ping command."""
        self.send_command(self.CMD_PING)
        status, data = self.read_response()
        return status == self.STATUS_OK and data == b'PONG'

    def screenshot(self):
        """Capture screenshot as BMP and return PIL Image."""
        try:
            from PIL import Image
            import io
        except ImportError:
            raise ImportError("PIL/Pillow required for screenshots: pip install Pillow")

        # BMP screenshot is ~230KB, needs longer timeout for serial transfer
        old_timeout = self.ser.timeout
        self.ser.timeout = max(old_timeout, 10)
        self.send_command(self.CMD_SCREENSHOT)
        status, data = self.read_response()
        self.ser.timeout = old_timeout

        if status != self.STATUS_OK:
            error_msg = data.decode('utf-8', errors='replace') if data else "Unknown error"
            raise RuntimeError(f"Screenshot failed: {error_msg}")

        # Device sends BMP data, PIL handles the decode
        return Image.open(io.BytesIO(data))

    def key(self, char=None, special=None, shift=False, ctrl=False, alt=False, fn=False):
        """Send a key press event."""
        modifiers = 0
        if shift:
            modifiers |= self.MOD_SHIFT
        if ctrl:
            modifiers |= self.MOD_CTRL
        if alt:
            modifiers |= self.MOD_ALT
        if fn:
            modifiers |= self.MOD_FN

        if char is not None:
            # Send character key
            payload = bytes([ord(char), modifiers])
            self.send_command(self.CMD_KEY_CHAR, payload)
        elif special is not None:
            # Send special key
            key_code = self.SPECIAL_KEYS.get(special.lower())
            if key_code is None:
                raise ValueError(f"Unknown special key: {special}")
            payload = bytes([key_code, modifiers])
            self.send_command(self.CMD_KEY_SPECIAL, payload)
        else:
            raise ValueError("Must specify either char or special")

        status, data = self.read_response()
        if status != self.STATUS_OK:
            error_msg = data.decode('utf-8', errors='replace') if data else "Unknown error"
            raise RuntimeError(f"Key send failed: {error_msg}")

    def screen_info(self):
        """Get screen information."""
        self.send_command(self.CMD_SCREEN_INFO)
        status, data = self.read_response()

        if status != self.STATUS_OK:
            error_msg = data.decode('utf-8', errors='replace') if data else "Unknown error"
            raise RuntimeError(f"Screen info failed: {error_msg}")

        return json.loads(data.decode('utf-8'))

    def wait_frame_text(self):
        """
        Wait for the next frame to be rendered and capture all text.

        Returns a list of text items, each with:
        - x: X pixel position
        - y: Y pixel position
        - color: RGB565 color value
        - text: The rendered text string
        """
        self.send_command(self.CMD_WAIT_FRAME_TEXT)
        status, data = self.read_response()

        if status != self.STATUS_OK:
            error_msg = data.decode('utf-8', errors='replace') if data else "Unknown error"
            raise RuntimeError(f"Wait frame text failed: {error_msg}")

        return json.loads(data.decode('utf-8'))

    def wait_frame_primitives(self):
        """
        Wait for the next frame to be rendered and capture all draw primitives.

        Returns a list of primitive objects, each with:
        - type: Primitive type (fill_rect, draw_rect, draw_line, fill_circle,
                draw_circle, fill_triangle, draw_triangle, fill_round_rect,
                draw_round_rect, draw_pixel)
        - color: RGB565 color value
        - Additional fields depending on type:
          - rect/round_rect: x, y, w, h (and r for round_rect)
          - line: x1, y1, x2, y2
          - circle: x, y, r
          - triangle: x1, y1, x2, y2, x3, y3
          - pixel: x, y
        """
        self.send_command(self.CMD_WAIT_FRAME_PRIMITIVES)
        status, data = self.read_response()

        if status != self.STATUS_OK:
            error_msg = data.decode('utf-8', errors='replace') if data else "Unknown error"
            raise RuntimeError(f"Wait frame primitives failed: {error_msg}")

        return json.loads(data.decode('utf-8'))

    def file_write(self, device_path, data):
        """Write a file to the device filesystem.

        Uses the binary FILE_WRITE command for efficient transfer.
        Payload format: [path_len:2 LE][path][file_data]
        """
        path_bytes = device_path.encode('utf-8')
        if isinstance(data, str):
            data = data.encode('utf-8')
        payload = struct.pack('<H', len(path_bytes)) + path_bytes + data
        old_timeout = self.ser.timeout
        self.ser.timeout = max(old_timeout, 10)
        self.send_command(self.CMD_FILE_WRITE, payload)
        status, resp = self.read_response()
        self.ser.timeout = old_timeout
        if status != self.STATUS_OK:
            error_msg = resp.decode('utf-8', errors='replace') if resp else "Unknown error"
            raise RuntimeError(f"File write failed: {error_msg}")
        return json.loads(resp.decode('utf-8'))

    def file_read(self, device_path, offset=0, length=0):
        """Read a file (or portion) from the device.

        Args:
            device_path: Path on device (e.g. /fs/screens/menu.lua)
            offset: Byte offset to start reading from
            length: Number of bytes to read (0 = entire file)
        Returns:
            bytes: The file content
        """
        path_bytes = device_path.encode('utf-8')
        payload = (struct.pack('<H', len(path_bytes)) + path_bytes +
                   struct.pack('<II', offset, length if length > 0 else 0xFFFFFFFF))
        old_timeout = self.ser.timeout
        self.ser.timeout = max(old_timeout, 10)
        self.send_command(self.CMD_FILE_READ, payload)
        status, data = self.read_response(max_payload=64 * 1024)
        self.ser.timeout = old_timeout
        if status != self.STATUS_OK:
            error_msg = data.decode('utf-8', errors='replace') if data else "Unknown error"
            raise RuntimeError(f"File read failed: {error_msg}")
        return data

    def write_at(self, device_path, offset, data):
        """Write data at a specific offset in an existing file.

        The file must already exist. Data is written starting at offset
        without truncating the rest of the file.
        """
        path_bytes = device_path.encode('utf-8')
        if isinstance(data, str):
            data = data.encode('utf-8')
        payload = (struct.pack('<H', len(path_bytes)) + path_bytes +
                   struct.pack('<I', offset) + data)
        old_timeout = self.ser.timeout
        self.ser.timeout = max(old_timeout, 10)
        self.send_command(self.CMD_WRITE_AT, payload)
        status, resp = self.read_response()
        self.ser.timeout = old_timeout
        if status != self.STATUS_OK:
            error_msg = resp.decode('utf-8', errors='replace') if resp else "Unknown error"
            raise RuntimeError(f"Write-at failed: {error_msg}")
        return json.loads(resp.decode('utf-8'))

    def lua_exec(self, code):
        """
        Execute Lua code on the device and return the result.

        The code is executed in the device's Lua state with access to all
        tdeck.* APIs. Expression results are automatically returned.

        Args:
            code: Lua code string to execute

        Returns:
            The result of the Lua code (parsed from JSON), or None for statements.

        Raises:
            RuntimeError: If the Lua code fails to compile or execute
        """
        self.send_command(self.CMD_LUA_EXEC, code.encode('utf-8'))
        status, data = self.read_response()

        if status != self.STATUS_OK:
            error_msg = data.decode('utf-8', errors='replace') if data else "Unknown error"
            raise RuntimeError(f"Lua execution failed: {error_msg}")

        return json.loads(data.decode('utf-8'))


def main():
    parser = argparse.ArgumentParser(
        description='ezOS Remote Control Client',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s /dev/ttyACM0                    Test connection
  %(prog)s /dev/ttyACM0 -s screenshot.png  Take screenshot
  %(prog)s /dev/ttyACM0 -k a               Send character 'a'
  %(prog)s /dev/ttyACM0 -k enter           Send Enter key
  %(prog)s /dev/ttyACM0 -k A --shift       Send shift+a (uppercase A)
  %(prog)s /dev/ttyACM0 --info             Get screen info
  %(prog)s /dev/ttyACM0 --text             Capture all text from next frame
  %(prog)s /dev/ttyACM0 --primitives       Capture all draw primitives from next frame
  %(prog)s /dev/ttyACM0 --logs             Get buffered log entries
  %(prog)s /dev/ttyACM0 --monitor          Monitor raw serial output
  %(prog)s /dev/ttyACM0 -e "1+1"           Execute Lua and print result
  %(prog)s /dev/ttyACM0 -e "Debug.memory()"  Call debug function
  %(prog)s /dev/ttyACM0 -f script.lua      Execute Lua file
        """
    )

    parser.add_argument('port', help='Serial port (e.g., /dev/ttyACM0)')
    parser.add_argument('-s', '--screenshot', metavar='FILE',
                        help='Save screenshot to file (PNG or BMP)')
    parser.add_argument('--crop', metavar='X,Y,W,H',
                        help='Crop region for screenshot (e.g., --crop 0,0,160,120)')
    parser.add_argument('-k', '--key', metavar='KEY',
                        help='Send key (single char or special key name)')
    parser.add_argument('--shift', action='store_true',
                        help='Hold Shift modifier')
    parser.add_argument('--ctrl', action='store_true',
                        help='Hold Ctrl modifier')
    parser.add_argument('--alt', action='store_true',
                        help='Hold Alt modifier')
    parser.add_argument('--fn', action='store_true',
                        help='Hold Fn modifier')
    parser.add_argument('--info', action='store_true',
                        help='Get screen information')
    parser.add_argument('--text', action='store_true',
                        help='Wait for next frame and capture all rendered text')
    parser.add_argument('--primitives', action='store_true',
                        help='Wait for next frame and capture all draw primitives')
    parser.add_argument('-e', '--exec', metavar='CODE', dest='lua_code',
                        help='Execute Lua code and print result')
    parser.add_argument('-f', '--exec-file', metavar='FILE',
                        help='Execute Lua code from file')
    parser.add_argument('--logs', action='store_true',
                        help='Get buffered log entries from Logger service')
    parser.add_argument('--status', action='store_true',
                        help='Show radio, mesh, and system status')
    parser.add_argument('--nodes', action='store_true',
                        help='List discovered mesh nodes')
    parser.add_argument('--watch', metavar='EXPR', nargs='?', const='ez.mesh.get_rx_count()',
                        help='Poll a Lua expression every second (default: rx count)')
    parser.add_argument('--reload', metavar='FILE', nargs='+',
                        help='Hot-reload Lua file(s) on device (e.g., lua/screens/settings.lua)')
    parser.add_argument('--monitor', action='store_true',
                        help='Monitor serial output (Ctrl+C to stop)')
    parser.add_argument('--raw', action='store_true',
                        help='Output raw JSON instead of formatted text (for --text/--primitives)')
    parser.add_argument('-b', '--baudrate', type=int, default=921600,
                        help='Serial baudrate (default: 921600)')
    parser.add_argument('-t', '--timeout', type=float, default=5,
                        help='Read timeout in seconds (default: 5)')

    args = parser.parse_args()

    try:
        remote = EzRemote(args.port, args.baudrate, args.timeout)
    except serial.SerialException as e:
        print(f"Error opening serial port: {e}", file=sys.stderr)
        return 1

    try:
        if args.screenshot:
            print(f"Taking screenshot...")
            img = remote.screenshot()
            if args.crop:
                x, y, w, h = [int(v) for v in args.crop.split(',')]
                img = img.crop((x, y, x + w, y + h))
                print(f"Cropped to {w}x{h} at ({x},{y})")
            img.save(args.screenshot)
            print(f"Saved: {args.screenshot}")

        elif args.key:
            key_str = args.key
            if len(key_str) == 1:
                # Single character
                remote.key(char=key_str, shift=args.shift, ctrl=args.ctrl,
                          alt=args.alt, fn=args.fn)
                print(f"Sent key: '{key_str}'")
            else:
                # Special key name
                remote.key(special=key_str, shift=args.shift, ctrl=args.ctrl,
                          alt=args.alt, fn=args.fn)
                print(f"Sent key: {key_str}")

        elif args.info:
            info = remote.screen_info()
            print(json.dumps(info, indent=2))

        elif args.text:
            print("Waiting for next frame...")
            texts = remote.wait_frame_text()
            if args.raw:
                print(json.dumps(texts, indent=2))
            else:
                # Sort by y then x position for readable output
                texts.sort(key=lambda t: (t.get('y', 0), t.get('x', 0)))
                for entry in texts:
                    print(entry.get('text', ''))

        elif args.primitives:
            print("Waiting for next frame...")
            primitives = remote.wait_frame_primitives()
            print(json.dumps(primitives, indent=2))

        elif args.logs:
            # Fetch log entries from the Lua Logger service
            # Falls back to ez.system.get_last_error() when Logger isn't initialized
            # (e.g., boot script failed before Logger was loaded)
            try:
                result = remote.lua_exec("Logger.get_entries()")
                if isinstance(result, list):
                    for entry in result:
                        print(entry)
                else:
                    print("No log entries.")
            except RuntimeError:
                # Logger not available, try to get the last error from C++
                try:
                    error = remote.lua_exec("ez.system.get_last_error()")
                    if error:
                        print(f"Boot error: {error}")
                    else:
                        print("No logs or errors available.")
                except RuntimeError as e2:
                    print(f"Could not retrieve logs: {e2}", file=sys.stderr)

        elif args.status:
            # Query radio, mesh, and system status in separate small calls
            status = {}
            queries = {
                'radio': 'local r=ez.radio return{init=r.is_initialized(),rx=r.is_receiving(),tx=r.is_transmitting(),busy=r.is_busy(),rssi=r.get_last_rssi(),snr=r.get_last_snr(),cfg=r.get_config()}',
                'mesh': 'if not ez.mesh.is_initialized() then return{init=false} end return{init=true,id=ez.mesh.get_node_id(),name=ez.mesh.get_node_name(),rx=ez.mesh.get_rx_count(),tx=ez.mesh.get_tx_count(),nodes=ez.mesh.get_node_count(),txq=ez.mesh.get_tx_queue_size(),pc=ez.mesh.get_path_check()}',
                'sys': 'return{mem=collectgarbage("count")}'
            }
            for key, code in queries.items():
                try:
                    status[key] = remote.lua_exec(code)
                except (RuntimeError, TimeoutError) as e:
                    status[key] = {'error': str(e)}
            # Format output
            r = status.get('radio', {})
            print("=== Radio ===")
            print(f"  Initialized:  {r.get('init')}")
            print(f"  Receiving:    {r.get('rx')}")
            print(f"  Transmitting: {r.get('tx')}")
            print(f"  Busy:         {r.get('busy')}")
            print(f"  Last RSSI:    {r.get('rssi')} dBm")
            print(f"  Last SNR:     {r.get('snr')} dB")
            cfg = r.get('cfg', {})
            if cfg:
                print(f"  Frequency:    {cfg.get('frequency')} MHz")
                print(f"  Bandwidth:    {cfg.get('bandwidth')} kHz")
                print(f"  SF/CR:        SF{cfg.get('spreading_factor')} CR4/{cfg.get('coding_rate')}")
                print(f"  TX Power:     {cfg.get('tx_power')} dBm")
                print(f"  Sync Word:    0x{cfg.get('sync_word', 0):02X}")
            print()
            m = status.get('mesh', {})
            print("=== Mesh ===")
            print(f"  Initialized:  {m.get('init')}")
            if m.get('init'):
                print(f"  Node ID:      {m.get('id')}")
                print(f"  Node Name:    {m.get('name')}")
                print(f"  RX Count:     {m.get('rx')}")
                print(f"  TX Count:     {m.get('tx')}")
                print(f"  Known Nodes:  {m.get('nodes')}")
                print(f"  TX Queue:     {m.get('txq')}")
                print(f"  Path Check:   {m.get('pc')}")
            print()
            s = status.get('sys', {})
            print("=== System ===")
            print(f"  Lua Memory:   {s.get('mem', 0):.0f} KB")

        elif args.nodes:
            nodes = remote.lua_exec("ez.mesh.get_nodes()")
            if not nodes or len(nodes) == 0:
                print("No nodes discovered.")
            else:
                print(f"{'Name':<20} {'ID':<14} {'RSSI':>6} {'SNR':>6} {'Hops':>5} {'Path':>6}")
                print("-" * 60)
                for node in nodes:
                    name = node.get('name', '?')
                    node_id = node.get('id', '?')
                    rssi = node.get('rssi', 0)
                    snr = node.get('snr', 0)
                    hops = node.get('hops', '?')
                    path_hash = node.get('path_hash', 0)
                    print(f"{name:<20} {node_id:<14} {rssi:>5.0f} {snr:>5.1f} {hops:>5} {path_hash:>5}")

        elif args.watch is not None:
            # Poll a Lua expression repeatedly
            expr = args.watch
            print(f"Watching: {expr}  (Ctrl+C to stop)")
            import time
            prev = None
            try:
                while True:
                    try:
                        result = remote.lua_exec(expr)
                        display = json.dumps(result) if not isinstance(result, (int, float, str)) else str(result)
                        if result != prev:
                            ts = time.strftime("%H:%M:%S")
                            print(f"[{ts}] {display}")
                            prev = result
                    except (RuntimeError, TimeoutError) as e:
                        print(f"  Error: {e}")
                    time.sleep(1)
            except KeyboardInterrupt:
                print("\nStopped.")

        elif args.monitor:
            # Simple serial monitor mode - just read and print serial output
            print("Monitoring serial output (Ctrl+C to stop)...")
            remote.ser.timeout = 0.1  # Short timeout for responsive reading
            try:
                while True:
                    data = remote.ser.read(1024)
                    if data:
                        sys.stdout.write(data.decode('utf-8', errors='replace'))
                        sys.stdout.flush()
            except KeyboardInterrupt:
                print("\nMonitor stopped.")

        elif args.reload:
            import os

            for filepath in args.reload:
                # Resolve module name: lua/screens/settings.lua -> screens.settings
                norm = filepath.replace('\\', '/')
                if norm.startswith('lua/'):
                    norm = norm[4:]
                if norm.endswith('.lua'):
                    norm = norm[:-4]
                mod_name = norm.replace('/', '.')
                dev_path = '/fs/' + norm + '.lua'

                if not os.path.isfile(filepath):
                    print(f"File not found: {filepath}", file=sys.stderr)
                    continue

                with open(filepath, 'rb') as f:
                    new_data = f.read()

                # Try to read existing file from device for diffing
                old_data = None
                try:
                    old_data = remote.file_read(dev_path)
                except (RuntimeError, TimeoutError):
                    pass  # File doesn't exist yet, full upload needed

                if old_data and len(old_data) == len(new_data):
                    # Same length: find changed regions and patch them
                    patches = []
                    i = 0
                    while i < len(new_data):
                        if new_data[i] != old_data[i]:
                            start = i
                            while i < len(new_data) and new_data[i] != old_data[i]:
                                i += 1
                            patches.append((start, new_data[start:i]))
                        else:
                            i += 1

                    if not patches:
                        print(f"  {filepath} (unchanged)")
                    else:
                        total_patch = sum(len(d) for _, d in patches)
                        print(f"  {filepath} ({len(patches)} patch(es), {total_patch} bytes)")
                        ok = True
                        for offset, data in patches:
                            try:
                                remote.write_at(dev_path, offset, data)
                            except (RuntimeError, TimeoutError) as e:
                                print(f"  Patch failed at {offset}: {e}", file=sys.stderr)
                                ok = False
                                break
                        if not ok:
                            continue
                else:
                    # Different length or no existing file: full upload
                    print(f"  {filepath} ({len(new_data)} bytes)")
                    try:
                        written = remote.file_write(dev_path, new_data)
                        print(f"  Uploaded {written} bytes")
                    except (RuntimeError, TimeoutError) as e:
                        print(f"  Upload failed: {e}", file=sys.stderr)
                        continue

                # Trigger hot reload on device
                try:
                    result = remote.lua_exec(
                        f"local ok, err = hot_reload('{mod_name}') "
                        f"if ok then return 'ok' else return err end"
                    )
                    if result == 'ok':
                        print(f"  Reloaded: {mod_name}")
                    else:
                        print(f"  Reload error: {result}")
                except (RuntimeError, TimeoutError) as e:
                    print(f"  Reload failed: {e}", file=sys.stderr)

        elif args.lua_code:
            result = remote.lua_exec(args.lua_code)
            print(json.dumps(result, indent=2))

        elif args.exec_file:
            with open(args.exec_file, 'r') as f:
                code = f.read()
            result = remote.lua_exec(code)
            print(json.dumps(result, indent=2))

        else:
            # Default: ping test
            if remote.ping():
                print("T-Deck connected!")
            else:
                print("Connection failed: unexpected response", file=sys.stderr)
                return 1

    except TimeoutError as e:
        print(f"Timeout: {e}", file=sys.stderr)
        return 1
    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except ImportError as e:
        print(f"Missing dependency: {e}", file=sys.stderr)
        return 1
    finally:
        remote.close()

    return 0


if __name__ == '__main__':
    sys.exit(main())
