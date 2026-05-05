-- Text / Lua editor.
--
-- Plain UTF-8 line editor with optional line numbers, soft scroll,
-- and Save / Open via the existing dialog.prompt path. Designed for
-- editing Lua scripts on /sd/scripts/ but happily edits any text
-- file. We deliberately keep the model dead simple:
--
--   * lines : array of strings (one per row, no trailing newline).
--   * row   : 1-based cursor row index into `lines`.
--   * col   : 1-based cursor column = byte offset within the line + 1.
--             Plain ASCII assumed; multi-byte UTF-8 characters survive
--             round-trip through file I/O but the cursor steps by
--             *bytes* mid-glyph, which is fine for code and acceptable
--             for casual text entry.
--   * scroll_row : the topmost visible row.
--
-- Keys:
--   ↑/↓/←/→    move cursor (with horizontal clamping at line ends)
--   ENTER       split line at cursor
--   BACKSPACE   delete left of cursor / merge with previous line
--   DEL         delete right of cursor / pull next line in
--   character   insert byte at cursor
--   Alt+S       save (prompts for path on first save)
--   Alt+O       open file (prompts for path)
--   Alt+N       new (clears, drops the current path)
--   Alt+Z       undo last edit (up to 100 steps; consecutive
--               character inserts coalesce into one step)
--   Back        close screen ONLY when there's nothing to delete and
--               the buffer is unmodified (otherwise the back key
--               doubles as the BACKSPACE delete-left)
--
-- The T-Deck has no Ctrl key (see CLAUDE.md "Keyboard layout"), so the
-- traditional Ctrl+S/O/N shortcuts are wired to Alt instead. Alt+letter
-- normally maps to a punctuation/number on this keyboard, so we accept
-- both the bare letter and the alt-mapped character (S/O/N) when alt is
-- held; whichever the layer emits, the screen reacts.
--
-- Pass `{ path = "/sd/foo.lua" }` as initial state to open a file.

local ui     = require("ezui")
local node   = require("ezui.node")
local theme  = require("ezui.theme")
local focus  = require("ezui.focus")
local dialog = require("ezui.dialog")

local Editor = { title = "Editor" }

-- ---------------------------------------------------------------------------
-- Editor view node
-- ---------------------------------------------------------------------------
--
-- A focusable node owning the buffer state. Drawing is straightforward
-- (one draw_text per visible line + a 2px-wide cursor caret); editing
-- is done from on_key. We track the buffer on the node itself so a
-- screen rebuild doesn't reset state.

local LINE_NUMBER_W = 28
local PAD_X         = 4
local PAD_Y         = 2

-- Undo history depth. Each snapshot stores a shallow copy of the
-- `lines` array (strings are immutable in Lua, so sharing the
-- string entries is safe and cheap) plus cursor + scroll position.
-- A 100-row buffer with 100 snapshots is ~80 KB of Lua table
-- overhead; well within budget on a buffer this size.
local UNDO_DEPTH    = 100

local function ensure_state(n)
    if not n._lines then
        n._lines = { "" }
        n._row, n._col = 1, 1
        n._scroll_row  = 0
        n._undo = {}
        n._undo_last_kind = nil
    end
end

-- Shallow copy of the lines list. Lua strings are immutable so the
-- entries are shared with the live buffer; only the wrapper table is
-- duplicated. O(num_lines) per snapshot rather than O(total_chars).
local function clone_lines(lines)
    local out = {}
    for i = 1, #lines do out[i] = lines[i] end
    return out
end

-- Push a snapshot before a modification. `kind` is a coarse label
-- ("insert" / "newline" / "delete" / "tab" / "paste") used to
-- coalesce consecutive same-kind actions into one undo step --
-- typing "hello" should rewind in one Undo, not five.
local function push_undo(n, kind)
    n._undo = n._undo or {}
    if kind == "insert" and n._undo_last_kind == "insert" then
        -- Already snapshotted at the start of this typing run; this
        -- character is part of the same step.
        return
    end
    n._undo[#n._undo + 1] = {
        lines      = clone_lines(n._lines),
        row        = n._row,
        col        = n._col,
        scroll_row = n._scroll_row,
    }
    while #n._undo > UNDO_DEPTH do
        table.remove(n._undo, 1)
    end
    n._undo_last_kind = kind
