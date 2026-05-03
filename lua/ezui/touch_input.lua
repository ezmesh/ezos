-- ezui.touch_input -- global touch -> widget bridge.
--
-- Hooked once at boot from boot.lua. Subscribes to the touch/down,
-- touch/move, and touch/up bus topics and turns single-finger taps
-- into widget activations on whichever focusable node sits under the
-- down point. With this loaded, every list_item / button across the
-- entire OS becomes tappable at no per-screen cost.
--
-- Behaviour:
--   * touch/down  -- cache (x, y, ms). Walk the active screen's focus
--                    chain to find the focusable node whose layout
--                    rectangle contains the point. If we find one,
--                    move focus there immediately so the highlight
--                    follows the finger (mirrors how a press on a
--                    real button looks).
--   * touch/move  -- cancel the tap if the finger has moved further
--                    than TAP_SLOP pixels from the down point. The
--                    user is probably scrolling / dragging, not
--                    tapping. (Vertical drag-to-scroll is handled
--                    here too, walking up to the nearest scroll
--                    ancestor of the down-target.)
--   * touch/up    -- if the down was on a focusable, the finger
--                    didn't drift, and the lift happened within
--                    TAP_HOLD_MS, fire the node's on_activate.
--
-- Screens that need finer-grained touch (Paint canvas, Editor, the
-- map widget) bypass this helper by subscribing to the bus topics
-- directly. The helper only consumes events when it can resolve them
-- to a focusable widget, so per-screen subscribers still see every
-- event.

local node_mod = require("ezui.node")
local focus    = require("ezui.focus")

local M = {}

-- Pixel slack before a tap becomes a drag. Capacitive panels jitter a
-- few pixels even when the user thinks the finger is still, so 0 is
-- too tight; 12 is comfortable without making intentional drags feel
-- sticky.
local TAP_SLOP    = 12
-- Maximum down-to-up window for an activation. Beyond this we assume
-- the user changed their mind and don't fire.
local TAP_HOLD_MS = 600
-- One-finger drag inside a scroll container moves the offset by this
-- multiplier of the y-delta. 1.0 keeps content under the finger.
local DRAG_SCALE  = 1.0

-- Touch-mode minimum target height (in px). Widgets that participate
-- in tap activation (list_item, button, ...) consult this from their
-- measure() so each row is large enough to land a finger on without
-- guessing. Lives here rather than in theme.lua so the bridge and the
-- widgets agree on a single number; widgets read it as
-- `require("ezui.touch_input").MIN_TARGET_H`.
local MIN_TARGET_H = 32

-- Pending tap state. Kept module-local because the device is single
-- user; only one finger can have an in-flight tap at a time.
local _pending = nil

local function rect_contains(n, x, y)
    if not n._x or not n._y then return false end
    return x >= n._x and x < n._x + (n._aw or 0)
       and y >= n._y and y < n._y + (n._ah or 0)
end

local function walk_focus_chain_for_point(x, y)
    -- The focus module already collected every focusable in the
    -- active screen tree, with each node's layout rect (_x/_y/_aw/_ah)
    -- recorded by the most recent draw pass. Walk in reverse so the
    -- topmost (most-recently drawn) candidate wins on overlap, which
    -- matches what the user sees.
    local chain = focus.chain
    if not chain then return nil end
    for i = #chain, 1, -1 do
        local n = chain[i]
        if rect_contains(n, x, y) then return n, i end
    end
    return nil
end

-- Find a scroll container whose drawn rectangle contains the point.
-- Used when the down event landed on a non-focusable area (padding
-- between rows, a section header) so we still know which scroll to
-- drag. The focus chain stores `_scroll_parent` for every focusable;
-- we collect those into a unique set so we don't have to walk the
-- whole tree on every touch.
local function scroll_under_point(x, y)
    local chain = focus.chain
    if not chain then return nil end
    local seen = {}
    for _, n in ipairs(chain) do
        local s = n._scroll_parent
        if s and not seen[s] then
            seen[s] = true
            if rect_contains(s, x, y) then return s end
        end
    end
    return nil
end

local function set_focus_to(idx)
    if not idx or idx == focus.index then return end
    focus.index = idx
    if focus._update_marks then focus._update_marks() end
    require("ezui.screen").invalidate()
end

local function fire_activate(n)
    local h = node_mod.handler(n.type)
    if not h or not h.on_activate then return false end
    -- on_activate is normally called with a synthetic key=ENTER. The
    -- list_item / button handlers don't read key fields beyond the
    -- presence check, so an empty table is enough.
    h.on_activate(n, { special = "ENTER", source = "touch" })
    require("ezui.screen").invalidate()
    return true
end

