# T-Deck OS Browser Simulator

A browser-based simulator that runs T-Deck OS Lua scripts using Wasmoon (Lua 5.4 compiled to WebAssembly).

## Quick Start

```bash
cd tools/simulator
npm install
npm start
# Open http://localhost:3000 in your browser
```

## Features

- **Real Lua 5.4**: Uses Wasmoon for accurate Lua execution
- **Full display API**: Canvas-based rendering with all drawing primitives
- **Keyboard input**: Browser keyboard events mapped to T-Deck keyboard API
- **Virtual filesystem**: Loads scripts from `data/scripts/`, persists files to IndexedDB
- **Mock hardware**: Simulated mesh network, GPS (uses browser geolocation), audio
- **Console output**: See all print() and log() output in real-time

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   Browser                        │
├─────────────────────────────────────────────────┤
│  ┌─────────┐  ┌──────────┐  ┌───────────────┐   │
│  │ Canvas  │  │ Console  │  │  Controls     │   │
│  │ 320x240 │  │ Output   │  │  Restart/Pause│   │
│  └────┬────┘  └────┬─────┘  └───────────────┘   │
│       │            │                             │
│  ┌────┴────────────┴────────────────────────┐   │
│  │          Mock Layer (JavaScript)          │   │
│  │  display.js  keyboard.js  system.js      │   │
│  │  storage.js  mesh.js      radio.js       │   │
│  │  audio.js    gps.js       crypto.js      │   │
│  └──────────────────┬───────────────────────┘   │
│                     │                            │
│  ┌──────────────────┴───────────────────────┐   │
│  │           Wasmoon (Lua 5.4)              │   │
│  │                                           │   │
│  │   data/scripts/boot.lua                  │   │
│  │     ├── services/scheduler.lua           │   │
│  │     ├── services/screen_manager.lua      │   │
│  │     └── ui/screens/*.lua                 │   │
│  └───────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

## Mock Modules

### tdeck.display
Maps to HTML5 Canvas 2D API. Supports all drawing primitives:
- `clear()`, `flush()`
- `fill_rect()`, `draw_rect()`, `draw_rounded_rect()`, `fill_rounded_rect()`
- `draw_text()`, `draw_text_centered()`, `text_width()`, `set_font_size()`
- `draw_line()`, `draw_hline()`, `draw_vline()`, `draw_pixel()`
- `draw_circle()`, `fill_circle()`, `draw_triangle()`, `fill_triangle()`
- `draw_bitmap()`, `draw_indexed_bitmap()`
- Color constants: `BLACK`, `WHITE`, `RED`, `GREEN`, `BLUE`, etc.

### tdeck.keyboard
Maps to browser keyboard events:
- `available()`, `read()`, `peek()`, `clear()`
- `is_shift_held()`, `is_ctrl_held()`, `is_alt_held()`
- Arrow keys mapped to `UP`, `DOWN`, `LEFT`, `RIGHT`
- Special keys: `ENTER`, `ESCAPE`, `TAB`, `BACKSPACE`

### tdeck.system
Time and system functions:
- `millis()`, `micros()` - Uses `performance.now()`
- `get_time()` - Returns current date/time components
- `get_free_heap()`, `get_psram_size()` - Mock values
- `set_timer()`, `set_interval()`, `cancel_timer()`
- `log()` - Output to browser console

### tdeck.storage
Uses IndexedDB for files, localStorage for preferences:
- `read_file()`, `write_file()`, `append_file()`, `exists()`, `delete_file()`
- `list_dir()`, `mkdir()`, `rmdir()`
- `get_pref()`, `set_pref()`, `delete_pref()`
- `json_encode()`, `json_decode()`

### tdeck.mesh
Simulated mesh network with mock nodes:
- `is_initialized()`, `get_node_id()`, `get_nodes()`
- `send_channel_message()`, `send_direct_message()`
- `join_channel()`, `leave_channel()`, `get_channels()`

### tdeck.gps
Uses browser Geolocation API (with fallback to mock Amsterdam location):
- `init()`, `is_valid()`, `get_location()`
- `get_lat()`, `get_lon()`, `get_alt()`, `get_speed()`
- `distance()`, `bearing()` - Haversine calculations

### tdeck.audio
Uses Web Audio API:
- `play_tone()`, `beep()`, `play_click()`
- `play_success()`, `play_error()`, `play_notification()`
- `set_volume()`, `set_enabled()`

## Limitations

- **No true blocking**: Browser JS cannot block, so `read_blocking()` returns immediately
- **Async differences**: Wasmoon doesn't support yielding across JS-Lua boundaries the same way as ESP32
- **Font rendering**: Uses browser monospace font instead of bitmap font
- **No radio**: LoRa radio functions are stubbed

## Development

To modify the simulator:

1. Mock modules are in `mock/*.js`
2. Main entry point is `simulator.js`
3. UI is in `index.html`

Scripts are loaded from `../../data/scripts/` relative to the simulator.

## Troubleshooting

**"Failed to load boot.lua"**
- Make sure you're running from an HTTP server (not file://)
- Check that `data/scripts/boot.lua` exists

**Canvas stays black**
- Check browser console for errors
- Try the Restart button

**Keyboard not working**
- Click on the canvas first to focus it
