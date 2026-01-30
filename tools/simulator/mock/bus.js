/**
 * Mock Message Bus module for T-Deck simulator
 * Implements pub/sub messaging matching the C++ MessageBus API
 * Supports both string and table (object) data
 */

export function createBusModule() {
    // Subscription storage
    const subscriptions = new Map();
    let nextSubscriptionId = 1;

    // Message queue for deferred delivery
    const messageQueue = [];
    const MAX_QUEUE_SIZE = 64;

    // Process pending messages (called from main loop)
    function process() {
        while (messageQueue.length > 0) {
            const msg = messageQueue.shift();

            // Deliver to all matching subscribers
            for (const [id, sub] of subscriptions.entries()) {
                if (sub.active && sub.topic === msg.topic) {
                    try {
                        // Pass data as-is (string or object)
                        sub.callback(msg.topic, msg.data);
                    } catch (e) {
                        console.error(`[Bus] Callback error: ${e.message}`);
                    }
                }
            }
        }
    }

    // Built-in echo handler for bus/ping -> bus/echo
    const echoSubId = nextSubscriptionId++;
    subscriptions.set(echoSubId, {
        topic: 'bus/ping',
        callback: (topic, data) => {
            // Echo back on bus/echo (convert table to string for echo)
            const echoData = typeof data === 'object' ? JSON.stringify(data) : data;
            messageQueue.push({ topic: 'bus/echo', data: echoData });
        },
        active: true
    });

    return {
        // Subscribe to a topic
        // Callback receives (topic, data) where data can be string or table
        // Returns subscription ID
        subscribe: (topic, callback) => {
            const id = nextSubscriptionId++;
            subscriptions.set(id, {
                topic: topic,
                callback: callback,
                active: true
            });
            console.log(`[Bus] Subscribe id=${id} topic=${topic}`);
            return id;
        },

        // Unsubscribe by ID
        unsubscribe: (subscriptionId) => {
            const sub = subscriptions.get(subscriptionId);
            if (sub) {
                sub.active = false;
                console.log(`[Bus] Unsubscribe id=${subscriptionId}`);
                return true;
            }
            return false;
        },

        // Post a message (queued for delivery)
        // data can be string or table (object)
        post: (topic, data) => {
            if (messageQueue.length >= MAX_QUEUE_SIZE) {
                console.warn('[Bus] Queue full, dropping message');
                return;
            }
            // Accept any data type - string, object, or nil/undefined
            messageQueue.push({ topic: topic, data: data ?? '' });
        },

        // Check if topic has subscribers
        has_subscribers: (topic) => {
            for (const [id, sub] of subscriptions.entries()) {
                if (sub.active && sub.topic === topic) {
                    return true;
                }
            }
            return false;
        },

        // Get pending message count
        pending_count: () => {
            return messageQueue.length;
        },

        // Internal: process messages (call from main loop)
        _process: process
    };
}
