-- edit.lua - Basic nano-like text editor
-- Supports viewing and editing text files

local Edit = {
    title = "Edit",
    file_path = nil,
    lines = {},
    cursor_row = 1,
    cursor_col = 1,
    scroll_row = 0,
    scroll_col = 0,
    modified = false,
    message = nil,
    message_time = 0,
    menu_mode = false,
    menu_selected = 1,
    menu_items = {"Save", "Quit", "Quit!", "Back"}
}

function Edit:new(path)
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
        message_time = 0,
        menu_mode = false,
        menu_selected = 1,
        menu_items = {"Save", "Quit", "Quit!", "Back"}
    }
    setmetatable(o, {__index = Edit})
    return o
end

function Edit:on_enter()
    if self.file_path then
        self:load_file(self.file_path)
    end
end

function Edit:load_file(path)
    self.file_path = path
    self.lines = {}

    local content = tdeck.storage.read_file(path)
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

function Edit:save_file()
    if not self.file_path then
        self:show_message("No filename!")
        return false
    end

    local content = table.concat(self.lines, "\n")
    if tdeck.storage.write_file(self.file_path, content) then
        self.modified = false
        self:show_message("Saved: " .. self:basename(self.file_path))
        return true
    else
        self:show_message("Save failed!")
        return false
    end
end

function Edit:basename(path)
    return path:match("([^/]+)$") or path
end

function Edit:show_message(msg)
    self.message = msg
    self.message_time = tdeck.system.millis()
end

function Edit:current_line()
    return self.lines[self.cursor_row] or ""
end

function Edit:set_current_line(text)
    self.lines[self.cursor_row] = text
    self.modified = true
end

function Edit:insert_char(char)
    local line = self:current_line()
    local before = line:sub(1, self.cursor_col - 1)
    local after = line:sub(self.cursor_col)
    self:set_current_line(before .. char .. after)
    self.cursor_col = self.cursor_col + 1
end

function Edit:delete_char()
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

function Edit:backspace()
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

function Edit:insert_newline()
    local line = self:current_line()
    local before = line:sub(1, self.cursor_col - 1)
    local after = line:sub(self.cursor_col)
    self:set_current_line(before)
    table.insert(self.lines, self.cursor_row + 1, after)
    self.cursor_row = self.cursor_row + 1
    self.cursor_col = 1
end

function Edit:move_cursor(dr, dc)
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

function Edit:update_scroll(display)
    local visible_rows = display.rows - 3  -- Header and status lines
    local visible_cols = display.cols - 6  -- Line numbers and margins

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

function Edit:render(display)
    local colors = display.colors
    self:update_scroll(display)

    -- Header
    local title = self:basename(self.file_path or "untitled")
    if self.modified then
        title = title .. " *"
    end
    display.draw_box(0, 0, display.cols, display.rows - 1, title, colors.CYAN, colors.WHITE)

    -- Text area
    local visible_rows = display.rows - 3
    local visible_cols = display.cols - 6
    local line_num_width = 4

    for i = 1, visible_rows do
        local line_idx = self.scroll_row + i
        local py = (i) * display.font_height

        if line_idx <= #self.lines then
            -- Line number
            local line_num = string.format("%3d ", line_idx)
            display.draw_text(display.font_width, py, line_num, colors.TEXT_DIM)

            -- Line content
            local line = self.lines[line_idx]
            local visible_part = line:sub(self.scroll_col + 1, self.scroll_col + visible_cols)
            display.draw_text((line_num_width + 1) * display.font_width, py, visible_part, colors.TEXT)

            -- Cursor
            if line_idx == self.cursor_row then
                local cursor_x = (line_num_width + self.cursor_col - self.scroll_col) * display.font_width
                if cursor_x > line_num_width * display.font_width and
                   cursor_x < (display.cols - 1) * display.font_width then
                    -- Draw cursor as inverse block
                    display.fill_rect(cursor_x, py, display.font_width, display.font_height, colors.CYAN)
                    local char_under = line:sub(self.cursor_col, self.cursor_col)
                    if char_under == "" then char_under = " " end
                    display.draw_text(cursor_x, py, char_under, colors.BLACK)
                end
            end
        else
            -- Empty line indicator
            display.draw_text(display.font_width, py, "  ~ ", colors.TEXT_DIM)
        end
    end

    -- Status/Menu bar
    local status_y = (display.rows - 2) * display.font_height

    if self.menu_mode then
        -- Draw menu options
        local menu_x = display.font_width
        for i, item in ipairs(self.menu_items) do
            local label = "[" .. item .. "]"
            if i == self.menu_selected then
                display.draw_text(menu_x, status_y, label, colors.CYAN)
            else
                display.draw_text(menu_x, status_y, label, colors.TEXT_DIM)
            end
            menu_x = menu_x + (#label + 1) * display.font_width
        end
    else
        -- Show message or default status
        local status_text
        if self.message and (tdeck.system.millis() - self.message_time) < 2000 then
            status_text = self.message
        else
            status_text = string.format("L%d C%d  Bksp@start=Menu", self.cursor_row, self.cursor_col)
            self.message = nil
        end
        display.draw_text(display.font_width, status_y, status_text, colors.TEXT_DIM)
    end
end

function Edit:handle_key(key)
    tdeck.screen.invalidate()

    -- Menu mode handling
    if self.menu_mode then
        if key.special == "LEFT" then
            self.menu_selected = self.menu_selected - 1
            if self.menu_selected < 1 then
                self.menu_selected = #self.menu_items
            end
        elseif key.special == "RIGHT" then
            self.menu_selected = self.menu_selected + 1
            if self.menu_selected > #self.menu_items then
                self.menu_selected = 1
            end
        elseif key.special == "ENTER" then
            local action = self.menu_items[self.menu_selected]
            if action == "Save" then
                self:save_file()
                self.menu_mode = false
            elseif action == "Quit" then
                if self.modified then
                    self:show_message("Unsaved! Use Quit! to discard")
                    self.menu_mode = false
                else
                    return "pop"
                end
            elseif action == "Quit!" then
                -- Force quit without saving
                return "pop"
            elseif action == "Back" then
                self.menu_mode = false
            end
        elseif key.special == "BACKSPACE" then
            -- Backspace also closes menu
            self.menu_mode = false
        end
        return "continue"
    end

    -- Special keys (editing mode)
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
        -- Open menu when at very start of file (can't backspace further)
        if self.cursor_row == 1 and self.cursor_col == 1 then
            self.menu_mode = true
            self.menu_selected = 1
        else
            self:backspace()
        end
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

return Edit
