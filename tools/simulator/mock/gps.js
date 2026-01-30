/**
 * GPS mock module
 * Uses browser Geolocation API or provides mock data
 */

export function createGpsModule() {
    let currentLocation = null;
    let watchId = null;
    let useBrowserLocation = false;
    let initialized = false;

    // Default mock location (Amsterdam)
    const mockLocation = {
        lat: 52.3676,
        lon: 4.9041,
        alt: 0,
        speed: 0,
        course: 0,
        hdop: 1.5,
        satellites: 8,
        valid: true,
        timestamp: Date.now(),
    };

    const module = {
        // Initialize GPS
        init() {
            initialized = true;

            // Try to use browser geolocation
            if ('geolocation' in navigator) {
                try {
                    watchId = navigator.geolocation.watchPosition(
                        (pos) => {
                            useBrowserLocation = true;
                            currentLocation = {
                                lat: pos.coords.latitude,
                                lon: pos.coords.longitude,
                                alt: pos.coords.altitude || 0,
                                speed: pos.coords.speed || 0,
                                course: pos.coords.heading || 0,
                                hdop: pos.coords.accuracy / 10,
                                satellites: 10,
                                valid: true,
                                timestamp: pos.timestamp,
                            };
                        },
                        (err) => {
                            console.log('[GPS] Geolocation error, using mock data:', err.message);
                            useBrowserLocation = false;
                            currentLocation = { ...mockLocation };
                        },
                        {
                            enableHighAccuracy: true,
                            timeout: 10000,
                            maximumAge: 5000,
                        }
                    );
                } catch (e) {
                    console.log('[GPS] Geolocation not available, using mock data');
                    currentLocation = { ...mockLocation };
                }
            } else {
                currentLocation = { ...mockLocation };
            }

            return true;
        },

        // Check if GPS is initialized
        is_initialized() {
            return initialized;
        },

        // Check if location is valid
        is_valid() {
            return currentLocation && currentLocation.valid;
        },

        // Get current location
        get_location() {
            if (!currentLocation) {
                return { ...mockLocation, valid: false };
            }
            return { ...currentLocation };
        },

        // Get latitude
        get_lat() {
            return currentLocation ? currentLocation.lat : 0;
        },

        // Get longitude
        get_lon() {
            return currentLocation ? currentLocation.lon : 0;
        },

        // Get altitude (meters)
        get_alt() {
            return currentLocation ? currentLocation.alt : 0;
        },

        // Get speed (m/s)
        get_speed() {
            return currentLocation ? currentLocation.speed : 0;
        },

        // Get course/heading (degrees)
        get_course() {
            return currentLocation ? currentLocation.course : 0;
        },

        // Get HDOP (horizontal dilution of precision)
        get_hdop() {
            return currentLocation ? currentLocation.hdop : 99;
        },

        // Get satellite count
        get_satellites() {
            return currentLocation ? currentLocation.satellites : 0;
        },

        // Get fix age (ms since last fix)
        get_fix_age() {
            if (!currentLocation) return 999999;
            return Date.now() - currentLocation.timestamp;
        },

        // Calculate distance between two points (meters)
        distance(lat1, lon1, lat2, lon2) {
            const R = 6371000; // Earth's radius in meters
            const phi1 = lat1 * Math.PI / 180;
            const phi2 = lat2 * Math.PI / 180;
            const deltaPhi = (lat2 - lat1) * Math.PI / 180;
            const deltaLambda = (lon2 - lon1) * Math.PI / 180;

            const a = Math.sin(deltaPhi / 2) ** 2 +
                      Math.cos(phi1) * Math.cos(phi2) *
                      Math.sin(deltaLambda / 2) ** 2;
            const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

            return R * c;
        },

        // Calculate bearing between two points (degrees)
        bearing(lat1, lon1, lat2, lon2) {
            const phi1 = lat1 * Math.PI / 180;
            const phi2 = lat2 * Math.PI / 180;
            const deltaLambda = (lon2 - lon1) * Math.PI / 180;

            const y = Math.sin(deltaLambda) * Math.cos(phi2);
            const x = Math.cos(phi1) * Math.sin(phi2) -
                      Math.sin(phi1) * Math.cos(phi2) * Math.cos(deltaLambda);

            let bearing = Math.atan2(y, x) * 180 / Math.PI;
            return (bearing + 360) % 360;
        },

        // Set mock location (for testing)
        set_mock_location(lat, lon, alt = 0) {
            useBrowserLocation = false;
            currentLocation = {
                ...mockLocation,
                lat,
                lon,
                alt,
                timestamp: Date.now(),
            };
        },

        // Stop GPS updates
        stop() {
            if (watchId !== null) {
                navigator.geolocation.clearWatch(watchId);
                watchId = null;
            }
            initialized = false;
        },
    };

    return module;
}
