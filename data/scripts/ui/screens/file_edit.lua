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
    scroll_col = 0,         -- Horizontal scroll (used when wrap disabled)
    modified = false,
    message = nil,
    message_time = 0,
    wrap_width = 20,        -- Characters per visual line (set in render based on display)
    wrap_enabled = true,    -- Toggle soft wrapping
    readonly = false,       -- Read-only mode for embedded scripts
}

function FileEdit:new(path, readonly)
    local o = {
        title = "Edit",
        file_path = path or nil,
        lines = {""},
        cursor_row = 1,
        cursor_col = 1,
        scroll_visual_row = 0,
        scroll_col = 0,
        modified = false,
        message = nil,
        message_time = 0,
        wrap_width = 20,
        wrap_enabled = true,
        readonly = readonly or false,
    }
    setmetatable(o, {__index = FileEdit})

    -- Load file in constructor (async I/O works in coroutine context)
    if path then
        o:load_file(path)
    end

    return o
end

function FileEdit:on_enter()
    -- Use raw mode for text editing
    ez.keyboard.set_mode("raw")
end

function FileEdit:on_exit()
    ez.keyboard.set_mode("normal")
end

function FileEdit:is_lua_file()
    return self.file_path and self.file_path:match("%.lua$") ~= nil
end

function FileEdit:load_file(path)
    self.file_path = path
    self.lines = {}

    -- Try embedded scripts first if readonly or in /scripts/ path
    local content = nil
    if self.readonly or ez.storage.is_embedded(path) then
        content = ez.storage.read_embedded(path)
        if content then
            self.readonly = true  -- Mark as readonly if loaded from embedded
        end
    end

    -- Fall back to filesystem if not embedded
    if not content then
        content = ez.storage.read_file(path)
    end

    if content then
        for line in (content .. "\n"):gmatch("([^\n]*)\n") do
            table.insert(self.lines, line)
        end
        if #self.lines > 1 and self.lines[#self.lines] == "" then
            table.remove(self.lines)
        end
        local msg = "Loaded: " .. self:basename(path)
        if self.readonly then
            msg = msg .. " (read-only)"
        end
        self:show_message(msg)
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
    if self.readonly then
        self:show_message("Read-only file!")
        return false
    end

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

function FileEdit:copy_to_sd()
    if not self.file_path then
        self:show_message("No filename!")
        return false
    end

    -- Determine destination path: /sd/scripts/... mirroring the embedded path
    local dest_path = "/sd" .. self.file_path
    local dest_dir = dest_path:match("(.+)/[^/]+$")

    -- Create destination directory if needed
    if dest_dir and not ez.storage.exists(dest_dir) then
        local parts = {}
        for part in dest_dir:gmatch("[^/]+") do
            table.insert(parts, part)
        end
        local current = ""
        for _, part in ipairs(parts) do
            current = current .. "/" .. part
            if not ez.storage.exists(current) then
                ez.storage.mkdir(current)
            end
        end
    end

    -- Write current content (including any edits)
    local content = table.concat(self.lines, "\n")
    if ez.storage.write_file(dest_path, content) then
        self:show_message("Copied to " .. self:basename(dest_path))

        -- Switch to the new file (now editable)
        self.file_path = dest_path
        self.readonly = false
        self.modified = false
        return true
    else
        self:show_message("Copy failed!")
        return false
    end
end

function FileEdit:copy_to_fs()
    if not self.file_path then
        self:show_message("No filename!")
        return false
    end

    -- Destination is the same path on LittleFS
    local dest_path = self.file_path
    local dest_dir = dest_path:match("(.+)/[^/]+$")

    -- Create destination directory if needed
    if dest_dir and not ez.storage.exists(dest_dir) then
        local parts = {}
        for part in dest_dir:gmatch("[^/]+") do
            table.insert(parts, part)
        end
        local current = ""
        for _, part in ipairs(parts) do
            current = current .. "/" .. part
            if not ez.storage.exists(current) then
                ez.storage.mkdir(current)
            end
        end
    end

    -- Write current content (including any edits)
    local content = table.concat(self.lines, "\n")
    if ez.storage.write_file(dest_path, content) then
        self:show_message("Copied to FS: " .. self:basename(dest_path))

        -- Switch to the new file (now editable on LittleFS)
        self.readonly = false
        self.modified = false
        return true
    else
        self:show_message("Copy failed!")
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
        self:set_current_line(line .. self.lines[self.cursor_row + 1])
        table.remove(self.lines, self.cursor_row + 1)
    end
end

