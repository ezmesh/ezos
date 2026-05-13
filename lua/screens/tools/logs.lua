-- System log viewer.
--
-- Reads the persistent log files maintained by services.log_persist
-- (/fs/logs/system.log + system.log.old) and renders the tail in a
-- scrollable viewport. Polls every POLL_MS so live activity appears
-- without the user having to leave and re-enter the screen.
--
-- Keys:
--   trackball UP/DOWN     -- scroll one line
--   ALT+UP / ALT+DOWN     -- scroll one page (12 lines)
--   F                     -- follow mode toggle (auto-pin to bottom)
--   C                     -- clear both log files (asks for confirmation)
--   R                     -- force a flush + reread now
--   D                     -- clear an unread coredump (only when present)
--   BACKSPACE             -- back
--
-- Touch:
--   Drag vertically anywhere in the log area to scroll. Drag delta
--   is converted from pixels to lines using the rendered row
--   height; a single finger flick of one screen-height roughly
--   equals one full page.

local ui     = require("ezui")
local node   = require("ezui.node")
local theme  = require("ezui.theme")
local screen = require("ezui.screen")

local Logs = { title = "System Log" }

local POLL_MS    = 1000  -- live-tail cadence
local MAX_LINES  = 600   -- cap retained line count to keep render cheap;
                         -- older lines drop off the top of the viewport.

-- Pull the configured paths from the service so the on-screen
-- footer matches what the shell `logs` command shows.
local function persist()
    return require("services.log_persist")
end

local function load_lines()
    local svc = persist()
    if svc.flush then svc.flush() end
    local body = svc.read_tail(MAX_LINES) or ""
    local lines = {}
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

-- Same colour rules as the shell's logs command -- session markers
-- and crash-related lines stand out so users can scan for the
-- interesting bits.
local function color_for(line)
    if line:find("^==== boot") then
        return theme.color("ACCENT")
    end
    if line:find("[Ee]rror") or line:find("panic")
       or line:find("[Tt]ask_wdt") or line:find("brownout")
       or line:find("watchdog") then
        return theme.color("ERROR") or theme.color("DANGER")
            or theme.color("TEXT")
    end
    if line:find("^%[") then
        return theme.color("TEXT_MUTED")
    end
    return theme.color("TEXT")
end

-- Single custom node that handles the entire log surface: header
-- bar, scroll viewport, and a status footer. Easier than a vbox of
-- list_items because the line count changes constantly and node
-- rebuilds would dominate the per-tick cost.
if not node.handler("log_view") then
    node.register("log_view", {
        focusable = true,

        -- Defer trackball UP/DOWN to the host screen. focus.handle_key
        -- consumes those keys (it always returns "handled" once a
        -- focus chain exists, see lua/ezui/focus.lua:212), so the
        -- screen's handle_key never gets a shot. Returning "handled"
        -- from on_key short-circuits the focus-nav step and routes
        -- the chord to the screen via _screen:_scroll_by.
        on_key = function(n, key)
            local s = n._screen
            if not s then return nil end
            if key.special == "UP" or key.special == "DOWN" then
                local dir = (key.special == "UP") and -1 or 1
                local big = key.alt and 12 or 1
                s:_scroll_by(dir * big)
                return "handled"
            end
            return nil
        end,

        measure = function(n, max_w, max_h)
            return max_w, max_h
        end,
        draw = function(n, d, x, y, w, h)
            d.fill_rect(x, y, w, h, theme.color("BG"))
            -- Stash the rendered bounds + row height so the touch
            -- handler can hit-test and convert pixel drags into
            -- line-count scrolls. Updated every draw so a layout
            -- change (rotation, screen resize) always sees the
            -- latest geometry.
            n._x, n._y, n._w, n._h = x, y, w, h

            local lines  = n.lines  or {}
            local scroll = n.scroll or 0
            local follow = n.follow

            theme.set_font("small_aa")
            local lh = theme.font_height() + 1
            n._row_h = lh

            -- Header strip with line count + follow indicator. Mirror
            -- of the packet_sniffer header so the two diagnostic
            -- screens feel consistent.
            local hdr_h = lh + 6
            d.fill_rect(x, y, w, hdr_h, theme.color("SURFACE"))
            d.fill_rect(x, y + hdr_h - 1, w, 1, theme.color("BORDER"))
            local total = #lines
            local visible = math.floor((h - hdr_h) / lh)
            local hdr = string.format(
                "%d lines  %s%s",
                total,
                follow and "[follow]" or "",
                (total > visible) and string.format(
                    "  scroll %d/%d", scroll + 1,
                    math.max(1, total - visible + 1)) or "")
            d.draw_text(x + 6, y + 3, hdr, theme.color("TEXT"))

            -- Coredump banner. Drawn under the header strip so it
            -- can't be scrolled away -- a present coredump is a
            -- post-mortem signal we don't want the user to miss.
            if n.coredump_present then
                local banner_y = y + hdr_h
                d.fill_rect(x, banner_y, w, lh + 4,
                    theme.color("ERROR") or theme.color("DANGER")
                        or theme.color("ACCENT"))
                local msg = string.format(
                    "! coredump waiting (%d B) - press D to clear",
                    n.coredump_size or 0)
                d.draw_text(x + 6, banner_y + 2, msg,
                    theme.color("BG"))
                hdr_h = hdr_h + lh + 4
                visible = math.floor((h - hdr_h) / lh)
            end

            -- Lines.
            local row_y = y + hdr_h + 2
            for i = scroll + 1, math.min(total, scroll + visible) do
                local line = lines[i]
                if line and line ~= "" then
                    d.draw_text(x + 6, row_y, line, color_for(line))
                end
                row_y = row_y + lh
            end

            if total == 0 then
                local msg = "(no log lines yet)"
                local mw = theme.text_width(msg)
                d.draw_text(x + (w - mw) // 2,
                    y + h // 2 - lh // 2, msg,
                    theme.color("TEXT_MUTED"))
            end
        end,
    })
