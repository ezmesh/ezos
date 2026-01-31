# Browser-Based ezOS Simulator

## Overview

A browser-based simulator that runs the same Lua scripts as the T-Deck firmware, enabling development and testing without physical hardware. The simulator would mock the `ez.*` API bindings and render the UI to an HTML5 canvas.

## Motivation

- **Faster iteration**: No need to flash firmware for UI/logic changes
- **Easier debugging**: Browser DevTools, console logging, breakpoints
- **Accessibility**: Anyone can try the OS without hardware
- **Testing**: Automated UI testing becomes possible
- **Development**: Work on scripts without the device present

## Lua Runtime Options

### Wasmoon (Recommended)

- **Repository**: https://github.com/ceifa/wasmoon
- **Lua Version**: 5.4 (official Lua compiled to WebAssembly)
- **Performance**: ~25x faster than Fengari
- **API**: Simple `global.set()` for exposing JS functions to Lua

```javascript
import { LuaFactory } from 'wasmoon';

const factory = new LuaFactory();
const lua = await factory.createEngine();

// Expose JS function to Lua
lua.global.set('sum', (x, y) => x + y);

// Run Lua code
await lua.doString('print(sum(10, 20))');
```

**Limitations**:
- Cannot await Promises in callbacks from JS to Lua without workarounds
- `null` evaluates to `true` in Lua (injected as userdata)
- Cannot yield across C-call boundaries

### Fengari (Alternative)

- **Repository**: https://github.com/fengari-lua/fengari
- **Lua Version**: 5.3 (reimplemented in JavaScript)
- **Performance**: Slower (~25x slower than Wasmoon)
- **API**: C API style (`lua_pushjsfunction`, etc.)

**Limitations**:
- No garbage collection control
- No weak tables
- No file I/O in browser
- No `__gc` metamethods

### Recommendation

**Use Wasmoon** for better performance and Lua 5.4 compatibility (matches firmware).

## API Surface to Mock

Based on analysis of `src/lua/bindings/*.cpp`, these modules need browser implementations:

### ez.display (~35 functions)

Maps to HTML5 Canvas 2D API.

| Function | Browser Implementation |
|----------|----------------------|
| `clear()` | `ctx.fillRect(0, 0, 320, 240)` |
| `flush()` | No-op (canvas updates immediately) |
| `fill_rect(x, y, w, h, color)` | `ctx.fillRect()` |
| `draw_rect(x, y, w, h, color)` | `ctx.strokeRect()` |
| `draw_text(x, y, text, color)` | `ctx.fillText()` |
| `draw_line(x1, y1, x2, y2, color)` | `ctx.beginPath(); ctx.moveTo(); ctx.lineTo()` |
| `draw_circle(x, y, r, color)` | `ctx.arc()` |
| `fill_circle(x, y, r, color)` | `ctx.arc(); ctx.fill()` |
| `draw_pixel(x, y, color)` | `ctx.fillRect(x, y, 1, 1)` |
| `rgb(r, g, b)` | Convert to RGB565 integer |
| `text_width(text)` | `ctx.measureText(text).width` |
| `set_font_size(size)` | Change canvas font |
| `draw_bitmap(...)` | `ctx.putImageData()` |
| `draw_indexed_bitmap(...)` | Decode 3-bit palette, `putImageData()` |

**Color handling**: Convert RGB565 to CSS:
```javascript
function rgb565ToCSS(color) {
  const r = ((color >> 11) & 0x1F) << 3;
  const g = ((color >> 5) & 0x3F) << 2;
  const b = (color & 0x1F) << 3;
  return `rgb(${r},${g},${b})`;
}
```

### ez.keyboard (~25 functions)

Maps to browser keyboard events.

| Function | Browser Implementation |
|----------|----------------------|
| `available()` | `keyQueue.length > 0` |
| `read()` | `keyQueue.shift()` |
| `is_shift_held()` | Track from keydown/keyup events |
| `is_ctrl_held()` | Track from keydown/keyup events |

