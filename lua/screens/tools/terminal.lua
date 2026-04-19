-- Terminal: a tiny unix-style shell.
--
-- Supports cd / ls / pwd / cat / echo / rm / mkdir / mv / cp / clear /
-- run / ./file / mem / reboot / exit. File paths resolve against a
-- current working directory that starts at /fs. The `run` command
-- (and the `./file` shorthand) loads a Lua file with `load()` and
-- executes it, capturing stdout via a temporary `print` override and
-- appending any return value to the transcript.
--
-- UI: a title sub-bar, a scrollable transcript, and a single input
-- prompt pinned at the bottom. Every keystroke goes to the prompt;
-- BACKSPACE on an empty prompt pops the screen. UP/DOWN cycle through
-- recent commands. The transcript auto-scrolls to the most recent
-- line by writing a large scroll_offset that the scroll widget
-- clamps.

local ui        = require("ezui")
local theme     = require("ezui.theme")
local node_mod  = require("ezui.node")
local text_util = require("ezui.text")
local transient = require("ezui.transient")

-- Transient state key. The whole terminal state — transcript, cwd,
-- history, current input, scroll position — survives a close/reopen
-- within the same boot. A reboot wipes it (cleaner than accumulating
-- session noise on the flash, and easy to undo by swapping in
-- ezui.persist if the user ever asks for reboot survival).
local STATE_KEY = "terminal"

local Terminal = { title = "Terminal" }

local MAX_LINES    = 200
local MAX_HISTORY  = 50
local PROMPT_COLOR = "ACCENT"
local ERROR_COLOR  = "ERROR"
local MUTED_COLOR  = "TEXT_MUTED"

-- Monospace font used by every transcript line + the prompt. Keeping
-- it in one constant makes it easy to swap (e.g. `small` for the
-- larger FreeMono 9pt) without editing several sites. `tiny` is
-- FreeMono 5pt (6 px/char), giving ~50 columns on the terminal view.
local TERM_FONT = "tiny"