end

function Logs.initial_state()
    return {
        scroll  = 0,    -- 0-based index of the topmost visible line
        follow  = true, -- pin to the bottom when new lines arrive
    }
end

function Logs:on_enter()
    self._view = self._view or { type = "log_view" }
    -- The on_key handler on the node delegates back here; cache the
    -- screen reference on the node so it can call _scroll_by without
    -- chasing a global lookup.
    self._view._screen = self
    self:_refresh()
    local me = self
    self._timer = ez.system.set_interval(POLL_MS, function()
        me:_refresh()
    end)

    -- Touch drag: convert vertical finger motion within the log
    -- viewport into line-count scrolls. We bus-subscribe rather
    -- than using a `touchable` node attribute because we want
    -- continuous tracking (touch/move) not just tap/release. The
    -- pattern matches lua/screens/menu.lua's tab-bar drag handling.
    local drag = nil  -- {start_y, start_scroll}
    self._touch_subs = {}

    table.insert(self._touch_subs, ez.bus.subscribe("touch/down",
        function(_, d)
            if type(d) ~= "table" then return end
            local ti = require("ezui.touch_input")
            if ti.is_locked() or ti.is_wake_event() then return end
            local v = me._view
            if not v._x then return end  -- not laid out yet
            -- Reject touches that started in the title bar so back-
            -- button taps still register normally; everything below
            -- the title strip drives the scroll.
            if d.y < v._y then return end
            drag = {
                start_y      = d.y,
                start_scroll = me._state.scroll,
                row_h        = math.max(1, v._row_h or 12),
                touched      = false,
            }
        end))

    table.insert(self._touch_subs, ez.bus.subscribe("touch/move",
        function(_, d)
            if require("ezui.touch_input").is_locked() then return end
            if not drag or type(d) ~= "table" then return end
            local dy_px    = d.y - drag.start_y
            local dy_lines = -math.floor(dy_px / drag.row_h)
            local lines    = me._view.lines or {}
            local cap      = max_scroll(#lines)
            local new      = drag.start_scroll + dy_lines
            if new < 0 then new = 0 end
            if new > cap then new = cap end
            if new ~= me._state.scroll then
                me._state.scroll = new
                -- Any meaningful drag cancels follow mode -- the
                -- user is reading scrollback and would hate the
                -- viewport snapping back to the bottom every tick.
                me._state.follow = false
                me._view.scroll = new
                me._view.follow = false
                drag.touched = true
                screen.invalidate()
            end
        end))

    table.insert(self._touch_subs, ez.bus.subscribe("touch/up",
        function()
            -- Always clear: if the lock engaged mid-drag, swallowing
            -- this touch/up without resetting `drag` leaves stale
            -- start_y/row_h pinned, and the next touch/move after
            -- unlock would compute a huge spurious scroll against
            -- the old anchor. Clearing is unconditional and cheap.
            drag = nil
        end))
end

function Logs:on_exit()
    if self._timer then
        ez.system.cancel_timer(self._timer)
        self._timer = nil
    end
    if self._touch_subs then
        for _, id in ipairs(self._touch_subs) do
            ez.bus.unsubscribe(id)
        end
        self._touch_subs = nil
    end
end

-- Compute the maximum legal scroll given the current viewport. The
-- 240 pixels of usable height + small_aa's row height work out to
-- roughly 24 visible lines, but we don't have the rendered viewport
-- size here -- approximate and let the draw clamp on the actual
-- size each frame.
local function max_scroll(line_count)
    local approx_visible = 14  -- conservative; real visible count
                               -- recomputed in draw().
    return math.max(0, line_count - approx_visible)
end

function Logs:_refresh()
    local lines = load_lines()
    self._view.lines = lines
    -- Pin to bottom when in follow mode -- reading scrollback while
    -- new lines stream in is much friendlier when the latest line
    -- stays on screen instead of fighting the scroll position.
    if self._state.follow then
        self._state.scroll = max_scroll(#lines)
    end
    self._view.scroll = self._state.scroll
    self._view.follow = self._state.follow
    if ez.system.coredump_status then
        local cd = ez.system.coredump_status()
        self._view.coredump_present = cd.present
        self._view.coredump_size    = cd.size or 0
    end
    screen.invalidate()
end

function Logs:build(state)
    self._view.scroll = state.scroll
    self._view.follow = state.follow
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("System Log", { back = true }),
        self._view,
    })
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function Logs:_scroll_by(delta)
    local lines = self._view.lines or {}
    local cap = max_scroll(#lines)
    self._state.scroll = clamp(self._state.scroll + delta, 0, cap)
    -- Manual scroll cancels follow mode -- the user is reading
    -- history and doesn't want the viewport jumping back to the
    -- bottom every time a new line arrives.
    if delta < 0 or (delta > 0 and self._state.scroll < cap) then
        self._state.follow = false
    end
    self._view.scroll = self._state.scroll
    self._view.follow = self._state.follow
    screen.invalidate()
end

function Logs:_clear()
    local cur, old = persist().get_paths()
    ez.storage.remove(cur)
    ez.storage.remove(old)
    -- Prime a fresh session header so the file isn't empty when the
    -- next flush hits -- otherwise the screen would briefly look
    -- broken until a new log line arrives.
    ez.log("[log_persist] log cleared from viewer")
    if persist().flush then persist().flush() end
    self:_refresh()
end

function Logs:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end

    -- UP / DOWN are handled by the log_view's on_key (focus consumes
    -- them before they reach this handler). HOME / END come from the
    -- remote tool only -- the on-device keyboard doesn't have them.
    local s = key.special
    if s == "HOME" then
        self._state.scroll = 0
        self._state.follow = false
        self:_refresh()
        return "handled"
    end
    if s == "END" then
        self._state.follow = true
        self:_refresh()
        return "handled"
    end

    local c = key.character
    if c == "f" or c == "F" then
        self._state.follow = not self._state.follow
        self:_refresh()
        return "handled"
    end
    if c == "r" or c == "R" then
        self:_refresh()
        return "handled"
    end
    if c == "c" or c == "C" then
        local dialog = require("ezui.dialog")
        local me = self
        dialog.confirm({
            title    = "Clear log?",
            message  = "This deletes /fs/logs/system.log and " ..
                "system.log.old. Cannot be undone.",
            ok_label = "Clear",
        }, function() me:_clear() end)
        return "handled"
    end
    if (c == "d" or c == "D") and self._view.coredump_present then
        local dialog = require("ezui.dialog")
        local me = self
        dialog.confirm({
            title    = "Clear coredump?",
            message  = "Erase the panic dump from flash. Run " ..
                "tools/read_coredump.sh from the host first if " ..
                "you want to keep it.",
            ok_label = "Erase",
        }, function()
            if ez.system.clear_coredump then
                ez.system.clear_coredump()
            end
            me:_refresh()
        end)
        return "handled"
    end
    return nil
end

return Logs
