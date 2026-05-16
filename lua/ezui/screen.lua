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
    charging    = false,
    time        = nil,
    radio_ok    = nil,
    signal_bars = 0,
    node_id     = nil,
    wifi_bars   = nil,
    gps_bars    = nil,
    power_tag   = nil,   -- "lp" (frugal) / "LP" (survival) / nil
    title       = nil,
}

screen.status_interval = 5000  -- poll hardware every 5s
screen.status_last = -10000    -- negative so the first update() runs the poll immediately

-- Screensaver: overlay drawn on top of the current screen after idle
-- timeout to exercise subpixels. Dismissed on any keypress. Seeded
-- to the boot timestamp (rather than 0) so the activation gate fires
-- even if the device sits idle from boot without a keypress -- which
-- is exactly the scenario the screensaver is designed for.
screen.last_input_time = ez.system.millis()  -- millis() of last keypress (or boot)

-- Idle ladder: dim -> screensaver -> panel-off. Driven from screen.update()
-- by comparing now - last_input_time against ss_timeout and disp_off_delay.
-- Stage 0 = active, 1 = dim, 2 = screensaver (existing behaviour), 3 = panel
-- off (backlight 0, render loop suspended). Wakelocks held in `_wakelocks`
-- keep the ladder pinned to stage 0; an empty table means "no inhibitors".
screen.idle_stage = 0
screen._normal_brightness = nil  -- cached on first dim, restored on wake
screen._wakelocks = {}

-- Pre-dim lead time: ramp to dim brightness this many ms BEFORE the
-- screensaver fires. The issue spec calls this out as 30 s; tunable
-- via ss_predim pref (seconds, 0 disables the dim stage).
screen.predim_lead_default = 30

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
        local top = list and list[1]
        -- DND-silenced notifications still land in the list (so the
        -- unread count updates) but don't render a toast and don't
        -- wake the panel. The user catches up next time they look at
        -- the device.
        if top and not top.silent then
            screen.show_toast(top)
        end
        -- An incoming notification is a "high-priority" wake signal:
        -- if the panel is off or dim the user should see the toast
        -- without having to touch the device. notify_input() handles
        -- restoring brightness + clearing the idle stage. Gate on
        -- idle_stage so dismiss()/dismiss_source()/mark_all_read()
        -- (which fire the same bus event) don't wake the panel from
        -- background subscribers -- e.g. the OTA flow calling
        -- dismiss_source("ota") after an update would otherwise pull
        -- the device out of stage 3 every time. Also skip the wake on
        -- silent (DND) notifications -- the whole point is "don't
        -- light the panel".
        if screen.idle_stage ~= 0 and not (top and top.silent) then
            screen.notify_input()
        end
    end)
    _toast_subscribed = true
end

-- Wire bus events that should hold a wakelock for the duration of an
-- activity. Lazy for the same reason as the toast subscriber: ez.bus
-- must be live. The tags are namespaced so multiple subsystems can
-- coexist without one releasing another's lock.
local _wakelock_subscribed = false
local function ensure_wakelock_subscribed()
    if _wakelock_subscribed then return end
    if not (ez and ez.bus and ez.bus.subscribe) then return end

    -- File transfer in progress: hold a wakelock from the first
    -- progress event (which fires on connect/transferring) until
    -- file/done or file/error.
    ez.bus.subscribe("file/progress", function(_t, _d)
        screen.acquire_wakelock("file_transfer")
    end)
    ez.bus.subscribe("file/done", function(_t, _d)
        screen.release_wakelock("file_transfer")
    end)
    ez.bus.subscribe("file/error", function(_t, _d)
        screen.release_wakelock("file_transfer")
    end)

    _wakelock_subscribed = true
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

