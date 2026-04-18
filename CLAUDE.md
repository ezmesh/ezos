# ezOS Project Guidelines

## Overview

ezOS is a complete embedded operating system for the LilyGo T-Deck Plus (ESP32-S3 with LoRa). It combines:
- **C++ firmware** for hardware drivers and mesh networking
- **Lua scripting** for the entire UI and application logic
- **MeshCore protocol** for encrypted mesh communication

## Serial Port Access

**IMPORTANT:** Never use `stty` or interactive serial monitor commands (`pio device monitor`, `minicom`, etc.) as they block the user's interactive terminal session. The user typically has a serial monitor already open.

Instead, use the remote control tool for debugging:
- `python tools/remote/ez_remote.py /dev/ttyACM0 --logs` - Get buffered log entries
- `python tools/remote/ez_remote.py /dev/ttyACM0 --monitor` - Stream real-time logs
- `python tools/remote/ez_remote.py /dev/ttyACM0 -e "return collectgarbage('count')"` - Query device state

For building and flashing:
- `pio run` - Build firmware
- `pio run -t upload` - Build and flash

**IMPORTANT:** Do not send messages to public mesh channels (e.g. `public <msg>` via
meshcore-cli). The public channel is shared with real users. Only use DMs to the user's
own devices for testing.

**Note:** `/dev/ttyUSB0` is typically the user's separate MeshCore CLI node, not the
T-Deck. The T-Deck is usually on `/dev/ttyACM0`. If `ttyACM0` isn't present, ask the
user to plug it in rather than falling back to `ttyUSB0`.

## On-device font character set

The built-in bitmap fonts (`src/fonts/FreeSans7pt7b.h`, `FreeMono5pt7b.h`) only cover
**printable ASCII 0x20..0x7E**. Any other codepoint renders as a `[]` missing-glyph box.

This commonly bites when:
- Using `·` (U+00B7 middle dot), `•` (U+2022 bullet), `…` (U+2026 ellipsis) as separators or decoration
- Pulling display strings from external APIs (GPS names, channel names, contact names) without sanitizing
- Copying UI conventions from web/desktop apps

Safe substitutes:
- Separator: `|` or multiple spaces
- Ellipsis: `...`
- Bullet: `-` or `*`

If a new glyph is genuinely needed, extend the bitmap font (run the font generator with
a wider range); otherwise stick to ASCII in any string that reaches `draw_text`.

## Building and Flashing

```bash
# Build only
pio run

# Build and flash
pio run -t upload
```

## Project Structure

```
ezos/
├── src/                    # C++ firmware
│   ├── main.cpp           # Boot sequence, main loop
│   ├── hardware/          # Display, keyboard, radio, GPS drivers
│   ├── mesh/              # MeshCore implementation (identity, routing, crypto)
│   ├── lua/               # Lua runtime and bindings
│   │   └── bindings/      # C++ wrappers for Lua APIs
│   └── remote/            # USB remote control protocol
├── lua/                    # Lua scripts (embedded into firmware)
│   ├── boot.lua           # Entry point (services init, apply settings)
│   ├── core/              # Module infrastructure (modules.lua)
│   ├── ezui/              # Declarative UI framework
│   │   ├── init.lua       # Public API, main loop
│   │   ├── screen.lua     # Screen stack manager
│   │   ├── node.lua       # Node tree system
│   │   ├── layout.lua     # Layout nodes (vbox, hbox, scroll, etc.)
│   │   ├── widgets.lua    # Widget constructors (button, list_item, etc.)
│   │   ├── focus.lua      # Focus/navigation manager
│   │   ├── text.lua       # Text measurement and wrapping
│   │   ├── theme.lua      # Colors, fonts, dimensions
│   │   ├── icons.lua      # PNG icon definitions
│   │   └── async.lua      # Async file I/O helpers
│   ├── screens/           # Screen definitions
│   └── services/          # Background services (channels, contacts, DMs)
├── tools/                  # Development utilities
│   ├── maps/              # Offline map generation
│   ├── simulator/         # Browser-based simulator
│   └── remote/            # Remote control client
└── docs/                   # Documentation
```

## UI System Architecture (ezui)

### Declarative Screen Model
Screens define a `build(state)` method that returns a node tree. State changes via
`set_state()` trigger an automatic rebuild and redraw.

