-- Cooperative Multitasking Scheduler for T-Deck OS
-- Provides interval-based service registration and execution

local Scheduler = {
    services = {},
    timers = {},
    next_timer_id = 1
}

-- Register a background service that runs at specified interval
-- @param name: unique service name
-- @param callback: function to call
-- @param interval_ms: milliseconds between calls
-- @param immediate: if true, run immediately on registration
function Scheduler.register_service(name, callback, interval_ms, immediate)
    if type(callback) ~= "function" then
        ez.system.log("[Scheduler] Invalid callback for service: " .. name)
        return false
    end

    interval_ms = interval_ms or 1000

    Scheduler.services[name] = {
        callback = callback,
        interval = interval_ms,
        last_run = immediate and 0 or ez.system.millis(),
        enabled = true,
        run_count = 0,
        errors = 0
    }

    ez.system.log("[Scheduler] Registered service: " .. name .. " (interval: " .. interval_ms .. "ms)")
    return true
end

-- Unregister a service
function Scheduler.unregister_service(name)
    if Scheduler.services[name] then
        Scheduler.services[name] = nil
        ez.system.log("[Scheduler] Unregistered service: " .. name)
        return true
    end
    return false
end

-- Enable/disable a service without removing it
function Scheduler.set_service_enabled(name, enabled)
    local service = Scheduler.services[name]
    if service then
        service.enabled = enabled
        return true
    end
    return false
end

-- Get service info
function Scheduler.get_service_info(name)
    local service = Scheduler.services[name]
    if service then
        return {
            name = name,
            interval = service.interval,
            enabled = service.enabled,
            run_count = service.run_count,
            errors = service.errors,
            last_run = service.last_run
        }
    end
    return nil
end

-- List all registered services
function Scheduler.list_services()
    local list = {}
    for name, service in pairs(Scheduler.services) do
        table.insert(list, {
            name = name,
            interval = service.interval,
            enabled = service.enabled,
            run_count = service.run_count
        })
    end
    return list
end

-- Set a one-shot timer
-- @param delay_ms: milliseconds until callback
-- @param callback: function to call
-- @return timer_id that can be used to cancel
function Scheduler.set_timer(delay_ms, callback)
    local id = Scheduler.next_timer_id
    Scheduler.next_timer_id = Scheduler.next_timer_id + 1

    Scheduler.timers[id] = {
        callback = callback,
        fire_at = ez.system.millis() + delay_ms,
        repeating = false
    }

    return id
end

-- Set a repeating interval timer
-- @param interval_ms: milliseconds between calls
-- @param callback: function to call
-- @return timer_id that can be used to cancel
function Scheduler.set_interval(interval_ms, callback)
    local id = Scheduler.next_timer_id
    Scheduler.next_timer_id = Scheduler.next_timer_id + 1

    Scheduler.timers[id] = {
        callback = callback,
        fire_at = ez.system.millis() + interval_ms,
        interval = interval_ms,
        repeating = true
    }

    return id
end

-- Cancel a timer
function Scheduler.cancel_timer(timer_id)
    if Scheduler.timers[timer_id] then
        Scheduler.timers[timer_id] = nil
        return true
    end
    return false
end

-- Process all pending services and timers
-- Call this from the main loop
function Scheduler.update()
    local now = ez.system.millis()

    -- Process services
    for name, service in pairs(Scheduler.services) do
        if service.enabled and (now - service.last_run) >= service.interval then
            service.last_run = now

            local ok, err = pcall(service.callback)
            if ok then
                service.run_count = service.run_count + 1
            else
                service.errors = service.errors + 1
                ez.system.log("[Scheduler] Service error in " .. name .. ": " .. tostring(err))
            end
        end
    end

    -- Process timers
    local expired = {}
    for id, timer in pairs(Scheduler.timers) do
        if now >= timer.fire_at then
            table.insert(expired, id)
        end
    end

    for _, id in ipairs(expired) do
        local timer = Scheduler.timers[id]
        if timer then
            local ok, err = pcall(timer.callback)
            if not ok then
                ez.system.log("[Scheduler] Timer error: " .. tostring(err))
            end

            if timer.repeating then
                timer.fire_at = now + timer.interval
            else
                Scheduler.timers[id] = nil
            end
        end
    end
end

-- Yield control for cooperative multitasking
-- Use this in long-running operations
function Scheduler.yield()
    -- In a coroutine context, this would yield
    -- For now, just process pending work
    Scheduler.update()
end

return Scheduler
