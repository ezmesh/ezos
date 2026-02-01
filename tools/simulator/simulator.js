/**
 * ezOS Browser Simulator
 * Runs Lua scripts using Wasmoon (Lua 5.4 via WebAssembly)
 */

// Wasmoon is loaded via script tag in index.html (UMD build exposes window.wasmoon)
const { LuaFactory } = window.wasmoon;

// Import mock modules
import { createDisplayModule, loadFonts } from './mock/display.js';
import { createKeyboardModule } from './mock/keyboard.js';
import { createSystemModule } from './mock/system.js';
import { createStorageModule, preloadBinaryFiles } from './mock/storage.js';
import { createMeshModule } from './mock/mesh.js';
import { createRadioModule } from './mock/radio.js';
import { createAudioModule } from './mock/audio.js';
import { createGpsModule } from './mock/gps.js';
import { createCryptoModule } from './mock/crypto.js';
import { createBusModule } from './mock/bus.js';

// UI Elements
const canvas = document.getElementById('screen');
const ctx = canvas.getContext('2d');
const statusEl = document.getElementById('status');
const consoleEl = document.getElementById('console');
const lastKeyEl = document.getElementById('last-key');
const btnRestart = document.getElementById('btn-restart');
const btnPause = document.getElementById('btn-pause');

// Overlay elements
const overlayImg = document.getElementById('overlay');
const overlayToggle = document.getElementById('overlay-toggle');
const overlayFile = document.getElementById('overlay-file');
const overlayOpacity = document.getElementById('overlay-opacity');
const opacityValue = document.getElementById('opacity-value');

// Lua console elements
const luaInput = document.getElementById('lua-input');
const luaExecute = document.getElementById('lua-execute');
const luaOutput = document.getElementById('lua-output');

// Simulator state
let lua = null;
let running = false;
let paused = false;
let frameCount = 0;
let lastFrameTime = 0;
let hasError = false;
let lastError = null;
let keyboardModule = null;  // Reference to keyboard module for virtual keyboard
let busModule = null;       // Reference to bus module for message processing

// Console logging
function log(msg, type = 'log') {
    const line = document.createElement('div');
    line.className = type;
    const time = new Date().toLocaleTimeString('en-US', { hour12: false });
    line.textContent = `[${time}] ${msg}`;
    consoleEl.appendChild(line);
    consoleEl.scrollTop = consoleEl.scrollHeight;

    // Keep console from growing too large
    while (consoleEl.children.length > 500) {
        consoleEl.removeChild(consoleEl.firstChild);
    }

    // Also log to browser console
    console[type === 'error' ? 'error' : type === 'warn' ? 'warn' : 'log']('[Sim]', msg);
}

function setStatus(text, type = 'loading') {
    statusEl.textContent = text;
    statusEl.className = `status ${type}`;
}

// Virtual filesystem - load scripts from data/scripts/
const scriptCache = new Map();

// Base path for scripts - detected automatically
let scriptBasePath = null;

async function detectBasePath() {
    const possiblePaths = [
        './data/scripts/',
        '../data/scripts/',
        '../../data/scripts/',
        '/data/scripts/',
    ];

    for (const basePath of possiblePaths) {
        try {
            const response = await fetch(`${basePath}boot.lua`, { method: 'HEAD' });
            if (response.ok) {
                log(`Script base path: ${basePath}`, 'info');
                return basePath;
            }
        } catch (e) {
            // Try next path
        }
    }

    throw new Error('Could not find data/scripts/ directory. Run server from project root.');
}