**Key translation** needed for special keys:
```javascript
function translateKey(event) {
  const special = {
    'ArrowUp': 'UP', 'ArrowDown': 'DOWN',
    'ArrowLeft': 'LEFT', 'ArrowRight': 'RIGHT',
    'Enter': 'ENTER', 'Escape': 'ESCAPE',
    'Tab': 'TAB', 'Backspace': 'BACKSPACE',
  };
  return {
    character: event.key.length === 1 ? event.key : null,
    special: special[event.key] || null,
    shift: event.shiftKey,
    ctrl: event.ctrlKey,
    alt: event.altKey,
    valid: true
  };
}
```

### ez.system (~30 functions)

| Function | Browser Implementation |
|----------|----------------------|
| `millis()` | `performance.now()` |
| `delay(ms)` | `await new Promise(r => setTimeout(r, ms))` |
| `get_free_heap()` | Return mock value (e.g., 65536) |
| `get_battery_percent()` | Return 100 (or use Battery API) |
| `log(msg)` | `console.log('[Lua]', msg)` |
| `get_time()` | `new Date()` components |
| `set_timer(ms, cb)` | `setTimeout()` |
| `set_interval(ms, cb)` | `setInterval()` |
| `cancel_timer(id)` | `clearTimeout()/clearInterval()` |
| `yield(ms)` | Integration with `requestAnimationFrame` |
| `restart()` | `location.reload()` |

### ez.storage (~20 functions)

Use IndexedDB for persistence, with in-memory fallback.

| Function | Browser Implementation |
|----------|----------------------|
| `read_file(path)` | IndexedDB or fetch from server |
| `write_file(path, content)` | IndexedDB |
| `exists(path)` | Check IndexedDB |
| `list_dir(path)` | IndexedDB keys with prefix |
| `get_pref(key, default)` | `localStorage.getItem()` |
| `set_pref(key, value)` | `localStorage.setItem()` |
| `json_encode(value)` | `JSON.stringify()` |
| `json_decode(str)` | `JSON.parse()` |

### ez.crypto (~15 functions)

Use Web Crypto API.

| Function | Browser Implementation |
|----------|----------------------|
| `sha256(data)` | `crypto.subtle.digest('SHA-256', ...)` |
| `sha512(data)` | `crypto.subtle.digest('SHA-512', ...)` |
| `random_bytes(n)` | `crypto.getRandomValues()` |
| `aes128_ecb_encrypt(...)` | `crypto.subtle.encrypt()` (needs mode adaptation) |
| `bytes_to_hex(data)` | Pure JS conversion |
| `hex_to_bytes(hex)` | Pure JS conversion |
| `base64_encode(data)` | `btoa()` |
| `base64_decode(str)` | `atob()` |

**Note**: Web Crypto doesn't support ECB mode directly. May need a pure JS AES implementation or use CBC with single block.

### ez.mesh (~50 functions) - Simulated

Create a mock mesh network for testing.

```javascript
const mockMesh = {
  initialized: true,
  nodeId: 'SIMULA',
  shortId: 'SIM',
  nodes: [
    { path_hash: 0x42, name: 'TestNode1', rssi: -65, snr: 8.5, role: 2 },
    { path_hash: 0x73, name: 'TestNode2', rssi: -82, snr: 4.2, role: 1 },
  ],

  is_initialized: () => true,
  get_node_id: () => 'SIMULATOR01234',
  get_short_id: () => 'SIMULA',
  get_nodes: () => mockMesh.nodes,
  send_announce: () => true,
  // ... etc
};
```

### ez.radio (~20 functions) - Stubbed

Most functions return mock values or no-op.

```javascript
const mockRadio = {
  is_initialized: () => false, // or true with mock
  get_config: () => ({
    frequency: 915.0,
    bandwidth: 250,
    spreading_factor: 10,
    tx_power: 22
  }),
  send: () => 'ok',
  available: () => false,
};
```

### ez.audio (~10 functions)

Use Web Audio API.

