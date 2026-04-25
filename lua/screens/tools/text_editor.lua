-- Text editor — loads any file on LittleFS or SD, saves back to the
-- same path. Plain-text by default; .lua files additionally get:
--
--   * syntax highlighting (keywords / strings / comments / numbers /
--     identifiers), line-local tokeniser — no multi-line string / block-
--     comment tracking, but good enough for scratch scripts
--   * keyword tab-completion. As soon as you've typed a prefix that
--     matches at least one Lua keyword, the matches show in a strip
--     along the bottom. Hold Alt + trackball (LEFT / RIGHT) to scroll
--     through them; press SPACE to accept the highlighted candidate —
--     the prefix is replaced with the full keyword plus a trailing
--     space. Plain SPACE with no completion inserts a space as usual.
--
-- Keys:
--   printable char        : insert at caret (also re-evaluates completions)
--   ENTER                 : newline
--   BACKSPACE             : delete char before caret (pop if buffer empty)
--   LEFT/RIGHT/UP/DOWN    : cursor movement (trackball mapped here)
--   HOME / END            : jump to start / end of current line
--   SPACE                 : accept completion if any, else insert ' '
--   Alt + LEFT / RIGHT    : scroll completion selection
--   Alt + SPACE           : insert a literal space (bypass completion)
--   Alt + M               : open the Save / Run / Quit menu
--
-- Save / Run / Quit live in the Alt+M global menu rather than as
-- dedicated chords so the editor's keystroke surface is minimal;
-- BACKSPACE on an empty buffer still pops (consistent with every
-- other screen that uses BACKSPACE as back).

local ui       = require("ezui")
local theme    = require("ezui.theme")
local node_mod = require("ezui.node")
local async    = require("ezui.async")

local Editor = { title = "Text Editor" }

local EDITOR_FONT = "tiny"   -- Spleen 6x12 — dense enough for ~50 cols

-- ---------------------------------------------------------------------------
-- Lua syntax info
-- ---------------------------------------------------------------------------

local KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
}
local KEYWORD_SET = {}
for _, k in ipairs(KEYWORDS) do KEYWORD_SET[k] = true end

