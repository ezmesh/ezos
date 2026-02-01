/**
 * WiFi mock module for simulator
 * Simulates WiFi connectivity in the browser
 */

export function createWifiModule() {
    let enabled = false;
    let connected = false;
    let connecting = false;
    let ssid = '';
    let ip = '0.0.0.0';
    let rssi = -60;

    // Mock networks for scanning
    const mockNetworks = [
        { ssid: 'Home WiFi', rssi: -45, channel: 6, secure: true, bssid: 'AA:BB:CC:DD:EE:01' },
        { ssid: 'Guest Network', rssi: -55, channel: 11, secure: true, bssid: 'AA:BB:CC:DD:EE:02' },
        { ssid: 'Open Cafe', rssi: -70, channel: 1, secure: false, bssid: 'AA:BB:CC:DD:EE:03' },
        { ssid: 'Neighbor', rssi: -80, channel: 6, secure: true, bssid: 'AA:BB:CC:DD:EE:04' },
        { ssid: '', rssi: -75, channel: 3, secure: true, bssid: 'AA:BB:CC:DD:EE:05' }, // Hidden
    ];

    const module = {
        scan() {
            console.log('[WiFi] Scanning...');
            enabled = true;
            // Return copy of mock networks
            return mockNetworks.map(n => ({ ...n }));
        },

        connect(networkSsid, password) {
            console.log(`[WiFi] Connecting to: ${networkSsid}`);
            enabled = true;
            connecting = true;
            ssid = networkSsid;

            // Simulate connection delay
            setTimeout(() => {
                connecting = false;
                connected = true;
                ip = '192.168.1.' + Math.floor(Math.random() * 200 + 10);
                rssi = -50 - Math.floor(Math.random() * 30);
                console.log(`[WiFi] Connected! IP: ${ip}`);
            }, 2000);

            return true;
        },

        disconnect() {
            console.log('[WiFi] Disconnecting');
            connected = false;
            connecting = false;
            ssid = '';
            ip = '0.0.0.0';
        },

        is_connected() {
            return connected;
        },

        wait_connected(timeout = 10) {
            // In mock, just return current state
            return connected;
        },

        get_ip() {
            return connected ? ip : '0.0.0.0';
        },

        get_rssi() {
            return connected ? rssi : 0;
        },

        get_ssid() {
            return connected ? ssid : '';
        },

        get_mac() {
            return 'DE:AD:BE:EF:CA:FE';
        },

        get_status() {
            if (!enabled) return 'disabled';
            if (connected) return 'connected';
            if (connecting) return 'connecting';
            return 'disconnected';
        },

        get_gateway() {
            return connected ? '192.168.1.1' : '0.0.0.0';
        },

        get_dns() {
            return connected ? '8.8.8.8' : '0.0.0.0';
        },

        set_power(state) {
            enabled = state;
            if (!state) {
                connected = false;
                connecting = false;
                ssid = '';
                ip = '0.0.0.0';
            }
            console.log(`[WiFi] Power: ${state ? 'on' : 'off'}`);
        },

        is_enabled() {
            return enabled;
        }
    };

    return module;
}
