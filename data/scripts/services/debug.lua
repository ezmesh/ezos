-- Debug utilities for T-Deck OS
-- Provides introspection and debugging capabilities accessible via remote control

local Debug = {}

-- Memory information
function Debug.memory()
    local info = {}

    -- Lua memory usage
    info.lua_kb = math.floor(collectgarbage("count"))

    -- System memory (if available)
    if ez.system and ez.system.get_free_heap then
        info.heap_free = ez.system.get_free_heap()
    end
    if ez.system and ez.system.get_min_free_heap then
        info.heap_min = ez.system.get_min_free_heap()
    end
    if ez.system and ez.system.get_psram_free then
        info.psram_free = ez.system.get_psram_free()
    end
    if ez.system and ez.system.get_psram_size then
        info.psram_total = ez.system.get_psram_size()
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

    if ez.mesh then
        if ez.mesh.is_initialized then
            info.initialized = ez.mesh.is_initialized()
        end
        if ez.mesh.get_node_count then
            info.node_count = ez.mesh.get_node_count()
        end
        if ez.mesh.get_tx_count then
            info.tx_packets = ez.mesh.get_tx_count()
        end
        if ez.mesh.get_rx_count then
            info.rx_packets = ez.mesh.get_rx_count()
        end
    end

    return info
end

-- Radio status
function Debug.radio()
    local info = {}

    if ez.radio then
        if ez.radio.is_initialized then
            info.initialized = ez.radio.is_initialized()
        end
        if ez.radio.get_last_rssi then
            info.last_rssi = ez.radio.get_last_rssi()
        end
        if ez.radio.get_last_snr then
            info.last_snr = ez.radio.get_last_snr()
        end
    end

    return info
end

-- GPS status
function Debug.gps()
    local info = {}

    if ez.gps then
        if ez.gps.is_initialized then
            info.initialized = ez.gps.is_initialized()
        end
        if ez.gps.has_fix then
            info.has_fix = ez.gps.has_fix()
        end
        if ez.gps.get_latitude then
            info.latitude = ez.gps.get_latitude()
        end
        if ez.gps.get_longitude then
            info.longitude = ez.gps.get_longitude()
        end
        if ez.gps.get_altitude then
            info.altitude = ez.gps.get_altitude()
        end
        if ez.gps.get_satellites then
            info.satellites = ez.gps.get_satellites()
        end
    end

    return info
end

-- System uptime and info
function Debug.system()
    local info = {}

    if ez.system then
        if ez.system.get_uptime then
            info.uptime_ms = ez.system.get_uptime()
            info.uptime_sec = math.floor(info.uptime_ms / 1000)
        end
        if ez.system.get_cpu_freq then
            info.cpu_mhz = ez.system.get_cpu_freq()
        end
    end

    -- Battery info
    if ez.battery then
        if ez.battery.get_voltage then
            info.battery_mv = ez.battery.get_voltage()
        end
        if ez.battery.get_percentage then
            info.battery_pct = ez.battery.get_percentage()
        end
        if ez.battery.is_charging then
            info.charging = ez.battery.is_charging()
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

    if _G.Toast and _G.Toast.show then
        _G.Toast.show(message, duration)
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
