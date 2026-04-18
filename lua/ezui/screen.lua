-- ezui.screen: Screen stack manager with declarative build lifecycle
-- Screens define a build(state) method that returns a node tree.
-- State changes via set_state() trigger rebuild and redraw.

local node = require("ezui.node")
local focus = require("ezui.focus")
local theme = require("ezui.theme")

local screen = {}

-- Screen stack
screen.stack = {}
screen.dirty = true
screen.last_render = 0
screen.frame_interval = 33  -- ~30 FPS

-- ---------------------------------------------------------------------------
-- Screen instance creation
-- ---------------------------------------------------------------------------

-- Create a screen instance. screen_def is the screen's module table.
-- initial_state is the starting state table.
function screen.create(screen_def, initial_state)
    local inst = {
        title   = screen_def.title or "",
        _def    = screen_def,
        _state  = initial_state or {},
        _tree   = nil,
        _scroll = nil,  -- Reference to scroll node for focus tracking
    }

    -- Bind methods from screen_def
    for k, v in pairs(screen_def) do
        if type(v) == "function" and k ~= "new" and k ~= "build" then
            inst[k] = v
        end
    end

    -- State setter: triggers rebuild
    function inst:set_state(partial)
        for k, v in pairs(partial) do
            self._state[k] = v
        end
        self:_rebuild()
        screen.invalidate()
    end

    -- Get current state
    function inst:get_state()
        return self._state
    end

    -- Internal rebuild
    function inst:_rebuild()
        if self._def.build then
            self._tree = self._def.build(self, self._state)
        end
        if self._tree then
            -- Measure the full tree (screens include their own title bars)
            node.measure(self._tree, theme.SCREEN_W, theme.SCREEN_H)
            -- Only rebuild focus chain if this is the active (top) screen,
            -- otherwise a background screen's timer could corrupt focus
            if screen.peek() == self then
                focus.rebuild(self._tree)
            end
        end
    end

    return inst
end

-- ---------------------------------------------------------------------------
-- Stack operations
-- ---------------------------------------------------------------------------

function screen.push(inst)
    if not inst then
        ez.log("[Screen] Error: push nil")
        return
    end

    -- Pause current screen
    local current = screen.peek()
    if current and current.on_leave then
        current:on_leave()
    end

    table.insert(screen.stack, inst)

    -- Reset focus for new screen
    focus.chain = {}
    focus.index = 0
    focus.editing = false

    if inst.on_enter then inst:on_enter() end
    inst:_rebuild()
    screen.dirty = true
end

function screen.pop()
    if #screen.stack <= 1 then return end  -- Never pop the last (root) screen
    local inst = table.remove(screen.stack)
    if inst.on_exit then inst:on_exit() end

    -- Clear references to help GC
    inst._tree = nil
    inst = nil
    run_gc("collect", "screen-pop")

    -- Restore previous screen
    local current = screen.peek()
    if current then
        focus.chain = {}
        focus.index = 0
        focus.editing = false
        if current.on_enter then current:on_enter() end
        current:_rebuild()
    end

    screen.dirty = true
end

function screen.replace(inst)
    if #screen.stack > 0 then
        local old = table.remove(screen.stack)
        if old.on_exit then old:on_exit() end
        old._tree = nil
        old = nil
        run_gc("collect", "screen-replace")
    end
    screen.push(inst)
end

function screen.peek()
    if #screen.stack == 0 then return nil end
    return screen.stack[#screen.stack]
end

function screen.depth()
    return #screen.stack
end

function screen.invalidate()
    screen.dirty = true
end

-- ---------------------------------------------------------------------------
-- Input handling
-- ---------------------------------------------------------------------------

-- Cooldown for key-initiated pops. The T-Deck keyboard does not emit
-- release events for character keys, and its internal matrix scan re-sends
-- a held keycode every ~60ms. Without this guard a single tap of 'q' pops
-- several screens in quick succession (viewer → file manager → menu → ...).
screen.last_pop_time = 0
screen.pop_cooldown_ms = 500

function screen.handle_input()
    local key = ez.keyboard.read()
    if not key or not key.valid then return false end

    local inst = screen.peek()
    if not inst then return false end

    local result = focus.handle_key(key, inst)

    if result == "pop" then
        local now = ez.system.millis()
        if now - screen.last_pop_time < screen.pop_cooldown_ms then
            -- Swallow: looks like a keyboard-repeat event for the same press
            return true
        end
        screen.last_pop_time = now
        screen.pop()
    elseif result == "exit" then
        while #screen.stack > 0 do screen.pop() end
    elseif result == "handled" then
        screen.dirty = true
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

function screen.render()
    if not screen.dirty then return end

    local now = ez.system.millis()
    if now - screen.last_render < screen.frame_interval then return end

    local d = ez.display
    local inst = screen.peek()
    if not inst then
        d.fill_rect(0, 0, theme.SCREEN_W, theme.SCREEN_H, theme.color("BG"))
        d.flush()
        screen.dirty = false
        return
    end

    -- Ensure no stale clip rect from previous frame
    d.clear_clip_rect()

    -- Clear background
    d.fill_rect(0, 0, theme.SCREEN_W, theme.SCREEN_H, theme.color("BG"))

    -- Draw the node tree
    if inst._tree then
        node.draw(inst._tree, d, 0, 0, theme.SCREEN_W, theme.SCREEN_H)
    end

    d.flush()
    screen.dirty = false
    screen.last_render = now
end

-- ---------------------------------------------------------------------------
-- Main loop step (called every frame)
-- ---------------------------------------------------------------------------

function screen.update()
    -- Drain all pending input
    while screen.handle_input() do end

    -- Call screen's update method if it exists (for polling/animations)
    local inst = screen.peek()
    if inst and inst.update then
        inst:update()
    end

    screen.render()
end

return screen
