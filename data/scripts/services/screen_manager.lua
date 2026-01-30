-- Screen Manager for T-Deck OS
-- Pure Lua screen stack management with keyboard input handling

local ScreenManager = {
    stack = {},           -- Screen stack (bottom to top)
    dirty = true,         -- Needs redraw
    last_render = 0,      -- For frame rate limiting
    frame_interval = 33,  -- ~30 FPS minimum interval
}

-- Push a new screen onto the stack
function ScreenManager.push(screen)
    if not screen then
        tdeck.system.log("[ScreenManager] Error: attempted to push nil screen")
        return
    end

    -- Call on_leave on current screen if any
    local current = ScreenManager.peek()
    if current and current.on_leave then
        current:on_leave()
    end

    -- Add to stack
    table.insert(ScreenManager.stack, screen)

    -- Call on_enter on new screen
    if screen.on_enter then
        screen:on_enter()
    end

    ScreenManager.dirty = true
end

-- Pop the current screen
function ScreenManager.pop()
    if #ScreenManager.stack == 0 then
        return nil
    end

    -- Get and remove top screen
    local screen = table.remove(ScreenManager.stack)

    -- Call on_exit if defined
    if screen and screen.on_exit then
        screen:on_exit()
    end

    -- Clear reference and collect garbage to free memory
    screen = nil
    run_gc("collect", "screen-pop")

    -- Call on_enter on the screen below (it's coming back into view)
    local current = ScreenManager.peek()
    if current and current.on_enter then
        current:on_enter()
    end

    ScreenManager.dirty = true
    return nil  -- Don't return the screen since we cleared it
end

-- Replace current screen without stack growth
function ScreenManager.replace(screen)
    if not screen then
        tdeck.system.log("[ScreenManager] Error: attempted to replace with nil screen")
        return
    end

    -- Pop current (with on_exit)
    local old = table.remove(ScreenManager.stack)
    if old and old.on_exit then
        old:on_exit()
    end

    -- Clear old screen reference and collect garbage
    old = nil
    run_gc("collect", "screen-replace")

    -- Push new (with on_enter)
    table.insert(ScreenManager.stack, screen)
    if screen.on_enter then
        screen:on_enter()
    end

    ScreenManager.dirty = true
end

-- Get current screen (top of stack)
function ScreenManager.peek()
    if #ScreenManager.stack == 0 then
        return nil
    end
    return ScreenManager.stack[#ScreenManager.stack]
end

-- Check if stack is empty
function ScreenManager.is_empty()
    return #ScreenManager.stack == 0
end

-- Get stack depth
function ScreenManager.depth()
    return #ScreenManager.stack
end

-- Mark screen for redraw
function ScreenManager.invalidate()
    ScreenManager.dirty = true
end

-- Process keyboard input
-- Returns true if input was handled
function ScreenManager.process_input()
    -- Skip normal keyboard reading if screen has capture_input flag
    local screen = ScreenManager.peek()
    if screen and screen.capture_input then
        return false
    end

    -- Read the key (non-blocking) - includes keyboard and trackball
    -- Note: Don't use available() as it only checks keyboard I2C, not trackball GPIOs
    local key = tdeck.keyboard.read()
    if not key or not key.valid then
        return false
    end

    -- Notify screen timeout service of activity (may consume key as wake event)
    if _G.ScreenTimeout and _G.ScreenTimeout.on_activity then
        if _G.ScreenTimeout.on_activity() then
            -- Key was consumed to wake screen, don't process further
            return true
        end
    end

    -- Let overlays process input first (highest z-order first)
    if _G.Overlays and _G.Overlays.process_key then
        if _G.Overlays.process_key(key) then
            return true
        end
    end

    -- Get current screen
    local screen = ScreenManager.peek()
    if not screen then
        return false
    end

    -- Dispatch to screen's handle_key
    if screen.handle_key then
        local result = screen:handle_key(key)

        -- Handle standard return values
        if result == "pop" then
            if _G.SoundUtils and _G.SoundUtils.back then
                pcall(_G.SoundUtils.back)
            end
            ScreenManager.pop()
        elseif result == "exit" then
            -- Pop all screens
            while #ScreenManager.stack > 0 do
                ScreenManager.pop()
            end
        end
        -- "continue" or nil means stay on current screen

        return true
    end

    return false
end

-- Render current screen and overlays
function ScreenManager.render()
    -- Skip if not dirty and within frame interval
    local now = tdeck.system.millis()
    if not ScreenManager.dirty then
        return
    end

    -- Frame rate limiting
    if now - ScreenManager.last_render < ScreenManager.frame_interval then
        return
    end

    local display = tdeck.display

    -- Render main screen
    local screen = ScreenManager.peek()
    if screen and screen.render then
        screen:render(display)
    else
        -- No screen - show blank
        display.fill_rect(0, 0, display.width, display.height, display.colors.BLACK)
    end

    -- Render overlays via the global Overlays system
    if _G.Overlays and _G.Overlays.render_all then
        _G.Overlays.render_all(display)
    end

    -- Flush display
    display.flush()

    ScreenManager.dirty = false
    ScreenManager.last_render = now
end

-- Main update function - process input and render
function ScreenManager.update()
    -- Process all pending input (keyboard and trackball)
    -- Loop until no more input available
    while ScreenManager.process_input() do
        -- Keep processing until no more input
    end

    -- Call screen's update method if it exists (for polling, animations, etc.)
    local screen = ScreenManager.peek()
    if screen and screen.update then
        screen:update()
    end

    -- Render if needed
    ScreenManager.render()
end

-- Clear all screens (emergency reset)
function ScreenManager.clear()
    while #ScreenManager.stack > 0 do
        local screen = table.remove(ScreenManager.stack)
        if screen and screen.on_exit then
            screen:on_exit()
        end
    end
    ScreenManager.dirty = true
end

return ScreenManager
