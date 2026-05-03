-- ezui.screen: Screen stack manager with declarative build lifecycle
-- Screens define a build(state) method that returns a node tree.
-- State changes via set_state() trigger rebuild and redraw.

local node = require("ezui.node")
local focus = require("ezui.focus")
local theme = require("ezui.theme")
local async = require("ezui.async")

local screen = {}

-- Screen stack
screen.stack = {}
screen.dirty = true
screen.last_render = 0
screen.frame_interval = 33  -- ~30 FPS

-- Global status bar state, refreshed by update_status() from sensor APIs.
-- Populated into a reusable node each frame before drawing.
screen.status = {
    battery     = nil,
    time        = nil,
    radio_ok    = nil,
    signal_bars = 0,
    node_id     = nil,
    wifi_bars   = nil,
    gps_bars    = nil,
    title       = nil,
}

screen.status_interval = 5000  -- poll hardware every 5s
screen.status_last = -10000    -- negative so the first update() runs the poll immediately

-- Node reused every frame to render the global status bar. Keeping one
-- instance avoids a garbage-generating allocation per frame.
local _status_node = { type = "status_bar" }

-- Persistent fields per node type — copied from the previous tree onto
-- the freshly-built one each rebuild so scroll positions, dropdown-open
-- flags, cursors, etc. survive a set_state(). Without this, any screen
-- that calls set_state periodically (GPS live status, etc.) would reset
-- scroll to 0 and collapse open dropdowns on every tick.
local _PERSISTENT_FIELDS = {
    scroll     = { "scroll_offset" },
    dropdown   = { "_open", "_cursor", "_scroll" },
    text_input = { "_cursor" },
}

