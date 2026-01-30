# T-Deck OS Project Guidelines

## Overview

T-Deck OS is a complete embedded operating system for the LilyGo T-Deck Plus (ESP32-S3 with LoRa). It combines:
- **C++ firmware** for hardware drivers and mesh networking
- **Lua scripting** for the entire UI and application logic
- **MeshCore protocol** for encrypted mesh communication

## Serial Port Access

**IMPORTANT:** Never use `stty` or interactive serial monitor commands (`pio device monitor`, `minicom`, etc.) as they block the user's interactive terminal session. The user typically has a serial monitor already open.

Instead:
- Use `pio run -t upload` to flash firmware
- Trust that the user is watching serial output in their own terminal
- If you need to see serial output for debugging, ask the user to share the relevant log lines

## Building and Flashing

```bash
# Build only
pio run

# Build and flash
pio run -t upload
```

## Project Structure

```
tdeck-os/
├── src/                    # C++ firmware
│   ├── main.cpp           # Boot sequence, main loop
│   ├── hardware/          # Display, keyboard, radio, GPS drivers
│   ├── mesh/              # MeshCore implementation (identity, routing, crypto)
│   ├── lua/               # Lua runtime and bindings
│   │   └── bindings/      # C++ wrappers for Lua APIs
│   └── remote/            # USB remote control protocol
├── data/scripts/           # Lua UI scripts
│   ├── boot.lua           # Entry point (services init, apply settings)
│   └── ui/
│       ├── screens/       # Individual screens (40+ files)
│       └── services/      # Background services
├── tools/                  # Development utilities
│   ├── maps/              # Offline map generation
│   ├── simulator/         # Browser-based simulator
│   └── remote/            # Remote control client
└── docs/                   # Documentation
```

## UI System Architecture

### Screen Stack
The UI uses a stack-based screen management system. Screens are Lua classes with standard methods:

```lua
local MyScreen = { title = "My Screen" }

function MyScreen:new()
    local o = { ... }
    setmetatable(o, {__index = MyScreen})
    return o
end

function MyScreen:on_enter()     -- Called when screen becomes active
function MyScreen:on_exit()      -- Called when screen is popped
function MyScreen:render(display) -- Draw the screen
function MyScreen:handle_key(key) -- Process input, return "continue" or "pop"
function MyScreen:get_menu_items() -- Optional: context menu items
```

### Main Loop (boot.lua → main_loop.lua)

The main loop runs at ~100Hz (10ms per frame):
1. Update mesh network (every 50ms, or 500ms in game mode)
2. Process timers via Scheduler
3. Handle keyboard input
4. Render active screen
5. Periodic garbage collection

### Services

Services are initialized in order at boot:
1. **Scheduler** - Timer/interval management
2. **Overlays** - Modal overlay management
3. **StatusBar** - Battery, signal, node ID display
4. **ThemeManager** - Wallpaper, colors, icon themes
5. **TitleBar** - Screen title rendering
6. **ScreenManager** - Screen stack management
7. **MainLoop** - Frame loop coordinator
8. **Logger** - Message logging to storage

### Module Loading

```lua
load_module(path)           -- Async load (yields in coroutine)
unload_module(path)         -- Memory cleanup
spawn(fn)                   -- Run function in coroutine
spawn_screen(path, ...)     -- Load and push screen
spawn_module(path, method)  -- Load and call method
```

### Settings Save/Restore Pattern

Settings must be both saved when changed AND restored at boot.

**Where settings are defined:**
- `data/scripts/ui/screens/settings.lua` - Settings UI with definitions, defaults, save logic

**How settings are saved:**
1. In `save_settings()`: Write to preferences using `tdeck.storage.set_pref(key, value)`
2. ThemeManager settings: Saved via `ThemeManager.save()`

**How settings are restored at boot:**
- `data/scripts/boot.lua` - `apply_saved_settings()` function

**Adding a new setting:**
1. Add setting definition to `settings.lua` with name, label, type, default value
2. Add save logic in `save_settings()` using `tdeck.storage.set_pref()`
3. Add restore logic in `boot.lua` `apply_saved_settings()` using `tdeck.storage.get_pref()`

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

Browser-based T-Deck OS simulator using Wasmoon (Lua 5.4 in WebAssembly).

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

## Remote Control (`tools/remote/`)

Control T-Deck over USB serial from host computer.

### Usage

```bash
cd tools/remote
pip install pyserial pillow

# Test connection
python tdeck_remote.py /dev/ttyACM0

# Take screenshot
python tdeck_remote.py /dev/ttyACM0 -s screenshot.png

# Send key
python tdeck_remote.py /dev/ttyACM0 -k enter
python tdeck_remote.py /dev/ttyACM0 -k a
python tdeck_remote.py /dev/ttyACM0 -k up

# With modifiers
python tdeck_remote.py /dev/ttyACM0 -k c --ctrl
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

## Key Components

### Identity System (Ed25519)
- Keypairs stored in NVS (`privkey`, `pubkey`)
- Node ID derived from SHA-256 hash of public key (first 6 bytes)
- Sign/verify methods for message authentication

### Channel System
- Default channel: `#Public` (joined automatically on startup)
- Encrypted channels: password-based AES-256-GCM with HKDF key derivation
- All channel messages are signed with Ed25519

### Radio Status
- `!RF` indicator means radio failed to initialize
- Check LoRa module wiring if this appears

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