```javascript
const audioCtx = new AudioContext();

function playTone(frequency, durationMs) {
  const oscillator = audioCtx.createOscillator();
  const gainNode = audioCtx.createGain();

  oscillator.connect(gainNode);
  gainNode.connect(audioCtx.destination);

  oscillator.frequency.value = frequency;
  oscillator.start();

  setTimeout(() => oscillator.stop(), durationMs);
}
```

### ez.gps (~10 functions) - Browser Geolocation

Can use actual browser geolocation for testing location features.

```javascript
const mockGPS = {
  location: null,

  init: () => {
    navigator.geolocation.watchPosition(pos => {
      mockGPS.location = {
        lat: pos.coords.latitude,
        lon: pos.coords.longitude,
        alt: pos.coords.altitude || 0,
        valid: true
      };
    });
    return true;
  },

  get_location: () => mockGPS.location,
  is_valid: () => mockGPS.location?.valid || false,
};
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Browser                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐  ┌───────────────┐  ┌─────────────────┐  │
│  │   Canvas     │  │  IndexedDB    │  │   Keyboard      │  │
│  │  (320x240)   │  │  Virtual FS   │  │    Events       │  │
│  └──────┬───────┘  └───────┬───────┘  └────────┬────────┘  │
│         │                  │                    │           │
│  ┌──────┴──────────────────┴────────────────────┴────────┐  │
│  │                  Mock Layer (JavaScript)               │  │
│  │                                                        │  │
│  │  ez.display   ez.keyboard   ez.system        │  │
│  │  ez.storage   ez.mesh       ez.crypto        │  │
│  │  ez.radio     ez.audio      ez.gps           │  │
│  └────────────────────────┬──────────────────────────────┘  │
│                           │                                  │
│  ┌────────────────────────┴──────────────────────────────┐  │
│  │                Wasmoon (Lua 5.4 WASM)                 │  │
│  │                                                        │  │
│  │  ┌──────────────────────────────────────────────────┐ │  │
│  │  │              data/scripts/*.lua                  │ │  │
│  │  │                                                  │ │  │
│  │  │  boot.lua                                        │ │  │
│  │  │    ├── services/scheduler.lua                   │ │  │
│  │  │    ├── services/screen_manager.lua              │ │  │
│  │  │    ├── services/main_loop.lua                   │ │  │
│  │  │    ├── ui/status_bar.lua                        │ │  │
│  │  │    └── ui/screens/main_menu.lua                 │ │  │
│  │  └──────────────────────────────────────────────────┘ │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Challenges

### 1. Main Loop Integration

**Good news**: The existing `main_loop.lua` is already browser-friendly! It exposes `_G.main_loop()` which C++ calls each frame, and internally uses `MainLoop.step()` for single iterations.

**Solution: Frame-based execution (Recommended)**

```javascript
// Mock yield as no-op (we yield at frame boundaries anyway)
lua.global.set('tdeck', {
  system: {
    yield: (ms) => { /* no-op in browser */ },
    millis: () => performance.now(),
    // ... other system functions
  }
});

// Run boot.lua which sets up _G.main_loop
await lua.doFile('/scripts/boot.lua');

// Frame loop using requestAnimationFrame
let lastFrame = 0;
function runFrame(timestamp) {
  // Throttle to ~60fps max, but allow slower
  if (timestamp - lastFrame >= 16) {
    try {
      lua.global.call('main_loop');
    } catch (e) {
      console.error('Lua error:', e);
    }
    lastFrame = timestamp;
  }
  requestAnimationFrame(runFrame);
}
requestAnimationFrame(runFrame);
```

**Alternative: Web Worker with real timing**

For more accurate timing simulation, run Lua in a Web Worker:

```javascript
// simulator-worker.js
importScripts('wasmoon.js');

