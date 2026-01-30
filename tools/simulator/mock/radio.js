/**
 * Radio mock module
 * Provides LoRa radio status and configuration
 */

export function createRadioModule() {
    const config = {
        frequency: 869.525,
        bandwidth: 250,
        spreading_factor: 10,
        coding_rate: 5,
        tx_power: 22,
        sync_word: 0x12,
    };

    let initialized = true;

    const module = {
        // Check if radio is initialized
        is_initialized() {
            return initialized;
        },

        // Get radio configuration
        get_config() {
            return { ...config };
        },

        // Set frequency (MHz)
        set_frequency(freq) {
            config.frequency = freq;
            console.log(`[Radio] Frequency set to ${freq} MHz`);
            return true;
        },

        // Set bandwidth (kHz)
        set_bandwidth(bw) {
            config.bandwidth = bw;
            console.log(`[Radio] Bandwidth set to ${bw} kHz`);
            return true;
        },

        // Set spreading factor
        set_spreading_factor(sf) {
            config.spreading_factor = sf;
            console.log(`[Radio] Spreading factor set to ${sf}`);
            return true;
        },

        // Set TX power (dBm)
        set_tx_power(power) {
            config.tx_power = power;
            console.log(`[Radio] TX power set to ${power} dBm`);
            return true;
        },

        // Send raw packet
        send(data) {
            console.log(`[Radio] Sending ${data.length} bytes`);
            return 'ok';
        },

        // Check if data available
        available() {
            return false;
        },

        // Read received data
        read() {
            return null;
        },

        // Get last packet RSSI
        get_rssi() {
            return -75 + Math.floor(Math.random() * 20);
        },

        // Alias for get_rssi (used by status_services.lua)
        get_last_rssi() {
            return -75 + Math.floor(Math.random() * 20);
        },

        // Get last packet SNR
        get_snr() {
            return 5 + Math.random() * 5;
        },

        // Alias for get_snr
        get_last_snr() {
            return 5 + Math.random() * 5;
        },

        // Get frequency error
        get_frequency_error() {
            return Math.floor(Math.random() * 1000) - 500;
        },

        // Put radio to sleep
        sleep() {
            console.log('[Radio] Entering sleep mode');
            return true;
        },

        // Wake radio from sleep
        wake() {
            console.log('[Radio] Waking up');
            return true;
        },

        // Start continuous receive
        start_receive() {
            console.log('[Radio] Starting continuous receive');
            return true;
        },

        // Get radio status string
        get_status() {
            return initialized ? 'OK' : 'NOT_INITIALIZED';
        },

        // Check if radio is busy
        is_busy() {
            return false;
        },

        // Check if in receive mode
        is_receiving() {
            return true; // Simulating continuous receive
        },

        // Check if currently transmitting
        is_transmitting() {
            return false;
        },

        // Set coding rate
        set_coding_rate(cr) {
            config.coding_rate = cr;
            console.log(`[Radio] Coding rate set to ${cr}`);
            return 'ok';
        },

        // Set sync word
        set_sync_word(sw) {
            config.sync_word = sw;
            console.log(`[Radio] Sync word set to 0x${sw.toString(16)}`);
            return 'ok';
        },

        // Receive packet (returns data, rssi, snr)
        receive() {
            // No packets to receive in simulator
            return null;
        },
    };

    return module;
}