async function loadScript(path) {
    if (!scriptBasePath) {
        scriptBasePath = await detectBasePath();
    }

    let normalizedPath = path;
    if (path.startsWith('/scripts/')) {
        normalizedPath = path.substring(9);
    }

    if (scriptCache.has(normalizedPath)) {
        return scriptCache.get(normalizedPath);
    }

    try {
        // Add cache-busting parameter to avoid browser caching issues during development
        const cacheBuster = `?t=${Date.now()}`;
        const response = await fetch(`${scriptBasePath}${normalizedPath}${cacheBuster}`);
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        const content = await response.text();
        scriptCache.set(normalizedPath, content);
        return content;
    } catch (e) {
        log(`Failed to load: ${path} - ${e.message}`, 'error');
        return null;
    }
}

function getScriptSync(path) {
    let normalizedPath = path;
    if (path.startsWith('/scripts/')) {
        normalizedPath = path.substring(9);
    }
    return scriptCache.get(normalizedPath) || null;
}

// Preload all required scripts before boot
async function preloadScripts() {
    const scripts = [
        // Core modules (loaded first)
        'core/modules.lua',
        'core/class.lua',
        'core/utils.lua',
        'core/timers.lua',
        'core/time.lua',
        'boot.lua',
        // Services
        'services/scheduler.lua',
        'services/screen_manager.lua',
        'services/main_loop.lua',
        'services/theme.lua',
        'services/logger.lua',
        'services/contacts.lua',
        'services/direct_messages.lua',
        'services/status_services.lua',
        'services/screen_timeout.lua',
        'services/channels.lua',
        'services/debug.lua',
        'services/timezone_sync.lua',
        // UI utilities
        'ui/overlays.lua',
        'ui/status_bar.lua',
        'ui/title_bar.lua',
        'ui/icons.lua',
        'ui/bitmap.lua',
        'ui/messagebox.lua',
        'ui/toast.lua',
        'ui/cards.lua',
        'ui/text_utils.lua',
        'ui/splash.lua',
        'ui/sound_utils.lua',
        'ui/list_mixin.lua',
        'ui/node_utils.lua',
        'ui/time_utils.lua',
        // UI components (individual files)
        'ui/components/text_input.lua',
        'ui/components/button.lua',
        'ui/components/checkbox.lua',
        'ui/components/radio_group.lua',
        'ui/components/dropdown.lua',
        'ui/components/text_area.lua',
        'ui/components/vertical_list.lua',
        'ui/components/number_input.lua',
        'ui/components/toggle.lua',
        'ui/components/flex.lua',
        'ui/components/grid.lua',
        'ui/components/label.lua',
        'ui/components/init.lua',
        'ui/components.lua',
        'ui/screens/main_menu.lua',
        'ui/screens/app_menu.lua',
        'ui/screens/settings.lua',
        'ui/screens/settings_category.lua',
        'ui/screens/error_screen.lua',
        'ui/screens/nodes.lua',
        'ui/screens/node_info.lua',
        'ui/screens/node_details.lua',
        'ui/screens/messages.lua',
        'ui/screens/channels.lua',
        'ui/screens/channel_view.lua',
        'ui/screens/channel_compose.lua',
        'ui/screens/join_channel.lua',
        'ui/screens/compose.lua',
        'ui/screens/conversation_view.lua',
        'ui/screens/dm_conversation.lua',
        'ui/screens/contacts.lua',
        'ui/screens/files.lua',
        'ui/screens/file_edit.lua',
        'ui/screens/system_info.lua',
        'ui/screens/games_menu.lua',
        'ui/screens/snake.lua',
        'ui/screens/tetris.lua',
        'ui/screens/breakout.lua',
        'ui/screens/poker.lua',
        'ui/screens/map_viewer.lua',
        'ui/screens/map_nodes.lua',
        'ui/screens/radio_test.lua',
        'ui/screens/input_test.lua',
        'ui/screens/sound_test.lua',
        'ui/screens/color_test.lua',
        'ui/screens/color_picker.lua',
        'ui/screens/keyboard_matrix.lua',
        'ui/screens/key_repeat_test.lua',
        'ui/screens/trackball_test.lua',
        'ui/screens/hotkey_config.lua',
        'ui/screens/log_viewer.lua',
        'ui/screens/usb_transfer.lua',
        'ui/screens/storage.lua',
        'ui/screens/set_clock.lua',
        'ui/screens/packets.lua',
        'ui/screens/test_icon.lua',
        'ui/screens/testing_menu.lua',
        'ui/screens/bus_test.lua',
        'ui/screens/component_test.lua',
        'ui/screens/sprite_test.lua',
    ];

    log(`Preloading ${scripts.length} scripts...`, 'info');

    let loaded = 0;
    let failed = 0;

    for (const script of scripts) {
        const content = await loadScript(script);
        if (content) {
            loaded++;
        } else {
            failed++;
        }
    }

    log(`Preloaded ${loaded} scripts (${failed} failed)`, 'info');
}

