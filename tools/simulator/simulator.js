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

async function loadScript(path) {
    // Normalize path - remove /scripts/ prefix if present
    let normalizedPath = path;
    if (path.startsWith('/scripts/')) {
        normalizedPath = path.substring(9);
    }

    if (scriptCache.has(normalizedPath)) {
        return scriptCache.get(normalizedPath);
    }

    try {
        // Try loading from the data/scripts directory (relative to simulator)
        const response = await fetch(`../../data/scripts/${normalizedPath}`);
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

    // Create tdeck namespace table in Lua
    await lua.doString(`
        tdeck = {
            display = {},
            keyboard = {},
            system = {},
            storage = {},
            mesh = {},
            radio = {},
            audio = {},
            gps = {},
            crypto = {}
        }
    `);

    // Helper to set methods on tdeck namespace
    function setModule(name, module) {
        const luaModule = lua.global.get('tdeck')[name];
        for (const [key, value] of Object.entries(module)) {
            luaModule[key] = value;
        }
    }

    setModule('display', display);
    setModule('keyboard', keyboard);
    setModule('system', system);
    setModule('storage', storage);
    setModule('mesh', mesh);
    setModule('radio', radio);
    setModule('audio', audio);
    setModule('gps', gps);
    setModule('crypto', crypto);

    // Global aliases for convenience (some scripts use both patterns)
    lua.global.set('display', display);
    lua.global.set('keyboard', keyboard);
    lua.global.set('system', system);
    lua.global.set('storage', storage);
    lua.global.set('mesh', mesh);
    lua.global.set('radio', radio);
    lua.global.set('audio', audio);
    lua.global.set('gps', gps);

    // Custom dofile that loads from our virtual filesystem
    // This is critical - it must return the module's return value
    lua.global.set('__load_script', async (path) => {
        const content = await loadScript(path);
        return content;
    });

    // Set up dofile in Lua that uses our loader
    await lua.doString(`
        local original_dofile = dofile
        function dofile(path)
            local content = __load_script(path)
            if not content then
                error("Failed to load file: " .. tostring(path))
            end
            local chunk, err = load(content, "@" .. path)
            if not chunk then
                error("Parse error in " .. path .. ": " .. tostring(err))
            end
            return chunk()
        end
    `);

    // Global print function
    lua.global.set('print', (...args) => {
        log(args.map(a => String(a)).join('\t'), 'log');
    });

    // Async functions for file I/O (simplified for browser)
    lua.global.set('async_read', async (path) => {
        // For scripts, use our loader
        if (path.startsWith('/scripts/')) {
            return await loadScript(path);
        }
        // For other files, use storage module
        return await storage.read_file(path);
    });

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
    setStatus('Loading boot.lua...', 'loading');

    try {
        const bootScript = await loadScript('boot.lua');
        if (!bootScript) {
            throw new Error('Failed to load boot.lua');
        }

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