-- Lock-mode overlay: a banner pinned to the bottom of the screen
-- whenever services.input_lock reports locked. Drawn last so it sits
-- above screensaver, toast, and any modal -- it has to stay visible
-- even when the input chain is rejecting everything. The hint says
-- exactly what unlocks the device so the user isn't left wondering
-- why nothing responds.
function screen._draw_lock_overlay(d)
    local ok, lock_svc = pcall(require, "services.input_lock")
    if not ok or not lock_svc.is_locked() then return end

    theme.set_font("small_aa")
    local fh = theme.font_height()
    local pad = 4
    local h = fh + pad * 2
    local y = theme.SCREEN_H - h
    local w = theme.SCREEN_W

    -- Black bar with white text, regardless of theme/accent. The lock
    -- is a system-level state, not user-themed content, and a fixed
    -- high-contrast pair stays readable when the user has picked a
    -- light accent (green, yellow) that would otherwise wash out the
    -- label. Lock icon glyphs aren't in the ASCII font (see CLAUDE.md
    -- "On-device font character set"), so the prefix is plain text.
    d.fill_rect(0, y, w, h, 0x0000)         -- black
    d.fill_rect(0, y, w, 1, theme.color("ACCENT"))  -- thin accent top edge

    local label = "Locked -- Shift+Alt+U to unlock"
    local lw = theme.text_width(label)
    local lx = math.floor((w - lw) / 2)
    d.draw_text(lx, y + pad, label, 0xFFFF)  -- white
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

    local chg = ez.system.is_charging and ez.system.is_charging() or false
    if chg ~= s.charging then s.charging = chg; changed = true end

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

    -- Power tier indicator. Empty string from short_indicator() is
    -- normalised to nil so the bar renderer can skip the slot.
    local power_tag = nil
    local pwr_ok, power_svc = pcall(require, "services.power")
    if pwr_ok and power_svc.short_indicator then
        local t = power_svc.short_indicator()
        if t and t ~= "" then power_tag = t end
    end
    if power_tag ~= s.power_tag then s.power_tag = power_tag; changed = true end

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

    -- State setter: stores partial into state and rebuilds the tree
    -- immediately. Widget-internal state (scroll offset, cursor, dropdown
    -- open flag) is carried over by _persist_state, so rebuilding while
    -- editing is safe.
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

-- Wakelock API: any non-nil tag in screen._wakelocks pins the idle
-- ladder at stage 0. Use this for foreground actions that need the
-- display alive (file transfers in progress, audio recording, etc.).
-- Releasing the same tag clears it; the next idle tick re-evaluates.
function screen.acquire_wakelock(tag)
    if not tag then return end
    screen._wakelocks[tag] = true
    if screen.idle_stage ~= 0 then
        -- Pretend the user just touched the device so the ladder
        -- unwinds via the same path as a real wake.
        screen.notify_input()
    end
end

function screen.release_wakelock(tag)
    if not tag then return end
    -- Releasing a tag that was never acquired must be a no-op: file
    -- transfer's early-fail paths (key-derivation failure, AP-start
    -- failure, OFFER undelivered) post `file/error` before any
    -- `file/progress`, so the subscriber on file/error would otherwise
    -- silently reset the user's idle countdown on every such failure.
    if screen._wakelocks[tag] == nil then return end
    screen._wakelocks[tag] = nil
    -- Restart the idle countdown from the release moment. Without
    -- this, last_input_time stays frozen at whenever the user last
    -- touched the device before acquiring the wakelock; a long-held
    -- wakelock (e.g. a multi-minute file transfer) would then make
    -- the next update() tick see an idle_s already past
    -- ss_timeout + disp_off_delay*60 and jump straight to stage 3
    -- with no dim or screensaver in between.
    screen.last_input_time = ez.system.millis()
end

local _prev_recording = false
local function _wakelocks_held()
    for _ in pairs(screen._wakelocks) do return true end
    -- Implicit wakelock: audio recording in progress. The voice-notes
    -- and signal-test screens flip ez.audio.is_recording() and may
    -- run unattended; blanking the panel mid-capture is confusing
    -- (and stops the user from seeing the "Recording... N s" timer).
    local recording = ez.audio and ez.audio.is_recording and ez.audio.is_recording() or false
    -- Falling edge: capture just ended. Restart the idle countdown so
    -- the next update() tick doesn't see an idle_s already past
    -- ss_timeout + disp_off_delay*60 and jump straight to panel-off.
    -- Mirrors the explicit release_wakelock() behaviour.
    if _prev_recording and not recording then
        screen.last_input_time = ez.system.millis()
    end
    _prev_recording = recording
    return recording
end

-- Restore the LCD backlight to the user's stored brightness, or to
-- the value cached when we first started dimming. Either way, idempotent.
local function _restore_brightness()
    if screen._normal_brightness then
        ez.display.set_brightness(screen._normal_brightness)
        screen._normal_brightness = nil
    else
        local b = tonumber(ez.storage.get_pref("screen_bright", 200)) or 200
        ez.display.set_brightness(b)
    end
end

