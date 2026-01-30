/**
 * Mesh network mock module
 * Provides simulated mesh network functionality
 */

export function createMeshModule() {
    // Simulated nodes for testing
    const mockNodes = [
        {
            path_hash: 0x42,
            name: 'TestNode-Alpha',
            pub_key: 'abcdef1234567890abcdef1234567890',
            rssi: -65,
            snr: 8.5,
            role: 2,  // Repeater
            lat: 52.3676,
            lon: 4.9041,
            has_location: true,
            last_seen: Date.now() - 30000,
        },
        {
            path_hash: 0x73,
            name: 'TestNode-Beta',
            pub_key: '1234567890abcdef1234567890abcdef',
            rssi: -82,
            snr: 4.2,
            role: 1,  // Chat client
            lat: 52.3702,
            lon: 4.8952,
            has_location: true,
            last_seen: Date.now() - 120000,
        },
        {
            path_hash: 0xAB,
            name: 'Repeater-1',
            pub_key: 'fedcba0987654321fedcba0987654321',
            rssi: -70,
            snr: 6.0,
            role: 2,  // Repeater
            lat: 0,
            lon: 0,
            has_location: false,
            last_seen: Date.now() - 5000,
        },
    ];

    const channels = [
        { name: '#Public', is_encrypted: false, member_count: 3 },
        { name: '#Private', is_encrypted: true, member_count: 1 },
    ];

    const messages = [];
    let initialized = true;

    const module = {
        // Check if mesh is initialized
        is_initialized() {
            return initialized;
        },

        // Update mesh (called periodically from main loop)
        update() {
            // No-op in simulator - would process radio packets on real device
        },

        // Get this node's ID
        get_node_id() {
            return 'SIMULATOR01234567890ABCDEF12345678';
        },

        // Get short node ID (first 6 chars)
        get_short_id() {
            return 'SIMULA';
        },

        // Get node name
        get_node_name() {
            return 'Simulator';
        },

        // Get list of known nodes
        get_nodes() {
            return mockNodes.map(node => ({
                ...node,
                last_seen: Date.now() - node.last_seen,
            }));
        },

        // Get node count
        get_node_count() {
            return mockNodes.length;
        },

        // Get node by path hash
        get_node_by_hash(pathHash) {
            return mockNodes.find(n => n.path_hash === pathHash) || null;
        },

        // Send announce/advertisement
        send_announce() {
            console.log('[Mesh] Sending announce');
            return true;
        },

        // Get channels
        get_channels() {
            return channels;
        },

        // Join channel
        join_channel(name, password = null) {
            const existing = channels.find(c => c.name === name);
            if (!existing) {
                channels.push({
                    name,
                    is_encrypted: password !== null,
                    member_count: 1,
                });
            }
            console.log(`[Mesh] Joined channel: ${name}`);
            return true;
        },

        // Leave channel
        leave_channel(name) {
            const idx = channels.findIndex(c => c.name === name);
            if (idx >= 0) {
                channels.splice(idx, 1);
                console.log(`[Mesh] Left channel: ${name}`);
                return true;
            }
            return false;
        },

        // Send channel message
        send_channel_message(channel, message) {
            console.log(`[Mesh] Sending to ${channel}: ${message}`);
            messages.push({
                type: 'channel',
                channel,
                message,
                timestamp: Date.now(),
                from: 'SIMULA',
            });
            return true;
        },

        // Send direct message
        send_direct_message(nodeId, message) {
            console.log(`[Mesh] Sending DM to ${nodeId}: ${message}`);
            messages.push({
                type: 'direct',
                to: nodeId,
                message,
                timestamp: Date.now(),
                from: 'SIMULA',
            });
            return true;
        },

        // Check for incoming messages
        has_message() {
            return false; // No incoming messages in simulator
        },

        // Read incoming message
        read_message() {
            return null;
        },

        // Get message history
        get_messages() {
            return messages;
        },

        // Get last RSSI
        get_last_rssi() {
            return -70;
        },

        // Get last SNR
        get_last_snr() {
            return 6.5;
        },

        // Get channel message count
        get_channel_message_count(channel) {
            return messages.filter(m => m.channel === channel).length;
        },

        // Set node name
        set_node_name(name) {
            console.log(`[Mesh] Node name set to: ${name}`);
            return true;
        },

        // Set location
        set_location(lat, lon) {
            console.log(`[Mesh] Location set to: ${lat}, ${lon}`);
            return true;
        },

        // Register group packet callback
        on_group_packet(callback) {
            console.log('[Mesh] Group packet callback registered');
            return true;
        },

        // Send group packet
        send_group_packet(hash, data) {
            console.log(`[Mesh] Sending group packet to hash ${hash}, ${data ? data.length : 0} bytes`);
            return true;
        },

        // Register node discovered callback
        on_node_discovered(callback) {
            console.log('[Mesh] Node discovered callback registered');
            return true;
        },

        // Get our public key
        get_public_key() {
            return 'simulator_public_key_0123456789abcdef';
        },

        // Sign data
        sign(data) {
            return 'mock_signature_' + data.substring(0, 10);
        },

        // Verify signature
        verify(data, signature, pubKey) {
            return true; // Always verify in simulator
        },

        // Set path check (skip packets where our hash is in path)
        set_path_check(enabled) {
            console.log(`[Mesh] Path check ${enabled ? 'enabled' : 'disabled'}`);
            return true;
        },

        // Get path check state
        get_path_check() {
            return true;
        },

        // Register packet callback
        on_packet(callback) {
            console.log('[Mesh] Packet callback registered');
            return true;
        },

        // Get our path hash
        get_path_hash() {
            return 0x42; // Mock hash
        },

        // Ed25519 sign (mock)
        ed25519_sign(data) {
            // Return mock 64-byte signature
            return 'x'.repeat(64);
        },

        // Ed25519 verify (mock - always returns true in simulator)
        ed25519_verify(data, signature, pubKey) {
            return true;
        },

        // Calculate shared secret (X25519) - mock returns deterministic bytes
        calc_shared_secret(pubKey) {
            // Return 32 mock bytes based on pubKey for consistency
            let result = '';
            for (let i = 0; i < 32; i++) {
                const byte = (pubKey.charCodeAt(i % pubKey.length) + i) & 0xFF;
                result += String.fromCharCode(byte);
            }
            return result;
        },

        // Get public key as hex string
        get_public_key_hex() {
            return '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';
        },

        // Build a packet (mock)
        build_packet(routeType, payloadType, payload, path) {
            // Build header byte: route_type(2) | payload_type(4) | version(2)
            const header = (routeType & 0x03) | ((payloadType & 0x0F) << 2);
            // Return header + path + payload as binary string
            return String.fromCharCode(header) + (path || '') + (payload || '');
        },

        // Queue packet for sending (mock - just logs)
        queue_send(packetData) {
            console.log(`[Mesh] Would send ${packetData ? packetData.length : 0} byte packet`);
            return true;
        },

        // Remove a file (for storage)
        remove(path) {
            console.log(`[Storage] Would remove: ${path}`);
            return true;
        },

        // Role constants (matching MeshCore protocol)
        ROLE: {
            CHAT: 1,        // Chat client
            REPEATER: 2,    // Repeater/infrastructure
            ROUTER: 3,      // Router
            GATEWAY: 4,     // Gateway
        },
    };

    return module;
}
