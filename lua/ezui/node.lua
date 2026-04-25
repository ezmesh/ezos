-- ezui.node: Declarative UI node system
-- Nodes are plain tables with a `type` field and optional children.
-- Each type has measure(node, max_w, max_h) and draw(node, d, x, y, w, h) functions.
-- The framework walks the tree to compute layout and render.

local theme = require("ezui.theme")

local node = {}

-- Registry of node type handlers: { [type_name] = { measure=fn, draw=fn, focusable=bool } }
local types = {}

-- Register a node type
function node.register(name, handler)
    types[name] = handler
end

-- Get handler for a node type
function node.handler(name)
    return types[name]
end

-- ---------------------------------------------------------------------------
-- Tree traversal
-- ---------------------------------------------------------------------------

-- Measure a node. Sets node._w, node._h.
-- max_w, max_h are the constraints from the parent.
function node.measure(n, max_w, max_h)
    if not n or not n.type then return 0, 0 end
    local h = types[n.type]
    if h and h.measure then
        local w, ht = h.measure(n, max_w, max_h)
        n._w = w
        n._h = ht
        return w, ht
    end
    n._w = 0
    n._h = 0
    return 0, 0
end

-- Draw a node at the given position and size.
-- The node's allocated region is (x, y, w, h).
function node.draw(n, d, x, y, w, h)
    if not n or not n.type then return end
    -- Store layout position for focus/hit testing
    n._x = x
    n._y = y
    n._aw = w  -- allocated width
    n._ah = h  -- allocated height
    local handler = types[n.type]
    if handler and handler.draw then
        handler.draw(n, d, x, y, w, h)
    end
end

-- ---------------------------------------------------------------------------
-- Focus helpers
-- ---------------------------------------------------------------------------

-- Collect all focusable nodes in tree order (depth-first).
-- Also records the nearest scroll ancestor for each focusable node.
-- Returns a flat list of nodes (each with _scroll_parent set if inside a scroll).
function node.collect_focusable(root)
    local result = {}
    node._walk_focusable(root, result, nil)
    return result
end

function node._walk_focusable(n, result, scroll_parent)
    if not n then return end
    -- Track scroll containers as we descend
    if n.type == "scroll" then
        scroll_parent = n
    end
    local h = types[n.type]
    if h and h.focusable then
        n._scroll_parent = scroll_parent
        result[#result + 1] = n
    end
    if n.children then
        for _, child in ipairs(n.children) do
            node._walk_focusable(child, result, scroll_parent)
        end
    end
    if n._rendered_items then
        for _, item in ipairs(n._rendered_items) do
            node._walk_focusable(item, result, scroll_parent)
        end
    end
end

return node