-- Reset the idle timer and, if the screensaver is currently up,
-- dismiss it. Returns true when the screensaver was just dismissed
-- so the caller can swallow the originating event (key or touch) --
-- a tap that wakes the device should not also activate whatever sat
-- under the overlay. Called from the keyboard path here and from
-- ezui/touch_input.lua's on_down/move/up.
function screen.notify_input()
    screen.last_input_time = ez.system.millis()
    -- Any non-zero stage clamped the LCD backlight (stage 1 dim,
    -- stage 2 screensaver-active, stage 3 panel off), so restoring
    -- on wake has to cover all three. Excluding stage 2 here would
    -- leave the LCD pinned at ss_bright after the key press that
    -- dismisses the screensaver, since ss.stop() only restores the
    -- keyboard backlight.
    local was_dim_or_off = (screen.idle_stage ~= 0)
    if was_dim_or_off then
        _restore_brightness()
        screen.dirty = true
    end
    screen.idle_stage = 0
    local ss_ok, ss = pcall(require, "screens.tools.screensaver")
    if ss_ok and ss.is_active() then
        ss.stop()
        screen.dirty = true
        return true
    end
    -- Treat a wake from dim or panel-off as a "swallow this input"
    -- event too: a tap to wake shouldn't also click whatever sat
    -- under the finger.
    return was_dim_or_off
end

function screen.handle_input()
    local key = ez.keyboard.read()
    if not key or not key.valid then return false end

    -- Global input lock. Shift+Alt+L locks, Shift+Alt+U unlocks. Both
    -- chords are recognised before notify_input / screensaver so a
    -- locked device can still be unlocked even when the screensaver
    -- is up; the unlock chord wakes the screen *and* clears the lock
    -- in one keypress. While locked, every other key is swallowed
    -- here -- handle_input returns true so update() keeps draining
    -- the input queue but no screen sees the press.
    -- Recognise the chord on either case: the on-device matrix path
    -- uppercases letters when shift is held (keyboard.cpp:704), while
    -- the remote-control injection path passes the raw char through
    -- verbatim plus the shift flag, so accept both 'L'/'l' and 'U'/'u'.
    local input_lock = require("services.input_lock")
    if key.alt and key.shift and key.character then
        local ch = key.character
        if ch == "L" or ch == "l" then
            input_lock.set(true)
            screen.notify_input()
            screen.dirty = true
            return true
        elseif ch == "U" or ch == "u" then
            input_lock.set(false)
            screen.notify_input()
            screen.dirty = true
            return true
        end
    end
    if input_lock.is_locked() then
        return true  -- swallow; only the unlock chord above gets through
    end

    -- Reset idle timer + dismiss-and-consume any active screensaver.
    if screen.notify_input() then
        return true  -- consume the key that woke the screen
    end

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
            -- Don't fire the toast action while the device is locked.
            -- Some actions (DM open, OTA restart) would otherwise let
            -- a notification bypass the lockscreen invariant that
            -- only the input path is gated.
            local lk_ok, lk = pcall(require, "services.lockscreen")
            if lk_ok and lk and lk.is_locked() then
                return true  -- consumed; swallow without firing
            end
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

    -- Global lock chord: Shift+Alt+K locks the device immediately when
    -- the lockscreen mode is set. Runs before focus.handle_key so a
    -- text field can't swallow the chord. No-op when the lockscreen
    -- is already on top. Uses Shift+Alt per CLAUDE.md's reservation
    -- of Alt+Shift combos for system-level global chords (the input
    -- lock toggle uses Shift+Alt+L / Shift+Alt+U, hence K here).
    if key.alt and key.shift and key.character
           and (key.character == "k" or key.character == "K") then
        local lk_ok, lk = pcall(require, "services.lockscreen")
        if lk_ok and lk and lk.is_armed() and not lk.is_locked() then
            lk.lock()
            return true
        end
    end

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

    -- Screensaver overlay (drawn on top of the screen content)
    local ss_ok, ss = pcall(require, "screens.tools.screensaver")
    if ss_ok and ss.is_active() then
        ss.draw(d)
        screen.dirty = true  -- keep animating
    end

    -- Toast on top of everything else so it's visible from any screen.
    screen._draw_toast(d)

    -- Mouse-mode cursor: rendered last so it floats above every
    -- screen. No-op when the mode is off.
    local ok_ti, touch_input = pcall(require, "ezui.touch_input")
    if ok_ti and touch_input.render_cursor then
        touch_input.render_cursor(d)
    end

    -- Input-lock banner sits above even the mouse cursor: while
    -- locked, the cursor can't be moved anyway, and the banner is
    -- the user's only affordance for getting out of the lock.
    screen._draw_lock_overlay(d)

    d.flush()
end

-- ---------------------------------------------------------------------------
-- Main loop step (called every frame)
-- ---------------------------------------------------------------------------

