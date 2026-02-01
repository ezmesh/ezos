-- Main Loop for T-Deck OS
-- Lua-controlled main loop that handles mesh, input, and rendering

local MainLoop = {
    running = false,
    screen_manager = nil,
    update_callbacks = {},  -- Additional update callbacks
    last_mesh_update = 0,
    mesh_update_interval = 50,  -- Update mesh every 50ms (normal mode)
    mesh_interval_normal = 50,  -- Normal interval
    mesh_interval_game = 500,   -- Slower interval during games (500ms)
    last_gc = 0,
    gc_interval = 2000,  -- Run incremental GC every 2 seconds
    gc_enabled = true,  -- Can be disabled for games that manage GC themselves
}

-- Initialize the main loop
function MainLoop.init(screen_manager)
    MainLoop.screen_manager = screen_manager
    MainLoop.running = false
    MainLoop.update_callbacks = {}
    ez.log("[MainLoop] Initialized")
end

-- Register an update callback (called each frame)
-- callback = function() end
function MainLoop.on_update(name, callback)
    MainLoop.update_callbacks[name] = callback
end

-- Unregister an update callback
function MainLoop.off_update(name)
    MainLoop.update_callbacks[name] = nil
end

-- Disable scheduled garbage collection (for games that manage GC themselves)
function MainLoop.disable_gc()
    MainLoop.gc_enabled = false
end

-- Enable scheduled garbage collection
function MainLoop.enable_gc()
    MainLoop.gc_enabled = true
end

-- Set mesh update interval
function MainLoop.set_mesh_interval(interval_ms)
    MainLoop.mesh_update_interval = interval_ms
end

-- Enter game mode (disables GC, slows mesh, and hides status bar for smooth performance)
function MainLoop.enter_game_mode()
    MainLoop.gc_enabled = false
    MainLoop.mesh_update_interval = MainLoop.mesh_interval_game
    if _G.StatusBar then _G.StatusBar.disable() end
end

-- Exit game mode (re-enables everything)
function MainLoop.exit_game_mode()
    MainLoop.gc_enabled = true
    MainLoop.mesh_update_interval = MainLoop.mesh_interval_normal
    if _G.StatusBar then _G.StatusBar.enable() end
    run_gc("collect", "exit-game-mode")
end

-- Single update iteration
function MainLoop.step()
    local now = ez.system.millis()

    -- Update mesh networking periodically (slower during games)
    if now - MainLoop.last_mesh_update >= MainLoop.mesh_update_interval then
        if ez.mesh.is_initialized() then
            ez.mesh.update()
        end
        MainLoop.last_mesh_update = now
    end

    -- Process scheduled services and timers
    if _G.Scheduler then
        _G.Scheduler.update()
    end

    -- Process keyboard input and render via screen manager
    if MainLoop.screen_manager then
        MainLoop.screen_manager.update()
    end

    -- Call registered update callbacks
    for name, callback in pairs(MainLoop.update_callbacks) do
        local ok, err = pcall(callback)
        if not ok then
            ez.log("[MainLoop] Update callback '" .. name .. "' error: " .. tostring(err))
        end
    end

    -- Periodic incremental garbage collection (can be disabled for games)
    if MainLoop.gc_enabled and now - MainLoop.last_gc >= MainLoop.gc_interval then
        run_gc("step", nil, 10)  -- Small incremental step, no context to reduce log noise
        MainLoop.last_gc = now
    end
end

-- Start the Lua main loop
-- Sets global main_loop function that C++ calls each frame
function MainLoop.start()
    if MainLoop.running then
        ez.log("[MainLoop] Already running")
        return
    end

    if not MainLoop.screen_manager then
        ez.log("[MainLoop] Error: screen_manager not set")
        return
    end

    MainLoop.running = true

    -- Set global function that C++ will call each frame
    _G.main_loop = function()
        if MainLoop.running then
            MainLoop.step()
        end
    end

    ez.log("[MainLoop] Started")
end

-- Stop the Lua main loop
function MainLoop.stop()
    if not MainLoop.running then
        return
    end

    MainLoop.running = false
    _G.main_loop = nil

    ez.log("[MainLoop] Stopped")
end

return MainLoop