-- Register the input-row node once. It composes a prompt, the current
-- input buffer, and a blinking cursor into a single line; cheaper than
-- three stacked text widgets and lets us choose where to clip.
if not node_mod.handler("terminal_input") then
    node_mod.register("terminal_input", {
        measure = function(n, max_w, max_h)
            theme.set_font(TERM_FONT)
            return max_w, theme.font_height() + 2
        end,
        draw = function(n, d, x, y, w, h)
            theme.set_font(TERM_FONT)
            local fh = theme.font_height()
            local prompt = (n.prompt or "$ ")
            local value = n.value or ""
            local pw = theme.text_width(prompt)
            d.draw_text(x + 4, y + 1, prompt, theme.color(PROMPT_COLOR))
            d.draw_text(x + 4 + pw, y + 1, value, theme.color("TEXT"))
            -- Blink the cursor at ~2 Hz. Invalidate unconditionally so the
            -- blink keeps advancing when the shell is idle between frames.
            if (ez.system.millis() // 500) % 2 == 0 then
                local cx = x + 4 + pw + theme.text_width(value)
                d.fill_rect(cx, y + 1, 2, fh, theme.color(PROMPT_COLOR))
            end
            require("ezui.screen").invalidate()
        end,
    })
end

-- Custom transcript line. Wraps the input string to the allocated
-- width in measure() and reports the resulting multi-line height, so
-- long output (`ls` listings, help) doesn't overdraw the next line.
-- Wrapping is broken on word boundaries via text_util.wrap; the
-- wrapped lines are stashed on the node and reused in draw().
if not node_mod.handler("term_line") then
    node_mod.register("term_line", {
        measure = function(n, max_w, max_h)
            theme.set_font(TERM_FONT)
            local fh = theme.font_height()
            local lines = text_util.wrap(n.value or "", max_w)
            if #lines == 0 then lines = { "" } end
            n._lines = lines
            return max_w, #lines * fh
        end,
        draw = function(n, d, x, y, w, h)
            theme.set_font(TERM_FONT)
            local fh = theme.font_height()
            local color = theme.color(n.color or "TEXT")
            for i, line in ipairs(n._lines or { n.value or "" }) do
                d.draw_text(x, y + (i - 1) * fh, line, color)
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Path + FS helpers
-- ---------------------------------------------------------------------------

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Normalise `path` relative to `cwd`. Handles leading "/", "." and "..".
local function resolve(cwd, path)
    if not path or path == "" then return cwd end
    local abs = path:sub(1, 1) == "/"
    local base = abs and "" or cwd
    local combined = base .. "/" .. path
    local parts = {}
    for seg in combined:gmatch("[^/]+") do
        if seg == ".." then
            parts[#parts] = nil
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return "/" .. table.concat(parts, "/")
end

local function is_dir(path)
    -- list_dir returns an array on directories and nil on files / missing.
    local ok, entries = pcall(ez.storage.list_dir, path)
    return ok and type(entries) == "table"
end

-- Split a line on whitespace, honouring single- and double-quoted
-- substrings so `echo "hello world"` yields two tokens.
local function tokenize(line)
    local tokens = {}
    local i, n = 1, #line
    while i <= n do
        local c = line:sub(i, i)
        if c == " " or c == "\t" then
            i = i + 1
        elseif c == '"' or c == "'" then
            local quote = c
            local j = i + 1
            while j <= n and line:sub(j, j) ~= quote do j = j + 1 end
            tokens[#tokens + 1] = line:sub(i + 1, j - 1)
            i = j + 1
        else
            local j = i
            while j <= n and line:sub(j, j) ~= " " and line:sub(j, j) ~= "\t" do
                j = j + 1
            end
            tokens[#tokens + 1] = line:sub(i, j - 1)
            i = j
        end
    end
    return tokens
end

-- ---------------------------------------------------------------------------
-- Transcript helpers
-- ---------------------------------------------------------------------------

local function append(state, text, color)
    -- Split multi-line text into individual transcript entries so the
    -- layout stays one line per vbox child.
    for segment in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
        state.lines[#state.lines + 1] = { text = segment, color = color }
        if #state.lines > MAX_LINES then
            table.remove(state.lines, 1)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Command implementations. Each returns nothing; they all print via append().
-- ---------------------------------------------------------------------------

local commands = {}

commands.help = function(_, state)
    -- Terminal is ~50 columns wide (FreeMono 5pt, 6 px/char, after 6 px
    -- padding each side and room for the 3 px scrollbar). Layout is
    -- "  cmd<args>    description" with descriptions left-aligned at
    -- column 15 for readability.
    append(state, "Commands:", MUTED_COLOR)
    append(state, "  ls [path]    list directory")
    append(state, "  cd <path>    change directory")
    append(state, "  pwd          print working dir")
    append(state, "  cat <file>   print file contents")
    append(state, "  echo <text>  print text")
    append(state, "  rm <file>    remove file")
    append(state, "  mkdir <dir>  make directory")
    append(state, "  mv <a> <b>   rename / move")
    append(state, "  cp <a> <b>   copy file")
    append(state, "  run <file>   execute a Lua file")
    append(state, "  ./<file>     execute (alias)")
    append(state, "  mem          memory stats")
    append(state, "  clear        clear transcript")
    append(state, "  reboot       restart device")
    append(state, "  exit         close terminal")
end

commands.pwd = function(_, state)
    append(state, state.cwd)
end

commands.cd = function(args, state)
    local target = args[1] or "/fs"
    local resolved = resolve(state.cwd, target)
    if not is_dir(resolved) then
        append(state, "cd: not a directory: " .. resolved, ERROR_COLOR)
        return
    end
    state.cwd = resolved
end

commands.ls = function(args, state)
    local target = args[1] and resolve(state.cwd, args[1]) or state.cwd
    local ok, entries = pcall(ez.storage.list_dir, target)
    if not ok or type(entries) ~= "table" then
        append(state, "ls: cannot open " .. target, ERROR_COLOR)
        return
    end
    -- Group dirs first, then sort alphabetically.
    table.sort(entries, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        return a.name < b.name
    end)
    if #entries == 0 then
        append(state, "(empty)", MUTED_COLOR)
        return
    end
    for _, e in ipairs(entries) do
        local name = e.is_dir and (e.name .. "/") or e.name
        append(state, name, e.is_dir and PROMPT_COLOR or "TEXT")
    end
end

commands.cat = function(args, state)
    if not args[1] then
        append(state, "cat: missing operand", ERROR_COLOR); return
    end
    local target = resolve(state.cwd, args[1])
    local content = ez.storage.read_file(target)
    if not content then
        append(state, "cat: cannot read " .. target, ERROR_COLOR); return
    end
    append(state, content)
end

commands.echo = function(args, state)
    append(state, table.concat(args, " "))
end

commands.rm = function(args, state)
    if not args[1] then
        append(state, "rm: missing operand", ERROR_COLOR); return
    end
    local target = resolve(state.cwd, args[1])
    if ez.storage.remove(target) then
        append(state, "removed " .. target, MUTED_COLOR)
    else
        append(state, "rm: cannot remove " .. target, ERROR_COLOR)
    end
end

commands.mkdir = function(args, state)
    if not args[1] then
        append(state, "mkdir: missing operand", ERROR_COLOR); return
    end
    local target = resolve(state.cwd, args[1])
    if ez.storage.mkdir(target) then
        append(state, "created " .. target, MUTED_COLOR)
    else
        append(state, "mkdir: failed " .. target, ERROR_COLOR)
    end
end

commands.mv = function(args, state)
    if #args < 2 then
        append(state, "mv: usage: mv <from> <to>", ERROR_COLOR); return
    end
    local from = resolve(state.cwd, args[1])
    local to   = resolve(state.cwd, args[2])
    if ez.storage.rename(from, to) then
        append(state, from .. " -> " .. to, MUTED_COLOR)
    else
        append(state, "mv: failed", ERROR_COLOR)
    end
end

commands.cp = function(args, state)
    if #args < 2 then
        append(state, "cp: usage: cp <from> <to>", ERROR_COLOR); return
    end
    local from = resolve(state.cwd, args[1])
    local to   = resolve(state.cwd, args[2])
    if ez.storage.copy_file and ez.storage.copy_file(from, to) then
        append(state, from .. " -> " .. to, MUTED_COLOR)
    else
        append(state, "cp: failed", ERROR_COLOR)
    end
end

commands.mem = function(_, state)
    local kb = collectgarbage("count")
    append(state, string.format("Lua heap: %.1f KB", kb))
    if ez.system.get_free_heap then
        append(state, string.format("Free heap: %d B", ez.system.get_free_heap()))
    end
    if ez.storage.get_flash_info then
        local info = ez.storage.get_flash_info()
        if info then
            append(state, string.format("Flash: %d / %d B used",
                info.used or 0, info.total or 0))
        end
    end
end

commands.clear = function(_, state)
    state.lines = {}
end

commands.reboot = function(_, state)
    append(state, "rebooting...", MUTED_COLOR)
    ez.system.restart()
end

commands.exit = function(_, state)
    state._exit = true
end

commands.run = function(args, state)
    if not args[1] then
        append(state, "run: missing operand", ERROR_COLOR); return
    end
    local target = resolve(state.cwd, args[1])
    local content = ez.storage.read_file(target)
    if not content then
        append(state, "run: cannot read " .. target, ERROR_COLOR); return
    end
    local chunk, err = load(content, "@" .. target)
    if not chunk then
        append(state, "run: parse: " .. tostring(err), ERROR_COLOR); return
    end
    -- Capture print() output from the script so it lands in the
    -- transcript instead of serial-only.
    local captured = {}
    local orig_print = _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
        captured[#captured + 1] = table.concat(parts, "\t")
    end
    local ok, result = pcall(chunk)
    _G.print = orig_print
    for _, line in ipairs(captured) do append(state, line) end
    if not ok then
        append(state, "error: " .. tostring(result), ERROR_COLOR); return
    end
    if result ~= nil then append(state, tostring(result), MUTED_COLOR) end
end

-- ---------------------------------------------------------------------------
-- Input execution
-- ---------------------------------------------------------------------------

local function execute(state, raw)
    raw = trim(raw)
    append(state, state.cwd .. " $ " .. raw, PROMPT_COLOR)
    if raw == "" then return end
    -- Remember in history, deduping adjacent repeats.
    if state.history[#state.history] ~= raw then
        state.history[#state.history + 1] = raw
        if #state.history > MAX_HISTORY then
            table.remove(state.history, 1)
        end
    end
    state.history_idx = #state.history + 1

    local tokens = tokenize(raw)
    local cmd = tokens[1] or ""
    local args = {}
    for i = 2, #tokens do args[i - 1] = tokens[i] end

    if cmd:sub(1, 2) == "./" then
        table.insert(args, 1, cmd:sub(3))
        cmd = "run"
    end

    local fn = commands[cmd]
    if not fn then
        append(state, "unknown: " .. cmd, ERROR_COLOR); return
    end
    local ok, err = pcall(fn, args, state)
    if not ok then
        append(state, "internal error: " .. tostring(err), ERROR_COLOR)
    end
end

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

function Terminal.initial_state()
    -- If there's a snapshot from a previous open this boot, restore
    -- it verbatim and return early — transcript, cwd, history, scroll
    -- all come back as the user left them.
    local saved = transient.load(STATE_KEY)
    if saved then
        saved._exit = false
        return saved
    end

    -- First open this boot. Bitmap fonts ship only printable ASCII,
    -- so stick to ASCII in the welcome banner.
    return {
        cwd         = "/fs",
        lines       = {
            { text = "ezOS shell - type `help`", color = PROMPT_COLOR },
        },
        input       = "",
        history     = {},
        history_idx = 1,
        scroll      = 1 << 20,  -- clamped to max_scroll; pins to bottom
        _exit       = false,
    }
end

-- Called when the terminal screen is popped off the stack. Park the
-- whole state table in the transient store so the next open picks it
-- up intact. Survives screen cycling but not a power cycle.
function Terminal:on_exit()
    transient.save(STATE_KEY, self._state)
end

-- Pixels to scroll per UP/DOWN tick. Matches roughly one text line at
-- small_aa so the movement feels predictable.
local SCROLL_STEP = 12

-- The scroll node is child #2 of the outer vbox (title bar, scroll,
-- input row). Look it up on demand rather than storing a reference
-- that would stale across rebuilds.
local function find_scroll(tree)
    return tree and tree.children and tree.children[2]
end

function Terminal:build(state)
    local line_nodes = {}
    for _, l in ipairs(state.lines) do
        line_nodes[#line_nodes + 1] = {
            type = "term_line",
            value = l.text,
            color = l.color or "TEXT",
        }
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Terminal", { back = true, right = state.cwd }),
        ui.scroll({ grow = 1 },
            ui.vbox({ gap = 0, padding = { 2, 6, 2, 6 } }, line_nodes)),
        { type = "terminal_input", prompt = "$ ", value = state.input },
    })
end

function Terminal:handle_key(key)
    local state = self._state

    if key.special == "ENTER" then
        execute(state, state.input)
        state.input = ""
        self:set_state({})
        -- Snap to the bottom AFTER the rebuild so the newly-added
        -- lines are visible. Mutating the live scroll node bypasses
        -- the screen framework's state-preservation (which would
        -- otherwise copy the previous scroll position onto the
        -- fresh tree).
        local scroll = find_scroll(self._tree)
        if scroll then scroll.scroll_offset = 1 << 20 end
        if state._exit then
            state._exit = false
            return "pop"
        end
        return "handled"
    elseif key.special == "BACKSPACE" then
        if #state.input > 0 then
            state.input = state.input:sub(1, -2)
            self:set_state({})
            return "handled"
        end
        return nil  -- default back → pop the screen
    elseif key.special == "UP" then
        local scroll = find_scroll(self._tree)
        if scroll then
            scroll.scroll_offset = (scroll.scroll_offset or 0) - SCROLL_STEP
            if scroll.scroll_offset < 0 then scroll.scroll_offset = 0 end
            require("ezui.screen").invalidate()
        end
        return "handled"
    elseif key.special == "DOWN" then
        local scroll = find_scroll(self._tree)
        if scroll then
            scroll.scroll_offset = (scroll.scroll_offset or 0) + SCROLL_STEP
            require("ezui.screen").invalidate()
        end
        return "handled"
    elseif key.character then
        state.input = state.input .. key.character
        self:set_state({})
        -- Typing after scrolling back up brings us back to the prompt.
        local scroll = find_scroll(self._tree)
        if scroll then scroll.scroll_offset = 1 << 20 end
        return "handled"
    end
    return nil
end

return Terminal
