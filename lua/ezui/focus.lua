-- ezui.focus: Focus chain management and key routing
-- Maintains the list of focusable nodes and dispatches input.

local node_mod = require("ezui.node")

local focus = {}

-- Current state
focus.chain = {}     -- Ordered list of focusable nodes
focus.index = 0      -- Currently focused index (0 = none)
focus.editing = false -- True when a text widget has captured input

-- Rebuild the focus chain from a node tree
function focus.rebuild(root)
    focus.chain = node_mod.collect_focusable(root)
    -- Clamp index
    if focus.index > #focus.chain then
        focus.index = #focus.chain
    end
    if focus.index < 1 and #focus.chain > 0 then
        focus.index = 1
    end
    -- Mark focused node
    focus._update_marks()
end

-- Get the currently focused node (or nil)
function focus.current()
    if focus.index >= 1 and focus.index <= #focus.chain then
        return focus.chain[focus.index]
    end
    return nil
end

-- Move focus forward (clamp at end, don't wrap)
function focus.next()
    if #focus.chain == 0 then return end
    if focus.index < #focus.chain then
        focus.index = focus.index + 1
        focus._update_marks()
    end
end

-- Move focus backward (clamp at start, don't wrap)
function focus.prev()
    if #focus.chain == 0 then return end
    if focus.index > 1 then
        focus.index = focus.index - 1
        focus._update_marks()
    end
end

-- Set focus to a specific node
function focus.set(target)
    for i, n in ipairs(focus.chain) do
        if n == target then
            focus.index = i
            focus._update_marks()
            return true
        end
    end
    return false
end

-- Enter/exit edit mode (for text inputs)
function focus.enter_edit()
    focus.editing = true
end

function focus.exit_edit()
    focus.editing = false
end

-- Update _focused flag on all nodes and auto-scroll to keep focus visible
function focus._update_marks()
    for i, n in ipairs(focus.chain) do
        n._focused = (i == focus.index)
    end
    -- Auto-scroll: ensure focused node is visible in its scroll parent
    local n = focus.current()
    if n and n._scroll_parent then
        focus._auto_scroll(n, n._scroll_parent)
    end
end

-- Scroll a scroll container so that the focused node is visible.
-- After draw, item._y is the on-screen Y (with scroll offset applied).
-- scroll._y is the scroll viewport's screen Y.
-- To get the item's position in content space: content_y = screen_y - scroll_y + offset
function focus._auto_scroll(item, scroll)
    if not item._y or not scroll._y then return end

    local offset = scroll.scroll_offset or 0
    local viewport_h = scroll._ah or 0
    local item_h = item._ah or 0

    -- Convert screen position back to content-space position
    local content_y = (item._y - scroll._y) + offset
    local content_bottom = content_y + item_h

    -- Scroll down if item extends below viewport
    if content_bottom > offset + viewport_h then
        scroll.scroll_offset = content_bottom - viewport_h
    end
    -- Scroll up if item is above viewport
    if content_y < offset then
        scroll.scroll_offset = content_y
    end
end

-- Route a key event through the focus system.
-- Returns: "handled", "pop", "exit", or nil (unhandled)
function focus.handle_key(key, screen)
    -- If editing, all keys go to the focused widget
    if focus.editing then
        local n = focus.current()
        if n then
            local handler = node_mod.handler(n.type)
            if handler and handler.on_key then
                local result = handler.on_key(n, key)
                if result then return result end
            end
        end
        -- ESCAPE exits edit mode
        if key.special == "ESCAPE" then
            focus.exit_edit()
            return "handled"
        end
        return "handled"
    end

    -- Let the focused widget handle directional keys first (for grid navigation etc.)
    local n = focus.current()
    if n and (key.special == "UP" or key.special == "DOWN"
           or key.special == "LEFT" or key.special == "RIGHT") then
        local handler = node_mod.handler(n.type)
        if handler and handler.on_key then
            local result = handler.on_key(n, key)
            if result then return result end
        end
    end

    -- Default navigation: UP/DOWN move focus linearly, ENTER activates
    -- Only consume these keys when there are focusable nodes in the tree
    if key.special == "UP" and #focus.chain > 0 then
        focus.prev()
        return "handled"
    elseif key.special == "DOWN" and #focus.chain > 0 then
        focus.next()
        return "handled"
    elseif key.special == "ENTER" then
        if n then
            local handler = node_mod.handler(n.type)
            if handler and handler.on_activate then
                local result = handler.on_activate(n, key)
                if result then return result end
            end
            return "handled"
        end
    end

    -- Let the screen handle all remaining keys
    if screen and screen.handle_key then
        local result = screen:handle_key(key)
        if result then return result end
    end

    -- Default back: ESCAPE or 'q' pops the screen
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    return nil
end

-- Ensure focused item is visible in a scroll container.
-- Call after focus changes. Adjusts scroll_offset on the scroll node.
function focus.ensure_visible(scroll_node, viewport_h)
    local n = focus.current()
    if not n or not scroll_node then return end

    local offset = scroll_node.scroll_offset or 0
    local item_y = (n._y or 0) - (scroll_node._y or 0) + offset
    local item_h = n._ah or 0

    -- Scroll down if item is below viewport
    if item_y + item_h > offset + viewport_h then
        scroll_node.scroll_offset = item_y + item_h - viewport_h
    end
    -- Scroll up if item is above viewport
    if item_y < offset then
        scroll_node.scroll_offset = item_y
    end
end

return focus