// Initialize Lua environment
async function initLua() {
    setStatus('Loading fonts...', 'loading');

    // Load bitmap fonts from C++ headers
    await loadFonts();
    log('Bitmap fonts loaded', 'info');

    setStatus('Loading binary files...', 'loading');

    // Preload binary files (maps, etc.)
    await preloadBinaryFiles();
    log('Binary files loaded', 'info');

    setStatus('Loading Wasmoon (Lua 5.4)...', 'loading');

    // Create Lua factory and instance
    const factory = new LuaFactory();
    lua = await factory.createEngine({
        // Disable automatic Promise handling - we'll handle it manually
        injectObjects: true,
    });

    setStatus('Setting up API...', 'loading');

    // Create mock modules
    const display = createDisplayModule(ctx, canvas);
    const keyboard = createKeyboardModule(canvas, (key) => {
        lastKeyEl.textContent = key.character || key.special || '-';
    });
    keyboardModule = keyboard;  // Store reference for virtual keyboard
    const system = createSystemModule(log);
    const storage = createStorageModule();
    const mesh = createMeshModule();
    const radio = createRadioModule();
    const audio = createAudioModule();
    const gps = createGpsModule();
    const cryptoMod = createCryptoModule();
    const bus = createBusModule();
    busModule = bus;  // Store reference for main loop

    // Set up modules as top-level globals first
    lua.global.set('_display', display);
    lua.global.set('_keyboard', keyboard);
    lua.global.set('_system', system);
    lua.global.set('_storage', storage);
    lua.global.set('_mesh', mesh);
    lua.global.set('_radio', radio);
    lua.global.set('_audio', audio);
    lua.global.set('_gps', gps);
    lua.global.set('_crypto', cryptoMod);
    lua.global.set('_bus', bus);

    // Create ez.log function
    lua.global.set('_log', (msg) => {
        if (log) {
            log(String(msg), 'log');
        } else {
            console.log('[Lua]', msg);
        }
    });

    // Create the ez namespace in Lua to avoid JS object nesting issues
    await lua.doString(`
        ez = {
            display = _display,
            keyboard = _keyboard,
            system = _system,
            storage = _storage,
            mesh = _mesh,
            radio = _radio,
            audio = _audio,
            gps = _gps,
            crypto = _crypto,
            bus = _bus,
            log = _log,
        }
        -- Also set global aliases
        display = _display
        keyboard = _keyboard
        system = _system
        storage = _storage
        mesh = _mesh
        radio = _radio
        audio = _audio
        gps = _gps
        -- Clean up temp globals
        _display = nil
        _keyboard = nil
        _system = nil
        _storage = nil
        _mesh = nil
        _radio = nil
        _audio = nil
        _gps = nil
        _crypto = nil
        _bus = nil
        _log = nil
    `);

    // Simulator flag
    lua.global.set('__SIMULATOR__', true);

    // async_read function
    lua.global.set('async_read', (path) => {
        if (path.startsWith('/scripts/')) {
            const content = getScriptSync(path);
            if (!content) {
                log(`Script not preloaded: ${path}`, 'error');
                return null;
            }
            return content;
        }
        return storage.read(path);
    });

    // Other async functions (synchronous in simulator)
    lua.global.set('async_write', (path, data) => storage.write(path, data));
    lua.global.set('async_exists', (path) => storage.exists(path));
    lua.global.set('_raw_async_read_bytes', (path, offset, len) => {
        // Use storage.read_bytes which handles both binary files and localStorage
        // Now synchronous - uses XMLHttpRequest for Range requests
        try {
            const result = storage.read_bytes(path, offset, len);
            // Ensure we return undefined (not null) for Lua nil conversion
            if (result === null || result === undefined) {
                return undefined;
            }
            return result;
        } catch (e) {
            console.error(`[Storage] async_read_bytes error: ${e.message}`);
            return undefined;
        }
    });

    // Wrapper that converts byte arrays to strings (Wasmoon returns arrays to avoid null-byte truncation)
    await lua.doString(`
        do
            local raw_read = _raw_async_read_bytes  -- Capture in local before clearing global
            function async_read_bytes(path, offset, len)
                local result = raw_read(path, offset, len)
                if result == nil then return nil end
                if type(result) == "string" then return result end
                -- Convert array/table/userdata to string
                local chars = {}
                local length = result.length or #result
                -- Detect 1-indexed (Wasmoon tables have nil at [0] but value at [1])
                local start_idx = 0
                if result[0] == nil and result[1] ~= nil then
                    start_idx = 1
                end
                for i = 0, length - 1 do
                    local byte = result[start_idx + i]
                    if byte then
                        chars[#chars + 1] = string.char(byte)
                    end
                end
                return table.concat(chars)
            end
        end
        _raw_async_read_bytes = nil  -- Clean up global
    `);

    // RLE decompression for map tiles
    // Format: 0xFF <count> <value> = repeat value count times, otherwise literal byte
    // Returns array of byte values (to avoid null-byte truncation in Wasmoon)
    lua.global.set('async_rle_read', (path, offset, len) => {
        const compressed = storage.read_bytes(path, offset, len);
        if (!compressed) return undefined;  // undefined -> nil in Lua

        // compressed is now an array of byte values

        // First pass: calculate output size
        let outputSize = 0;
        let i = 0;
        while (i < compressed.length) {
            if (compressed[i] === 0xFF && i + 2 < compressed.length) {
                outputSize += compressed[i + 1];
                i += 3;
            } else {
                outputSize++;
                i++;
            }
        }

        // Second pass: decompress into array
        const output = [];
        i = 0;
        while (i < compressed.length) {
            if (compressed[i] === 0xFF && i + 2 < compressed.length) {
                const count = compressed[i + 1];
                const value = compressed[i + 2];
                for (let j = 0; j < count; j++) {
                    output.push(value);
                }
                i += 3;
            } else {
                output.push(compressed[i]);
                i++;
            }
        }

        return output;
    });
    lua.global.set('async_append', (path, data) => {
        const existing = storage.read(path) || '';
        return storage.write(path, existing + data);
    });
    lua.global.set('async_json_read', (path) => storage.read(path));
    lua.global.set('async_json_write', (path, data) => storage.write(path, data));

    // JSON helpers
    lua.global.set('json_encode', (value) => {
        try {
            return JSON.stringify(value);
        } catch (e) {
            return null;
        }
    });

    lua.global.set('json_decode', (str) => {
        try {
            return JSON.parse(str);
        } catch (e) {
            return null;
        }
    });

    // Global print
    lua.global.set('print', (...args) => {
        log(args.map(a => String(a)).join('\t'), 'log');
    });

    log('Lua environment initialized (Wasmoon)', 'info');
    return true;
}