```lua
local MyScreen = { title = "My Screen" }

function MyScreen:build(state)
    return ui.vbox({ gap = 4 }, {
        ui.title_bar("My Screen", { back = true }),
        ui.text_widget({ text = state.message or "Hello" }),
    })
end

function MyScreen:on_enter()      -- Called when screen becomes active
function MyScreen:on_leave()      -- Called when screen is paused (another pushed on top)
function MyScreen:on_exit()       -- Called when screen is popped off the stack
function MyScreen:handle_key(key) -- Process input not handled by focused nodes
```

### Main Loop

The C++ `loop()` calls `_G.main_loop()` which is set by `ui.start()`:
1. Update mesh network (every 50ms via `ez.mesh.update()`)
2. Screen manager update (input + render at ~30 FPS)
3. Incremental garbage collection (every 2 seconds)

Timers and bus messages are processed by C++ `LuaRuntime::update()` before the Lua main loop runs.

### Services

Services are initialized in order in `lua/boot.lua`:
1. **contacts** - Contact list CRUD with persistence
2. **channels** - Channel management, GRP_TXT decryption
3. **direct_messages** - Encrypted DMs via TXT_MSG packets

### Module Loading

```lua
load_module(path)           -- Async load from LittleFS (yields in coroutine)
require("module.name")      -- Standard Lua require (loads embedded scripts first)
spawn(fn)                   -- Run function in coroutine
```

### Settings

Settings are stored via `ez.storage.set_pref(key, value)` and restored in
`lua/boot.lua` at startup.

## Map Tools (`tools/maps/`)

Convert OpenStreetMap vector tiles to optimized TDMAP format for offline viewing.

### Files

| File | Purpose |
|------|---------|
| `pmtiles_to_tdmap.py` | Main converter - PMTiles to TDMAP |
| `config.py` | Tile sources, regions, 8-color semantic palette |
| `process.py` | Grayscale conversion, dithering, RLE compression |
| `archive.py` | TDMAP format writer/reader |
| `land_mask.py` | Natural Earth land polygon downloader |
| `viewer.html` | Browser-based TDMAP viewer |

### Usage

```bash
cd tools/maps
pip install -r requirements.txt
python pmtiles_to_tdmap.py input.pmtiles -o output.tdmap
python pmtiles_to_tdmap.py input.pmtiles --bounds 4.0,52.0,5.5,52.5 --zoom 10,14 -o region.tdmap
```

### TDMAP Format (v4)

Optimized archive format for ESP32:
- **Header** (33 bytes): Magic, version, compression type, tile/label counts, offsets
- **Palette** (16 bytes): 8 RGB565 colors for semantic features
- **Tile Index**: Sorted by (zoom, x, y) for binary search
- **Tile Data**: RLE-compressed 3-bit indexed pixels
- **Labels**: Geographic coordinates (lat_e6, lon_e6), zoom ranges, label types

Semantic feature indices (0-7): Land, Water, Park, Building, RoadMinor, RoadMajor, Highway, Railway

### Resume Support

Checkpoints saved every 500 tiles. Interrupted conversions resume automatically:
```bash
# If interrupted, just run again:
python pmtiles_to_tdmap.py input.pmtiles -o output.tdmap
```

## Simulator (`tools/simulator/`)

Browser-based ezOS simulator using Wasmoon (Lua 5.4 in WebAssembly).

### Running

```bash
cd tools/simulator
npm install
npm start
# Opens http://localhost:3000/tools/simulator/
```

### Architecture

```
Browser (Canvas + Console)
    ↓
JavaScript Mocks (display, keyboard, storage, mesh, GPS, audio)
    ↓
Wasmoon (Lua 5.4 VM)
    ↓
Lua Scripts (boot.lua, screens, services)
```

### Mock APIs

| File | Purpose |
|------|---------|
| `mock/display.js` | Canvas rendering with all drawing APIs |
| `mock/keyboard.js` | Browser keyboard event mapping |
| `mock/storage.js` | IndexedDB for files, localStorage for prefs |
| `mock/mesh.js` | Simulated mesh network with mock nodes |
| `mock/gps.js` | Browser geolocation + mock location |
| `mock/audio.js` | Web Audio API synthesis |
| `mock/bus.js` | Message bus for screen communication |
| `mock/crypto.js` | Crypto primitives (AES, HMAC, key derivation) |
| `mock/system.js` | System APIs (timers, millis, memory) |
| `mock/radio.js` | LoRa radio simulation |
| `mock/wifi.js` | WiFi mock |

