/**
 * T-Deck OS Browser Simulator
 * Runs Lua scripts using Wasmoon with mocked tdeck.* API
 */

import { LuaFactory } from 'https://cdn.jsdelivr.net/npm/wasmoon@1.16.0/+esm';

// Import mock modules
import { createDisplayModule } from './mock/display.js';
import { createKeyboardModule } from './mock/keyboard.js';
import { createSystemModule } from './mock/system.js';
import { createStorageModule } from './mock/storage.js';
import { createMeshModule } from './mock/mesh.js';
import { createRadioModule } from './mock/radio.js';
import { createAudioModule } from './mock/audio.js';
import { createGpsModule } from './mock/gps.js';
import { createCryptoModule } from './mock/crypto.js';

// UI Elements
const canvas = document.getElementById('screen');
const ctx = canvas.getContext('2d');
const statusEl = document.getElementById('status');
const consoleEl = document.getElementById('console');
const lastKeyEl = document.getElementById('last-key');
const btnRestart = document.getElementById('btn-restart');
const btnPause = document.getElementById('btn-pause');

// Simulator state
let lua = null;
let running = false;
let paused = false;
let frameCount = 0;
let lastFrameTime = 0;

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
    // Try different possible paths based on where the server is run from
    const possiblePaths = [
        './data/scripts/',           // Server run from project root
        '../data/scripts/',          // Server run from tools/
        '../../data/scripts/',       // Server run from tools/simulator/
        '/data/scripts/',            // Absolute path from root
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
    // Detect base path on first call
    if (!scriptBasePath) {
        scriptBasePath = await detectBasePath();
    }

    // Normalize path - remove /scripts/ prefix if present
    let normalizedPath = path;
    if (path.startsWith('/scripts/')) {
        normalizedPath = path.substring(9);
    }

    if (scriptCache.has(normalizedPath)) {
        return scriptCache.get(normalizedPath);
    }

    try {
        const response = await fetch(`${scriptBasePath}${normalizedPath}`);
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        const content = await response.text();
        scriptCache.set(normalizedPath, content);
        log(`Loaded: ${normalizedPath}`, 'info');
        return content;
    } catch (e) {
        log(`Failed to load: ${path} - ${e.message}`, 'error');
        return null;
    }
}