// Load and run boot.lua
async function boot() {
    setStatus('Preloading scripts...', 'loading');

    try {
        await preloadScripts();

        const bootScript = getScriptSync('boot.lua');
        if (!bootScript) {
            throw new Error('Failed to load boot.lua');
        }

        setStatus('Executing boot.lua...', 'loading');
        log('Executing boot.lua...', 'info');
        await lua.doString(bootScript);

        setStatus('Running', 'running');
        running = true;
        btnPause.disabled = false;

        // Start main loop
        requestAnimationFrame(mainLoop);

    } catch (e) {
        log(`Boot failed: ${e.message}`, 'error');
        console.error(e);
        setStatus(`Error: ${e.message}`, 'error');
        hasError = true;
        lastError = e.message;
        showErrorScreen(e.message);
    }
}

// Display error screen on canvas
function showErrorScreen(errorMessage) {
    ctx.fillStyle = '#1a0000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    // Red border
    ctx.strokeStyle = '#ff0000';
    ctx.lineWidth = 4;
    ctx.strokeRect(2, 2, canvas.width - 4, canvas.height - 4);

    // Title
    ctx.fillStyle = '#ff4444';
    ctx.font = 'bold 18px monospace';
    ctx.textAlign = 'center';
    ctx.fillText('RUNTIME ERROR', canvas.width / 2, 30);

    // Error message with word wrap
    ctx.fillStyle = '#ffffff';
    ctx.font = '12px monospace';
    ctx.textAlign = 'left';

    const maxWidth = canvas.width - 20;
    const lineHeight = 16;
    let y = 60;

    // Simple word wrap
    const words = errorMessage.split(/\s+/);
    let line = '';
    for (const word of words) {
        const testLine = line + (line ? ' ' : '') + word;
        const metrics = ctx.measureText(testLine);
        if (metrics.width > maxWidth && line) {
            ctx.fillText(line, 10, y);
            line = word;
            y += lineHeight;
            if (y > canvas.height - 40) break;
        } else {
            line = testLine;
        }
    }
    if (line && y <= canvas.height - 40) {
        ctx.fillText(line, 10, y);
    }

    // Footer
    ctx.fillStyle = '#888888';
    ctx.font = '11px monospace';
    ctx.textAlign = 'center';
    ctx.fillText('Press Restart to reload', canvas.width / 2, canvas.height - 15);
    ctx.textAlign = 'left';
}

