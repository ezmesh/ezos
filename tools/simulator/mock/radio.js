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

        // Get last packet SNR
        get_snr() {
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
    };

    return module;
}
