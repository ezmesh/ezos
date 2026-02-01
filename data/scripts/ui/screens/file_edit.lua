-- file_edit.lua - Basic nano-like text editor
-- Supports viewing and editing text files with soft wrapping

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local FileEdit = {
    title = "Edit",
    file_path = nil,
    lines = {},
    cursor_row = 1,
    cursor_col = 1,
    scroll_visual_row = 0,  -- Scroll position in visual rows (accounts for wrapping)
    modified = false,
    message = nil,
    message_time = 0,
    -- Cached layout info (recalculated on render)
    wrap_width = 40,  -- Characters per visual line (set in render)
}

function FileEdit:new(path)
    local o = {
        title = "Edit",
        file_path = path or nil,
        lines = {""},
        cursor_row = 1,
        cursor_col = 1,
        scroll_visual_row = 0,
        modified = false,
        message = nil,
        message_time = 0,
        wrap_width = 40,
    }
    setmetatable(o, {__index = FileEdit})

    -- Load file content immediately in constructor
    if path then
        o:load_file(path)
    end

    return o
end

function FileEdit:on_enter()
    -- Set keyboard to input mode for text editing
    ez.keyboard.set_mode("input")
end

function FileEdit:on_exit()
    -- Reset keyboard to normal mode
    ez.keyboard.set_mode("normal")
end

function FileEdit:is_lua_file()
    return self.file_path and self.file_path:match("%.lua$") ~= nil
end

function FileEdit:load_file(path)
    self.file_path = path
    self.lines = {}

    local content = ez.storage.read_file(path)
    if content then
        -- Split content into lines
        for line in (content .. "\n"):gmatch("([^\n]*)\n") do
            table.insert(self.lines, line)
        end
        -- Remove trailing empty line if file didn't end with newline
        if #self.lines > 1 and self.lines[#self.lines] == "" then
            table.remove(self.lines)
        end
        self:show_message("Loaded: " .. self:basename(path))
    else
        self.lines = {""}
        self:show_message("New file: " .. self:basename(path))
    end

    if #self.lines == 0 then
        self.lines = {""}
    end

    self.cursor_row = 1
    self.cursor_col = 1
    self.scroll_visual_row = 0
    self.modified = false
end

function FileEdit:save_file()
    if not self.file_path then
        self:show_message("No filename!")
        return false
    end

    local content = table.concat(self.lines, "\n")
    if ez.storage.write_file(self.file_path, content) then
        self.modified = false
        self:show_message("Saved: " .. self:basename(self.file_path))
        return true
    else
        self:show_message("Save failed!")
        return false
    end
end

function FileEdit:basename(path)
    return path:match("([^/]+)$") or path
end

function FileEdit:show_message(msg)
    self.message = msg
    self.message_time = ez.system.millis()
end

function FileEdit:current_line()
    return self.lines[self.cursor_row] or ""
end

function FileEdit:set_current_line(text)
    self.lines[self.cursor_row] = text
    self.modified = true
end

function FileEdit:insert_char(char)
    local line = self:current_line()
    local before = line:sub(1, self.cursor_col - 1)
    local after = line:sub(self.cursor_col)
    self:set_current_line(before .. char .. after)
    self.cursor_col = self.cursor_col + #char
end

function FileEdit:delete_char()
    local line = self:current_line()
    if self.cursor_col <= #line then
        local before = line:sub(1, self.cursor_col - 1)
        local after = line:sub(self.cursor_col + 1)
        self:set_current_line(before .. after)
    elseif self.cursor_row < #self.lines then
        -- Join with next line
        self:set_current_line(line .. self.lines[self.cursor_row + 1])
        table.remove(self.lines, self.cursor_row + 1)
    end
end

function FileEdit:backspace()
    if self.cursor_col > 1 then
        self.cursor_col = self.cursor_col - 1
        self:delete_char()
    elseif self.cursor_row > 1 then
        -- Join with previous line
        local prev_len = #self.lines[self.cursor_row - 1]
        self.lines[self.cursor_row - 1] = self.lines[self.cursor_row - 1] .. self:current_line()
        table.remove(self.lines, self.cursor_row)
        self.cursor_row = self.cursor_row - 1
        self.cursor_col = prev_len + 1
        self.modified = true
    end
