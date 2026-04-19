-- Script editor: a tiny Lua code editor with syntax highlighting,
-- a keyword/operator palette for picking tokens, and a "type mode"
-- that falls back to direct keyboard input. Useful as a developer
-- scratchpad — nothing here is meant to rival a real IDE.
--
-- UI layout:
--   title bar
--   code_view    : the script with syntax highlighting + caret
--   token_palette: horizontally scrollable keyword list (hidden in TYPE mode)
--
-- Modes:
--   "keys"       : LEFT/RIGHT scrub the palette, ENTER inserts the token
--                  at the caret. Letter keys are ignored. UP/DOWN still
--                  move the caret through text.
--   "type"       : all printable keys insert characters at the caret.
--                  LEFT/RIGHT/UP/DOWN navigate the caret. ENTER inserts \n.
--
-- Alt+M toggles between modes; BACKSPACE deletes the character before
-- the caret (pops the screen when the script is empty), Sym + various
-- characters still produce the symbol layer in TYPE mode via the
-- keyboard driver itself.

local ui        = require("ezui")
local theme     = require("ezui.theme")
local node_mod  = require("ezui.node")
local transient = require("ezui.transient")

local Editor = { title = "Editor" }

local STATE_KEY = "script_editor"
local EDITOR_FONT = "tiny"  -- Spleen 6x12 — dense enough to see context

-- ---------------------------------------------------------------------------
-- Token tables
-- ---------------------------------------------------------------------------

-- Lua 5.4 reserved words (22). Order follows the language reference.
local KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
}

-- Operators and punctuation, grouped so the palette scrolls in a
-- predictable order.
local OPERATORS = {
    "=", "==", "~=", "<", ">", "<=", ">=",
    "+", "-", "*", "/", "//", "%", "^",
    "&", "|", "~", "<<", ">>",
    "(", ")", "{", "}", "[", "]",
    "::", ";", ":", ",", ".", "..", "...", "#",
}

-- Editor actions (ACT mode). Handlers defined near handle_key.
local ACTION_LABELS = { "Run", "Save", "Clear", "Exit" }

-- Modes, cycled via Alt+M. Short names used in the title-bar right
-- slot; palette items come from MODE_PALETTE for the two pick-a-token
-- modes and from ACTION_LABELS in ACT mode. TYPE mode has no palette.
local MODES = { "keys", "ops", "type", "actions" }
local MODE_LABEL = {
    keys    = "KEYS",
    ops     = "OPS",
    type    = "TYPE",
    actions = "ACT",
}
local MODE_PALETTE = {
    keys    = KEYWORDS,
    ops     = OPERATORS,
    actions = ACTION_LABELS,
}

-- Set form so tokeniser can test word-is-keyword in O(1).
local KEYWORD_SET = {}
for _, k in ipairs(KEYWORDS) do KEYWORD_SET[k] = true end

-- ---------------------------------------------------------------------------
-- Syntax tokeniser (line-local; no multi-line strings / comments).
-- ---------------------------------------------------------------------------