let lua;
async function init() {
  const factory = new LuaFactory();
  lua = await factory.createEngine();
  // Setup mocks...
  await lua.doFile('/scripts/boot.lua');

  // Run at consistent intervals
  setInterval(() => {
    lua.global.call('main_loop');
    // Post screen buffer to main thread for rendering
    postMessage({ type: 'frame', buffer: getScreenBuffer() });
  }, 16);
}

// Main thread
const worker = new Worker('simulator-worker.js');
worker.onmessage = (e) => {
  if (e.data.type === 'frame') {
    renderToCanvas(e.data.buffer);
  }
};
```

### 2. Blocking Operations

Functions like `keyboard.read_blocking()` can't truly block in browser JavaScript.

**Good news**: The existing Lua scripts don't use `read_blocking()`! They already use the polling pattern (`available()` + `read()`), which works naturally with the frame-based approach. The solutions below are only needed if future code uses blocking calls.

Several solutions for blocking operations:

**Solution A: Coroutine Transformation (Recommended)**

Wasmoon supports Lua coroutines. Transform blocking calls to yield/resume patterns:

```javascript
// Keyboard state
const keyQueue = [];
let waitingForKey = null;

// Non-blocking read
keyboard.available = () => keyQueue.length > 0;
keyboard.read = () => keyQueue.shift() || null;

// "Blocking" read using coroutines
keyboard.read_blocking = () => {
  if (keyQueue.length > 0) {
    return keyQueue.shift();
  }
  // Return a special marker that Lua wrapper detects
  return { __await_key: true };
};

// Lua wrapper that handles the coroutine dance
const blockingWrapper = `
local real_read_blocking = ez.keyboard.read_blocking
ez.keyboard.read_blocking = function()
  while true do
    local result = real_read_blocking()
    if type(result) == "table" and result.__await_key then
      coroutine.yield("await_key")
    else
      return result
    end
  end
end
`;

// In frame loop, handle coroutine resumption
function runFrame() {
  const co = lua.global.get('_main_coroutine');
  if (co) {
    const [ok, result] = lua.global.call('coroutine.resume', co);
    if (result === 'await_key' && keyQueue.length > 0) {
      // Key available, will resume next frame
    }
  }
  requestAnimationFrame(runFrame);
}
```

**Solution B: Web Worker + SharedArrayBuffer (True Blocking)**

For applications requiring true blocking semantics:

```javascript
// Requires COOP/COEP headers on server:
// Cross-Origin-Opener-Policy: same-origin
// Cross-Origin-Embedder-Policy: require-corp

// Shared memory for keyboard state
const keyBuffer = new SharedArrayBuffer(256);
const keyArray = new Int32Array(keyBuffer);
// keyArray[0] = number of keys available
// keyArray[1..] = key codes

// In worker (can actually block)
keyboard.read_blocking = () => {
  // Wait until key available (blocks worker thread)
  while (Atomics.load(keyArray, 0) === 0) {
    Atomics.wait(keyArray, 0, 0, 100); // Wait up to 100ms
  }
  // Read key
  const keyCount = Atomics.load(keyArray, 0);
  const key = Atomics.load(keyArray, 1);
  // Shift remaining keys
  for (let i = 1; i < keyCount; i++) {
    Atomics.store(keyArray, i, Atomics.load(keyArray, i + 1));
  }
  Atomics.sub(keyArray, 0, 1);
  return decodeKey(key);
};

// Main thread (handles DOM events)
document.addEventListener('keydown', (e) => {
  const keyCode = encodeKey(e);
  const idx = Atomics.add(keyArray, 0, 1) + 1;
  Atomics.store(keyArray, idx, keyCode);
  Atomics.notify(keyArray, 0); // Wake up waiting worker
});
```

**Solution C: Rewrite Blocking Calls in Lua (Simplest)**

If modifying Lua code is acceptable, replace blocking patterns with polling:

```lua
-- Instead of:
local key = ez.keyboard.read_blocking()

-- Use:
local function wait_for_key()
  while not ez.keyboard.available() do
    ez.system.yield(10)
  end
  return ez.keyboard.read()
