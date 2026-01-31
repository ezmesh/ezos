-- file_edit.lua - Basic nano-like text editor
-- Supports viewing and editing text files

local FileEdit = {
    title = "Edit",
    file_path = nil,
    lines = {},
    cursor_row = 1,
    cursor_col = 1,
    scroll_row = 0,
    scroll_col = 0,
    modified = false,
    message = nil,
    message_time = 0
}

function FileEdit:new(path)
    local o = {
        title = "Edit",
        file_path = path or nil,
        lines = {""},
        cursor_row = 1,
        cursor_col = 1,
        scroll_row = 0,
        scroll_col = 0,
        modified = false,
        message = nil,
        message_time = 0
    }
    setmetatable(o, {__index = FileEdit})
    return o
end

function FileEdit:on_enter()
    if self.file_path then
        self:load_file(self.file_path)
    end
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
    self.scroll_row = 0
    self.scroll_col = 0
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
    self.cursor_col = self.cursor_col + 1
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

function FileEdit:update_scroll_with_dims(rows, cols)
    local visible_rows = rows - 3  -- Header and status lines
    local visible_cols = cols - 6  -- Line numbers and margins

    -- Vertical scroll
    if self.cursor_row <= self.scroll_row then
        self.scroll_row = self.cursor_row - 1
    elseif self.cursor_row > self.scroll_row + visible_rows then
        self.scroll_row = self.cursor_row - visible_rows
    end

    -- Horizontal scroll
    if self.cursor_col <= self.scroll_col then
        self.scroll_col = self.cursor_col - 1
    elseif self.cursor_col > self.scroll_col + visible_cols then
        self.scroll_col = self.cursor_col - visible_cols
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

function FileEdit:render(display)
    -- Ensure medium font (status bar may have changed to small)
    display.set_font_size("medium")

    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local fw = display.get_font_width()
    local fh = display.get_font_height()
    local cols = display.get_cols()
    local rows = display.get_rows()

    self:update_scroll_with_dims(rows, cols)

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    -- Header
    local title = self:basename(self.file_path or "untitled")
    if self.modified then
        title = title .. " *"
    end
    display.draw_box(0, 0, cols, rows - 1, title, colors.ACCENT, colors.WHITE)

    -- Text area
    local visible_rows = rows - 3
    local visible_cols = cols - 6
    local line_num_width = 4

    for i = 1, visible_rows do
        local line_idx = self.scroll_row + i
        local py = i * fh

        if line_idx <= #self.lines then
            -- Line number
            local line_num = string.format("%3d ", line_idx)
            display.draw_text(fw, py, line_num, colors.TEXT_SECONDARY)

            -- Line content
            local line = self.lines[line_idx]
            local visible_part = line:sub(self.scroll_col + 1, self.scroll_col + visible_cols)
            display.draw_text((line_num_width + 1) * fw, py, visible_part, colors.TEXT)

            -- Cursor
            if line_idx == self.cursor_row then
                local cursor_x = (line_num_width + self.cursor_col - self.scroll_col) * fw
                if cursor_x > line_num_width * fw and cursor_x < (cols - 1) * fw then
                    -- Draw cursor as inverse block
                    display.fill_rect(cursor_x, py, fw, fh, colors.ACCENT)
                    local char_under = line:sub(self.cursor_col, self.cursor_col)
                    if char_under == "" then char_under = " " end
                    display.draw_text(cursor_x, py, char_under, colors.BLACK)
                end
            end
        else
            -- Empty line indicator
            display.draw_text(fw, py, "  ~ ", colors.TEXT_MUTED)
        end
    end

    -- Status bar (only show messages, position is in header)
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