-- Classify one line as a list of { kind, value } tokens. Handles
-- single-line strings in either quote style, "--" line comments, and
-- word-boundary keyword / identifier detection; anything else (ops,
-- whitespace) passes through as "default".
local function tokenise(line)
    local tokens = {}
    local i, n = 1, #line
    while i <= n do
        local c = line:sub(i, i)
        -- Line comment — eats the rest of the line.
        if c == "-" and line:sub(i + 1, i + 1) == "-" then
            tokens[#tokens + 1] = { kind = "comment", value = line:sub(i) }
            return tokens
        end
        -- String literal.
        if c == '"' or c == "'" then
            local quote = c
            local j = i + 1
            while j <= n and line:sub(j, j) ~= quote do
                if line:sub(j, j) == "\\" then j = j + 1 end
                j = j + 1
            end
            tokens[#tokens + 1] = { kind = "string", value = line:sub(i, j) }
            i = j + 1
        -- Number (starts with a digit; accepts the ASCII subset of
        -- Lua's numeric literal form — enough for colouring).
        elseif c:match("%d") then
            local j = i
            while j <= n and line:sub(j, j):match("[%w%.]") do j = j + 1 end
            tokens[#tokens + 1] = { kind = "number", value = line:sub(i, j - 1) }
            i = j
        -- Identifier / keyword.
        elseif c:match("[%a_]") then
            local j = i
            while j <= n and line:sub(j, j):match("[%w_]") do j = j + 1 end
            local word = line:sub(i, j - 1)
            local kind = KEYWORD_SET[word] and "keyword" or "ident"
            tokens[#tokens + 1] = { kind = kind, value = word }
            i = j
        else
            tokens[#tokens + 1] = { kind = "default", value = c }
            i = i + 1
        end
    end
    return tokens
end

local function token_color(kind)
    if kind == "keyword" then return theme.color("ACCENT")
    elseif kind == "string" then return theme.color("SUCCESS")
    elseif kind == "comment" then return theme.color("TEXT_MUTED")
    elseif kind == "number" then return theme.color("INFO")
    elseif kind == "ident"  then return theme.color("TEXT")
    else                          return theme.color("TEXT_SEC")
    end
end

-- ---------------------------------------------------------------------------
-- Cursor / text helpers
-- ---------------------------------------------------------------------------

-- Split the full text on \n into an array of lines. Trailing newline
-- produces a final empty string, which lines_of() intentionally keeps
-- so the caret on an empty last line is addressable.
local function lines_of(text)
    local lines = {}
    local start = 1
    local len = #text
    for i = 1, len do
        if text:sub(i, i) == "\n" then
            lines[#lines + 1] = text:sub(start, i - 1)
            start = i + 1
        end
    end
    lines[#lines + 1] = text:sub(start, len)
    return lines
end

-- Turn a byte-position caret into (row, col) both 1-based.
local function cursor_rc(text, cur)
    local row, col = 1, 1
    for i = 1, cur - 1 do
        if text:sub(i, i) == "\n" then
            row = row + 1
            col = 1
        else
            col = col + 1
        end
    end
    return row, col
end

-- Inverse: turn (row, col) back into a byte position, clamping col
-- to the target row's length.
local function rc_cursor(text, row, col)
    local lines = lines_of(text)
    if row < 1 then row = 1 end
    if row > #lines then row = #lines end
    if col < 1 then col = 1 end
    local line = lines[row] or ""
    if col > #line + 1 then col = #line + 1 end

    local pos = 1
    for i = 1, row - 1 do
        pos = pos + #lines[i] + 1  -- +1 for the \n
    end
    return pos + col - 1
end

local function insert_at(text, pos, s)
    return text:sub(1, pos - 1) .. s .. text:sub(pos)
end

local function delete_before(text, pos)
    if pos <= 1 then return text, pos end
    return text:sub(1, pos - 2) .. text:sub(pos), pos - 1
end

-- ---------------------------------------------------------------------------
-- code_view node — multi-line highlighted text with caret overlay.
-- ---------------------------------------------------------------------------

if not node_mod.handler("code_view") then
    node_mod.register("code_view", {
        measure = function(n, max_w, max_h)
            return max_w, max_h
        end,
        draw = function(n, d, x, y, w, h)
            theme.set_font(EDITOR_FONT)
            local fh = theme.font_height()
            local px = x + 3

            local lines = lines_of(n.text or "")
            local cur_row, cur_col = cursor_rc(n.text or "", n.cursor or 1)

            -- Only draw lines that fit in the viewport — a very long
            -- script would otherwise spill below the bottom and waste
            -- CPU. Scrolling could be added later by offsetting the
            -- starting line index.
            local first = math.max(1, cur_row - math.floor(h / fh) + 3)
            local y_ofs = y + 2
            for i = first, #lines do
                local ly = y_ofs + (i - first) * fh
                if ly + fh > y + h then break end

                -- Render tokens left-to-right.
                local cx = px
                for _, tok in ipairs(tokenise(lines[i])) do
                    d.draw_text(cx, ly, tok.value, token_color(tok.kind))
                    cx = cx + theme.text_width(tok.value)
                end

                -- Caret overlay. Request the next frame unconditionally
                -- so the blink keeps advancing while the editor is idle.
                if i == cur_row then
                    local prefix = lines[i]:sub(1, cur_col - 1)
                    local caret_x = px + theme.text_width(prefix)
                    -- Blink at ~2 Hz so the caret is obvious when the
                    -- user is looking for it but doesn't dominate.
                    if (ez.system.millis() // 500) % 2 == 0 then
                        d.fill_rect(caret_x, ly, 1, fh, theme.color("ACCENT"))
                    end
                    require("ezui.screen").invalidate()
                end
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- token_palette node — horizontal scrolling selector.
-- ---------------------------------------------------------------------------

if not node_mod.handler("token_palette") then
    node_mod.register("token_palette", {
        measure = function(n, max_w, max_h)
            theme.set_font(EDITOR_FONT)
            return max_w, theme.font_height() + 8
        end,
        draw = function(n, d, x, y, w, h)
            theme.set_font(EDITOR_FONT)
            local fh = theme.font_height()

            -- Thin separator.
            d.fill_rect(x, y, w, 1, theme.color("BORDER"))

            -- Compute how wide each pill is and which fit on screen,
            -- centred around the selected one.
            local pills = n.items or {}
            local sel = n.selected or 1
            local pad = 4
            local cx = x + 4
            local gap = 4

            -- Find the starting index so the selection stays visible.
            -- Simplest: scan leftwards from selection until we overflow
            -- the budget, then start there.
            local budget_left = math.floor(w / 2) - 4
            local start = sel
            local used = 0
            while start > 1 do
                local tw = theme.text_width(pills[start - 1]) + pad * 2 + gap
                if used + tw > budget_left then break end
                used = used + tw
                start = start - 1
            end

            local py = y + 4
            for i = start, #pills do
                local label = pills[i]
                local tw = theme.text_width(label)
                local pw = tw + pad * 2
                if cx + pw > x + w then break end

                if i == sel then
                    d.fill_round_rect(cx, py, pw, fh + 2, 3,
                        theme.color("ACCENT"))
                    d.draw_text(cx + pad, py + 1, label, theme.color("BG"))
                else
                    d.draw_text(cx + pad, py + 1, label,
                        theme.color("TEXT_SEC"))
                end
                cx = cx + pw + gap
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

function Editor.initial_state()
    local saved = transient.load(STATE_KEY)
    if saved then return saved end
    return {
        text    = "-- Lua scratchpad\nlocal x = 1\nprint(x)\n",
        cursor  = 1,
        mode    = "keys",
        key_idx = 1,
        status  = nil,   -- last status (Run result, Save path, etc.)
    }
end

function Editor:on_exit()
    transient.save(STATE_KEY, self._state)
end

function Editor:build(state)
    local items = {
        ui.title_bar("Editor", { back = true, right = MODE_LABEL[state.mode] }),
        {
            type   = "code_view",
            text   = state.text,
            cursor = state.cursor,
            grow   = 1,
        },
    }

    -- One-liner status above the palette. Run result / Save path /
    -- parse error message appear here; cleared on next action.
    if state.status and state.status ~= "" then
        items[#items + 1] = ui.padding({ 2, 6, 1, 6 }, ui.text_widget(
            state.status,
            { font = EDITOR_FONT, color = "TEXT_SEC", wrap = true }))
    end

    local palette = MODE_PALETTE[state.mode]
    if palette then
        items[#items + 1] = {
            type     = "token_palette",
            items    = palette,
            selected = state.key_idx,
        }
    else
        items[#items + 1] = ui.padding({ 3, 6, 3, 6 }, ui.text_widget(
            "TYPE mode: keys insert chars; Alt+M -> next mode",
            { font = EDITOR_FONT, color = "TEXT_MUTED" }))
    end
    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

-- ---------------------------------------------------------------------------
-- Input handling
-- ---------------------------------------------------------------------------

local function move_caret_row(state, delta)
    local r, c = cursor_rc(state.text, state.cursor)
    state.cursor = rc_cursor(state.text, r + delta, c)
end

local function move_caret_col(state, delta)
    local new_cur = state.cursor + delta
    if new_cur < 1 then new_cur = 1 end
    if new_cur > #state.text + 1 then new_cur = #state.text + 1 end
    state.cursor = new_cur
end

local function insert_token(state, token)
    state.text = insert_at(state.text, state.cursor, token)
    state.cursor = state.cursor + #token
end

-- ACT mode handlers. Each returns nothing; the status string drives
-- the one-liner readout above the palette.
local ACTIONS = {}

ACTIONS.Run = function(state)
    local chunk, err = load(state.text, "@editor")
    if not chunk then
        state.status = "Parse: " .. tostring(err):sub(1, 80)
        return
    end
    local captured = {}
    local orig_print = _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring(select(i, ...))
        end
        captured[#captured + 1] = table.concat(parts, "\t")
    end
    local ok, result = pcall(chunk)
    _G.print = orig_print
    if not ok then
        state.status = "Error: " .. tostring(result):sub(1, 80)
    elseif #captured > 0 then
        state.status = "Out: " .. table.concat(captured, "; "):sub(1, 80)
    elseif result ~= nil then
        state.status = "-> " .. tostring(result):sub(1, 80)
    else
        state.status = "ok"
    end
end

ACTIONS.Save = function(state)
    local dialog = require("ezui.dialog")
    dialog.prompt({
        title       = "Save script",
        message     = "File path:",
        value       = state.save_path or "/fs/scripts/scratch.lua",
        placeholder = "/fs/scripts/name.lua",
    }, function(path)
        if not path or path == "" then
            state.status = "Save cancelled"
            return
        end
        -- Auto-create the parent directory so the first Save into a
        -- fresh /fs/scripts doesn't fail with "no such dir".
        local dir = path:match("^(.-)/[^/]+$")
        if dir and not ez.storage.exists(dir) then
            ez.storage.mkdir(dir)
        end
        local ok = ez.storage.write_file(path, state.text)
        state.save_path = path
        state.status = ok and ("Saved " .. path) or ("Save failed: " .. path)
    end, function()
        state.status = "Save cancelled"
    end)
end

ACTIONS.Clear = function(state)
    state.text = ""
    state.cursor = 1
    state.status = "Cleared"
end

ACTIONS.Exit = function(state)
    state._exit = true
end

local function cycle_mode(state)
    for i, m in ipairs(MODES) do
        if m == state.mode then
            state.mode = MODES[(i % #MODES) + 1]
            state.key_idx = 1
            state.status = nil
            return
        end
    end
    state.mode = MODES[1]
end

function Editor:handle_key(key)
    local state = self._state

    -- Alt+M cycles through modes.
    if key.character == "m" and key.alt then
        cycle_mode(state); self:set_state({}); return "handled"
    end

    -- Alt + arrow moves the text caret in every mode. Without the
    -- modifier, plain LEFT/RIGHT go to the palette in KEYS/OPS/ACT;
    -- plain UP/DOWN already move the caret in all modes (kept for
    -- convenience). Alt+UP/Alt+DOWN also route to the caret so the
    -- modifier-held scheme is symmetric.
    if key.alt then
        if key.special == "LEFT" then
            move_caret_col(state, -1); self:set_state({}); return "handled"
        elseif key.special == "RIGHT" then
            move_caret_col(state, 1);  self:set_state({}); return "handled"
        elseif key.special == "UP" then
            move_caret_row(state, -1); self:set_state({}); return "handled"
        elseif key.special == "DOWN" then
            move_caret_row(state, 1);  self:set_state({}); return "handled"
        end
    end

    -- Plain UP/DOWN is also a caret move — same effect in every mode.
    if key.special == "UP" then
        move_caret_row(state, -1); self:set_state({}); return "handled"
    elseif key.special == "DOWN" then
        move_caret_row(state, 1);  self:set_state({}); return "handled"
    end

    -- Shared BACKSPACE: delete a char; pop on empty, but only in TYPE
    -- mode so an empty palette navigation doesn't accidentally exit.
    local function del_or_pop()
        if #state.text == 0 then
            if state.mode == "type" then return nil end
            return "handled"
        end
        state.text, state.cursor = delete_before(state.text, state.cursor)
        self:set_state({}); return "handled"
    end

    local palette = MODE_PALETTE[state.mode]
    if palette then
        if key.special == "LEFT" then
            state.key_idx = math.max(1, state.key_idx - 1)
            self:set_state({}); return "handled"
        elseif key.special == "RIGHT" then
            state.key_idx = math.min(#palette, state.key_idx + 1)
            self:set_state({}); return "handled"
        elseif key.special == "ENTER" then
            local item = palette[state.key_idx]
            if state.mode == "actions" then
                local fn = ACTIONS[item]
                if fn then fn(state) end
                if state._exit then
                    state._exit = false
                    return "pop"
                end
            elseif state.mode == "keys" and KEYWORD_SET[item] then
                insert_token(state, item .. " ")  -- trailing space for typing comfort
            else
                insert_token(state, item)         -- operators sit flush
            end
            self:set_state({}); return "handled"
        elseif key.special == "BACKSPACE" then
            return del_or_pop()
        end
        -- Character keys are swallowed in palette modes.
        if key.character then return "handled" end
        return nil
    end

    -- TYPE mode: full text editing.
    if key.special == "LEFT"  then move_caret_col(state, -1); self:set_state({}); return "handled" end
    if key.special == "RIGHT" then move_caret_col(state,  1); self:set_state({}); return "handled" end
    if key.special == "ENTER" then insert_token(state, "\n"); self:set_state({}); return "handled" end
    if key.special == "BACKSPACE" then return del_or_pop() end
    if key.character then
        insert_token(state, key.character)
        self:set_state({}); return "handled"
    end
    return nil
end

return Editor