local function on_down(_topic, data)
    if type(data) ~= "table" or not data.x or not data.y then return end

    local hit, idx = walk_focus_chain_for_point(data.x, data.y)
    -- Resolve the scroll ancestor. If the finger came down on a
    -- focusable inside the list, that focusable's _scroll_parent is
    -- authoritative. Otherwise (padding, section header, raw scroll
    -- background) probe the tree's scroll containers directly so a
    -- drag in the gutter still scrolls.
    local scroll_node = hit and hit._scroll_parent or scroll_under_point(data.x, data.y)

    -- Some widgets (slider thumb, color picker, scrubbers) want to
    -- handle the touch directly without going through the activate
    -- path. They expose `on_touch_down` / `on_touch_drag` on their
    -- node handler; we call those instead of routing to a scroll
    -- container or firing fire_activate on lift.
    local hit_handler = hit and node_mod.handler(hit.type) or nil
    local owns_touch = hit_handler and hit_handler.on_touch_down ~= nil

    _pending = {
        x0   = data.x,
        y0   = data.y,
        ms0  = ez.system.millis(),
        node = hit,
        idx  = idx,
        owns_touch = owns_touch,
        -- Skip the scroll fallback when the widget is claiming the
        -- touch -- a drag inside a slider must not also nudge the
        -- enclosing scroll container.
        scroll = (not owns_touch) and scroll_node or nil,
        scroll_start_off = nil,
    }
    if _pending.scroll then
        _pending.scroll_start_off = _pending.scroll.scroll_offset or 0
    end
    if hit and idx then
        set_focus_to(idx)
    end
    if owns_touch then
        hit_handler.on_touch_down(hit, data.x, data.y)
        require("ezui.screen").invalidate()
    end
end

local function on_move(_topic, data)
    if not _pending or type(data) ~= "table" then return end

    local dx = data.x - _pending.x0
    local dy = data.y - _pending.y0

    -- Widget-owned touch (slider, scrubber). Stream every move event
    -- to the node so it can update its value continuously. The
    -- bridge stops doing anything else (no scroll, no tap) for the
    -- rest of this gesture.
    if _pending.owns_touch and _pending.node then
        local h = node_mod.handler(_pending.node.type)
        if h and h.on_touch_drag then
            h.on_touch_drag(_pending.node, data.x, data.y, dx, dy)
            require("ezui.screen").invalidate()
        end
        _pending.cancelled = true
        return
    end

    -- One-finger scroll: only kicks in once the finger has actually
    -- moved past the slop. Drag content with the finger so a swipe
    -- up reveals lower entries (matches every other touch UI).
    if math.abs(dy) > TAP_SLOP and _pending.scroll then
        local s = _pending.scroll
        local viewport_h = s._ah or 0
        local content_h  = s._content_h or viewport_h
        local max_off    = math.max(0, content_h - viewport_h)
        local new_off    = _pending.scroll_start_off - dy * DRAG_SCALE
        if new_off < 0 then new_off = 0 end
        if new_off > max_off then new_off = max_off end
        if new_off ~= s.scroll_offset then
            s.scroll_offset = new_off
            require("ezui.screen").invalidate()
        end
        -- A drag-to-scroll cancels the tap; the user isn't selecting
        -- the row their finger started on.
        if not _pending.scrolling and (math.abs(dy) > TAP_SLOP) then
            _pending.scrolling = true
        end
    end

    if (math.abs(dx) > TAP_SLOP or math.abs(dy) > TAP_SLOP)
            and not _pending.scrolling then
        -- Moved off the down target without engaging a scroll --
        -- treat the gesture as a non-tap so a release won't fire.
        _pending.cancelled = true
    end
end

local function on_up(_topic, data)
    if not _pending then return end
    local p = _pending
    _pending = nil

    if p.cancelled or p.scrolling then return end
    if not p.node then return end
    if (ez.system.millis() - p.ms0) > TAP_HOLD_MS then return end

    fire_activate(p.node)
end

-- Claim the in-flight gesture. Cancels any pending tap so the global
-- bridge won't fire on touch/up. Screens that own a custom gesture
-- (tab-strip drag, paint canvas, map pan) should call this from
-- their own touch/down subscriber once they decide to handle the
-- touch. Safe to call when there is no pending gesture.
function M.claim()
    if _pending then _pending.cancelled = true end
end

-- Minimum hit-target size in pixels. Widgets read this from their
-- measure() to enforce a layout floor when the touch panel is in
-- use; a 22 px row is reachable with a trackball but easy to miss
-- with a finger.
M.MIN_TARGET_H = MIN_TARGET_H

-- True if the touch panel is initialised. Cheap (one Lua-side bool
-- read per call), but cached because measure() runs many times per
-- frame across long lists. The value can't change after boot, so we
-- compute it lazily on first call and stick with the answer.
function M.touch_enabled()
    if M._touch_cached == nil then
        M._touch_cached = (ez and ez.touch and ez.touch.is_initialized
                           and ez.touch.is_initialized()) or false
    end
    return M._touch_cached
end

function M.init()
    if M._initialised then return end
    M._initialised = true
    ez.bus.subscribe("touch/down", on_down)
    ez.bus.subscribe("touch/move", on_move)
    ez.bus.subscribe("touch/up",   on_up)
end

return M
