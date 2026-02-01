-- Screen Timeout Service for T-Deck OS
-- Dims and turns off screen after periods of inactivity

local ScreenTimeout = {
    -- State
    last_activity = 0,
    state = "active",  -- "active", "dimmed", "off"
    saved_brightness = 200,

    -- Settings (in minutes, 0 = disabled)
    dim_timeout = 5,
    off_timeout = 10,
    dim_brightness = 50,

    -- Check interval (ms)
    check_interval = 1000,
    last_check = 0,
}

function ScreenTimeout.init()
    ScreenTimeout.last_activity = ez.system.millis()
    ScreenTimeout.state = "active"
    ScreenTimeout.load_settings()

    -- Get current brightness as saved value
    if ez.storage and ez.storage.get_pref then
        ScreenTimeout.saved_brightness = ez.storage.get_pref("brightness", 200)
    end
end

function ScreenTimeout.load_settings()
    if ez.storage and ez.storage.get_pref then
        ScreenTimeout.dim_timeout = ez.storage.get_pref("screenDimTimeout", 5)
        ScreenTimeout.off_timeout = ez.storage.get_pref("screenOffTimeout", 10)
    end
end

function ScreenTimeout.on_activity()
    local was_off = (ScreenTimeout.state == "off")
    local was_dimmed = (ScreenTimeout.state == "dimmed")

    ScreenTimeout.last_activity = ez.system.millis()

    -- Wake screen if it was dimmed or off
    if was_off or was_dimmed then
        ez.log("[ScreenTimeout] Activity detected while " .. ScreenTimeout.state .. ", waking...")
        ScreenTimeout.wake()
        return true  -- Signal that we consumed this as a wake event
    end

    return false  -- Normal key processing should continue
end

function ScreenTimeout.wake()
    if ScreenTimeout.state ~= "active" then
        ez.log("[ScreenTimeout] Waking from " .. ScreenTimeout.state .. ", brightness=" .. ScreenTimeout.saved_brightness)

        -- Ensure saved_brightness is valid (not 0)
        local brightness = tonumber(ScreenTimeout.saved_brightness) or 200
        if brightness <= 0 then
            brightness = 200
            ez.log("[ScreenTimeout] Brightness was 0, reset to 200")
        end
        ScreenTimeout.saved_brightness = brightness

        -- Restore brightness
        if ez.display and ez.display.set_brightness then
            ez.display.set_brightness(ScreenTimeout.saved_brightness)
        end
        ScreenTimeout.state = "active"

        -- Force screen redraw
        if _G.ScreenManager then
            _G.ScreenManager.invalidate()
        end
        ez.log("[ScreenTimeout] Wake complete")
    end
end

function ScreenTimeout.dim()
    if ScreenTimeout.state == "active" then
        -- Save current brightness before dimming
        if ez.storage and ez.storage.get_pref then
            ScreenTimeout.saved_brightness = ez.storage.get_pref("brightness", 200)
        end

        -- Set dim brightness
        if ez.display and ez.display.set_brightness then
            ez.display.set_brightness(ScreenTimeout.dim_brightness)
        end
        ScreenTimeout.state = "dimmed"
    end
end

function ScreenTimeout.turn_off()
    if ScreenTimeout.state ~= "off" then
        -- Save brightness if not already saved (in case we skipped dim)
        if ScreenTimeout.state == "active" then
            if ez.storage and ez.storage.get_pref then
                ScreenTimeout.saved_brightness = ez.storage.get_pref("brightness", 200)
            end
        end

        -- Turn off display
        if ez.display and ez.display.set_brightness then
            ez.display.set_brightness(0)
        end
        ScreenTimeout.state = "off"
    end
end

function ScreenTimeout.update()
    local now = ez.system.millis()

    -- Only check periodically
    if now - ScreenTimeout.last_check < ScreenTimeout.check_interval then
        return
    end
    ScreenTimeout.last_check = now

    -- Note: Hardware pin polling (has_key_activity) disabled - pins read incorrectly on T-Deck Plus
    -- Wake detection relies on normal keyboard.read() path in screen_manager which uses edge detection

    -- Calculate idle time in minutes
    local idle_ms = now - ScreenTimeout.last_activity
    local idle_minutes = idle_ms / 60000

    -- Check off timeout first (if enabled)
    if ScreenTimeout.off_timeout > 0 and idle_minutes >= ScreenTimeout.off_timeout then
        if ScreenTimeout.state ~= "off" then
            ScreenTimeout.turn_off()
        end
        return
    end

    -- Check dim timeout (if enabled)
    if ScreenTimeout.dim_timeout > 0 and idle_minutes >= ScreenTimeout.dim_timeout then
        if ScreenTimeout.state == "active" then
            ScreenTimeout.dim()
        end
        return
    end
end

function ScreenTimeout.is_screen_off()
    return ScreenTimeout.state == "off"
end

function ScreenTimeout.is_dimmed()
    return ScreenTimeout.state == "dimmed"
end

function ScreenTimeout.register()
    if _G.MainLoop then
        _G.MainLoop.on_update("screen_timeout", ScreenTimeout.update)
    end
end

function ScreenTimeout.unregister()
    if _G.MainLoop then
        _G.MainLoop.off_update("screen_timeout")
    end
end

return ScreenTimeout
