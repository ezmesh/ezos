# Remote Control Guide

Control your ezOS device over USB serial from a host computer. Supports screenshots, keyboard input, screen queries, and Lua code execution.

## Setup

```bash
cd tools/remote
python3 -m venv venv
source venv/bin/activate
pip install pyserial pillow
```

## Quick Start

```bash
# Test connection
python ez_remote.py /dev/ttyACM0

# Take screenshot
python ez_remote.py /dev/ttyACM0 -s screenshot.png

# Send key
python ez_remote.py /dev/ttyACM0 -k enter
```

## Commands

### Connection Test

```bash
python ez_remote.py /dev/ttyACM0
# Output: T-Deck connected!
```

### Screenshots

```bash
# Save to PNG
python ez_remote.py /dev/ttyACM0 -s screenshot.png

# Save to BMP
python ez_remote.py /dev/ttyACM0 -s screenshot.bmp
```

### Keyboard Input

#### Single Characters

```bash
python ez_remote.py /dev/ttyACM0 -k a
python ez_remote.py /dev/ttyACM0 -k A --shift
python ez_remote.py /dev/ttyACM0 -k c --ctrl    # Ctrl+C
```

#### Special Keys

| Key Name | Description |
|----------|-------------|
| `enter` | Enter/Select |
| `escape` / `esc` | Back/Cancel |
| `up` | Arrow up |
| `down` | Arrow down |
| `left` | Arrow left |
| `right` | Arrow right |
| `tab` | Tab |
| `backspace` | Backspace |
| `delete` | Delete |
| `home` | Home |
| `end` | End |

```bash
python ez_remote.py /dev/ttyACM0 -k enter
python ez_remote.py /dev/ttyACM0 -k escape
python ez_remote.py /dev/ttyACM0 -k up
```

#### Modifiers

| Flag | Modifier |
|------|----------|
| `--shift` | Shift |
| `--ctrl` | Control |
| `--alt` | Alt |
| `--fn` | Function |

```bash
python ez_remote.py /dev/ttyACM0 -k a --shift      # Uppercase A
python ez_remote.py /dev/ttyACM0 -k c --ctrl       # Ctrl+C
python ez_remote.py /dev/ttyACM0 -k tab --alt      # Alt+Tab
```

### Screen Information

```bash
python ez_remote.py /dev/ttyACM0 --info
```

Output:
```json
{
  "width": 320,
  "height": 240,
  "cols": 45,
  "rows": 15
}
```

### Frame Capture

#### Capture Text

Wait for the next frame and capture all rendered text:

```bash
python ez_remote.py /dev/ttyACM0 --text
```

Output:
```json
[
  {"x": 10, "y": 20, "color": 65535, "text": "Main Menu"},
  {"x": 10, "y": 40, "color": 65535, "text": "Channel Chat"}
]
```

#### Capture Primitives

Wait for the next frame and capture all draw primitives:

```bash
python ez_remote.py /dev/ttyACM0 --primitives
```

Output:
```json
[
  {"type": "fill_rect", "x": 0, "y": 0, "w": 320, "h": 20, "color": 31},
  {"type": "draw_line", "x1": 0, "y1": 20, "x2": 320, "y2": 20, "color": 65535}
]
```

### Lua Execution

Execute Lua code on the device and get results:

```bash
# Simple expression
python ez_remote.py /dev/ttyACM0 -e "1+1"
# Output: 2

# Get free memory
python ez_remote.py /dev/ttyACM0 -e "ez.system.get_free_heap()"
# Output: 142536

# Get current screen title
python ez_remote.py /dev/ttyACM0 -e "ScreenManager.get_current_screen().title"
# Output: "Main Menu"

# Call debug functions
python ez_remote.py /dev/ttyACM0 -e "Debug.memory()"

# Execute from file
python ez_remote.py /dev/ttyACM0 -f script.lua
```

### Log Access

```bash
# Get buffered log entries
python ez_remote.py /dev/ttyACM0 --logs
```

### Serial Monitor

```bash
# Monitor raw serial output (Ctrl+C to stop)
python ez_remote.py /dev/ttyACM0 --monitor
```

## Options

| Option | Description |
|--------|-------------|
| `-s, --screenshot FILE` | Save screenshot to file |
| `-k, --key KEY` | Send key (char or special name) |
| `--shift` | Hold Shift modifier |
| `--ctrl` | Hold Ctrl modifier |
| `--alt` | Hold Alt modifier |
| `--fn` | Hold Fn modifier |
| `--info` | Get screen information |
| `--text` | Capture rendered text from next frame |
| `--primitives` | Capture draw primitives from next frame |
| `-e, --exec CODE` | Execute Lua code |
| `-f, --exec-file FILE` | Execute Lua from file |
| `--logs` | Get buffered log entries |
| `--monitor` | Monitor serial output |
| `-b, --baudrate N` | Serial baudrate (default: 921600) |
| `-t, --timeout N` | Read timeout in seconds (default: 5) |

## Protocol Details

The remote control uses a simple binary protocol over USB serial at 921600 baud.

### Request Format

```
[CMD:1][LEN:2][PAYLOAD:LEN]
```

- `CMD`: Command byte
- `LEN`: Little-endian 16-bit payload length
- `PAYLOAD`: Command-specific data

### Response Format

```
[STATUS:1][LEN:2][DATA:LEN]
```

- `STATUS`: 0x00 = OK, 0x01 = ERROR
- `LEN`: Little-endian 16-bit data length
- `DATA`: Response data (often JSON)

### Command Codes

| Code | Name | Description |
|------|------|-------------|
| 0x01 | PING | Connection test (returns "PONG") |
| 0x02 | SCREENSHOT | RLE-compressed RGB565 framebuffer |
| 0x03 | KEY_CHAR | Send character + modifiers |
| 0x04 | KEY_SPECIAL | Send special key + modifiers |
| 0x05 | SCREEN_INFO | Get screen dimensions (JSON) |
| 0x06 | WAIT_FRAME_TEXT | Capture text from next frame |
| 0x07 | LUA_EXEC | Execute Lua code |
| 0x08 | WAIT_FRAME_PRIMITIVES | Capture primitives from next frame |

## Troubleshooting

### "Timeout waiting for response"

- Ensure device is powered on and showing the UI
- Check USB cable supports data (not charge-only)
- Try unplugging and reconnecting

### "Permission denied" on Linux

```bash
sudo usermod -a -G dialout $USER
# Log out and back in
```

### Wrong serial port

```bash
# List available ports
ls /dev/ttyACM* /dev/ttyUSB*

# On macOS
ls /dev/cu.usb*
```

### Screenshot shows garbage

- Ensure device has finished booting
- Wait for UI to be fully rendered before capturing