end
local key = wait_for_key()
```

This works naturally with the frame-based approach since `yield()` returns control.

**Recommendation**: Start with Solution C (polling pattern) for simplicity. The existing T-Deck code may already use polling in most places. Solution A (coroutines) is the fallback for any remaining blocking calls.

### Existing Async System (ESP32)

**Good news**: The T-Deck firmware already has a comprehensive async I/O system implemented in C++ (`/src/lua/async.cpp` and `/src/lua/async.h`). This system:

- Runs I/O operations on **Core 0** (worker task) while Lua runs on **Core 1**
- Uses **FreeRTOS queues** for cross-core communication
- Automatically **yields coroutines** via `lua_yield()` and **resumes** them via `lua_resume()` when operations complete
- Exposes these **global Lua functions**:

| Function | Purpose |
|----------|---------|
| `async_read(path)` | Read entire file as string |
| `async_read_bytes(path, offset, len)` | Read byte range from file |
| `async_write(path, data)` | Write string to file |
| `async_write_bytes(path, offset, data)` | Write at offset |
| `async_append(path, data)` | Append to file |
| `async_exists(path)` | Check if file exists |
| `async_json_read(path)` | Read and parse JSON file |
| `async_json_write(path, json_str)` | Write JSON to file |
| `async_rle_read(path, offset, len)` | Read RLE-compressed data |
| `async_aes_encrypt(key, data)` | AES-128 encryption |
| `async_aes_decrypt(key, data)` | AES-128 decryption |
| `async_hmac_sha256(key, data)` | HMAC-SHA256 |

**Current usage pattern** (must be called from a coroutine):
```lua
local co = coroutine.create(function()
    local data = async_read("/sd/some/file.txt")  -- Yields until complete
    -- Execution resumes here with result
    process(data)
end)
coroutine.resume(co)
```

**What's missing**: High-level `Async.run()` and `Async.await()` wrappers for cleaner syntax.

### Unified Async Coroutine System (Cross-Platform)

Building on the existing ESP32 async system, we can add a thin Lua wrapper that provides a cleaner API and works identically in the browser simulator.

#### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Lua Code                                 │
│  Async.run(function()                                            │
│      local data = async_read("/sd/file.txt")  -- yields         │
│      process(data)                                               │
│  end)                                                            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              Async Lua Wrapper (thin layer)                     │
│  - Async.run(fn) - create and start coroutine                   │
│  - Async.spawn(fn) - fire-and-forget variant                    │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
┌─────────────────────────────┐     ┌─────────────────────────────┐
│   ESP32 Backend (C++)       │     │  Browser Backend (JS)       │
│   ✅ ALREADY EXISTS         │     │   Needs implementation      │
│  - async_read, async_write  │     │  - Same global functions    │
│  - FreeRTOS worker on Core0 │     │  - Promise-based + yield    │
│  - lua_yield / lua_resume   │     │  - requestAnimationFrame    │
└─────────────────────────────┘     └─────────────────────────────┘
```

#### Lua Async Wrapper (`/scripts/services/async.lua`)

Since the C++ backend already handles `lua_yield()` and `lua_resume()` transparently, the Lua wrapper is minimal:

```lua
-- Thin wrapper for async coroutine management
local Async = {}

-- Run a function as an async coroutine
-- The function can use async_read, async_write, etc. which yield automatically
function Async.run(fn, on_complete, on_error)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok then
        if on_error then
            on_error(err)
        else
            error(err)
        end
    elseif coroutine.status(co) == "dead" and on_complete then
        -- Completed synchronously (no yields)
        on_complete()
    end
    -- If coroutine yielded, C++ AsyncIO will resume it when I/O completes
    return co
end

-- Fire-and-forget variant (errors go to global error handler)
function Async.spawn(fn)
    return Async.run(fn, nil, function(err)
        if show_error then
            show_error(err, "async")
        else
            print("[Async Error] " .. tostring(err))
        end
    end)
end

-- Check if we're currently in a coroutine (can use async functions)
function Async.in_coroutine()
    local running, is_main = coroutine.running()
    return running ~= nil and not is_main
end

return Async
```