function screen.update()
    -- Wire up the notifications -> toast subscription on the first
    -- frame, when ez.bus is guaranteed to be live.
    ensure_toast_subscribed()
    ensure_wakelock_subscribed()

    -- Drain all pending input
    while screen.handle_input() do end

    -- Idle ladder: dim -> screensaver -> panel-off.
    --
    -- Stage transitions are evaluated against the screensaver timeout
    -- (the existing `ss_timeout` pref, seconds, 0 disables the whole
    -- ladder). Stage 1 ramps brightness down a configurable lead time
    -- before the screensaver kicks in; stage 2 is the existing
    -- screensaver overlay; stage 3 turns the backlight off entirely
    -- after `disp_off_delay` minutes past the screensaver fire.
    --
    -- A held wakelock pins the ladder at stage 0 regardless of
    -- timeout. Bus subscribers below wire file_transfer / audio
    -- recording into the wakelock table so foreground activity
    -- doesn't get blanked mid-transfer.
    local panel_off = false
    do
        local timeout = tonumber(ez.storage.get_pref("ss_timeout", 0)) or 0
        if timeout > 0 and screen.last_input_time > 0
                and not _wakelocks_held() then
            local idle_s = (ez.system.millis() - screen.last_input_time) / 1000
            local autodim = (ez.storage.get_pref("ss_autodim", "1") == "1")
            local predim_lead = autodim and screen.predim_lead_default or 0
            local off_delay_min = tonumber(
                ez.storage.get_pref("disp_off_delay", 5)) or 5
            local off_at_s = (off_delay_min > 0)
                and (timeout + off_delay_min * 60) or nil

            local ss_ok2, ss2 = pcall(require, "screens.tools.screensaver")

            -- Stage 3: panel off (latest, so check first).
            if off_at_s and idle_s >= off_at_s then
                if screen.idle_stage ~= 3 then
                    if not screen._normal_brightness then
                        screen._normal_brightness = tonumber(
                            ez.storage.get_pref("screen_bright", 200)) or 200
                    end
                    ez.display.set_brightness(0)
                    screen.idle_stage = 3
                end
                panel_off = true

            -- Stage 2: screensaver firing.
            elseif idle_s >= timeout then
                if ss_ok2 and not ss2.is_active() then
                    local ss_bright_pct = tonumber(
                        ez.storage.get_pref("ss_bright", 30)) or 30
                    if not screen._normal_brightness then
                        screen._normal_brightness = tonumber(
                            ez.storage.get_pref("screen_bright", 200)) or 200
                    end
                    local clamped = math.floor(
                        screen._normal_brightness * ss_bright_pct / 100)
                    if clamped < 30 then clamped = 30 end
                    ez.display.set_brightness(clamped)
                    ss2.start()
                    -- Session lockscreen (issue #119): arm the lock
                    -- as soon as the screensaver starts. The
                    -- lockscreen sits under the screensaver overlay
                    -- so the user wakes into the unlock prompt.
                    local lk_ok, lk = pcall(require, "services.lockscreen")
                    if lk_ok and lk then lk.maybe_lock("idle") end
                end
                screen.idle_stage = 2

            -- Stage 1: pre-dim before screensaver. Skip when the
            -- screensaver timeout is shorter than the lead -- the
            -- dim stage only makes sense as a chain ahead of the
            -- screensaver, never coincident with it or earlier.
            elseif predim_lead > 0 and timeout > predim_lead
                    and idle_s >= (timeout - predim_lead) then
                if screen.idle_stage ~= 1 then
                    if not screen._normal_brightness then
                        screen._normal_brightness = tonumber(
                            ez.storage.get_pref("screen_bright", 200)) or 200
                    end
                    local ss_bright_pct = tonumber(
                        ez.storage.get_pref("ss_bright", 30)) or 30
                    local dimmed = math.floor(
                        screen._normal_brightness * ss_bright_pct / 100)
                    if dimmed < 30 then dimmed = 30 end
                    ez.display.set_brightness(dimmed)
                    screen.idle_stage = 1
                end
            end
        end
    end

    -- Refresh global status bar state (throttled internally)
    screen.update_status()

    -- Call screen's update method if it exists (for polling/animations)
    local inst = screen.peek()
    if inst and inst.update then
        inst:update()
    end

    -- Stage 3: backlight is off, skip the render path entirely so the
    -- panel keeps the framebuffer it already had and the CPU stops
    -- driving SPI. The next notify_input() re-enables both.
    if not panel_off then
        screen.render()
    end
end

return screen