// Main loop - calls Lua main_loop() each frame
async function mainLoop(timestamp) {
    if (!running) return;

    // Stop loop if we had an error
    if (hasError) {
        showErrorScreen(lastError);
        setStatus(`Error: ${lastError.substring(0, 50)}...`, 'error');
        return;
    }

    if (paused) {
        requestAnimationFrame(mainLoop);
        return;
    }

    // Throttle to ~30fps
    if (timestamp - lastFrameTime < 33) {
        requestAnimationFrame(mainLoop);
        return;
    }
    lastFrameTime = timestamp;

    try {
        // Process message bus (deliver queued messages)
        if (busModule) {
            busModule._process();
        }

        // Call the global main_loop function if it exists
        const mainLoopFn = lua.global.get('main_loop');
        if (typeof mainLoopFn === 'function') {
            await mainLoopFn();
        }

        frameCount++;

    } catch (e) {
        log(`Runtime error: ${e.message}`, 'error');
        console.error(e);
        hasError = true;
        lastError = e.message;
        showErrorScreen(e.message);
        setStatus(`Error: ${e.message.substring(0, 50)}...`, 'error');
        return;  // Stop the loop
    }

    requestAnimationFrame(mainLoop);
}

// Button handlers
btnRestart.addEventListener('click', async () => {
    running = false;
    paused = false;
    frameCount = 0;
    hasError = false;
    lastError = null;
    busModule = null;
    btnPause.textContent = 'Pause';
    btnPause.disabled = true;

    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    consoleEl.innerHTML = '';
    scriptCache.clear();

    log('Restarting simulator...', 'info');
    await initLua();
    await boot();
});

btnPause.addEventListener('click', () => {
    paused = !paused;
    btnPause.textContent = paused ? 'Resume' : 'Pause';
    setStatus(paused ? 'Paused' : 'Running', paused ? 'loading' : 'running');
});

