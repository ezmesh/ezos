/**
 * System mock module
 * Provides time, timers, and system-level functions
 */

export function createSystemModule(log) {
    const startTime = performance.now();
    const timers = new Map();
    let nextTimerId = 1;

    const module = {
        // Get milliseconds since start
        millis() {
            return Math.floor(performance.now() - startTime);
        },

        // Get microseconds since start
        micros() {
            return Math.floor((performance.now() - startTime) * 1000);
        },

        // Get uptime in seconds (used by Logger)
        uptime() {
            return Math.floor((performance.now() - startTime) / 1000);
        },

        // Delay (no-op in browser - use yield pattern instead)
        delay(ms) {
            // Cannot block in browser, this is a no-op
            // Lua code should use yield() pattern instead
        },

        // Yield control (used in main loop)
        yield(ms) {
            // No-op in browser - main loop handles frame timing
        },

        // Get free heap memory (mock value)
        get_free_heap() {
            return 150000; // ~150KB mock value
        },

        // Get minimum free heap (mock value)
        get_min_free_heap() {
            return 100000;
        },

        // Get total PSRAM (mock value)
        get_psram_size() {
            return 8 * 1024 * 1024; // 8MB
        },

        // Get free PSRAM (mock value)
        get_free_psram() {
            return 6 * 1024 * 1024; // 6MB
        },

        // Get battery percentage (mock value or use Battery API)
        get_battery_percent() {
            return 100;
        },

        // Check if charging (mock value)
        is_charging() {
            return true;
        },

        // Get current time components
        get_time() {
            const now = new Date();
            return {
                year: now.getFullYear(),
                month: now.getMonth() + 1,
                day: now.getDate(),
                hour: now.getHours(),
                minute: now.getMinutes(),
                second: now.getSeconds(),
                weekday: now.getDay(),
            };
        },

        // Get Unix timestamp
        get_timestamp() {
            return Math.floor(Date.now() / 1000);
        },

        // Get Unix time (same as get_timestamp, used by contacts.lua)
        get_time_unix() {
            return Math.floor(Date.now() / 1000);
        },

        // Set Unix time (no-op in browser)
        set_time_unix(timestamp) {
            console.log(`[System] Time would be set to: ${new Date(timestamp * 1000).toISOString()}`);
            return true;
        },

        // Log message
        log(msg) {
            if (log) {
                log(String(msg), 'log');
            } else {
                console.log('[Lua]', msg);
            }
        },

        // Log error
        log_error(msg) {
            if (log) {
                log(String(msg), 'error');
            } else {
                console.error('[Lua]', msg);
            }
        },

        // Set a one-shot timer
        set_timer(ms, callback) {
            const id = nextTimerId++;
            const handle = setTimeout(() => {
                timers.delete(id);
                if (typeof callback === 'function') {
                    try {
                        callback();
                    } catch (e) {
                        console.error('Timer callback error:', e);
                    }
                }
            }, ms);
            timers.set(id, { handle, type: 'timeout' });
            return id;
        },

        // Set a repeating interval
        set_interval(ms, callback) {
            const id = nextTimerId++;
            const handle = setInterval(() => {
                if (typeof callback === 'function') {
                    try {
                        callback();
                    } catch (e) {
                        console.error('Interval callback error:', e);
                    }
                }
            }, ms);
            timers.set(id, { handle, type: 'interval' });
            return id;
        },

        // Cancel a timer or interval
        cancel_timer(id) {
            const timer = timers.get(id);
            if (timer) {
                if (timer.type === 'timeout') {
                    clearTimeout(timer.handle);
                } else {
                    clearInterval(timer.handle);
                }
                timers.delete(id);
                return true;
            }
            return false;
        },

        // Restart the simulator
        restart() {
            location.reload();
        },

        // Get chip info (mock)
        get_chip_info() {
            return {
                model: 'ESP32-S3 (Simulated)',
                cores: 2,
                revision: 0,
                features: 'WiFi, BLE, PSRAM',
            };
        },

        // Get SDK version (mock)
        get_sdk_version() {
            return 'Browser Simulator v1.0';
        },

        // Sleep modes (no-op in browser)
        light_sleep(ms) {
            // No-op
        },

        deep_sleep(ms) {
            // No-op
        },

        // CPU frequency (mock)
        get_cpu_freq() {
            return 240; // MHz
        },

        set_cpu_freq(mhz) {
            // No-op
        },

        // Backlight control (no-op)
        set_backlight(level) {
            // Could potentially adjust canvas brightness
        },

        get_backlight() {
            return 255;
        },

        // Set timezone (POSIX string)
        set_timezone(posix) {
            console.log(`[System] Timezone set to: ${posix}`);
            return true;
        },

        // Get timezone
        get_timezone() {
            return 'UTC0';
        },

        // Chip model (API uses chip_model, not get_chip_info)
        chip_model() {
            return 'ESP32-S3 (Simulated)';
        },

        // CPU frequency (API uses cpu_freq, not get_cpu_freq)
        cpu_freq() {
            return 240; // MHz
        },

        // Get total heap memory
        get_total_heap() {
            return 320000; // ~320KB mock value
        },

        // Get total PSRAM
        get_total_psram() {
            return 8 * 1024 * 1024; // 8MB
        },

        // Get Lua memory usage
        get_lua_memory() {
            return 50000; // 50KB mock value
        },

        // Check if low on memory
        is_low_memory() {
            return false;
        },

        // Force garbage collection (no-op in browser)
        gc() {
            // Wasmoon handles GC automatically
        },

        // Incremental garbage collection
        gc_step(steps = 10) {
            return 0;
        },

        // Check if SD card is available
        is_sd_available() {
            return true; // Simulate SD card available
        },

        // USB MSC mode (not supported in browser)
        is_usb_msc_active() {
            return false;
        },

        start_usb_msc() {
            console.log('[System] USB MSC not supported in simulator');
            return false;
        },

        stop_usb_msc() {
            // No-op
        },

        // Get last error
        get_last_error() {
            return null;
        },

        // Reload scripts
        reload_scripts() {
            location.reload();
            return true;
        },

        // Get firmware info
        get_firmware_info() {
            return {
                partition_size: 4 * 1024 * 1024,
                app_size: 2 * 1024 * 1024,
                free_bytes: 2 * 1024 * 1024,
            };
        },

        // Get battery voltage
        get_battery_voltage() {
            return 4.2; // Full charge voltage
        },

        // Set time (full parameters)
        set_time(year, month, day, hour, minute, second) {
            console.log(`[System] Time would be set to: ${year}-${month}-${day} ${hour}:${minute}:${second}`);
            return true;
        },
    };

    return module;
}