**Note**: There's no explicit `Async.await()` needed because the `async_*` functions already yield and return results directly. The pattern is simply:

```lua
Async.run(function()
    local data = async_read("/sd/config.json")   -- yields, resumes with data
    local parsed = json_decode(data)
    async_write("/sd/backup.json", data)         -- yields, resumes with bool
    print("Done!")
end)
```

#### Browser JavaScript Backend

The browser needs to implement the same global `async_*` functions that the ESP32 provides. The key challenge is that Wasmoon doesn't support yielding across JS-to-Lua boundaries directly, so we need a polling approach.

```javascript
// Browser async I/O implementation
// Mirrors the ESP32's async.cpp functionality

class BrowserAsyncIO {
    constructor(lua) {
        this.lua = lua;
        this.pendingOps = new Map();  // id -> { promise, coroRef }
        this.nextId = 1;
        this.results = [];  // Completed results waiting to be processed
    }

    // Register all async_* functions as Lua globals
    registerBindings() {
        // async_read(path) -> string|nil
        this.lua.global.set('async_read', (path) => {
            return this._startOp('read', { path });
        });

        // async_read_bytes(path, offset, len) -> string|nil
        this.lua.global.set('async_read_bytes', (path, offset, len) => {
            return this._startOp('read_bytes', { path, offset, len });
        });

        // async_write(path, data) -> boolean
        this.lua.global.set('async_write', (path, data) => {
            return this._startOp('write', { path, data });
        });

        // async_exists(path) -> boolean
        this.lua.global.set('async_exists', (path) => {
            return this._startOp('exists', { path });
        });

        // async_json_read(path) -> string|nil
        this.lua.global.set('async_json_read', (path) => {
            return this._startOp('json_read', { path });
        });

        // async_json_write(path, json_string) -> boolean
        this.lua.global.set('async_json_write', (path, data) => {
            return this._startOp('json_write', { path, data });
        });

        // async_rle_read(path, offset, len) -> string|nil (decompressed)
        this.lua.global.set('async_rle_read', (path, offset, len) => {
            return this._startOp('rle_read', { path, offset, len });
        });
    }

    // Start an async operation
    _startOp(type, params) {
        const id = this.nextId++;
        let promise;

        switch (type) {
            case 'read':
            case 'json_read':
                promise = this._fileRead(params.path);
                break;
            case 'read_bytes':
                promise = this._fileReadBytes(params.path, params.offset, params.len);
                break;
            case 'write':
            case 'json_write':
                promise = this._fileWrite(params.path, params.data);
                break;
            case 'exists':
                promise = this._fileExists(params.path);
                break;
            case 'rle_read':
                promise = this._rleRead(params.path, params.offset, params.len);
                break;
            default:
                promise = Promise.reject(new Error(`Unknown op: ${type}`));
        }

        // Store pending operation
        this.pendingOps.set(id, { type, promise });

        // When complete, queue result for processing
        promise
            .then(result => this.results.push({ id, success: true, result }))
            .catch(err => this.results.push({ id, success: false, error: err.message }));

        // Return a marker that Lua can detect
        return { __pending_async: id };
    }

    // File operations using IndexedDB + fetch fallback
    async _fileRead(path) {
        // Try IndexedDB first (for user-written files)
        const cached = await idbGet(path);
        if (cached !== undefined) return cached;

        // Fall back to fetch from server (for bundled scripts)
        const response = await fetch(`/data${path}`);
        if (!response.ok) return null;
        return response.text();
    }

    async _fileReadBytes(path, offset, len) {
        const data = await this._fileRead(path);
        if (!data) return null;
        return data.slice(offset, offset + len);
    }

    async _fileWrite(path, data) {
        await idbSet(path, data);
        return true;
    }

    async _fileExists(path) {
        const cached = await idbGet(path);
        if (cached !== undefined) return true;
        const response = await fetch(`/data${path}`, { method: 'HEAD' });
        return response.ok;
    }

    async _rleRead(path, offset, len) {
        const compressed = await this._fileReadBytes(path, offset, len);
        if (!compressed) return null;
        return rleDecompress(compressed);
    }

    // Call from main loop to process completed operations
    update() {
        // Process all completed results
        while (this.results.length > 0) {
            const { id, success, result, error } = this.results.shift();
            const op = this.pendingOps.get(id);
            if (!op) continue;
            this.pendingOps.delete(id);

            // Resume the coroutine that was waiting
            // This requires tracking which coroutine yielded for this op
            // (simplified - actual implementation needs coroutine references)
        }
    }
}

// RLE decompression (matches ESP32 implementation)
function rleDecompress(data) {
    const output = [];
    let i = 0;
    while (i < data.length) {
        if (data.charCodeAt(i) === 0xFF && i + 2 < data.length) {
            const count = data.charCodeAt(i + 1);
            const value = data.charAt(i + 2);
            for (let j = 0; j < count; j++) output.push(value);
            i += 3;
        } else {
            output.push(data.charAt(i));
            i++;
        }
    }
    return output.join('');
}
```

