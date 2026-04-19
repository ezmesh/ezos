-- Text editor: a minimal plain-text editor for files on LittleFS or SD.
--
-- Opened via the apps registry (see services/apps.lua) — the file
-- manager hands us a path, we load it, and save back to the same path
-- with Ctrl+S. Everything is TYPE-mode; there's no syntax highlight or
-- token palette (that's what `screens/dev/script_editor.lua` is for).
--
-- Layout:
--   title bar (filename + dirty indicator)
--   text_view (flows; draws caret + visible slice of the buffer)
--   status bar (message like "Saved", "Load failed", etc.)
--
-- Keys:
--   printable char : insert at caret
--   ENTER          : insert newline
--   BACKSPACE      : delete char before caret (pops screen if buffer empty)
--   LEFT / RIGHT   : move caret by one char
--   UP / DOWN      : move caret by a row, clamping column to line length
--   HOME / END     : jump to start / end of current line
--   Alt+S          : save buffer to the source path
--   Alt+Q          : quit back to the caller (pop screen)
--
-- The T-Deck keyboard has no ESC or Ctrl, so editor commands are bound
-- to Alt+letter. BACKSPACE stays dedicated to delete because that's how
-- the physical key is labelled; the only way to pop from a non-empty
-- buffer is Alt+Q.

local ui       = require("ezui")
local theme    = require("ezui.theme")
local node_mod = require("ezui.node")
local async    = require("ezui.async")

local Editor = { title = "Text Editor" }

-- Spleen 6x12 — dense enough to show ~50 cols in the viewport while
-- staying readable. Matches the script editor so the two feel related.
local EDITOR_FONT = "tiny"

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
            row = row + 1
            col = 1
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
    for i = 1, row - 1 do
        pos = pos + #lines[i] + 1
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

-- Filename from a /fs/foo/bar.md-style path, for the title bar.
local function basename(path)
    return (path or ""):match("([^/]+)$") or path or "untitled"
end

-- ---------------------------------------------------------------------------
-- text_view: multi-line plain text with caret overlay. Draws only the
-- slice that fits in the current viewport, anchored so the caret row
-- is always visible — scrolling comes for free.
-- ---------------------------------------------------------------------------

if not node_mod.handler("plain_text_view") then
    node_mod.register("plain_text_view", {
        measure = function(n, max_w, max_h)
            return max_w, max_h
        end,

        draw = function(n, d, x, y, w, h)
            theme.set_font(EDITOR_FONT)
            local fh = theme.font_height()
            local px = x + 3
            local text_color = theme.color("TEXT")

            local text = n.text or ""
            local lines = lines_of(text)
            local cur_row, cur_col = cursor_rc(text, n.cursor or 1)

            -- Keep the caret row a few lines in from the bottom so
            -- continuing to type doesn't scroll on every keystroke.
            local visible_rows = math.floor(h / fh)
            local first = math.max(1, cur_row - visible_rows + 3)

            local y_ofs = y + 2
            for i = first, #lines do
                local ly = y_ofs + (i - first) * fh
                if ly + fh > y + h then break end
                d.draw_text(px, ly, lines[i], text_color)

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
-- Screen
-- ---------------------------------------------------------------------------

-- The registry calls `Editor.open(path)` — that pushes a fresh screen
-- with the path pre-populated in state.
function Editor.open(path)
    local screen_mod = require("ezui.screen")
    local inst = screen_mod.create(Editor, Editor.initial_state(path))
    screen_mod.push(inst)
end

-- Shown in the status line once the file is loaded and any transient
-- save / error message has cleared. The shortcut legend doubles as a
-- reminder that BACKSPACE deletes rather than exits.
local IDLE_HINT = "Alt+S save  Alt+Q quit"

function Editor.initial_state(path)
    return {
        path    = path,
        text    = "",
        cursor  = 1,
        dirty   = false,
        status  = path and ("Loading " .. basename(path) .. "...") or IDLE_HINT,
        loaded  = false,
        load_err = nil,
    }
end

function Editor:on_enter()
    local state = self:get_state()
    if state.loaded or not state.path then return end

    local this = self
    async.task(function()
        local content = async_read(state.path)
        if content then
            -- Replace the "Loading…" message with the shortcut hint so
            -- first-time users see how to save or quit. Plain nil in a
            -- set_state() literal is a no-op (pairs() skips absent keys),
            -- so the status must be set to a concrete value.
            this:set_state({
                text = content,
                cursor = 1,
                loaded = true,
                status = IDLE_HINT,
            })
        else
            -- Missing file is a valid starting point — treat it as a
            -- blank new buffer and let the user type + save to create
            -- it. The status line hints this happened.
            this:set_state({
                text = "",
                cursor = 1,
                loaded = true,
                status = "New file (will be created on save)",
            })
        end
    end)
end

function Editor:build(state)
    local title_right = state.dirty and "[*]" or nil
    local title = basename(state.path)

    local body
    if state.loaded then
        body = {
            type   = "plain_text_view",
            text   = state.text,
            cursor = state.cursor,
            grow   = 1,
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

    if state.status and state.status ~= "" then
        items[#items + 1] = ui.padding({ 2, 6, 3, 6 }, ui.text_widget(
            state.status,
            { font = EDITOR_FONT, color = "TEXT_SEC", wrap = true }))
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

local function jump_to_line_start(state)
    local r, _ = cursor_rc(state.text, state.cursor)
    state.cursor = rc_cursor(state.text, r, 1)
end

local function jump_to_line_end(state)
    local r, _ = cursor_rc(state.text, state.cursor)
    local lines = lines_of(state.text)
    state.cursor = rc_cursor(state.text, r, #(lines[r] or "") + 1)
end

local function save(self, state)
    if not state.path then
        state.status = "No file path to save to"
        return
    end
    -- Ensure the parent directory exists so saving to a fresh /fs/notes/…
    -- doesn't silently fail; mkdir is a no-op if it already exists.
    local dir = state.path:match("^(.-)/[^/]+$")
    if dir and #dir > 0 and not ez.storage.exists(dir) then
        ez.storage.mkdir(dir)
    end
    local ok = ez.storage.write_file(state.path, state.text)
    if ok then
        state.dirty = false
        state.status = "Saved " .. basename(state.path)
    else
        state.status = "Save failed: " .. state.path
    end
end

function Editor:handle_key(key)
    local state = self._state

    if not state.loaded then
        -- While the initial read is in flight we don't want keystrokes
        -- to be lost into the abyss or to begin mutating an empty
        -- buffer that will be overwritten by the load.
        if key.alt and key.character == "q" then return "pop" end
        return "handled"
    end

    -- Alt+S saves, Alt+Q exits. T-Deck has no Ctrl or ESC key, so every
    -- editor command goes through Alt+letter.
    if key.alt then
        if key.character == "s" then
            save(self, state)
            self:set_state({}); return "handled"
        elseif key.character == "q" then
            return "pop"
        end
    end

    if key.special == "UP" then
        move_caret_row(state, -1); self:set_state({}); return "handled"
    elseif key.special == "DOWN" then
        move_caret_row(state, 1); self:set_state({}); return "handled"
    elseif key.special == "LEFT" then
        move_caret_col(state, -1); self:set_state({}); return "handled"
    elseif key.special == "RIGHT" then
        move_caret_col(state, 1); self:set_state({}); return "handled"
    elseif key.special == "HOME" then
        jump_to_line_start(state); self:set_state({}); return "handled"
    elseif key.special == "END" then
        jump_to_line_end(state); self:set_state({}); return "handled"
    elseif key.special == "ENTER" then
        state.text = insert_at(state.text, state.cursor, "\n")
        state.cursor = state.cursor + 1
        state.dirty = true
        state.status = nil
        self:set_state({}); return "handled"
    elseif key.special == "BACKSPACE" then
        if #state.text == 0 then
            return "pop"
        end
        state.text, state.cursor = delete_before(state.text, state.cursor)
        state.dirty = true
        state.status = nil
        self:set_state({}); return "handled"
    end

    if key.character then
        state.text = insert_at(state.text, state.cursor, key.character)
        state.cursor = state.cursor + #key.character
        state.dirty = true
        state.status = nil
        self:set_state({}); return "handled"
    end

    return nil
end

return Editor
