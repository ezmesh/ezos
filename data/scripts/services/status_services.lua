-- Status Bar Update Services for T-Deck OS
-- Background services that periodically update the status bar

-- Use global Scheduler set up by boot.lua
local Scheduler = _G.Scheduler

local StatusServices = {
    channels_loaded = false
}

-- Lazy-load Channels service (saves ~27KB at boot)
function StatusServices.get_channels()
    if not StatusServices.channels_loaded then
        _G.Channels = load_module("/scripts/services/channels.lua")
        if tdeck.mesh.is_initialized() then
            _G.Channels.init()
        end
        StatusServices.channels_loaded = true
    end
    return _G.Channels
end

-- Battery monitoring service
-- Updates status bar and warns on low battery
function StatusServices.init_battery_service()
    Scheduler.register_service("battery", function()
        local percent = tdeck.system.get_battery_percent()
        if StatusBar then
            StatusBar.set_battery(percent)
        end

        -- Low battery warning at 10%
        if percent <= 10 then
            tdeck.system.log("[Battery] Low battery: " .. percent .. "%")
        end
    end, 30000)  -- Every 30 seconds
end

-- Mesh status service
-- Updates node count and unread message indicator
function StatusServices.init_mesh_service()
    Scheduler.register_service("mesh_status", function()
        if tdeck.mesh.is_initialized() then
            -- Update node count in status bar
            local count = tdeck.mesh.get_node_count()
            if StatusBar then
                StatusBar.set_node_count(count)
            end

            -- Check for unread messages (only if channels loaded)
            if _G.Channels then
                local channels = _G.Channels.get_all()
                local has_unread = false
                for _, ch in ipairs(channels) do
                    if ch.unread and ch.unread > 0 then
                        has_unread = true
                        break
                    end
                end
                if StatusBar then
                    StatusBar.set_unread(has_unread)
                end
            end
        end
    end, 5000)  -- Every 5 seconds
end

-- Radio status service
-- Updates radio indicator in status bar
function StatusServices.init_radio_service()
    Scheduler.register_service("radio_status", function()
        local ok = tdeck.radio.is_initialized()
        -- Calculate signal bars based on last RSSI
        local bars = 0
        if ok then
            local rssi = tdeck.radio.get_last_rssi()
            if rssi > -70 then
                bars = 4
            elseif rssi > -85 then
                bars = 3
            elseif rssi > -100 then
                bars = 2
            elseif rssi > -115 then
                bars = 1
            end
        end
        if StatusBar then
            StatusBar.set_radio(ok, bars)
        end
    end, 2000)  -- Every 2 seconds
end

-- Initialize all status services
function StatusServices.init_all()
    tdeck.system.log("[StatusServices] Starting status bar update services...")

    -- NOTE: Channels service is loaded on-demand via get_channels()
    -- to save memory at boot

    StatusServices.init_battery_service()
    StatusServices.init_mesh_service()
    StatusServices.init_radio_service()

    tdeck.system.log("[StatusServices] Services started")
end

-- Stop all status services
function StatusServices.stop_all()
    Scheduler.unregister_service("battery")
    Scheduler.unregister_service("mesh_status")
    Scheduler.unregister_service("radio_status")
end

return StatusServices