canvas.addEventListener('click', () => {
    canvas.focus();
});

canvas.tabIndex = 0;

// Virtual keyboard handling
const virtualKeyboard = document.getElementById('virtual-keyboard');
if (virtualKeyboard) {
    virtualKeyboard.addEventListener('click', (e) => {
        const keyEl = e.target.closest('.key');
        if (!keyEl || !keyboardModule) return;

        const keyStr = keyEl.dataset.key;
        if (!keyStr) return;

        // Visual feedback
        keyEl.classList.add('pressed');
        setTimeout(() => keyEl.classList.remove('pressed'), 100);

        // Inject the key
        keyboardModule.injectKey(keyStr);

        // Keep canvas focused
        canvas.focus();
    });
}

// Overlay handling
overlayToggle.addEventListener('change', () => {
    overlayImg.style.display = overlayToggle.checked ? 'block' : 'none';
});

overlayFile.addEventListener('change', (e) => {
    const file = e.target.files[0];
    if (file) {
        const reader = new FileReader();
        reader.onload = (event) => {
            overlayImg.src = event.target.result;
            overlayToggle.checked = true;
            overlayImg.style.display = 'block';
            log(`Loaded overlay: ${file.name}`, 'info');
        };
        reader.readAsDataURL(file);
    }
});

overlayOpacity.addEventListener('input', () => {
    const opacity = overlayOpacity.value / 100;
    overlayImg.style.opacity = opacity;
    opacityValue.textContent = `${overlayOpacity.value}%`;
});

// Lua console handling
async function executeLua(code) {
    if (!lua || !running) {
        luaOutput.textContent = 'Error: Simulator not running';
        luaOutput.className = 'lua-output error';
        return;
    }

    try {
        // Wrap expression to return value, or execute as statement
        let wrappedCode;
        if (code.includes('=') || code.includes('for ') || code.includes('if ') ||
            code.includes('function ') || code.includes('local ') || code.includes('return ')) {
            // Statement - execute directly
            wrappedCode = code;
        } else {
            // Expression - wrap to get return value
            wrappedCode = `return ${code}`;
        }

        const result = await lua.doString(wrappedCode);

        // Format result
        let output;
        if (result === undefined || result === null) {
            output = 'nil';
        } else if (typeof result === 'object') {
            try {
                output = JSON.stringify(result, null, 2);
            } catch {
                output = String(result);
            }
        } else {
            output = String(result);
        }

        luaOutput.textContent = output;
        luaOutput.className = 'lua-output success';
        log(`[Lua] > ${code}`, 'info');
        log(`[Lua] = ${output}`, 'log');
    } catch (e) {
        luaOutput.textContent = `Error: ${e.message}`;
        luaOutput.className = 'lua-output error';
        log(`[Lua] > ${code}`, 'info');
        log(`[Lua] Error: ${e.message}`, 'error');
    }
}

luaExecute.addEventListener('click', () => {
    const code = luaInput.value.trim();
    if (code) {
        executeLua(code);
    }
});

luaInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
        e.preventDefault();
        const code = luaInput.value.trim();
        if (code) {
            executeLua(code);
        }
    }
    // Stop propagation to prevent simulator keyboard handling
    e.stopPropagation();
});

// Initialize on page load
async function init() {
    log('T-Deck OS Simulator starting (Wasmoon - Lua 5.4)...', 'info');

    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    ctx.fillStyle = '#00d4ff';
    ctx.font = '16px monospace';
    ctx.textAlign = 'center';
    ctx.fillText('Loading...', canvas.width / 2, canvas.height / 2);
    ctx.textAlign = 'left';

    try {
        await initLua();
        await boot();
    } catch (e) {
        log(`Initialization failed: ${e.message}`, 'error');
        console.error(e);
        setStatus(`Failed: ${e.message}`, 'error');
    }
}

init();