function FileEdit:backspace()
    if self.cursor_col > 1 then
        self.cursor_col = self.cursor_col - 1
        self:delete_char()
    elseif self.cursor_row > 1 then
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

-- Get the visual row offset for cursor position within a line
function FileEdit:get_cursor_visual_offset()
    return math.floor((self.cursor_col - 1) / self.wrap_width)
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
    return self:get_visual_row_before_line(self.cursor_row) + self:get_cursor_visual_offset()
end

function FileEdit:move_cursor(dr, dc)
    if dr ~= 0 then
        self.cursor_row = math.max(1, math.min(#self.lines, self.cursor_row + dr))
        self.cursor_col = math.min(self.cursor_col, #self:current_line() + 1)
    end

    if dc ~= 0 then
        self.cursor_col = self.cursor_col + dc
        local line_len = #self:current_line()

        if self.cursor_col < 1 then
            if self.cursor_row > 1 then
                self.cursor_row = self.cursor_row - 1
                self.cursor_col = #self:current_line() + 1
            else
                self.cursor_col = 1
            end
        elseif self.cursor_col > line_len + 1 then
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

    if cursor_visual < self.scroll_visual_row then
        self.scroll_visual_row = cursor_visual
    end

    if cursor_visual >= self.scroll_visual_row + visible_rows then
        self.scroll_visual_row = cursor_visual - visible_rows + 1
    end
end

-- Menu items for app menu integration
function FileEdit:get_menu_items()
    local self_ref = self
    local items = {}

    if self.readonly then
        -- Read-only file: offer Copy to SD/FS instead of Save
        if ez.storage.is_sd_available() then
            table.insert(items, {
                label = "Copy to SD",
                action = function()
                    self_ref:copy_to_sd()
                    ScreenManager.invalidate()
                end
            })
        end
        table.insert(items, {
            label = "Copy to FS",
            action = function()
                self_ref:copy_to_fs()
                ScreenManager.invalidate()
            end
        })
    else
        table.insert(items, {
            label = "Save",
            action = function()
                self_ref:save_file()
                ScreenManager.invalidate()
            end
        })
    end

    if self:is_lua_file() then
        table.insert(items, {
            label = "Run",
            action = function()
                if self_ref.modified and not self_ref.readonly then
                    self_ref:save_file()
                end
                local path = self_ref.file_path
                local ok, result = pcall(dofile, path)
                if ok then
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
        label = self_ref.wrap_enabled and "Wrap: On" or "Wrap: Off",
        action = function()
            self_ref.wrap_enabled = not self_ref.wrap_enabled
            self_ref.scroll_visual_row = 0
            self_ref.scroll_col = 0
            ScreenManager.invalidate()
        end
    })

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

-- Render a segment with Lua syntax highlighting
function FileEdit:render_lua_segment(display, segment, x, y, colors)
    local fw = display.get_font_width()
    local pos = 1
    local draw_x = x

    while pos <= #segment do
        local char = segment:sub(pos, pos)

        -- Comment
        if segment:sub(pos, pos + 1) == "--" then
            display.draw_text(draw_x, y, segment:sub(pos), colors.TEXT_MUTED)
            return
        end

        -- String
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
        -- Other
        else
            display.draw_text(draw_x, y, char, colors.TEXT)
            draw_x = draw_x + fw
            pos = pos + 1
        end
    end
end

function FileEdit:update_scroll_nowrap(visible_rows, visible_cols)
    -- Vertical scroll
    if self.cursor_row <= self.scroll_visual_row then
        self.scroll_visual_row = self.cursor_row - 1
    elseif self.cursor_row > self.scroll_visual_row + visible_rows then
        self.scroll_visual_row = self.cursor_row - visible_rows
    end
    -- Horizontal scroll
    if self.cursor_col <= self.scroll_col then
        self.scroll_col = self.cursor_col - 1
    elseif self.cursor_col > self.scroll_col + visible_cols then
        self.scroll_col = self.cursor_col - visible_cols
    end
end

function FileEdit:render(display)
    display.set_font_size("small")

    local colors = ListMixin.get_colors(display)
    local fw = display.get_font_width()
    local fh = display.get_font_height()
    local cols = display.get_cols()
    local rows = display.get_rows()

    local line_num_width = 4
    local visible_rows = rows - 3
    local visible_cols = cols - line_num_width - 1
    self.wrap_width = visible_cols

    ListMixin.draw_background(display)

    -- Header frame with filename
    local title = self:basename(self.file_path or "untitled")
    if self.readonly then
        title = title .. " [RO]"
    elseif self.modified then
        title = title .. " *"
    end
    display.draw_box(0, 0, cols, rows - 1, "", colors.ACCENT, colors.WHITE)
    display.draw_text_bg(fw, 0, title, colors.WHITE, colors.BLACK, 1)

    local text_x = (line_num_width + 1) * fw
    local is_lua = self:is_lua_file()

    if self.wrap_enabled then
        -- Soft wrap mode
        self:update_scroll(visible_rows)

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

        local skip_wraps = self.scroll_visual_row - visual_row
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

                if wrap_idx == 0 then
                    display.draw_text(fw, py, string.format("%3d ", line_idx), colors.TEXT_SECONDARY)
                else
                    display.draw_text(fw, py, "  + ", colors.TEXT_MUTED)
                end

                if #segment > 0 then
                    if is_lua then
                        self:render_lua_segment(display, segment, text_x, py, colors)
                    else
                        display.draw_text(text_x, py, segment, colors.TEXT)
                    end
                end

                if line_idx == self.cursor_row then
                    local cursor_wrap = self:get_cursor_visual_offset()
                    if cursor_wrap == wrap_idx then
                        local cursor_col_in_wrap = ((self.cursor_col - 1) % self.wrap_width)
                        local cursor_x = text_x + cursor_col_in_wrap * fw
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
    else
        -- No wrap mode (horizontal scroll)
        self:update_scroll_nowrap(visible_rows, visible_cols)

        for i = 1, visible_rows do
            local line_idx = self.scroll_visual_row + i
            local py = i * fh

            if line_idx <= #self.lines then
                display.draw_text(fw, py, string.format("%3d ", line_idx), colors.TEXT_SECONDARY)

                local line = self.lines[line_idx]
                local visible_part = line:sub(self.scroll_col + 1, self.scroll_col + visible_cols)

                if is_lua then
                    self:render_lua_segment(display, visible_part, text_x, py, colors)
                else
                    display.draw_text(text_x, py, visible_part, colors.TEXT)
                end

                if line_idx == self.cursor_row then
                    local cursor_x = text_x + (self.cursor_col - self.scroll_col - 1) * fw
                    if cursor_x >= text_x and cursor_x < (cols - 1) * fw then
                        display.fill_rect(cursor_x, py, fw, fh, colors.ACCENT)
                        local char_under = line:sub(self.cursor_col, self.cursor_col)
                        if char_under == "" then char_under = " " end
                        display.draw_text(cursor_x, py, char_under, colors.BLACK)
                    end
                end
            else
                display.draw_text(fw, py, "  ~ ", colors.TEXT_MUTED)
            end
        end
    end

    -- Fill remaining rows with empty indicators (wrap mode only)
    if self.wrap_enabled then
        local screen_row = visible_rows + 1
        -- (already handled in loop)
    end

    -- Status bar
    local status_y = (rows - 2) * fh
    if self.message and (ez.system.millis() - self.message_time) < 2000 then
        display.draw_text(fw, status_y, self.message, colors.TEXT_SECONDARY)
    else
        self.message = nil
        display.draw_text(fw, status_y, string.format("L%d C%d", self.cursor_row, self.cursor_col), colors.TEXT_SECONDARY)
    end
end

function FileEdit:handle_key(key)
    ScreenManager.invalidate()

    if key.special == "UP" then
        self:move_cursor(-1, 0)
    elseif key.special == "DOWN" then
        self:move_cursor(1, 0)
    elseif key.special == "LEFT" then
        self:move_cursor(0, -1)
    elseif key.special == "RIGHT" then
        self:move_cursor(0, 1)
    elseif key.special == "ENTER" then
        if not self.readonly then
            self:insert_newline()
        end
    elseif key.special == "BACKSPACE" then
        if not self.readonly then
            self:backspace()
        end
    elseif key.special == "DELETE" then
        if not self.readonly then
            self:delete_char()
        end
    elseif key.special == "HOME" then
        self.cursor_col = 1
    elseif key.special == "END" then
        self.cursor_col = #self:current_line() + 1
    elseif key.special == "PAGE_UP" then
        self:move_cursor(-10, 0)
    elseif key.special == "PAGE_DOWN" then
        self:move_cursor(10, 0)
    elseif key.special == "ESCAPE" then
        if self.readonly or not self.modified then
            return "pop"
        else
            self:show_message("Unsaved! Use menu to quit")
        end
    elseif key.character and #key.character == 1 then
        if not self.readonly then
            local byte = key.character:byte()
            if byte >= 32 and byte < 127 then
                self:insert_char(key.character)
            elseif key.character == "\t" then
                self:insert_char("    ")
            end
        end
    end

    return "continue"
end

return FileEdit