## Remote Control (`tools/remote/`)

Control T-Deck over USB serial from host computer. This is the primary tool for automated testing and debugging.

### Setup

```bash
cd tools/remote
pip install pyserial pillow
```

### Commands

```bash
# Test connection
python ez_remote.py /dev/ttyACM0

# Screenshots
python ez_remote.py /dev/ttyACM0 -s screenshot.png

# Send keys
python ez_remote.py /dev/ttyACM0 -k enter
python ez_remote.py /dev/ttyACM0 -k a
python ez_remote.py /dev/ttyACM0 -k up
python ez_remote.py /dev/ttyACM0 -k c --ctrl

# Screen info
python ez_remote.py /dev/ttyACM0 --info

# Capture rendered text (for UI verification)
python ez_remote.py /dev/ttyACM0 --text

# Capture draw primitives (for debugging rendering)
python ez_remote.py /dev/ttyACM0 --primitives

# Get buffered logs
python ez_remote.py /dev/ttyACM0 --logs

# Monitor serial output (real-time logs)
python ez_remote.py /dev/ttyACM0 --monitor

# Execute Lua code
python ez_remote.py /dev/ttyACM0 -e "1+1"
python ez_remote.py /dev/ttyACM0 -e "return collectgarbage('count')"
python ez_remote.py /dev/ttyACM0 -e "ez.system.get_time()"
python ez_remote.py /dev/ttyACM0 -f script.lua
```

### Capture Modes

**Text Capture (`--text`)**: Returns all text rendered in a frame with positions and colors. Useful for verifying UI content.

**Primitive Capture (`--primitives`)**: Returns all draw calls (rects, lines, circles, triangles, bitmaps) with coordinates. Useful for debugging rendering issues like map tiles.

Example primitive output for map tiles:
```json
[
  {"type": "draw_bitmap", "x": 32, "y": 48, "w": 64, "h": 64, "transparent_color": 0},
  {"type": "fill_rect", "x": 0, "y": 0, "w": 320, "h": 24, "color": 0}
]
```

### Protocol

- Baudrate: 921600
- Request: `[CMD:1][LEN:2][PAYLOAD:LEN]`
- Response: `[STATUS:1][LEN:2][DATA:LEN]`

Commands:
- `0x01` PING - Test connection
- `0x02` SCREENSHOT - Capture RLE-compressed RGB565 framebuffer
- `0x03` KEY_CHAR - Send character with modifiers
- `0x04` KEY_SPECIAL - Send special key (arrows, enter, etc.)
- `0x05` SCREEN_INFO - Get current screen title and dimensions
- `0x06` WAIT_FRAME_TEXT - Capture text from next rendered frame
- `0x07` LUA_EXEC - Execute Lua code and return result
- `0x08` WAIT_FRAME_PRIMITIVES - Capture draw primitives from next frame

## Development Workflow

### Building and Testing

1. **Build firmware**: `pio run`
2. **Flash to device**: `pio run -t upload`
3. **Verify with remote control**:
   - Take screenshot: `python tools/remote/ez_remote.py /dev/ttyACM0 -s test.png`
   - Check logs: `python tools/remote/ez_remote.py /dev/ttyACM0 --logs`
   - Run tests via Lua: `python tools/remote/ez_remote.py /dev/ttyACM0 -e "your_test_code"`

### Debugging UI Issues

**IMPORTANT:** Prefer using `--text` over screenshots when verifying UI content. Text capture is faster, uses less bandwidth, and can be easily compared or searched programmatically.

1. Navigate to the problematic screen (use `ui.push_screen()` via `-e` flag)
2. **Prefer:** Capture text to verify content: `--text`
3. **If needed:** Capture primitives to debug rendering: `--primitives`
4. **Last resort:** Take screenshot for visual verification: `-s screenshot.png`
5. Check logs for errors: `--logs`

Screenshots are best for:
- Verifying visual layout, colors, and graphics
- Debugging rendering issues not captured by text/primitives
- Creating documentation or bug reports

### Debugging with Lua Execution

The `-e` flag executes Lua code on the device and returns JSON results:

