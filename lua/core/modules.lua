-- Module loading infrastructure for ezOS
-- Provides async module loading, spawning, and memory management

local function mem()
    return math.floor((ez.system.get_free_heap() + ez.system.get_free_psram()) / 1024)
end

-- Global GC helper that logs memory before/after
-- @param mode "collect" (full) or "step" (incremental)
-- @param context Optional string describing why GC is being called
-- @param arg Optional argument for step mode
function _G.run_gc(mode, context, arg)
    local before = mem()
    if mode == "step" then
        collectgarbage("step", arg or 10)
    else
        collectgarbage("collect")
    end
    local after = mem()
    local freed = after - before
    local ctx = context and (" [" .. context .. "]") or ""
    if freed ~= 0 then
        ez.log(string.format("[GC]%s %dKB -> %dKB (%+dKB)", ctx, before, after, freed))
    end
end

-- Track loaded modules for potential unloading
_G.loaded_modules = {}

-- Load a module using async I/O (must be called from within a coroutine)
-- Uses async_read which yields until the file is loaded
-- Returns the module result directly (no callback needed)
-- @param path Path to the module file
-- @param no_gc Skip GC before/after loading (for batch loading)
function _G.load_module(path, no_gc)
    if not no_gc then
        run_gc("collect", "pre-load " .. path)
    end

    -- Read file asynchronously - yields here, resumes when file is read
    -- Note: async_read returns instantly for embedded scripts (no actual I/O)
    local content = async_read(path)

    if not content then
        error("Failed to read: " .. path)
    end

    -- Compile the Lua code
    local chunk, err = load(content, "@" .. path)
    if not chunk then
        error("Parse error in " .. path .. ": " .. tostring(err))
    end

    -- Execute the chunk
    local ok, result = pcall(chunk)
    if not ok then
        error("Execute error in " .. path .. ": " .. tostring(result))
    end

    _G.loaded_modules[path] = true
    if not no_gc then
        run_gc("collect", "post-load " .. path)
    end

    return result
end

-- Unload a previously loaded module to free memory
function _G.unload_module(path)
    if _G.loaded_modules[path] then
        _G.loaded_modules[path] = nil
        run_gc("collect", "unload " .. path)
    end
end

-- Cooperative-yield scheduler.
--
-- IMPORTANT: this only resumes coroutines that explicitly opted in
-- via wait_ms() below. Coroutines that yield via C-side bindings
-- (ez.http.fetch, async I/O, defer()) are NOT added here -- those
-- have their own resume drivers in C++, and resuming them from this
-- scheduler too would either double-resume (causing
-- "cannot resume dead coroutine" on the C side) or feed nil into a
-- function that was waiting on a real response, corrupting state.
-- Earlier this file did add every suspended coroutine; that broke
-- ez.http.fetch and the OTA upload path among other things.
local _pending_coros = {}

-- Spawn a coroutine and immediately resume it.
-- Use this to run async code (like load_module, manual TCP work, or
-- other multi-step flows) from event handlers.
--   * If `fn` yields via a C-side binding (ez.http.fetch / async
--     I/O / defer), that binding owns the resume.
--   * If `fn` yields via wait_ms() (cooperative sleep), the
--     scheduler below picks it up on the next tick.
-- @param fn Function to run in the coroutine
-- @return The coroutine object
function _G.spawn(fn)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co)
    if not ok and ez and ez.log then
        ez.log("[spawn] error: " .. tostring(err))
    end
    return co
end

-- Drain cooperatively-yielded coroutines once. Called from the main
-- loop (see ezui/init.lua) every frame. A coroutine that wait_ms()es
-- again is re-queued by the next wait call; a coroutine that finishes
-- or errors is dropped.
function _G.tick_coroutines()
    if #_pending_coros == 0 then return end
    local ready = _pending_coros
    _pending_coros = {}
    for _, co in ipairs(ready) do
        if coroutine.status(co) == "suspended" then
            local ok, err = coroutine.resume(co)
            if not ok and ez and ez.log then
                ez.log("[coro] error: " .. tostring(err))
            end
            -- Notice we don't re-queue here -- if the coroutine
            -- yielded again via wait_ms it will have re-registered
            -- itself before yielding (see _enqueue_self below).
        end
    end
end

-- Internal: register the running coroutine for the next tick. Used
-- by wait_ms() before each yield so the scheduler knows to pick it
-- up. Stays out of the public surface to discourage callers from
-- bypassing wait_ms.
local function _enqueue_self()
    local co = coroutine.running()
    if co then _pending_coros[#_pending_coros + 1] = co end
end

-- Cooperative sleep usable inside a spawn()'d coroutine. Yields the
-- coroutine repeatedly until `ms` milliseconds have elapsed, so the
-- main loop continues to render frames and process input while the
-- caller waits. Replaces ez.system.delay() in async code paths --
-- that one blocks the whole Lua runtime.
function _G.wait_ms(ms)
    local deadline = ez.system.millis() + (ms or 0)
    while ez.system.millis() < deadline do
        _enqueue_self()
        coroutine.yield()
    end
end

-- Spawn and push a screen to the ScreenManager
-- Handles async module loading, error handling, and ScreenManager.push
-- @param path Path to the screen module file
-- @param ... Arguments passed to the screen's :new() constructor
-- @return The coroutine object
-- @example spawn_screen("$ui/screens/settings.lua")
-- @example spawn_screen("$ui/screens/node_details.lua", node)
function _G.spawn_screen(path, ...)
    local args = {...}
    return spawn(function()
        local ok, Screen = pcall(load_module, path)
        if not ok then
            local err_msg = tostring(Screen)
            ez.log("[spawn_screen] Load error: " .. err_msg)
            -- Show error screen to user
            if _G.show_error then
                _G.show_error(err_msg, path)
            end
            return
        end
        if Screen and _G.ScreenManager then
            _G.ScreenManager.push(Screen:new(table.unpack(args)))
        end
    end)
end

-- Spawn and run a module's method
-- Handles async module loading and method invocation
-- @param path Path to the module file
-- @param method Method name to call (default "main")
-- @param ... Arguments passed to the method
-- @return The coroutine object
-- @example spawn_module("$services/sync.lua", "start")
-- @example spawn_module("$tools/export.lua", "run", filename)
function _G.spawn_module(path, method, ...)
    method = method or "main"
    local args = {...}
    return spawn(function()
        local ok, Module = pcall(load_module, path)
        if not ok then
            ez.log("[spawn_module] Load error: " .. tostring(Module))
            return
        end
        if Module and Module[method] then
            Module[method](table.unpack(args))
        elseif Module and type(Module) == "function" then
            -- Module returned a function directly
            Module(table.unpack(args))
        end
    end)
end

-- Override dofile to prevent accidental use - use load_module instead
function _G.dofile(path)
    error("dofile() is deprecated. Use load_module() instead (must be called from a coroutine). Path: " .. tostring(path))
end

-- Return mem() for use by boot.lua
return {
    mem = mem
}
