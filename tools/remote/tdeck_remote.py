#!/usr/bin/env python3
"""
T-Deck Remote Control Client

A command-line tool for controlling T-Deck OS over USB serial.
Supports screenshot capture, keyboard input injection, and screen queries.

Usage:
    python tdeck_remote.py /dev/ttyACM0                    # Test connection (ping)
    python tdeck_remote.py /dev/ttyACM0 -s screenshot.png  # Take screenshot
    python tdeck_remote.py /dev/ttyACM0 -k a               # Send character 'a'
    python tdeck_remote.py /dev/ttyACM0 -k enter           # Send Enter key
    python tdeck_remote.py /dev/ttyACM0 --info             # Get screen info
    python tdeck_remote.py /dev/ttyACM0 --text             # Capture rendered text
"""

import serial
import struct
import argparse
import sys
import json


class TDeckRemote:
    """Client for T-Deck remote control protocol."""

    # Command codes
    CMD_PING = 0x01
    CMD_SCREENSHOT = 0x02
    CMD_KEY_CHAR = 0x03
    CMD_KEY_SPECIAL = 0x04
    CMD_SCREEN_INFO = 0x05
    CMD_WAIT_FRAME_TEXT = 0x06

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
        header = struct.pack('<BH', cmd, len(payload))
        self.ser.write(header + payload)
        self.ser.flush()

    def read_response(self):
        """Read response from T-Deck."""
        # Read header: [STATUS:1][LEN:2]
        header = self.ser.read(3)
        if len(header) < 3:
            raise TimeoutError("Timeout waiting for response header")

        status = header[0]
        length = struct.unpack('<H', header[1:3])[0]

        # Read payload
        data = b''
        if length > 0:
            data = self.ser.read(length)
            if len(data) < length:
                raise TimeoutError(f"Timeout reading payload (got {len(data)}/{length})")

        return status, data

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


def main():
    parser = argparse.ArgumentParser(
        description='T-Deck Remote Control Client',
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
    parser.add_argument('-b', '--baudrate', type=int, default=921600,
                        help='Serial baudrate (default: 921600)')
    parser.add_argument('-t', '--timeout', type=float, default=5,
                        help='Read timeout in seconds (default: 5)')

    args = parser.parse_args()

    try:
        remote = TDeckRemote(args.port, args.baudrate, args.timeout)
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