```bash
# Check system state
python ez_remote.py /dev/ttyACM0 -e "ez.system.get_time()"
python ez_remote.py /dev/ttyACM0 -e "return collectgarbage('count')"
python ez_remote.py /dev/ttyACM0 -e "return ez.system.millis()"

# Query settings
python ez_remote.py /dev/ttyACM0 -e "ez.storage.get_pref('brightness', 200)"

# Access services
python ez_remote.py /dev/ttyACM0 -e "local ch = require('services.channels'); return #ch.get_history('#Public')"
python ez_remote.py /dev/ttyACM0 -e "local dm = require('services.direct_messages'); return dm.get_total_unread()"
```

### Navigating Screens

Push screens using the ezui API:

```bash
# Push a screen loaded from LittleFS
python ez_remote.py /dev/ttyACM0 -e "local ui = require('ezui'); ui.push_screen('\$screens/messages.lua')"

# Push a screen from a require()'d module
python ez_remote.py /dev/ttyACM0 -e "local ui = require('ezui'); local s = require('ezui.screen'); local def = require('screens.contacts'); s.push(s.create(def, {}))"

# Pop current screen (go back)
python ez_remote.py /dev/ttyACM0 -e "require('ezui.screen').pop()"
```

### Testing Changes

Lua scripts in `lua/` are embedded into the firmware at build time. `require()` loads
embedded scripts before LittleFS, so you must rebuild and flash for changes to take effect:

```bash
pio run -t upload
```

Both Lua and C++ changes require a full rebuild and flash.

### Verifying Fixes

After making a fix:
1. Build and flash: `pio run -t upload`
2. Navigate to relevant screen via remote key injection
3. Verify with appropriate capture mode (text/primitives/screenshot)
4. Check logs for any errors

## Key Components

### Identity System (Ed25519)
- Keypairs stored in NVS (`privkey`, `pubkey`)
- Node ID derived from SHA-256 hash of public key (first 6 bytes)
- Sign/verify methods for message authentication

### Channel System
- Default channel: `#Public` (joined automatically on startup)
- Encrypted channels: AES-128-ECB with password-derived keys
- GRP_TXT plaintext format: `[timestamp:4 LE][type:1][sendername: text]`
- Room server relays wrap an additional `[timestamp:4][type:1][sender: text]` inside the text

### Direct Messages (TXT_MSG)
- ECDH shared secret (X25519) → first 16 bytes as AES key, full 32 bytes as HMAC key
- Over-the-air payload: `[dest_hash:1][src_hash:1][MAC:2][ciphertext:N]`
- MAC: HMAC-SHA256 truncated to 2 bytes, keyed with full 32-byte shared secret
- Ciphertext: AES-128-ECB, zero-padded to 16-byte boundary
- Inner plaintext: `[timestamp:4 LE][flags:1][text:N]`
- Receiver filters by dest_hash, then tries contacts/nodes matching src_hash

### Radio Status
- `!RF` indicator means radio failed to initialize
- Check LoRa module wiring if this appears

## C++ Binding Safety Rules

### Dangling lua_State* Pointer Bug

**CRITICAL:** Never store a `lua_State* L` parameter in a static/global variable when
the function may be called from a Lua coroutine. The coroutine's state becomes invalid
after it is garbage collected, causing crashes when the stored pointer is later used.

This bug has occurred multiple times:
- `callbackState` in `mesh_bindings.cpp` — stored boot coroutine's state, crashed on packet callbacks
- `timerLuaState` in `system_bindings.cpp` — stored boot coroutine's state, crashed on 30-second timer

**Fix pattern:** Use the `LUA_STATE` macro (`LuaRuntime::instance().getState()`) which
always returns the main Lua state. Include `lua_runtime.h` for access.

```cpp
// BAD: L may be a coroutine state that gets GC'd
static lua_State* savedState = nullptr;
LUA_FUNCTION(my_func) {
    savedState = L;  // Dangling after coroutine GC!
}

// GOOD: Always use main state
void myCallback() {
    lua_State* L = LUA_STATE;  // Always valid
    if (L) { lua_pcall(L, ...); }
}
```

When writing new C++ bindings that register callbacks, audit every `lua_State*` that
outlives the current function call. If it's stored for later use, it must come from
`LUA_STATE`, not from the `L` parameter.