end

function FileEdit:insert_newline()
    local line = self:current_line()
    local before = line:sub(1, self.cursor_col - 1)
    local after = line:sub(self.cursor_col)
    self:set_current_line(before)
    table.insert(self.lines, self.cursor_row + 1, after)
    self.cursor_row = self.cursor_row + 1
    self.cursor_col = 1
end

-- Calculate how many visual rows a line takes with soft wrapping
function FileEdit:get_visual_line_count(line)
    if #line == 0 then return 1 end
    return math.ceil(#line / self.wrap_width)
end

-- Get the visual row offset for a cursor position within a line
function FileEdit:get_cursor_visual_offset(col)
    return math.floor((col - 1) / self.wrap_width)
end

-- Calculate total visual rows before a given logical line
function FileEdit:get_visual_row_before_line(line_idx)
    local total = 0
    for i = 1, line_idx - 1 do
        total = total + self:get_visual_line_count(self.lines[i] or "")
    end
    return total
end

-- Get cursor's absolute visual row (0-indexed)
function FileEdit:get_cursor_visual_row()
    local visual_row = self:get_visual_row_before_line(self.cursor_row)
    visual_row = visual_row + self:get_cursor_visual_offset(self.cursor_col)
    return visual_row
end

function FileEdit:move_cursor(dr, dc)
    -- Vertical movement
    if dr ~= 0 then
        self.cursor_row = math.max(1, math.min(#self.lines, self.cursor_row + dr))
        -- Clamp column to line length
        self.cursor_col = math.min(self.cursor_col, #self:current_line() + 1)
    end

    -- Horizontal movement
    if dc ~= 0 then
        self.cursor_col = self.cursor_col + dc
        local line_len = #self:current_line()

        if self.cursor_col < 1 then
            -- Wrap to end of previous line
            if self.cursor_row > 1 then
                self.cursor_row = self.cursor_row - 1
                self.cursor_col = #self:current_line() + 1
            else
                self.cursor_col = 1
            end
        elseif self.cursor_col > line_len + 1 then
            -- Wrap to start of next line
            if self.cursor_row < #self.lines then
                self.cursor_row = self.cursor_row + 1
                self.cursor_col = 1
            else
                self.cursor_col = line_len + 1
            end
        end
    end
end

function FileEdit:update_scroll(visible_rows)
    local cursor_visual = self:get_cursor_visual_row()

    -- Scroll up if cursor is above visible area
    if cursor_visual < self.scroll_visual_row then
        self.scroll_visual_row = cursor_visual
    end

    -- Scroll down if cursor is below visible area
    if cursor_visual >= self.scroll_visual_row + visible_rows then
        self.scroll_visual_row = cursor_visual - visible_rows + 1
    end
end

-- Menu items for app menu integration
function FileEdit:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = "Save",
        action = function()
            self_ref:save_file()
            ScreenManager.invalidate()
        end
    })

    -- Run action for Lua files
    if self:is_lua_file() then
        table.insert(items, {
            label = "Run",
            action = function()
                -- Save first if modified
                if self_ref.modified then
                    self_ref:save_file()
                end
                -- Try to load and run the Lua file
                local path = self_ref.file_path
                local ok, result = pcall(dofile, path)
                if ok then
                    -- If it returns a screen class, push it
                    if type(result) == "table" and result.new then
                        ScreenManager.push(result:new())
                    else
                        self_ref:show_message("Ran successfully")
                    end
                else
                    self_ref:show_message("Error: " .. tostring(result):sub(1, 30))
                end
                ScreenManager.invalidate()
            end
        })
    end

    table.insert(items, {
        label = "Quit",
        action = function()
            if self_ref.modified then
                self_ref:show_message("Unsaved changes! Use Force Quit")
                ScreenManager.invalidate()
            else
                ScreenManager.pop()
            end
        end
    })

    table.insert(items, {
        label = "Force Quit",
        action = function()
            ScreenManager.pop()
        end
    })

    return items
end

-- Lua keywords for syntax highlighting
local LUA_KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
    ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
    ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
    ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
    ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true,
}

-- Render a line segment with Lua syntax highlighting
function FileEdit:render_lua_segment(display, segment, x, y, colors)
    local fw = display.get_font_width()
    local pos = 1
    local draw_x = x

    while pos <= #segment do
        local char = segment:sub(pos, pos)

        -- Comment (-- to end of line)
        if segment:sub(pos, pos + 1) == "--" then
            local rest = segment:sub(pos)
            display.draw_text(draw_x, y, rest, colors.TEXT_MUTED)
            return
        end

        -- String (single or double quote)
        if char == '"' or char == "'" then
            local quote = char
            local end_pos = pos + 1
            while end_pos <= #segment do
                if segment:sub(end_pos, end_pos) == quote then
                    end_pos = end_pos + 1
                    break
                elseif segment:sub(end_pos, end_pos) == "\\" then
                    end_pos = end_pos + 2
                else
                    end_pos = end_pos + 1
                end
            end
            local str = segment:sub(pos, end_pos - 1)
            display.draw_text(draw_x, y, str, colors.SUCCESS)
            draw_x = draw_x + #str * fw
            pos = end_pos
        -- Number
        elseif char:match("%d") then
            local end_pos = pos
            while end_pos <= #segment and segment:sub(end_pos, end_pos):match("[%d%.xXaAbBcCdDeEfF]") do
                end_pos = end_pos + 1
            end
            local num = segment:sub(pos, end_pos - 1)
            display.draw_text(draw_x, y, num, colors.WARNING)
            draw_x = draw_x + #num * fw
            pos = end_pos
        -- Identifier or keyword
        elseif char:match("[%a_]") then
            local end_pos = pos
            while end_pos <= #segment and segment:sub(end_pos, end_pos):match("[%w_]") do
                end_pos = end_pos + 1
            end
            local word = segment:sub(pos, end_pos - 1)
            local word_color = LUA_KEYWORDS[word] and colors.ACCENT or colors.TEXT
            display.draw_text(draw_x, y, word, word_color)
            draw_x = draw_x + #word * fw
            pos = end_pos
        -- Other characters
        else
            display.draw_text(draw_x, y, char, colors.TEXT)
            draw_x = draw_x + fw
            pos = pos + 1
        end
    end
end

function FileEdit:render(display)
    -- Use small font for more text on screen
    display.set_font_size("small")

    local colors = ListMixin.get_colors(display)
    local fw = display.get_font_width()
    local fh = display.get_font_height()
    local cols = display.get_cols()
    local rows = display.get_rows()

    -- Calculate wrap width (text area width in characters)
    local line_num_width = 4
    self.wrap_width = cols - line_num_width - 2  -- Account for line numbers and margins

    local visible_rows = rows - 3  -- Header and status lines
    self:update_scroll(visible_rows)

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Header bar with filename
    local title = self:basename(self.file_path or "untitled")
    if self.modified then
        title = title .. " *"
    end
    display.fill_rect(0, 0, cols * fw, fh, colors.ACCENT)
    display.draw_text_bg(fw, 0, title, colors.WHITE, colors.ACCENT, 1)

    -- Text area with soft wrapping
    local text_x = (line_num_width + 1) * fw
    local is_lua = self:is_lua_file()
    local cursor_visual_row = self:get_cursor_visual_row()

    -- Find which logical line corresponds to scroll_visual_row
    local visual_row = 0
    local start_line = 1
    for i = 1, #self.lines do
        local line_visual_count = self:get_visual_line_count(self.lines[i])
        if visual_row + line_visual_count > self.scroll_visual_row then
            start_line = i
            break
        end
        visual_row = visual_row + line_visual_count
    end

    -- Calculate which wrap segment to start with in the first visible line
    local skip_wraps = self.scroll_visual_row - visual_row

    -- Render visible lines with wrapping
    local screen_row = 1
    local line_idx = start_line

    while screen_row <= visible_rows and line_idx <= #self.lines do
        local line = self.lines[line_idx]
        local line_len = #line
        local wrap_count = self:get_visual_line_count(line)
        local start_wrap = (line_idx == start_line) and skip_wraps or 0

        for wrap_idx = start_wrap, wrap_count - 1 do
            if screen_row > visible_rows then break end

            local py = screen_row * fh
            local seg_start = wrap_idx * self.wrap_width + 1
            local seg_end = math.min(seg_start + self.wrap_width - 1, line_len)
            local segment = line:sub(seg_start, seg_end)

            -- Line number (only on first wrap of each line)
            if wrap_idx == 0 then
                local line_num = string.format("%3d ", line_idx)
                display.draw_text(fw, py, line_num, colors.TEXT_SECONDARY)
            else
                -- Continuation indicator
                display.draw_text(fw, py, "  + ", colors.TEXT_MUTED)
            end

            -- Line content
            if #segment > 0 then
                if is_lua then
                    self:render_lua_segment(display, segment, text_x, py, colors)
                else
                    display.draw_text(text_x, py, segment, colors.TEXT)
                end
            end

            -- Cursor
            if line_idx == self.cursor_row then
                local cursor_wrap = self:get_cursor_visual_offset(self.cursor_col)
                if cursor_wrap == wrap_idx then
                    local cursor_col_in_wrap = ((self.cursor_col - 1) % self.wrap_width)
                    local cursor_x = text_x + cursor_col_in_wrap * fw
                    -- Draw cursor as inverse block
                    display.fill_rect(cursor_x, py, fw, fh, colors.ACCENT)
                    local char_under = line:sub(self.cursor_col, self.cursor_col)
                    if char_under == "" then char_under = " " end
                    display.draw_text(cursor_x, py, char_under, colors.BLACK)
                end
            end

            screen_row = screen_row + 1
        end

        line_idx = line_idx + 1
    end

    -- Fill remaining rows with empty line indicators
    while screen_row <= visible_rows do
        local py = screen_row * fh
        display.draw_text(fw, py, "  ~ ", colors.TEXT_MUTED)
        screen_row = screen_row + 1
    end

    -- Status bar
    local status_y = (rows - 2) * fh
    if self.message and (ez.system.millis() - self.message_time) < 2000 then
        display.draw_text(fw, status_y, self.message, colors.TEXT_SECONDARY)
    else
        self.message = nil
        -- Show cursor position
        local pos = string.format("L%d C%d", self.cursor_row, self.cursor_col)
        display.draw_text(fw, status_y, pos, colors.TEXT_SECONDARY)
    end
end

function FileEdit:handle_key(key)
    ScreenManager.invalidate()

    -- Special keys
    if key.special == "UP" then
        self:move_cursor(-1, 0)
    elseif key.special == "DOWN" then
        self:move_cursor(1, 0)
    elseif key.special == "LEFT" then
        self:move_cursor(0, -1)
    elseif key.special == "RIGHT" then
        self:move_cursor(0, 1)
    elseif key.special == "ENTER" then
        self:insert_newline()
    elseif key.special == "BACKSPACE" then
        self:backspace()
    elseif key.special == "DELETE" then
        self:delete_char()
    elseif key.special == "HOME" then
        self.cursor_col = 1
    elseif key.special == "END" then
        self.cursor_col = #self:current_line() + 1
    elseif key.special == "PAGE_UP" then
        self:move_cursor(-10, 0)
    elseif key.special == "PAGE_DOWN" then
        self:move_cursor(10, 0)
    elseif key.special == "ESCAPE" then
        -- Quick escape if not modified
        if not self.modified then
            return "pop"
        else
            self:show_message("Unsaved! Use menu to quit")
        end
    elseif key.character and #key.character == 1 then
        -- Regular character input
        local byte = key.character:byte()
        if byte >= 32 and byte < 127 then
            self:insert_char(key.character)
        elseif key.character == "\t" then
            -- Insert spaces for tab
            self:insert_char("    ")
        end
    end

    return "continue"
end

return FileEdit
