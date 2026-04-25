-- ezui.async: Promise-based async/await for Lua
-- Wraps the coroutine-yield C++ async system (AsyncIO on Core 0)
-- with composable primitives: promises, async functions, parallel execution.
--
-- The C++ runtime provides:
--   async_read/write/etc  - yield in coroutine, resume when I/O completes
--   defer()               - yield, resume on next frame
--   ez.system.set_timer   - schedule callback after delay
--
-- This module adds:
--   Promise               - chainable async result container
--   async()               - wrap a function to run in a coroutine, return a Promise
--   await()               - suspend coroutine until Promise resolves (sugar for yield)
--   await_all()           - run multiple async fns in parallel, wait for all

local async = {}

-- ---------------------------------------------------------------------------
-- Global pending-op counter
-- Drives the status-bar spinner. Increments/decrements automatically around
-- any work wrapped with async.fn() (and the read/write/json/etc helpers
-- below). Screens that manage their own coroutines can call begin()/done()
-- manually to participate in the indicator.
-- ---------------------------------------------------------------------------

local _pending = 0
local _listeners = {}

local function notify()
    for i = 1, #_listeners do _listeners[i](_pending) end
end

function async.begin()
    _pending = _pending + 1
    if _pending == 1 then notify() end
end

function async.done()
    if _pending > 0 then _pending = _pending - 1 end
    if _pending == 0 then notify() end
end

function async.pending_count()
    return _pending
end

function async.is_busy()
    return _pending > 0
end

-- Register a listener invoked whenever the busy state edges (0→1 or 1→0).
-- Used by the screen renderer to wake on async activity.
function async.on_busy_change(cb)
    _listeners[#_listeners + 1] = cb
end

-- Spawn `fn` as a coroutine with automatic busy-counter bookkeeping:
-- begin() fires before the body, done() fires after regardless of
-- success or error. Use this for user-visible work (file reads,
-- downloads, parsing) where the status-bar spinner should appear.
-- Background services with "while true" loops should keep using
-- plain spawn() so they don't pin the spinner on forever.
function async.task(fn)
    async.begin()
    spawn(function()
        local ok, err = pcall(fn)
        async.done()
        if not ok then
            ez.log("[async.task] error: " .. tostring(err))
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Promise
-- ---------------------------------------------------------------------------

local PENDING  = 0
local RESOLVED = 1
local REJECTED = 2

local Promise = {}
Promise.__index = Promise

function Promise.new(executor)
    local self = setmetatable({
        _state = PENDING,
        _value = nil,
        _queue = {},
    }, Promise)

    if executor then
        local ok, err = pcall(executor,
            function(v) self:_settle(RESOLVED, v) end,
            function(e) self:_settle(REJECTED, e) end
        )
        if not ok then self:_settle(REJECTED, err) end
    end

    return self
end

function Promise:_settle(state, value)
    if self._state ~= PENDING then return end
    self._state = state
    self._value = value
    for _, h in ipairs(self._queue) do
        self:_dispatch(h)
    end
    self._queue = nil
end

function Promise:_dispatch(handler)
    local cb = (self._state == RESOLVED) and handler[1] or handler[2]
    if cb then
        local ok, result = pcall(cb, self._value)
        if ok then
            handler[3]:_settle(RESOLVED, result)
        else
            handler[3]:_settle(REJECTED, result)
        end
    else
        -- Pass through
        handler[3]:_settle(self._state, self._value)
    end
end

function Promise:and_then(on_resolve, on_reject)
    local p = Promise.new()
    local h = { on_resolve, on_reject, p }
    if self._state == PENDING then
        self._queue[#self._queue + 1] = h
    else
        self:_dispatch(h)
    end
    return p
end

function Promise:catch(on_reject)
    return self:and_then(nil, on_reject)
end

function Promise.resolve(value)
    local p = Promise.new()
    p:_settle(RESOLVED, value)
    return p
end

function Promise.reject(err)
    local p = Promise.new()
    p:_settle(REJECTED, err)
    return p
end

-- Wait for all promises to resolve. Rejects on first rejection.
function Promise.all(promises)
    return Promise.new(function(resolve, reject)
        local n = #promises
        if n == 0 then resolve({}) return end
        local results = {}
        local remaining = n
        local rejected = false
        for i = 1, n do
            promises[i]:and_then(
                function(v)
                    if rejected then return end
                    results[i] = v
                    remaining = remaining - 1
                    if remaining == 0 then resolve(results) end
                end,
                function(e)
                    if rejected then return end
                    rejected = true
                    reject(e)
                end
            )
        end
    end)
end

-- Return first promise to settle
function Promise.race(promises)
    return Promise.new(function(resolve, reject)
        local settled = false
        for _, p in ipairs(promises) do
            p:and_then(
                function(v) if not settled then settled = true; resolve(v) end end,
                function(e) if not settled then settled = true; reject(e) end end
            )
        end
    end)
end

async.Promise = Promise

-- ---------------------------------------------------------------------------
-- async() / await() / await_all()
-- ---------------------------------------------------------------------------

-- Wrap a function so it runs in a coroutine and returns a Promise.
-- Inside the function, use the raw coroutine-yield async_* functions directly.
function async.fn(func)
    return function(...)
        local args = { ... }
        return Promise.new(function(resolve, reject)
            async.begin()
            spawn(function()
                local ok, result = pcall(func, table.unpack(args))
                async.done()
                if ok then
                    resolve(result)
                else
                    reject(result)
                end
            end)
        end)
    end
end

-- Await a Promise from within a coroutine.
-- If the value is not a Promise, returns it immediately.
function async.await(promise_or_value)
    if type(promise_or_value) ~= "table" or getmetatable(promise_or_value) ~= Promise then
        return promise_or_value
    end

    local p = promise_or_value
    if p._state == RESOLVED then return p._value end
    if p._state == REJECTED then error(p._value) end

    -- Poll until settled, yielding each frame via defer()
    while p._state == PENDING do
        defer()
    end

    if p._state == RESOLVED then return p._value end
    error(p._value)
end

-- Run multiple async functions in parallel, wait for all results.
-- Each element is a function that will be spawned as a coroutine.
-- Returns a list of results in order.
function async.all(fns)
    local n = #fns
    local results = {}
    local done = 0
    local first_err = nil

    for i = 1, n do
        spawn(function()
            local ok, result = pcall(fns[i])
            if ok then
                results[i] = result
            elseif not first_err then
                first_err = result
            end
            done = done + 1
        end)
    end

    while done < n do
        defer()
    end

    if first_err then error(first_err) end
    return results
end

-- ---------------------------------------------------------------------------
-- Convenience wrappers for C++ async I/O
-- These return Promises and can be used from any context.
-- ---------------------------------------------------------------------------

function async.read(path)
    return async.fn(function() return async_read(path) end)()
end

function async.write(path, data)
    return async.fn(function() return async_write(path, data) end)()
end

function async.append(path, data)
    return async.fn(function() return async_append(path, data) end)()
end

function async.exists(path)
    return async.fn(function() return async_exists(path) end)()
end

function async.read_bytes(path, offset, length)
    return async.fn(function() return ez.storage.async_read_bytes(path, offset, length) end)()
end

function async.json_read(path)
    return async.fn(function() return async_json_read(path) end)()
end

function async.json_write(path, data)
    return async.fn(function() return async_json_write(path, data) end)()
end

-- Schedule a delay that resolves after ms milliseconds
function async.sleep(ms)
    return Promise.new(function(resolve)
        ez.system.set_timer(ms, function() resolve(true) end)
    end)
end

return async