## MeshCore Protocol Reference

Reference implementation: https://github.com/ripplebiz/MeshCore

### Cryptographic Constants
- `PUB_KEY_SIZE`: 32 bytes (Ed25519 public key)
- `PRV_KEY_SIZE`: 64 bytes (Ed25519 private key)
- `SIGNATURE_SIZE`: 64 bytes (Ed25519 signature)
- `SEED_SIZE`: 32 bytes

### Cipher Constants
- `CIPHER_KEY_SIZE`: 16 bytes
- `CIPHER_BLOCK_SIZE`: 16 bytes
- `CIPHER_MAC_SIZE`: 2 bytes

### Packet Constants
- `MAX_PACKET_PAYLOAD`: 184 bytes
- `MAX_PATH_SIZE`: 64 bytes
- `MAX_TRANS_UNIT`: 255 bytes
- `MAX_ADVERT_DATA_SIZE`: 32 bytes
- `PATH_HASH_SIZE`: 1 byte

### Packet Header Format (1 byte)
- Bits 0-1: Route type (mask 0x03)
- Bits 2-5: Payload type (shift 2, mask 0x0F)
- Bits 6-7: Payload version (shift 6, mask 0x03)

### Route Types
- `ROUTE_TYPE_TRANSPORT_FLOOD` (0x00): Flood with transport codes
- `ROUTE_TYPE_FLOOD` (0x01): Standard flood routing
- `ROUTE_TYPE_DIRECT` (0x02): Direct with supplied path
- `ROUTE_TYPE_TRANSPORT_DIRECT` (0x03): Direct with transport codes

### ADVERT Packet Payload Format
```
[pub_key:32][timestamp:4][signature:64][app_data:variable]
```
- Offset 0: Public key (32 bytes)
- Offset 32: Timestamp (4 bytes, little-endian)
- Offset 36: Ed25519 signature (64 bytes)
- Offset 100: App data (up to 32 bytes) - contains node name, location, metadata

**Signature computed over:** `[pub_key:32][timestamp:4][app_data:variable]`

### App Data Structure (within ADVERT)
All multi-byte integers are little-endian.

| Field | Offset | Size | Type | Description |
|-------|--------|------|------|-------------|
| flags | 0 | 1 | uint8 | Bit flags for presence/type |
| latitude | 1 | 4 | int32_le | Optional: lat × 1,000,000 |
| longitude | 5 | 4 | int32_le | Optional: lon × 1,000,000 |
| feature1 | 9 | 2 | uint16_le | Optional: reserved |
| feature2 | 11 | 2 | uint16_le | Optional: reserved |
| name | variable | variable | string | UTF-8 node name |

### Flags Byte
| Bit | Value | Meaning |
|-----|-------|---------|
| 0-1 | 0x01 | Chat node |
| 0-1 | 0x02 | Repeater |
| 0-1 | 0x03 | Room server |
| 2 | 0x04 | Sensor |
| 4 | 0x10 | Has location (lat/lon present) |
| 5 | 0x20 | Has feature1 |
| 6 | 0x40 | Has feature2 |
| 7 | 0x80 | Has name |

### Location Encoding
- Latitude/Longitude stored as `int32_le` = decimal degrees × 1,000,000
- Example: 47.543968° → 47543968, -122.108616° → -122108616
- Only present when flags bit 4 (0x10) is set

### Device Roles (bits 0-1)
- 0x01: Chat client (companion app user)
- 0x02: Repeater (infrastructure node, often has GPS)
- 0x03: Room server

### Key Source Files (ripplebiz/MeshCore)
- [src/Packet.h](https://github.com/ripplebiz/MeshCore/blob/main/src/Packet.h) - Packet structure and header format
- [src/Mesh.cpp](https://github.com/ripplebiz/MeshCore/blob/main/src/Mesh.cpp) - Packet handling including ADVERT processing
- [src/Identity.h](https://github.com/ripplebiz/MeshCore/blob/main/src/Identity.h) - Ed25519 identity class
- [src/MeshCore.h](https://github.com/ripplebiz/MeshCore/blob/main/src/MeshCore.h) - Main constants and definitions
- [src/helpers/AdvertDataHelpers.h](https://github.com/ripplebiz/MeshCore/blob/main/src/helpers/AdvertDataHelpers.h) - ADVERT appdata parsing
