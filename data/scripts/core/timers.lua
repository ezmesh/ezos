-- Timer utilities for ezOS
-- JavaScript-style timer APIs wrapping Scheduler

-- Note: These require Scheduler to be loaded first
-- They are initialized by boot.lua after Scheduler is available

local Timers = {}

-- Initialize timer globals (called from boot.lua after Scheduler is loaded)
function Timers.init(Scheduler)
    -- Set a one-shot timeout
    function _G.set_timeout(callback, delay_ms)
        return Scheduler.set_timeout(delay_ms, callback)
    end

    -- Cancel a timeout
    function _G.clear_timeout(timer_id)
        return Scheduler.cancel_timer(timer_id)
    end

    -- Set a repeating interval
    function _G.set_interval(callback, interval_ms)
        return Scheduler.set_interval(interval_ms, callback)
    end

    -- Cancel an interval
    function _G.clear_interval(timer_id)
        return Scheduler.cancel_timer(timer_id)
    end

    -- Spawn a function after a delay (combines set_timeout with spawn)
    -- Useful for async operations that need to run after a delay
    function _G.spawn_delay(delay_ms, callback)
        return set_timeout(function()
            spawn(callback)
        end, delay_ms)
    end
end

return Timers