**Note**: The browser implementation is more complex because Wasmoon doesn't support true `lua_yield()` from JS callbacks. Two approaches:

1. **Polling pattern** (shown above): Async functions return immediately with a marker, Lua code polls for completion
2. **Web Worker + SharedArrayBuffer**: True blocking possible but requires COOP/COEP headers

#### Usage Example

```lua
-- Same code works on ESP32 and browser!
local Async = require("services/async")

Async.run(function()
    -- Load config file asynchronously
    local content = async_read("/sd/data/config.json")
    if content then
        local config = json_decode(content)
        print("Loaded config: " .. config.name)
    end

    -- Write a file
    local ok = async_write("/sd/data/log.txt", "Hello from async!")
    print("Write result:", ok)
end)
```

#### Benefits of Unified Async System

1. **Code Portability**: Same Lua code runs on both platforms
2. **Clean Syntax**: Direct returns from `async_*` functions (no explicit await needed)
3. **Non-blocking**: UI stays responsive during I/O operations
4. **Already Working**: ESP32 backend exists and is production-tested
5. **Composable**: Async functions can call other async functions from coroutines
6. **Error Handling**: Errors propagate through the coroutine chain

#### Implementation Status

| Component | Status | Notes |
|-----------|--------|-------|
| ESP32 C++ Backend | ✅ Done | `/src/lua/async.cpp` - 12 async functions |
| Global Lua bindings | ✅ Done | `async_read`, `async_write`, etc. |
| Lua `Async.run()` wrapper | 📝 TODO | Simple ~30 line helper |
| Browser async backend | 📝 TODO | Needs IndexedDB + fetch implementation |

#### Migration Path

1. **Add `Async` Lua wrapper** - Create `/scripts/services/async.lua` with `run()` and `spawn()`
2. **Update boot.lua** - Load Async service at startup
3. **Browser implementation** - Implement same `async_*` globals in JavaScript
4. **No API changes needed** - Existing code already uses `async_*` functions

### 3. Virtual Filesystem

Scripts reference paths like `/scripts/ui/screens/main_menu.lua`. Need to:

```javascript
// Pre-load all scripts at startup
const scripts = new Map();

async function loadAllScripts() {
  const manifest = await fetch('/scripts/manifest.json').then(r => r.json());
  for (const path of manifest.files) {
    const content = await fetch(`/lua${path}`).then(r => r.text());
    scripts.set(path, content);
  }
}

// Override dofile
lua.global.set('dofile', (path) => {
  const content = scripts.get(path);
  if (!content) throw new Error(`File not found: ${path}`);
  return lua.doString(content);
});
```

### 4. Binary Data Handling

Lua strings can contain binary data (bitmaps, crypto). Ensure proper handling:

```javascript
// Use Uint8Array for binary data
function luaStringToBytes(str) {
  return new Uint8Array([...str].map(c => c.charCodeAt(0)));
}

function bytesToLuaString(bytes) {
  return String.fromCharCode(...bytes);
}
```

### 5. Font Rendering

The firmware uses a specific bitmap font. Options:
- **Simple**: Use CSS monospace font with similar metrics (8x16 pixels)
- **Accurate**: Port the bitmap font data and render pixel-by-pixel

```javascript
// Simple approach
ctx.font = '16px monospace';
ctx.textBaseline = 'top';

// Accurate approach: render from bitmap font
function drawChar(x, y, charCode, color) {
  const charData = FONT_DATA[charCode];
  for (let row = 0; row < 16; row++) {
    for (let col = 0; col < 8; col++) {
      if (charData[row] & (0x80 >> col)) {
        ctx.fillRect(x + col, y + row, 1, 1);
      }
    }
  }
}
```

## File Structure

```
tools/simulator/
├── index.html              # Main HTML page
├── simulator.js            # Entry point, initialization
├── package.json            # Dependencies (wasmoon)
├── mock/
│   ├── display.js          # Canvas rendering implementation
│   ├── keyboard.js         # Keyboard event handling
│   ├── storage.js          # IndexedDB + localStorage
│   ├── system.js           # Time, timers, memory mocks
│   ├── mesh.js             # Simulated mesh network
│   ├── radio.js            # Stubbed radio functions
│   ├── crypto.js           # Web Crypto wrappers
│   ├── audio.js            # Web Audio implementation
│   └── gps.js              # Geolocation API wrapper
├── fonts/
│   └── tdeck-font.json     # Bitmap font data (if needed)
├── assets/
│   └── icons/              # Icon assets
└── scripts/                # Symlink or copy of data/scripts/
```

## Development Phases

### Phase 1: Core Framework
- [ ] Set up Wasmoon
- [ ] Implement `ez.display` basics (clear, fill_rect, draw_text)
- [ ] Implement `ez.keyboard` (available, read)
- [ ] Implement `ez.system` (millis, log, yield)
- [ ] Virtual filesystem with dofile override
- [ ] Get boot.lua to start without errors

### Phase 2: Full Display
- [ ] All drawing primitives
- [ ] Bitmap rendering (draw_bitmap, draw_indexed_bitmap)
- [ ] Color constants
- [ ] Font rendering refinement

### Phase 3: Storage & Persistence
- [ ] IndexedDB for files
- [ ] localStorage for preferences
- [ ] JSON encode/decode

### Phase 4: Services
- [ ] Timer implementation
- [ ] Scheduler integration
- [ ] Main loop frame-based execution

### Phase 5: Mock Hardware
- [ ] Simulated mesh nodes
- [ ] GPS (browser geolocation)
- [ ] Audio (Web Audio API)
- [ ] Crypto (Web Crypto API)

### Phase 6: Developer Experience
- [ ] Hot reload of Lua scripts
- [ ] Console panel for logs
- [ ] Simulated trackball (mouse drag)
- [ ] Screenshot/recording
- [ ] Simulated node messages

## Usage

```bash
cd tools/simulator
npm install
npm start
# Opens browser at http://localhost:3000
```

## Future Enhancements

- **Multi-device simulation**: Run multiple simulator instances that can "see" each other via WebRTC or WebSocket
- **Script editor**: Built-in Monaco editor for modifying Lua scripts
- **State snapshots**: Save/restore simulator state
- **Automated testing**: Puppeteer integration for UI tests
- **Mobile support**: Touch events for trackball simulation

## References

- Wasmoon: https://github.com/ceifa/wasmoon
- Fengari: https://github.com/fengari-lua/fengari
- Web Crypto API: https://developer.mozilla.org/en-US/docs/Web/API/Web_Crypto_API
- Web Audio API: https://developer.mozilla.org/en-US/docs/Web/API/Web_Audio_API
- IndexedDB: https://developer.mozilla.org/en-US/docs/Web/API/IndexedDB_API
