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
        self.ser.write(header + payload)
        self.ser.flush()

    def read_response(self):
        """Read response from T-Deck."""
        # Skip any log lines that may have been output during command execution
        # Log lines are prefixed with #LOG# and end with newline
        while True:
            # Peek at first bytes to check for log prefix
            first_bytes = self.ser.read(5)
            if len(first_bytes) < 5:
                raise TimeoutError("Timeout waiting for response header")

            if first_bytes == b'#LOG#':
                # This is a log line - read until newline and discard
                while True:
                    ch = self.ser.read(1)
                    if not ch:
                        raise TimeoutError("Timeout reading log line")
                    if ch == b'\n':
                        break
                continue  # Check for more log lines

            # Not a log line - this should be the response header
            # We already read 5 bytes, but header is only 3 bytes
            # First 3 bytes are the header, remaining 2 are start of payload
            header = first_bytes[:3]
            extra = first_bytes[3:]
            break

        status = header[0]
        length = struct.unpack('<H', header[1:3])[0]

        # Read payload (we may have already read some bytes)
        data = extra
        remaining = length - len(extra)
        if remaining > 0:
            more_data = self.ser.read(remaining)
            if len(more_data) < remaining:
                raise TimeoutError(f"Timeout reading payload (got {len(data) + len(more_data)}/{length})")
            data += more_data

        return status, data[:length]

    def ping(self):
        """Test connection with ping command."""
        self.send_command(self.CMD_PING)
        status, data = self.read_response()
        return status == self.STATUS_OK and data == b'PONG'

    def screenshot(self):
        """Capture screenshot and return PIL Image."""
        try:
            from PIL import Image
        except ImportError:
            raise ImportError("PIL/Pillow required for screenshots: pip install Pillow")

        self.send_command(self.CMD_SCREENSHOT)
        status, data = self.read_response()

        if status != self.STATUS_OK:
            error_msg = data.decode('utf-8', errors='replace') if data else "Unknown error"
            raise RuntimeError(f"Screenshot failed: {error_msg}")

        return self._decode_rle(data, 320, 240)

    def _decode_rle(self, data, width, height):
        """Decode RLE-compressed RGB565 data to PIL Image."""
        from PIL import Image

        img = Image.new('RGB', (width, height))
        pixels = img.load()

        x, y = 0, 0
        i = 0

        while i + 2 < len(data) and y < height:
            count = data[i]
            # LovyanGFX sprite stores 16-bit colors in big-endian (high byte first)
            color = (data[i + 1] << 8) | data[i + 2]
            i += 3

            # Convert RGB565 to RGB888
            r = ((color >> 11) & 0x1F) << 3
            g = ((color >> 5) & 0x3F) << 2
            b = (color & 0x1F) << 3

            # Fill in lower bits for better color accuracy
            r |= r >> 5
            g |= g >> 6
            b |= b >> 5

            for _ in range(count):
                if y < height:
                    pixels[x, y] = (r, g, b)
                    x += 1
                    if x >= width:
                        x = 0
                        y += 1

        return img

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
    parser.add_argument('--monitor', action='store_true',
                        help='Monitor serial output (Ctrl+C to stop)')
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
            print(json.dumps(texts, indent=2))

        elif args.primitives:
            print("Waiting for next frame...")
            primitives = remote.wait_frame_primitives()
            print(json.dumps(primitives, indent=2))

        elif args.logs:
            # Fetch log entries from the Lua Logger service
            result = remote.lua_exec("Logger.get_entries()")
            if isinstance(result, list):
                for entry in result:
                    print(entry)
            else:
                print("No logs available (Logger not initialized?)")

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