end

-- Restore the most recent snapshot. The line table is replaced
-- wholesale (cheap, since the entries are interned strings); cursor
-- + scroll snap back to where they were captured.
local function pop_undo(n)
    if not n._undo or #n._undo == 0 then return false end
    local snap = table.remove(n._undo)
    n._lines      = snap.lines
    n._row        = snap.row
    n._col        = snap.col
    n._scroll_row = snap.scroll_row or 0
    -- Clear the coalesce tag so the next typing run starts a fresh
    -- snapshot rather than merging into whatever we just popped.
    n._undo_last_kind = nil
    return true
end

if not node.handler("text_editor") then
    node.register("text_editor", {
        focusable = true,

        measure = function(n, max_w, max_h)
            return max_w, max_h
        end,

        draw = function(n, d, x, y, w, h)
            ensure_state(n)
            -- Stash the editor's screen rect so the touch handler
            -- attached at the screen level can map a finger tap back
            -- to (row, col). Recorded every frame because layout can
            -- shift when the title-bar text changes width.
            n._draw_x  = x
            n._draw_y  = y
            n._draw_w  = w
            n._draw_h  = h
            theme.set_font("small")
            local fh   = theme.font_height()
            n._draw_fh = fh
            local rows = math.floor((h - 2 * PAD_Y) / fh)
            if rows < 1 then rows = 1 end

            -- Background.
            d.fill_rect(x, y, w, h, theme.color("BG"))
            -- Vertical separator after the line-number column.
            d.fill_rect(x + LINE_NUMBER_W - 1, y, 1, h, theme.color("BORDER"))

            -- Auto-scroll: keep the cursor inside the visible window.
            -- This runs in draw rather than on_key so a programmatic
            -- jump (Open / large insert) also gets normalised before
            -- the next paint.
            if n._row - 1 < n._scroll_row then
                n._scroll_row = n._row - 1
            elseif n._row > n._scroll_row + rows then
                n._scroll_row = n._row - rows
            end
            if n._scroll_row < 0 then n._scroll_row = 0 end

            local cur_color = theme.color("ACCENT")
            local txt_color = theme.color("TEXT")
            local num_color = theme.color("TEXT_MUTED")
            local code_x    = x + LINE_NUMBER_W + PAD_X
            local code_w    = w - LINE_NUMBER_W - PAD_X * 2

            for i = 0, rows - 1 do
                local row = n._scroll_row + i + 1
                local line = n._lines[row]
                local ly = y + PAD_Y + i * fh
                if line then
                    d.draw_text(x + 4, ly,
                        string.format("%3d", row), num_color)
                    -- Truncate visually -- the underlying string keeps
                    -- everything; we just don't paint past the right
                    -- edge.
                    local visible = line
                    if theme.text_width(visible) > code_w then
                        local lo, hi = 1, #visible
                        while lo < hi do
                            local mid = (lo + hi + 1) // 2
                            if theme.text_width(visible:sub(1, mid)) > code_w then
                                hi = mid - 1
                            else
                                lo = mid
                            end
                        end
                        visible = visible:sub(1, lo)
                    end
                    d.draw_text(code_x, ly, visible, txt_color)
                end

                -- Cursor caret: a 2-pixel-wide vertical bar at the
                -- byte offset corresponding to cursor.col, on the
                -- cursor.row line. Drawn whenever the row is on
                -- screen even if the focused-screen highlight is
                -- elsewhere -- a code editor really needs the caret
                -- visible.
                if row == n._row then
                    local prefix = (n._lines[row] or ""):sub(1, n._col - 1)
                    local cx = code_x + theme.text_width(prefix)
                    d.fill_rect(cx, ly, 2, fh, cur_color)
                end
            end

            -- Help line at the bottom.
            local hint = "Alt+S save  Alt+O open  Alt+N new  Alt+Z undo  Back quit"
            theme.set_font("tiny_aa")
            d.draw_text(x + 4, y + h - theme.font_height() - 1,
                hint, num_color)
            theme.set_font("small")
        end,

        on_key = function(n, key)
            ensure_state(n)
            local s   = key.special
            local c   = key.character
            local lines = n._lines

            -- Cursor moves end the current "typing run" so the next
            -- character insert starts a fresh undo step instead of
            -- merging into the previous one. Otherwise typing
            -- "hello", arrowing left, and typing "world" would all
            -- live in the same undo entry.
            if s == "UP" or s == "DOWN" or s == "LEFT" or s == "RIGHT" then
                n._undo_last_kind = nil
            end
            -- Navigation -----------------------------------------------
            if s == "UP" then
                if n._row > 1 then
                    n._row = n._row - 1
                    n._col = math.min(n._col, #lines[n._row] + 1)
                end
                return "handled"
            elseif s == "DOWN" then
                if n._row < #lines then
                    n._row = n._row + 1
                    n._col = math.min(n._col, #lines[n._row] + 1)
                end
                return "handled"
            elseif s == "LEFT" then
                if n._col > 1 then
                    n._col = n._col - 1
                elseif n._row > 1 then
                    n._row = n._row - 1
                    n._col = #lines[n._row] + 1
                end
                return "handled"
            elseif s == "RIGHT" then
                if n._col <= #lines[n._row] then
                    n._col = n._col + 1
                elseif n._row < #lines then
                    n._row = n._row + 1
                    n._col = 1
                end
                return "handled"
            end

            -- Editing --------------------------------------------------
            if s == "ENTER" then
                push_undo(n, "newline")
                local cur  = lines[n._row]
                local left = cur:sub(1, n._col - 1)
                local right = cur:sub(n._col)
                lines[n._row] = left
                table.insert(lines, n._row + 1, right)
                n._row = n._row + 1
                n._col = 1
                n._dirty = true
                return "handled"
            elseif s == "BACKSPACE" then
                if n._col > 1 then
                    push_undo(n, "delete")
                    local cur = lines[n._row]
                    lines[n._row] = cur:sub(1, n._col - 2) .. cur:sub(n._col)
                    n._col = n._col - 1
                    n._dirty = true
                elseif n._row > 1 then
                    push_undo(n, "delete")
                    local prev = lines[n._row - 1]
                    n._col = #prev + 1
                    lines[n._row - 1] = prev .. lines[n._row]
                    table.remove(lines, n._row)
                    n._row = n._row - 1
                    n._dirty = true
                else
                    -- At buffer start with nothing left to delete --
                    -- the BACKSPACE key (the only "back" signal on
                    -- the T-Deck; there is no Esc) doubles as quit.
                    -- For a dirty buffer, push a confirm dialog so
                    -- the user can decide whether to discard their
                    -- edits; clean buffer pops straight out.
                    if n._dirty then
                        local dialog = require("ezui.dialog")
                        dialog.confirm({
                            title    = "Discard changes?",
                            message  = "Unsaved edits will be lost. " ..
                                       "Use Alt+S to save first if you want to keep them.",
                            ok_label = "Discard",
                            cancel_label = "Keep editing",
                        }, function()
                            n._dirty = false
                            require("ezui.screen").pop()
                        end)
                        return "handled"
                    end
                    return "pop"
                end
                return "handled"
            elseif s == "DELETE" then
                local cur = lines[n._row]
                if n._col <= #cur then
                    push_undo(n, "delete")
                    lines[n._row] = cur:sub(1, n._col - 1) .. cur:sub(n._col + 1)
                    n._dirty = true
                elseif n._row < #lines then
                    push_undo(n, "delete")
                    lines[n._row] = cur .. lines[n._row + 1]
                    table.remove(lines, n._row + 1)
                    n._dirty = true
                end
                return "handled"
            end

            -- Alt+S / Alt+O / Alt+N / Alt+Z: shortcut dispatch.
            -- The focus system swallows non-arrow keys when in
            -- editing mode (see focus.handle_key), so the screen's
            -- handle_key never sees these. We handle them inline
            -- by calling callbacks the screen attaches to the node,
            -- with the exception of undo which is purely node-local
            -- and doesn't need a screen-level hook.
            if key.alt and c then
                local lc = c:lower()
                if lc == "z" then
                    pop_undo(n)
                    return "handled"
                end
                if (lc == "s" or lc == "o" or lc == "n") and n._on_shortcut then
                    n._on_shortcut(lc)
                    return "handled"
                end
            end

            -- Plain character insert ----------------------------------
            -- Tab -> 4 spaces because the bitmap font has no real \t
            -- advance, and editing Lua at 4-space indents matches the
            -- rest of this codebase.
            if s == "TAB" then
                push_undo(n, "tab")
                local cur = lines[n._row]
                lines[n._row] = cur:sub(1, n._col - 1) .. "    " .. cur:sub(n._col)
                n._col = n._col + 4
                n._dirty = true
                return "handled"
            end

            if c and not key.alt then
                push_undo(n, "insert")
                local cur = lines[n._row]
                lines[n._row] = cur:sub(1, n._col - 1) .. c .. cur:sub(n._col)
                n._col = n._col + 1
                n._dirty = true
                return "handled"
            end

            return nil
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

function Editor.initial_state(opts)
    opts = opts or {}
    return {
        path     = opts.path or nil,
        boot_buf = opts.text or nil,
    }
end

function Editor:_status()
    local n = self._editor_node
    if not n then return "" end
    local mark = n._dirty and "*" or " "
    local p    = self._state.path or "(unsaved)"
    return string.format("%s %s  L%d C%d", mark, p, n._row or 1, n._col or 1)
end

function Editor:_load(path)
    local data = ez.storage.read_file(path)
    if not data then
        dialog.prompt({
            title   = "Open failed",
            message = "Couldn't read " .. path,
        }, function() end)
        return
    end
    -- Tolerate \r\n + \r line endings -- normalise to \n before
    -- splitting.
    data = data:gsub("\r\n", "\n"):gsub("\r", "\n")
    local lines = {}
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then lines = { "" } end

    self._state.path = path
    if self._editor_node then
        self._editor_node._lines = lines
        self._editor_node._row, self._editor_node._col = 1, 1
        self._editor_node._scroll_row = 0
        self._editor_node._dirty = false
        -- Loading a new file is a hard cut: an undo from the freshly
        -- loaded state shouldn't pop back into the previously open
        -- file's history. Drop everything.
        self._editor_node._undo = {}
        self._editor_node._undo_last_kind = nil
    end
    self:set_state({})
end

function Editor:_save(path)
    if not self._editor_node then return end
    local body = table.concat(self._editor_node._lines, "\n")
    local ok = ez.storage.write_file(path, body)
    if ok then
        self._state.path = path
        self._editor_node._dirty = false
    end
    self:set_state({})
end

function Editor:on_exit()
    focus.exit_edit()
    if self._touch_subs then
        for _, id in ipairs(self._touch_subs) do
            ez.bus.unsubscribe(id)
        end
        self._touch_subs = nil
    end
end

-- Translate a screen-space touch into a (row, col) inside the
-- editor's buffer. Returns nil if the touch landed outside the editor
-- area (title bar, hint line, or off the right edge of code).
local function touch_to_cursor(n, screen_x, screen_y)
    if not n._draw_x or not n._draw_fh then return nil end
    local fh = n._draw_fh
    local code_x = n._draw_x + LINE_NUMBER_W + PAD_X
    local code_top = n._draw_y + PAD_Y
    -- Don't accept touches in the bottom-of-pane hint strip.
    local hint_h = fh + 2
    local code_bottom = n._draw_y + n._draw_h - hint_h
    if screen_y < code_top or screen_y >= code_bottom then return nil end

    local rel_y = screen_y - code_top
    local row_in_view = math.floor(rel_y / fh)
    local row = (n._scroll_row or 0) + row_in_view + 1
    if row < 1 then row = 1 end
    if row > #n._lines then row = #n._lines end

    local line = n._lines[row] or ""
    -- Pixel x relative to the start of code text. Walk the line
    -- character-by-character finding the byte offset whose accumulated
    -- width is closest to the tapped x.
    local target_px = screen_x - code_x
    if target_px < 0 then return row, 1 end
    theme.set_font("small")
    local best_col = 1
    for i = 1, #line do
        local sub_w = theme.text_width(line:sub(1, i))
        if sub_w < target_px then
            best_col = i + 1
        else
            -- Choose the closer of [i] and [i+1].
            local prev_w = theme.text_width(line:sub(1, i - 1))
            if (target_px - prev_w) < (sub_w - target_px) then
                best_col = i
            else
                best_col = i + 1
            end
            break
        end
    end
    if best_col > #line + 1 then best_col = #line + 1 end
    if best_col < 1 then best_col = 1 end
    return row, best_col
end

function Editor:on_enter()
    -- Materialise the editor node lazily so we keep its buffer across
    -- rebuilds. The node lives on `self`, not in build()'s tree, so
    -- a set_state-triggered rebuild reuses the same object.
    if not self._editor_node then
        self._editor_node = {
            type = "text_editor",
        }
        ensure_state(self._editor_node)
        -- Hook the editor's Alt+S / Alt+O / Alt+N dispatch back to
        -- the screen. Done here so the prompt callbacks see the
        -- screen instance via upvalue capture.
        local me = self
        self._editor_node._on_shortcut = function(letter)
            if letter == "s" then
                local path = me._state.path or "/sd/scripts/untitled.lua"
                dialog.prompt({
                    title       = "Save as",
                    message     = "Path",
                    value       = path,
                    placeholder = "/sd/scripts/foo.lua",
                }, function(p)
                    if p and p ~= "" then me:_save(p) end
                end)
            elseif letter == "o" then
                dialog.prompt({
                    title       = "Open",
                    message     = "Path",
                    value       = me._state.path or "/sd/scripts/",
                    placeholder = "/sd/scripts/foo.lua",
                }, function(p)
                    if p and p ~= "" then me:_load(p) end
                end)
            elseif letter == "n" then
                me._state.path = nil
                me._editor_node._lines = { "" }
                me._editor_node._row, me._editor_node._col = 1, 1
                me._editor_node._scroll_row = 0
                me._editor_node._dirty = false
                me._editor_node._undo = {}
                me._editor_node._undo_last_kind = nil
                me:set_state({})
            end
        end
    end
    -- Force focus into edit mode so plain character keys reach the
    -- text_editor node's on_key (without this, focus.handle_key only
    -- forwards UP/DOWN/LEFT/RIGHT to the focused widget and characters
    -- fall through to scrolling / screen.handle_key).
    focus.enter_edit()

    -- Touch support: tap a line to jump the cursor there. We resolve
    -- the down position to a (row, col) using the editor node's
    -- recorded layout rect, then move the cursor.
    self._touch_subs = self._touch_subs or {}
    if #self._touch_subs == 0 then
        local me = self
        table.insert(self._touch_subs,
            ez.bus.subscribe("touch/down", function(_, data)
                if type(data) ~= "table" then return end
                local n = me._editor_node
                if not n then return end
                local row, col = touch_to_cursor(n, data.x, data.y)
                if not row then return end
                n._row = row
                n._col = col
                me:set_state({})
            end))
    end
    if self._state.boot_buf and not self._state.path then
        local lines = {}
        local data = self._state.boot_buf:gsub("\r\n", "\n"):gsub("\r", "\n")
        for line in (data .. "\n"):gmatch("([^\n]*)\n") do
            lines[#lines + 1] = line
        end
        self._editor_node._lines = #lines > 0 and lines or { "" }
        self._state.boot_buf = nil
    elseif self._state.path then
        self:_load(self._state.path)
    end
end

function Editor:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar(self:_status(), { back = true }),
        self._editor_node,
    })
end

function Editor:handle_key(key)
    -- Note: in editing mode focus.handle_key swallows non-arrow keys
    -- before they reach this method. The Alt+S/O/N + plain typing path
    -- runs inside the text_editor node (see _on_shortcut and on_key in
    -- the node handler). This screen-level handler only fires when the
    -- focused widget releases input -- e.g. when the buffer is empty
    -- and the user pressed BACKSPACE so the node returned "pop".
    return nil
end

return Editor