// Get script from cache synchronously (for Lua dofile)
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
        'boot.lua',
        'services/scheduler.lua',
        'services/screen_manager.lua',
        'services/main_loop.lua',
        'services/theme.lua',
        'services/logger.lua',
        'services/contacts.lua',
        'services/direct_messages.lua',
        'services/status_services.lua',
        'services/screen_timeout.lua',
        'ui/overlays.lua',
        'ui/status_bar.lua',
        'ui/title_bar.lua',
        'ui/icons.lua',
        'ui/bitmap.lua',
        'ui/messagebox.lua',
        'ui/cards.lua',
        'ui/components.lua',
        'ui/text_utils.lua',
        'ui/splash.lua',
        'ui/sound_utils.lua',
        'services/channels.lua',
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
    setStatus('Loading Wasmoon...', 'loading');

    const factory = new LuaFactory();
    lua = await factory.createEngine();

    setStatus('Setting up API...', 'loading');

    // Create mock modules
    const display = createDisplayModule(ctx, canvas);
    const keyboard = createKeyboardModule(canvas, (key) => {
        lastKeyEl.textContent = key.character || key.special || '-';
    });
    const system = createSystemModule(log);
    const storage = createStorageModule();
    const mesh = createMeshModule();
    const radio = createRadioModule();
    const audio = createAudioModule();
    const gps = createGpsModule();
    const crypto = createCryptoModule();

    // Create tdeck namespace with all modules
    // Wasmoon works best when setting entire objects at once
    lua.global.set('tdeck', {
        display: display,
        keyboard: keyboard,
        system: system,
        storage: storage,
        mesh: mesh,
        radio: radio,
        audio: audio,
        gps: gps,
        crypto: crypto,
    });

    // Global aliases for convenience (some scripts use both patterns)
    lua.global.set('display', display);
    lua.global.set('keyboard', keyboard);
    lua.global.set('system', system);
    lua.global.set('storage', storage);
    lua.global.set('mesh', mesh);
    lua.global.set('radio', radio);
    lua.global.set('audio', audio);
    lua.global.set('gps', gps);

    // Synchronous script loader (scripts must be preloaded)
    lua.global.set('__get_script', (path) => {
        return getScriptSync(path);
    });

    // Global print function
    lua.global.set('print', (...args) => {
        log(args.map(a => String(a)).join('\t'), 'log');
    });

    // async_read - synchronous for preloaded scripts, async for other files
    // In browser simulator, scripts are preloaded so we return from cache immediately
    // For other files, we also return synchronously from localStorage/IndexedDB cache
    // IMPORTANT: Must always return a string or null, never undefined
    const asyncRead = (path) => {
        log(`async_read called: ${path}`, 'info');
        try {
            // For scripts, use synchronous cache lookup
            if (path.startsWith('/scripts/')) {
                const content = getScriptSync(path);
                if (content === null || content === undefined) {
                    log(`Script not preloaded: ${path}`, 'error');
                    return null;
                }
                log(`async_read returning ${content.length} chars for ${path}`, 'info');
                return content;
            }
            // For other files, use storage module's sync read
            // (In real device this would be async, but browser sim uses localStorage)
            const result = storage.read(path);
            log(`async_read (storage) returning for ${path}: ${result !== null ? 'found' : 'null'}`, 'info');
            return result === undefined ? null : result;
        } catch (e) {
            log(`async_read error for ${path}: ${e.message}`, 'error');
            return null;
        }
    };
    lua.global.set('async_read', asyncRead);

    lua.global.set('async_write', async (path, data) => {
        return await storage.write_file(path, data);
    });

    lua.global.set('async_exists', async (path) => {
        return await storage.exists(path);
    });

    lua.global.set('async_read_bytes', async (path, offset, len) => {
        const content = await storage.read_file(path);
        if (content) {
            return content.substring(offset, offset + len);
        }
        return null;
    });

    lua.global.set('async_append', async (path, data) => {
        return await storage.append_file(path, data);
    });

    lua.global.set('async_json_read', async (path) => {
        return await storage.read_file(path);
    });

    lua.global.set('async_json_write', async (path, data) => {
        return await storage.write_file(path, data);
    });

    // JSON helper functions
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

    log('Lua environment initialized', 'info');
    return true;
}

// Load and run boot.lua
async function boot() {
    setStatus('Preloading scripts...', 'loading');

    try {
        // Preload all scripts first so dofile works synchronously
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
    }
}

// Main loop - calls Lua main_loop() each frame
function mainLoop(timestamp) {
    if (!running) return;

    if (paused) {
        requestAnimationFrame(mainLoop);
        return;
    }

    // Throttle to ~30fps for performance
    if (timestamp - lastFrameTime < 33) {
        requestAnimationFrame(mainLoop);
        return;
    }
    lastFrameTime = timestamp;

    try {
        // Call the global main_loop function if it exists
        const mainLoopFn = lua.global.get('main_loop');
        if (typeof mainLoopFn === 'function') {
            mainLoopFn();
        }

        frameCount++;

    } catch (e) {
        log(`Runtime error: ${e.message}`, 'error');
        console.error(e);
        // Continue running despite errors
    }

    requestAnimationFrame(mainLoop);
}

// Button handlers
btnRestart.addEventListener('click', async () => {
    running = false;
    paused = false;
    frameCount = 0;
    btnPause.textContent = 'Pause';
    btnPause.disabled = true;

    // Clear canvas
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    // Clear console
    consoleEl.innerHTML = '';

    // Clear script cache to force reload
    scriptCache.clear();

    // Reinitialize
    log('Restarting simulator...', 'info');
    await initLua();
    await boot();
});

btnPause.addEventListener('click', () => {
    paused = !paused;
    btnPause.textContent = paused ? 'Resume' : 'Pause';
    setStatus(paused ? 'Paused' : 'Running', paused ? 'loading' : 'running');
});

// Focus canvas on click
canvas.addEventListener('click', () => {
    canvas.focus();
});

// Make canvas focusable
canvas.tabIndex = 0;

// Initialize on page load
async function init() {
    log('T-Deck OS Simulator starting...', 'info');

    // Clear canvas to black
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    // Show loading message on canvas
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