-- Line-local tokeniser (no multi-line strings / block comments). Each
-- returned token is { kind, value }; kinds match the colour map below.
local function tokenise(line)
    local tokens = {}
    local i, n = 1, #line
    while i <= n do
        local c = line:sub(i, i)
        if c == "-" and line:sub(i + 1, i + 1) == "-" then
            tokens[#tokens + 1] = { kind = "comment", value = line:sub(i) }
            return tokens
        end
        if c == '"' or c == "'" then
            local quote = c
            local j = i + 1
            while j <= n and line:sub(j, j) ~= quote do
                if line:sub(j, j) == "\\" then j = j + 1 end
                j = j + 1
            end
            tokens[#tokens + 1] = { kind = "string", value = line:sub(i, j) }
            i = j + 1
        elseif c:match("%d") then
            local j = i
            while j <= n and line:sub(j, j):match("[%w%.]") do j = j + 1 end
            tokens[#tokens + 1] = { kind = "number", value = line:sub(i, j - 1) }
            i = j
        elseif c:match("[%a_]") then
            local j = i
            while j <= n and line:sub(j, j):match("[%w_]") do j = j + 1 end
            local word = line:sub(i, j - 1)
            tokens[#tokens + 1] = {
                kind = KEYWORD_SET[word] and "keyword" or "ident",
                value = word,
            }
            i = j
        else
            tokens[#tokens + 1] = { kind = "default", value = c }
            i = i + 1
        end
    end
    return tokens
end

local function token_color(kind)
    if kind == "keyword" then return theme.color("ACCENT")     end
    if kind == "string"  then return theme.color("SUCCESS")    end
    if kind == "comment" then return theme.color("TEXT_MUTED") end
    if kind == "number"  then return theme.color("INFO")       end
    if kind == "ident"   then return theme.color("TEXT")       end
    return theme.color("TEXT_SEC")
end

-- ---------------------------------------------------------------------------
-- Buffer helpers (cursor is a 1-based byte index into state.text).
-- ---------------------------------------------------------------------------

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

local function cursor_rc(text, cur)
    local row, col = 1, 1
    for i = 1, cur - 1 do
        if text:sub(i, i) == "\n" then
            row, col = row + 1, 1
        else
            col = col + 1
        end
    end
    return row, col
end

local function rc_cursor(text, row, col)
    local lines = lines_of(text)
    if row < 1 then row = 1 end
    if row > #lines then row = #lines end
    if col < 1 then col = 1 end
    local line = lines[row] or ""
    if col > #line + 1 then col = #line + 1 end
    local pos = 1
    for i = 1, row - 1 do pos = pos + #lines[i] + 1 end
    return pos + col - 1
end

local function insert_at(text, pos, s)
    return text:sub(1, pos - 1) .. s .. text:sub(pos)
end

local function delete_before(text, pos)
    if pos <= 1 then return text, pos end
    return text:sub(1, pos - 2) .. text:sub(pos), pos - 1
end

local function basename(path)
    return (path or ""):match("([^/]+)$") or path or "untitled"
end

local function ext_of(path)
    return ((path or ""):match("%.([%w]+)$") or ""):lower()
end

-- ---------------------------------------------------------------------------
-- Completions
-- ---------------------------------------------------------------------------

-- Walk back from the cursor to find the identifier prefix the user is
-- typing. Returns the prefix as a string (possibly empty).
local function identifier_prefix(text, cursor)
    local prefix = ""
    local i = cursor - 1
    while i >= 1 do
        local c = text:sub(i, i)
        if not c:match("[%w_]") then break end
        prefix = c .. prefix
        i = i - 1
    end
    return prefix
end

-- Refresh the completion list for the current cursor position.
-- Non-Lua files or a no-prefix position clear it.
local function update_completions(state)
    if not state.is_lua then
        state.prefix = ""
        state.completions = {}
        state.completion_idx = 0
        return
    end
    local prefix = identifier_prefix(state.text, state.cursor)
    state.prefix = prefix
    local comps = {}
    if #prefix > 0 then
        for _, kw in ipairs(KEYWORDS) do
            if kw ~= prefix and kw:sub(1, #prefix) == prefix then
                comps[#comps + 1] = kw
            end
        end
    end
    state.completions = comps
    state.completion_idx = (#comps > 0) and 1 or 0
end

-- Replace the prefix with the currently-selected completion + a
-- trailing space. Returns true if applied.
local function accept_completion(state)
    local kw = state.completions[state.completion_idx]
    if not kw then return false end
    local start = state.cursor - #state.prefix
    state.text = state.text:sub(1, start - 1) .. kw .. " "
        .. state.text:sub(state.cursor)
    state.cursor = start + #kw + 1
    state.dirty = true
    state.status = nil
    update_completions(state)
    return true
end

-- ---------------------------------------------------------------------------
-- editor_view node — multi-line text with syntax highlighting and caret
-- ---------------------------------------------------------------------------

if not node_mod.handler("editor_view") then
    node_mod.register("editor_view", {
        measure = function(n, max_w, max_h) return max_w, max_h end,

        draw = function(n, d, x, y, w, h)
            theme.set_font(EDITOR_FONT)
            local fh = theme.font_height()
            local px = x + 3
            local default_color = theme.color("TEXT")

            local text = n.text or ""
            local lines = lines_of(text)
            local cur_row, cur_col = cursor_rc(text, n.cursor or 1)

            -- Anchor the viewport so the caret row stays a few lines
            -- in from the bottom edge — typing forward doesn't scroll
            -- per keystroke.
            local visible_rows = math.floor(h / fh)
            local first = math.max(1, cur_row - visible_rows + 3)

            local y_ofs = y + 2
            for i = first, #lines do
                local ly = y_ofs + (i - first) * fh
                if ly + fh > y + h then break end

                if n.highlight then
                    local cx = px
                    for _, tok in ipairs(tokenise(lines[i])) do
                        d.draw_text(cx, ly, tok.value, token_color(tok.kind))
                        cx = cx + theme.text_width(tok.value)
                    end
                else
                    d.draw_text(px, ly, lines[i], default_color)
                end

                if i == cur_row then
                    local prefix = lines[i]:sub(1, cur_col - 1)
                    local caret_x = px + theme.text_width(prefix)
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
-- completion_strip node — horizontally-scrolling pill list centred on
-- the selection. Drawn only when .lua file has active completions.
-- ---------------------------------------------------------------------------

if not node_mod.handler("completion_strip") then
    node_mod.register("completion_strip", {
        measure = function(n, max_w, max_h)
            theme.set_font(EDITOR_FONT)
            return max_w, theme.font_height() + 8
        end,

        draw = function(n, d, x, y, w, h)
            theme.set_font(EDITOR_FONT)
            local fh = theme.font_height()

            d.fill_rect(x, y, w, 1, theme.color("BORDER"))

            local items = n.items or {}
            local sel = n.selected or 1
            local pad, gap = 4, 4
            local cx = x + 4

            -- Keep the selected pill roughly centred; walk backwards
            -- from it while we have budget, then draw forward.
            local budget_left = math.floor(w / 2) - 4
            local start, used = sel, 0
            while start > 1 do
                local tw = theme.text_width(items[start - 1]) + pad * 2 + gap
                if used + tw > budget_left then break end
                used = used + tw
                start = start - 1
            end

            local py = y + 4
            for i = start, #items do
                local label = items[i]
                local tw = theme.text_width(label)
                local pw = tw + pad * 2
                if cx + pw > x + w then break end

                if i == sel then
                    d.fill_round_rect(cx, py, pw, fh + 2, 3, theme.color("ACCENT"))
                    d.draw_text(cx + pad, py + 1, label, theme.color("BG"))
                else
                    d.draw_text(cx + pad, py + 1, label, theme.color("TEXT_SEC"))
                end
                cx = cx + pw + gap
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

function Editor.open(path)
    local screen_mod = require("ezui.screen")
    screen_mod.push(screen_mod.create(Editor, Editor.initial_state(path)))
end

function Editor.initial_state(path)
    return {
        path            = path,
        text            = "",
        cursor          = 1,
        dirty           = false,
        status          = path and ("Loading " .. basename(path) .. "...")
                          or "",
        loaded          = false,
        is_lua          = ext_of(path) == "lua",
        prefix          = "",
        completions    = {},
        completion_idx = 0,
    }
end

function Editor:on_enter()
    local state = self:get_state()
    if state.loaded or not state.path then return end

    local this = self
    async.task(function()
        local content = async_read(state.path)
        if content then
            this:set_state({
                text   = content,
                cursor = 1,
                loaded = true,
                status = "",
            })
        else
            this:set_state({
                text   = "",
                cursor = 1,
                loaded = true,
                status = "New file (will be created on save)",
            })
        end
    end)
end

function Editor:build(state)
    local title = basename(state.path)
    local title_right = state.dirty and "[*]" or nil

    local body
    if state.loaded then
        body = {
            type      = "editor_view",
            text      = state.text,
            cursor    = state.cursor,
            highlight = state.is_lua,
            grow      = 1,
        }
    else
        body = ui.padding({ 16, 10, 10, 10 },
            ui.text_widget("Loading...", {
                font = "small_aa", color = "TEXT_MUTED",
            })
        )
        body.grow = 1
    end

    local items = {
        ui.title_bar(title, { back = true, right = title_right }),
        body,
    }

    if #state.completions > 0 then
        items[#items + 1] = {
            type     = "completion_strip",
            items    = state.completions,
            selected = state.completion_idx,
        }
    end

    if state.status and state.status ~= "" then
        items[#items + 1] = ui.padding({ 2, 6, 3, 6 }, ui.text_widget(
            state.status,
            { font = EDITOR_FONT, color = "TEXT_SEC", wrap = true }))
    end

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

-- ---------------------------------------------------------------------------
-- Input
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

local function jump_to_line_start(state)
    local r, _ = cursor_rc(state.text, state.cursor)
    state.cursor = rc_cursor(state.text, r, 1)
end

local function jump_to_line_end(state)
    local r, _ = cursor_rc(state.text, state.cursor)
    local lines = lines_of(state.text)
    state.cursor = rc_cursor(state.text, r, #(lines[r] or "") + 1)
end

local function save(state)
    if not state.path then
        state.status = "No file path to save to"
        return
    end
    local dir = state.path:match("^(.-)/[^/]+$")
    if dir and #dir > 0 and not ez.storage.exists(dir) then
        ez.storage.mkdir(dir)
    end
    local ok = ez.storage.write_file(state.path, state.text)
    if ok then
        state.dirty  = false
        state.status = "Saved " .. basename(state.path)
    else
        state.status = "Save failed: " .. state.path
    end
end

-- Compile + run the current buffer as Lua. Captures print() output and
-- the returned value so the status line can show whichever is more
-- interesting; errors go in as the status. Runs in the main Lua state
-- with no sandbox — scripts have the same API surface as a boot-time
-- module. That's fine for a developer scratchpad; don't open hostile
-- .lua files in this editor.
local function run_buffer(state)
    local chunk, err = load(state.text, "@" .. (state.path or "editor"))
    if not chunk then
        state.status = "Parse: " .. tostring(err):sub(1, 80)
        return
    end
    local captured = {}
    local orig_print = _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
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

-- Global menu items shown by Alt+M. Save and Quit are always
-- available; Run is gated on .lua files so we don't let a markdown
-- buffer compile as code.
function Editor:menu()
    local state = self._state
    local items = {
        {
            title    = "Save",
            subtitle = state.dirty and "Unsaved changes" or "No changes",
            on_press = function()
                save(state)
                self:set_state({})
            end,
        },
    }
    if state.is_lua then
        items[#items + 1] = {
            title    = "Run",
            subtitle = "Execute the buffer in-process",
            on_press = function()
                run_buffer(state)
                self:set_state({})
            end,
        }
    end
    items[#items + 1] = {
        title    = "Quit",
        subtitle = state.dirty and "Discards unsaved changes"
                   or "Back to caller",
        on_press = function()
            local screen_mod = require("ezui.screen")
            screen_mod.pop()
        end,
    }
    return items
end

function Editor:handle_key(key)
    local state = self._state

    if not state.loaded then
        -- Swallow all input until the initial load is done — avoids
        -- losing keystrokes into a buffer that's about to be replaced.
        return "handled"
    end

    -- Alt-modifier chords. ALT+LEFT/RIGHT cycles completions when a
    -- completion list is up; ALT+SPACE inserts a literal space
    -- (bypasses completion-accept). Save / Run / Quit are reachable
    -- via the Alt+M global menu (see Editor:menu()).
    if key.alt then
        if key.special == "LEFT" and #state.completions > 0 then
            state.completion_idx = math.max(1, state.completion_idx - 1)
            self:set_state({}); return "handled"
        elseif key.special == "RIGHT" and #state.completions > 0 then
            state.completion_idx = math.min(#state.completions,
                state.completion_idx + 1)
            self:set_state({}); return "handled"
        elseif key.character == " " then
            state.text = insert_at(state.text, state.cursor, " ")
            state.cursor = state.cursor + 1
            state.dirty  = true
            state.status = nil
            update_completions(state); self:set_state({}); return "handled"
        end
    end

    -- Cursor movement via arrow keys (trackball). No completion
    -- mutation — the user navigating away from the prefix naturally
    -- clears the completion list via update_completions below.
    if key.special == "UP" then
        move_caret_row(state, -1)
        update_completions(state); self:set_state({}); return "handled"
    elseif key.special == "DOWN" then
        move_caret_row(state, 1)
        update_completions(state); self:set_state({}); return "handled"
    elseif key.special == "LEFT" then
        move_caret_col(state, -1)
        update_completions(state); self:set_state({}); return "handled"
    elseif key.special == "RIGHT" then
        move_caret_col(state, 1)
        update_completions(state); self:set_state({}); return "handled"
    elseif key.special == "HOME" then
        jump_to_line_start(state)
        update_completions(state); self:set_state({}); return "handled"
    elseif key.special == "END" then
        jump_to_line_end(state)
        update_completions(state); self:set_state({}); return "handled"
    elseif key.special == "ENTER" then
        state.text = insert_at(state.text, state.cursor, "\n")
        state.cursor = state.cursor + 1
        state.dirty  = true
        state.status = nil
        update_completions(state); self:set_state({}); return "handled"
    elseif key.special == "BACKSPACE" then
        if #state.text == 0 then return "pop" end
        state.text, state.cursor = delete_before(state.text, state.cursor)
        state.dirty  = true
        state.status = nil
        update_completions(state); self:set_state({}); return "handled"
    end

    -- SPACE is the completion accept key when a list is up. Falling
    -- through inserts a literal space.
    if key.character == " " and #state.completions > 0 then
        accept_completion(state)
        self:set_state({}); return "handled"
    end

    -- Bare printable characters insert. Alt-modified characters are
    -- left unhandled so the global menu dispatcher (Alt+M) and any
    -- future Alt-chord we add upstream gets a clean pass; without
    -- this guard the editor would swallow Alt+M as a literal "m".
    if key.character and not key.alt then
        state.text = insert_at(state.text, state.cursor, key.character)
        state.cursor = state.cursor + #key.character
        state.dirty  = true
        state.status = nil
        update_completions(state); self:set_state({}); return "handled"
    end

    return nil
end

return Editor
