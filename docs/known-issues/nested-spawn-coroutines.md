# Nested Spawn Coroutines Issue

## Problem

Calling `spawn()` from within an already-spawned coroutine can cause "cannot resume dead coroutine" errors.

## Symptoms

- Error message: `cannot resume dead coroutine`
- Error source: `coroutine`
- Occurs when loading screens or modules that use nested async operations

## Root Cause

The `spawn()` function creates a new Lua coroutine for async operations. When code inside a spawned coroutine calls `spawn()` again to start another async operation, the nested coroutine context can cause issues:

1. The inner `spawn()` creates a new coroutine
2. When that inner coroutine yields (e.g., for `async_read_bytes()`), control returns to the scheduler
3. The scheduler may try to resume the wrong coroutine, or the original coroutine may have already completed

## Example of Problematic Code

```lua
-- BAD: Spawning inside a spawn creates nested coroutines
function MyScreen:load_data_async()
    spawn(function()
        -- First async operation
        local header = async_read_bytes(path, 0, 32)

        -- BAD: Spawning another coroutine from within this one
        self:load_extra_data_async()  -- This calls spawn() internally
    end)
end

function MyScreen:load_extra_data_async()
    spawn(function()  -- PROBLEM: Nested spawn
        local data = async_read_bytes(path, offset, size)
        -- ...
    end)
end
```

## Solution

Keep all async operations within the same coroutine context. Don't spawn nested coroutines - instead, call the async functions directly:

```lua
-- GOOD: All async operations in same coroutine
function MyScreen:load_data_async()
    spawn(function()
        -- First async operation
        local header = async_read_bytes(path, 0, 32)

        -- GOOD: Call the function directly, don't spawn
        self:load_extra_data(offset, size)  -- No internal spawn()
    end)
end

function MyScreen:load_extra_data(offset, size)
    -- GOOD: No spawn() wrapper - runs in caller's coroutine context
    local data = async_read_bytes(path, offset, size)
    -- ...
end
```

## Real-World Example

The map viewer originally had this issue:

```lua
-- Original problematic code in load_archive_async()
function MapViewer:load_archive_async()
    spawn(function()
        -- Load archive header...

        -- BAD: This spawned a nested coroutine
        self:load_labels_v4_async(offset, count)
    end)
end

function MapViewer:load_labels_v4_async(offset, count)
    spawn(function()  -- Nested spawn caused the error
        while labels_loaded < count do
            local chunk = async_read_bytes(...)
            -- ...
        end
    end)
end
```

Fixed by removing the inner spawn:

```lua
-- Fixed code
function MapViewer:load_archive_async()
    spawn(function()
        -- Load archive header...

        -- GOOD: Call directly without spawning
        self:load_labels_v4(offset, count)
    end)
end

function MapViewer:load_labels_v4(offset, count)
    -- No spawn() - runs in parent's coroutine context
    while labels_loaded < count do
        local chunk = async_read_bytes(...)
        -- ...
    end
end
```

## Guidelines

1. **One spawn per async task chain** - Use a single `spawn()` at the entry point
2. **Async functions should be coroutine-agnostic** - They should yield normally without creating new coroutines
3. **Use `spawn()` only at the top level** - For initiating an async operation from synchronous code (e.g., `on_enter()`)
4. **Test async code paths** - Nested spawn issues often only appear at runtime

## Related

- `data/scripts/ui/screens/map_viewer.lua` - Fixed in commit addressing this issue
- `spawn()` function defined in boot.lua