local function _persist_state(old, new)
    if not old or not new then return end
    if old.type == new.type then
        local fields = _PERSISTENT_FIELDS[old.type]
        if fields then
            for _, k in ipairs(fields) do
                if old[k] ~= nil then new[k] = old[k] end
            end
        end
    end
    if old.children and new.children then
        local n = math.min(#old.children, #new.children)
        for i = 1, n do
            _persist_state(old.children[i], new.children[i])
        end
    end
end

-- Wake the renderer whenever async activity begins or ends so the spinner
-- appears/disappears promptly (the status-bar widget keeps itself animating
-- while busy).
async.on_busy_change(function() screen.dirty = true end)

-- ---------------------------------------------------------------------------
-- Toast: brief overlay shown when a new notification is posted.
--
-- Rendered just below the global status bar, dismissed automatically
-- after a few seconds (longer for sticky notifications) or sooner on
-- the next user keypress. We only ever show one at a time -- a fresh
-- post replaces the active toast, which matches how short-lived OS
-- notifications behave on phones.
-- ---------------------------------------------------------------------------

screen.toast = nil  -- { title, body, expires_at_ms, source, action }

local TOAST_DURATION_MS         = 4000
local TOAST_STICKY_DURATION_MS  = 8000
local TOAST_HEIGHT_DEFAULT      = 36

function screen.show_toast(notif)
    if not notif or not notif.title then return end
    local now = ez.system.millis()
    local dur = notif.sticky and TOAST_STICKY_DURATION_MS or TOAST_DURATION_MS
    screen.toast = {
        title         = notif.title,
        body          = notif.body,
        source        = notif.source,
        action        = notif.action,
        expires_at_ms = now + dur,
    }
    screen.dirty = true
end

function screen.dismiss_toast()
    if screen.toast then
        screen.toast = nil
        screen.dirty = true
    end
end

-- Subscribe to the notifications service via the bus. Lazy because
-- ez.bus may not be ready at module-load time; the first update() call
-- (after boot) is a safe place to wire it up.
local _toast_subscribed = false
local function ensure_toast_subscribed()
    if _toast_subscribed then return end
    if not (ez and ez.bus and ez.bus.subscribe) then return end
    ez.bus.subscribe("notifications/changed", function(_topic, _data)
        local ok, svc = pcall(require, "services.notifications")
        if not ok then return end
        local list = svc.list()
        if list and list[1] then
            screen.show_toast(list[1])
        end
    end)
    _toast_subscribed = true
end

function screen._draw_toast(d)
    local t = screen.toast
    if not t then return end
    local now = ez.system.millis()
    if now >= t.expires_at_ms then
        screen.toast = nil
        return
    end

    -- Geometry: full width, just below status bar. Body wraps to a
    -- second line if there's room.
    theme.set_font("small_aa")
    local fh = theme.font_height()
    local pad = 4
    local has_body = t.body and t.body ~= ""
    local h = has_body and (fh * 2 + pad * 3) or (fh + pad * 2)
    if h < TOAST_HEIGHT_DEFAULT then h = TOAST_HEIGHT_DEFAULT end
    local y = theme.STATUS_H + 2
    local w = theme.SCREEN_W - 8
    local x = 4

    d.fill_round_rect(x, y, w, h, 6, theme.color("SURFACE"))
    d.draw_round_rect(x, y, w, h, 6, theme.color("ACCENT"))

    local tx = x + 8
    local ty = y + pad
    d.draw_text(tx, ty, t.title, theme.color("TEXT"))
    if has_body then
        d.draw_text(tx, ty + fh + 2, t.body, theme.color("TEXT_MUTED"))
    end

    -- Action hint on the right edge so the user knows the toast is
    -- not just informational. Drawn only when an action is attached.
    -- The "ALT+ENTER" prefix matches the key gate in handle_input --
    -- bare ENTER would dismiss the toast without invoking the action.
    if t.action and t.action.label then
        local hint = "ALT+ENTER " .. t.action.label
        local hw = theme.text_width(hint)
        d.draw_text(x + w - hw - 8, y + h - fh - pad, hint,
            theme.color("ACCENT"))
    end

    -- Keep redrawing until the toast expires so it disappears on time
    -- without needing other activity to trigger a frame.
    screen.dirty = true
end

-- ---------------------------------------------------------------------------
-- Status polling
-- ---------------------------------------------------------------------------

-- Returns the usable screen area (minus global status bar) for the given
-- screen instance. Screens can opt out via a truthy `fullscreen` field.
function screen.content_area(inst)
    local top = theme.STATUS_H
    if inst and inst._def and inst._def.fullscreen then top = 0 end
    return 0, top, theme.SCREEN_W, theme.SCREEN_H - top
end

function screen.update_status()
    local now = ez.system.millis()
    if now - screen.status_last < screen.status_interval then return end
    screen.status_last = now

    local s = screen.status
    local changed = false

    local bat = ez.system.get_battery_percent and ez.system.get_battery_percent() or nil
    if bat ~= s.battery then s.battery = bat; changed = true end

    local tstr = nil
    if ez.system.get_time then
        local t = ez.system.get_time()
        if t and t.hour then
            -- Re-read the format pref each tick rather than caching it:
            -- the Time settings screen writes it on toggle and we want
            -- the bar to flip immediately without a reboot. Lookup is a
            -- single NVS read, cheap enough at 1 Hz.
            local fmt = ez.storage.get_pref("time_format", "24h")
            if fmt == "12h" then
                local h = t.hour % 12
                if h == 0 then h = 12 end
                local ampm = t.hour < 12 and "a" or "p"
                tstr = string.format("%d:%02d%s", h, t.min or t.minute or 0, ampm)
            else
                tstr = string.format("%02d:%02d", t.hour, t.min or t.minute or 0)
            end
        end
    end
    if tstr ~= s.time then s.time = tstr; changed = true end

    local radio_ok = ez.mesh and ez.mesh.is_initialized and ez.mesh.is_initialized() or false
    if radio_ok ~= s.radio_ok then s.radio_ok = radio_ok; changed = true end

    local nid = (radio_ok and ez.mesh.get_short_id) and ez.mesh.get_short_id() or nil
    if nid ~= s.node_id then s.node_id = nid; changed = true end

    -- WiFi: show bars only while connected. Map RSSI (dBm) to 0..3:
    --   better than -60 → 3, better than -70 → 2, connected → 1, else nothing.
    local wifi_bars = nil
    if ez.wifi and ez.wifi.is_connected and ez.wifi.is_connected() then
        local rssi = ez.wifi.get_rssi and ez.wifi.get_rssi() or 0
        if     rssi > -60 then wifi_bars = 3
        elseif rssi > -70 then wifi_bars = 2
        else                   wifi_bars = 1
        end
    end
    if wifi_bars ~= s.wifi_bars then s.wifi_bars = wifi_bars; changed = true end

    -- GPS: only show when the user has the service enabled. Use satellite
    -- count to gauge quality (>=8 → 3, >=5 → 2, fix → 1, searching → 0).
    local gps_bars = nil
    local gps_ok, gps_svc = pcall(require, "services.gps")
    if gps_ok and gps_svc.is_enabled() then
        local sats = ez.gps and ez.gps.get_satellites and ez.gps.get_satellites() or nil
        local loc = ez.gps and ez.gps.get_location and ez.gps.get_location() or nil
        local n_sats = (type(sats) == "table" and sats.count) or (type(sats) == "number" and sats) or 0
        if     n_sats >= 8 then gps_bars = 3
        elseif n_sats >= 5 then gps_bars = 2
        elseif loc and loc.valid then gps_bars = 1
        else                    gps_bars = 0
        end
    end
    if gps_bars ~= s.gps_bars then s.gps_bars = gps_bars; changed = true end

    if changed then screen.dirty = true end
end

-- Draw the global status bar. Called by render() before flushing.
-- ``transparent`` lets the active screen request a dithered background so
-- the wallpaper underneath shows through (desktop only, currently).
function screen._draw_status_bar(d, title, transparent)
    local s = screen.status
    for k, v in pairs(s) do _status_node[k] = v end
    _status_node.title = title
    _status_node.transparent = transparent and true or nil
    node.draw(_status_node, d, 0, 0, theme.SCREEN_W, theme.STATUS_H)
end

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

    -- State setter: stores partial into state and (normally) rebuilds the
    -- tree immediately. While focus.editing is true — e.g. a dropdown is
    -- open or a text input has captured input — rebuilding would discard
    -- the widget's internal state (open flag, cursor). In that case we
    -- accumulate the new state and defer the rebuild until the widget
    -- releases input, which screen.handle_input picks up below.
    function inst:set_state(partial)
        for k, v in pairs(partial) do
            self._state[k] = v
        end
        if focus.editing then
            self._state_dirty = true
            screen.invalidate()
            return
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
        local old_tree = self._tree
        if self._def.build then
            self._tree = self._def.build(self, self._state)
        end
        if self._tree then
            -- Carry over widget-internal state (scroll offset, dropdown
            -- open flag, input cursor) so a rebuild doesn't visually
            -- snap the user back to the top of a page they'd scrolled.
            if old_tree then
                _persist_state(old_tree, self._tree)
            end
            -- Screens share the display with a global status bar at top;
            -- measure against the content area height so scrollables etc.
            -- size correctly.
            local _, _, aw, ah = screen.content_area(self)
            node.measure(self._tree, aw, ah)
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

-- Play a transition sound without hard-requiring ui_sounds. pcall so the
-- screen stack keeps working even if the service module failed to load.
local function play_transition(event)
    local ok, ui_sounds = pcall(require, "services.ui_sounds")
    if ok then ui_sounds.play(event) end
end

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
    play_transition("transition_up")
end

function screen.pop()
    if #screen.stack <= 1 then return end  -- Never pop the last (root) screen
    local inst = table.remove(screen.stack)
    if inst.on_exit then inst:on_exit() end
    play_transition("transition_down")

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

    -- Toast key handling: Alt+ENTER on a toast with an attached
    -- action invokes it (and consumes the key so the underlying
    -- screen doesn't also receive an Alt+ENTER chord). Bare ENTER --
    -- and any other key -- just dismisses passively, letting the
    -- press flow through. The Alt gate prevents an accidental ENTER
    -- (e.g. confirming a dialog under the toast) from triggering a
    -- destructive action like a reboot.
    if screen.toast then
        local t = screen.toast
        if t.action and type(t.action.on_press) == "function"
               and key.special == "ENTER" and key.alt then
            local fn = t.action.on_press
            screen.dismiss_toast()
            local ok, err = pcall(fn)
            if not ok then
                ez.log("[Toast] action error: " .. tostring(err))
            end
            return true  -- consumed
        end
        screen.dismiss_toast()
    end

    local inst = screen.peek()
    if not inst then return false end

    local result = focus.handle_key(key, inst)

    -- Global menu key: Alt+M. Runs AFTER focus / screen handle_key so
    -- screens that need Alt+M for their own purposes (the script
    -- editor's mode cycler) get first dibs — the global menu only
    -- opens when nothing else claimed the chord and the active screen
    -- exposes a `menu(self)` method.
    if result == nil and key.alt and not key.shift and key.character
            and (key.character == "m" or key.character == "M") then
        if inst._def and type(inst._def.menu) == "function" then
            local items = inst._def.menu(inst)
            if items and #items > 0 then
                local MenuDialog = require("screens.dialog.menu")
                screen.push(screen.create(MenuDialog,
                    MenuDialog.initial_state(items, inst.title)))
                result = "handled"
            end
        end
    end

    -- If a widget just released input (e.g. dropdown confirmed/cancelled)
    -- and set_state calls were buffered while editing, rebuild now so the
    -- tree reflects the stored state.
    if not focus.editing and inst._state_dirty then
        inst._state_dirty = false
        inst:_rebuild()
        screen.dirty = true
    end

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

    -- Clear the dirty flag BEFORE drawing so that animated nodes (e.g.
    -- the pulsing desktop icon) can call screen.invalidate() inside
    -- their draw handler to request the next frame without being
    -- immediately overwritten when this function returns.
    screen.dirty = false
    screen.last_render = now

    local d = ez.display
    local inst = screen.peek()
    if not inst then
        d.fill_rect(0, 0, theme.SCREEN_W, theme.SCREEN_H, theme.color("BG"))
        d.flush()
        return
    end

    -- Ensure no stale clip rect from previous frame
    d.clear_clip_rect()

    -- Clear background
    d.fill_rect(0, 0, theme.SCREEN_W, theme.SCREEN_H, theme.color("BG"))

    -- Draw the node tree into the content area below the global status bar
    local ax, ay, aw, ah = screen.content_area(inst)
    if inst._tree then
        node.draw(inst._tree, d, ax, ay, aw, ah)
    end

    -- Draw the global status bar on top (unless the screen opted out)
    if not (inst._def and inst._def.fullscreen) then
        local translucent = inst._def and inst._def.transparent_status
        screen._draw_status_bar(d, inst.title, translucent)
    end

    -- Toast on top of everything else so it's visible from any screen.
    screen._draw_toast(d)

    d.flush()
end

-- ---------------------------------------------------------------------------
-- Main loop step (called every frame)
-- ---------------------------------------------------------------------------

function screen.update()
    -- Wire up the notifications -> toast subscription on the first
    -- frame, when ez.bus is guaranteed to be live.
    ensure_toast_subscribed()

    -- Drain all pending input
    while screen.handle_input() do end

    -- Refresh global status bar state (throttled internally)
    screen.update_status()

    -- Call screen's update method if it exists (for polling/animations)
    local inst = screen.peek()
    if inst and inst.update then
        inst:update()
    end

    screen.render()
end

return screen
