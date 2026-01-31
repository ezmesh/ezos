/**
 * Keyboard mock module
 * Maps browser keyboard events to ez.keyboard API
 */

export function createKeyboardModule(canvas, onKeyCallback) {
    const keyQueue = [];
    let shiftHeld = false;
    let ctrlHeld = false;
    let altHeld = false;

    // Special key mapping
    const specialKeyMap = {
        'ArrowUp': 'UP',
        'ArrowDown': 'DOWN',
        'ArrowLeft': 'LEFT',
        'ArrowRight': 'RIGHT',
        'Enter': 'ENTER',
        'Escape': 'ESCAPE',
        'Tab': 'TAB',
        'Backspace': 'BACKSPACE',
        'Delete': 'DELETE',
        'Home': 'HOME',
        'End': 'END',
        'PageUp': 'PAGEUP',
        'PageDown': 'PAGEDOWN',
        'Insert': 'INSERT',
        'F1': 'F1',
        'F2': 'F2',
        'F3': 'F3',
        'F4': 'F4',
        'F5': 'F5',
        'F6': 'F6',
        'F7': 'F7',
        'F8': 'F8',
        'F9': 'F9',
        'F10': 'F10',
        'F11': 'F11',
        'F12': 'F12',
    };

    // Handle keydown events
    function handleKeyDown(e) {
        // Update modifier state
        shiftHeld = e.shiftKey;
        ctrlHeld = e.ctrlKey;
        altHeld = e.altKey;

        // Prevent default for arrow keys and other special keys to avoid scrolling
        if (specialKeyMap[e.key] || e.ctrlKey) {
            e.preventDefault();
        }

        // Build key object - use undefined instead of null (Wasmoon converts null to js_null)
        const keyObj = {
            shift: e.shiftKey,
            ctrl: e.ctrlKey,
            alt: e.altKey,
            valid: true,
        };

        // Check if it's a special key
        if (specialKeyMap[e.key]) {
            keyObj.special = specialKeyMap[e.key];
            // Don't set character at all (will be nil in Lua)
        } else if (e.key.length === 1) {
            // Regular character
            keyObj.character = e.key;
            // Don't set special at all (will be nil in Lua)
        } else {
            // Unknown key, ignore
            return;
        }

        keyQueue.push(keyObj);

        // Callback for UI update
        if (onKeyCallback) {
            onKeyCallback(keyObj);
        }
    }

    // Handle keyup events
    function handleKeyUp(e) {
        shiftHeld = e.shiftKey;
        ctrlHeld = e.ctrlKey;
        altHeld = e.altKey;
    }

    // Attach event listeners to canvas
    canvas.addEventListener('keydown', handleKeyDown);
    canvas.addEventListener('keyup', handleKeyUp);

    // Also listen on document for when canvas loses focus
    document.addEventListener('keydown', (e) => {
        if (document.activeElement === canvas) {
            return; // Already handled by canvas listener
        }
        // Only capture if clicking in simulator area
    });

    const module = {
        // Check if keys are available
        available() {
            return keyQueue.length > 0;
        },

        // Read next key from queue (non-blocking)
        read() {
            if (keyQueue.length === 0) {
                return undefined; // undefined becomes nil in Lua
            }
            const key = keyQueue.shift();
            // Ensure missing properties are undefined, not null (Wasmoon handles undefined better)
            return {
                character: key.character, // undefined if not set
                special: key.special,     // undefined if not set
                shift: key.shift,
                ctrl: key.ctrl,
                alt: key.alt,
                valid: key.valid,
            };
        },

        // Peek at next key without removing
        peek() {
            if (keyQueue.length === 0) {
                return undefined; // undefined becomes nil in Lua
            }
            const key = keyQueue[0];
            return {
                character: key.character,
                special: key.special,
                shift: key.shift,
                ctrl: key.ctrl,
                alt: key.alt,
                valid: key.valid,
            };
        },

        // Clear key queue
        clear() {
            keyQueue.length = 0;
        },

        // Check modifier states
        is_shift_held() {
            return shiftHeld;
        },

        is_ctrl_held() {
            return ctrlHeld;
        },

        is_alt_held() {
            return altHeld;
        },

        // Blocking read (returns null in browser - use polling pattern instead)
        read_blocking() {
            // Cannot truly block in browser
            // Return key if available, otherwise null
            return module.read();
        },

        // Get queue length
        queue_length() {
            return keyQueue.length;
        },

        // Inject a key programmatically (for virtual keyboard)
        inject(key) {
            keyQueue.push(key);
            if (onKeyCallback) {
                onKeyCallback(key);
            }
        },

        // Inject a key by string (convenience method for virtual keyboard)
        injectKey(keyStr, modifiers = {}) {
            const keyObj = {
                shift: modifiers.shift || false,
                ctrl: modifiers.ctrl || false,
                alt: modifiers.alt || false,
                valid: true,
            };

            // Check if it's a special key
            if (specialKeyMap[keyStr]) {
                keyObj.special = specialKeyMap[keyStr];
            } else if (keyStr.length === 1) {
                keyObj.character = keyStr;
            } else {
                return; // Unknown key
            }

            keyQueue.push(keyObj);
            if (onKeyCallback) {
                onKeyCallback(keyObj);
            }
        },

        // Set keyboard mode (normal, raw, etc.)
        set_mode(mode) {
            return true;
        },

        // Get current mode
        get_mode() {
            return 'normal';
        },

        // Enable/disable key repeat
        set_repeat_enabled(enabled) {
            console.log(`[Keyboard] Repeat ${enabled ? 'enabled' : 'disabled'}`);
            return true;
        },

        // Check if repeat is enabled
        is_repeat_enabled() {
            return false;
        },

        // Set repeat delay/rate
        set_repeat_delay(ms) {
            return true;
        },

        set_repeat_rate(ms) {
            return true;
        },

        // Backlight control
        set_backlight(level) {
            return true;
        },

        get_backlight() {
            return 255;
        },

        // Trackball sensitivity
        set_trackball_sensitivity(level) {
            console.log(`[Keyboard] Trackball sensitivity set to: ${level}`);
            return true;
        },

        get_trackball_sensitivity() {
            return 1;
        },

        // Trackball mode (polling or interrupt)
        set_trackball_mode(mode) {
            console.log(`[Keyboard] Trackball mode set to: ${mode}`);
            return true;
        },

        get_trackball_mode() {
            return 'polling';
        },

        // Read raw keyboard matrix (7 rows x 7 cols = 49 bits = 7 bytes)
        // Returns a table of 7 bytes representing the matrix state (one per column)
        read_raw_matrix() {
            // Return empty matrix (no keys pressed) - 7 bytes of zeros as table
            return [0, 0, 0, 0, 0, 0, 0];
        },
    };

    return module;
}
