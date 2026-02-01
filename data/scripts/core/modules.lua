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
    -- Skip GC in simulator (Wasmoon has issues with collectgarbage + JS interop)
    if __SIMULATOR__ then
        return
    end
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

-- Spawn a coroutine and immediately resume it
-- Use this to run async code (like load_module) from event handlers
-- In simulator mode, runs the function directly (no coroutine) since Wasmoon
-- has issues with JS calls from coroutines
-- @param fn Function to run in the coroutine
-- @return The coroutine object (or nil in simulator mode)
function _G.spawn(fn)
    if __SIMULATOR__ then
        -- Simulator: run directly (no coroutine needed, async_read is synchronous)
        local ok, err = pcall(fn)
        if not ok then
            ez.log("[spawn] Error: " .. tostring(err))
        end
        return nil
    else
        -- Real hardware: use coroutine for async I/O
        local co = coroutine.create(fn)
        coroutine.resume(co)
        return co
    end
end

-- Spawn and push a screen to the ScreenManager
-- Handles async module loading, error handling, and ScreenManager.push
-- @param path Path to the screen module file
-- @param ... Arguments passed to the screen's :new() constructor
-- @return The coroutine object (or nil in simulator mode)
-- @example spawn_screen("/scripts/ui/screens/settings.lua")
-- @example spawn_screen("/scripts/ui/screens/node_details.lua", node)
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
-- @return The coroutine object (or nil in simulator mode)
-- @example spawn_module("/scripts/services/sync.lua", "start")
-- @example spawn_module("/scripts/tools/export.lua", "run", filename)
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
