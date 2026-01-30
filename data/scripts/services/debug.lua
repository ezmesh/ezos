-- Debug utilities for T-Deck OS
-- Provides introspection and debugging capabilities accessible via remote control

local Debug = {}

-- Memory information
function Debug.memory()
    local info = {}

    -- Lua memory usage
    info.lua_kb = math.floor(collectgarbage("count"))

    -- System memory (if available)
    if tdeck.system and tdeck.system.get_free_heap then
        info.heap_free = tdeck.system.get_free_heap()
    end
    if tdeck.system and tdeck.system.get_min_free_heap then
        info.heap_min = tdeck.system.get_min_free_heap()
    end
    if tdeck.system and tdeck.system.get_psram_free then
        info.psram_free = tdeck.system.get_psram_free()
    end
    if tdeck.system and tdeck.system.get_psram_size then
        info.psram_total = tdeck.system.get_psram_size()
    end

    return info
end

-- Screen stack information
function Debug.screens()
    local info = {}

    if ScreenManager then
        info.stack_size = ScreenManager.stack_size and ScreenManager.stack_size() or 0
        local current = ScreenManager.current and ScreenManager.current()
        if current then
            info.current = current.title or "unknown"
        end
    end

    return info
end

-- Mesh network status
function Debug.mesh()
    local info = {}

    if tdeck.mesh then
        if tdeck.mesh.is_initialized then
            info.initialized = tdeck.mesh.is_initialized()
        end
        if tdeck.mesh.get_node_count then
            info.node_count = tdeck.mesh.get_node_count()
        end
        if tdeck.mesh.get_tx_count then
            info.tx_packets = tdeck.mesh.get_tx_count()
        end
        if tdeck.mesh.get_rx_count then
            info.rx_packets = tdeck.mesh.get_rx_count()
        end
    end

    return info
end

-- Radio status
function Debug.radio()
    local info = {}

    if tdeck.radio then
        if tdeck.radio.is_initialized then
            info.initialized = tdeck.radio.is_initialized()
        end
        if tdeck.radio.get_last_rssi then
            info.last_rssi = tdeck.radio.get_last_rssi()
        end
        if tdeck.radio.get_last_snr then
            info.last_snr = tdeck.radio.get_last_snr()
        end
    end

    return info
end

-- GPS status
function Debug.gps()
    local info = {}

    if tdeck.gps then
        if tdeck.gps.is_initialized then
            info.initialized = tdeck.gps.is_initialized()
        end
        if tdeck.gps.has_fix then
            info.has_fix = tdeck.gps.has_fix()
        end
        if tdeck.gps.get_latitude then
            info.latitude = tdeck.gps.get_latitude()
        end
        if tdeck.gps.get_longitude then
            info.longitude = tdeck.gps.get_longitude()
        end
        if tdeck.gps.get_altitude then
            info.altitude = tdeck.gps.get_altitude()
        end
        if tdeck.gps.get_satellites then
            info.satellites = tdeck.gps.get_satellites()
        end
    end

    return info
end

-- System uptime and info
function Debug.system()
    local info = {}

    if tdeck.system then
        if tdeck.system.get_uptime then
            info.uptime_ms = tdeck.system.get_uptime()
            info.uptime_sec = math.floor(info.uptime_ms / 1000)
        end
        if tdeck.system.get_cpu_freq then
            info.cpu_mhz = tdeck.system.get_cpu_freq()
        end
    end

    -- Battery info
    if tdeck.battery then
        if tdeck.battery.get_voltage then
            info.battery_mv = tdeck.battery.get_voltage()
        end
        if tdeck.battery.get_percentage then
            info.battery_pct = tdeck.battery.get_percentage()
        end
        if tdeck.battery.is_charging then
            info.charging = tdeck.battery.is_charging()
        end
    end

    return info
end

-- Get all debug info at once
function Debug.all()
    return {
        memory = Debug.memory(),
        screens = Debug.screens(),
        mesh = Debug.mesh(),
        radio = Debug.radio(),
        gps = Debug.gps(),
        system = Debug.system()
    }
end

-- Show a message box (useful for testing remote control)
function Debug.message(title, text)
    title = title or "Debug"
    text = text or "Remote control test"

    if _G.MessageBox and _G.MessageBox.alert then
        _G.MessageBox.alert(title, text)
        return true
    end
    return false
end

-- Show a toast notification
function Debug.toast(message, duration)
    message = message or "Debug toast"
    duration = duration or 2000

    if ScreenManager and ScreenManager.show_toast then
        ScreenManager.show_toast(message, duration)
        return true
    end
    return false
end

-- Force garbage collection
function Debug.gc()
    local before = collectgarbage("count")
    collectgarbage("collect")
    local after = collectgarbage("count")
    return {
        before_kb = math.floor(before),
        after_kb = math.floor(after),
        freed_kb = math.floor(before - after)
    }
end

-- List global variables (for debugging)
function Debug.globals()
    local names = {}
    for name, _ in pairs(_G) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- List methods/fields of a table by name
function Debug.inspect(name)
    local obj = _G[name]
    if obj == nil then
        return nil
    end

    local info = {
        type = type(obj)
    }

    if type(obj) == "table" then
        info.keys = {}
        for k, v in pairs(obj) do
            table.insert(info.keys, {
                name = tostring(k),
                type = type(v)
            })
        end
    end

    return info
end

-- Register as global
_G.Debug = Debug

return Debug
