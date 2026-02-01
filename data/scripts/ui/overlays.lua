-- overlays.lua - Generic overlay rendering system
-- Supports multiple overlays with z-ordering, enable/disable, and input handling

local Overlays = {
    layers = {},  -- Array of {name, render_fn, z_order, enabled, handle_key_fn}
}

-- Register an overlay
-- @param name Unique identifier for the overlay
-- @param render_fn Function that takes (display) and renders the overlay
-- @param z_order Higher values render on top (default: 0)
-- @param handle_key_fn Optional function that takes (key) and returns true if handled
function Overlays.register(name, render_fn, z_order, handle_key_fn)
    z_order = z_order or 0

    -- Remove existing overlay with same name
    Overlays.unregister(name)

    table.insert(Overlays.layers, {
        name = name,
        render = render_fn,
        z_order = z_order,
        enabled = true,
        handle_key = handle_key_fn
    })

    -- Sort by z_order (lowest first, so they render bottom-up)
    table.sort(Overlays.layers, function(a, b)
        return a.z_order < b.z_order
    end)
end

-- Unregister an overlay
function Overlays.unregister(name)
    for i, layer in ipairs(Overlays.layers) do
        if layer.name == name then
            table.remove(Overlays.layers, i)
            return true
        end
    end
    return false
end

-- Enable an overlay
function Overlays.enable(name)
    for _, layer in ipairs(Overlays.layers) do
        if layer.name == name then
            layer.enabled = true
            return true
        end
    end
    return false
end

-- Disable an overlay
function Overlays.disable(name)
    for _, layer in ipairs(Overlays.layers) do
        if layer.name == name then
            layer.enabled = false
            return true
        end
    end
    return false
end

-- Check if an overlay is enabled
function Overlays.is_enabled(name)
    for _, layer in ipairs(Overlays.layers) do
        if layer.name == name then
            return layer.enabled
        end
    end
    return false
end

-- Toggle an overlay
function Overlays.toggle(name)
    for _, layer in ipairs(Overlays.layers) do
        if layer.name == name then
            layer.enabled = not layer.enabled
            return layer.enabled
        end
    end
    return false
end

-- Get an overlay by name
function Overlays.get(name)
    for _, layer in ipairs(Overlays.layers) do
        if layer.name == name then
            return layer
        end
    end
    return nil
end

-- Render all enabled overlays
function Overlays.render_all(display)
    for _, layer in ipairs(Overlays.layers) do
        if layer.enabled and layer.render then
            local ok, err = pcall(layer.render, display)
            if not ok then
                ez.log("Overlay error (" .. layer.name .. "): " .. tostring(err))
            end
        end
    end
end

-- Process key input through overlays (highest z-order first)
-- Returns true if an overlay handled the key
function Overlays.process_key(key)
    -- Iterate in reverse (highest z-order first)
    for i = #Overlays.layers, 1, -1 do
        local layer = Overlays.layers[i]
        if layer.enabled and layer.handle_key then
            local ok, handled = pcall(layer.handle_key, key)
            if ok and handled then
                return true
            elseif not ok then
                ez.log("Overlay key error (" .. layer.name .. "): " .. tostring(handled))
            end
        end
    end
    return false
end

-- List all registered overlays (for debugging)
function Overlays.list()
    local result = {}
    for _, layer in ipairs(Overlays.layers) do
        table.insert(result, {
            name = layer.name,
            z_order = layer.z_order,
            enabled = layer.enabled
        })
    end
    return result
end

return Overlays
