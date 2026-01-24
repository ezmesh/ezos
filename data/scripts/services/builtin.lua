-- Built-in Background Services for T-Deck OS
-- These services run automatically when the scheduler is active

-- Use global Scheduler set up by boot.lua
local Scheduler = _G.Scheduler or require("services/scheduler")

local Builtin = {}

-- Battery monitoring service
-- Updates status bar and warns on low battery
function Builtin.init_battery_service()
    Scheduler.register_service("battery", function()
        local percent = tdeck.system.get_battery_percent()
        tdeck.screen.set_battery(percent)

        -- Low battery warning at 10%
        if percent <= 10 then
            -- Could trigger a notification here
            tdeck.system.log("[Battery] Low battery: " .. percent .. "%")
        end
    end, 30000)  -- Every 30 seconds
end

-- Mesh network heartbeat service
-- Sends periodic announcements and updates node count
function Builtin.init_mesh_service()
    Scheduler.register_service("mesh_heartbeat", function()
        if tdeck.mesh.is_initialized() then
            -- Update node count in status bar
            local count = tdeck.mesh.get_node_count()
            tdeck.screen.set_node_count(count)

            -- Check for unread messages
            local channels = tdeck.mesh.get_channels()
            local has_unread = false
            for _, ch in ipairs(channels) do
                if ch.unread_count > 0 then
                    has_unread = true
                    break
                end
            end
            tdeck.screen.set_unread(has_unread)
        end
    end, 5000)  -- Every 5 seconds

    -- Periodic announce (every 2 minutes)
    Scheduler.register_service("mesh_announce", function()
        if tdeck.mesh.is_initialized() then
            tdeck.mesh.send_announce()
        end
    end, 120000)
end

-- Radio status service
-- Updates radio indicator in status bar
function Builtin.init_radio_service()
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
        tdeck.screen.set_radio(ok, bars)
    end, 2000)  -- Every 2 seconds
end

-- Initialize all built-in services
function Builtin.init_all()
    tdeck.system.log("[Builtin] Initializing built-in services...")

    Builtin.init_battery_service()
    Builtin.init_mesh_service()
    Builtin.init_radio_service()

    tdeck.system.log("[Builtin] Built-in services initialized")
end

-- Stop all built-in services
function Builtin.stop_all()
    Scheduler.unregister_service("battery")
    Scheduler.unregister_service("mesh_heartbeat")
    Scheduler.unregister_service("mesh_announce")
    Scheduler.unregister_service("radio_status")
end

return Builtin
