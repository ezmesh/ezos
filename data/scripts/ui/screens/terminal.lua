-- Terminal Emulator with Lua REPL
-- Interactive shell for running Lua code and basic navigation

local Terminal = {
    title = "Terminal",

    -- Display settings
    FONT_SIZE = "small",
    LINE_HEIGHT = 12,
    MAX_LINES = 100,
    VISIBLE_LINES = 14,
    PROMPT = "> ",

    -- Colors
    COLOR_PROMPT = 0x07E0,    -- Green
    COLOR_OUTPUT = 0xFFFF,    -- White
    COLOR_ERROR = 0xF800,     -- Red
    COLOR_INFO = 0x07FF,      -- Cyan
    COLOR_RESULT = 0xFFE0,    -- Yellow
}

function Terminal:new()
    local o = {
        title = self.title,
        lines = {},           -- Output lines: {text, color}
        input = "",           -- Current input line
        history = {},         -- Command history
        history_idx = 0,      -- Current position in history (0 = new input)
        scroll_offset = 0,    -- Scroll position
        cwd = "/sd",          -- Current working directory
        cursor_pos = 0,       -- Cursor position in input
        cursor_visible = true,
        cursor_timer = 0,
    }
    setmetatable(o, {__index = Terminal})

    -- Welcome message
    o:print_line("ezOS Terminal v1.0", self.COLOR_INFO)
    o:print_line("Type 'help' for commands", self.COLOR_INFO)
    o:print_line("", self.COLOR_OUTPUT)

    return o
end

function Terminal:on_enter()
    ez.keyboard.set_mode("typing")
end

function Terminal:on_exit()
    ez.keyboard.set_mode("normal")
end

function Terminal:print_line(text, color)
    table.insert(self.lines, {text = text, color = color or self.COLOR_OUTPUT})

    -- Trim old lines if too many
    while #self.lines > self.MAX_LINES do
        table.remove(self.lines, 1)
    end

    -- Auto-scroll to bottom
    self:scroll_to_bottom()
end

function Terminal:scroll_to_bottom()
    local total = #self.lines + 1  -- +1 for input line
    if total > self.VISIBLE_LINES then
        self.scroll_offset = total - self.VISIBLE_LINES
    else
        self.scroll_offset = 0
    end
end

function Terminal:execute(cmd)
    -- Add to history
    if cmd ~= "" then
        table.insert(self.history, cmd)
        if #self.history > 50 then
            table.remove(self.history, 1)
        end
    end
    self.history_idx = 0

    -- Echo command
    self:print_line(self.PROMPT .. cmd, self.COLOR_PROMPT)

    -- Parse command
    local parts = {}
    for part in cmd:gmatch("%S+") do
        table.insert(parts, part)
    end

    if #parts == 0 then return end

    local command = parts[1]

    -- Built-in commands
    if command == "help" then
        self:cmd_help()
    elseif command == "ls" then
        self:cmd_ls(parts[2])
    elseif command == "cd" then
        self:cmd_cd(parts[2])
    elseif command == "pwd" then
        self:print_line(self.cwd, self.COLOR_OUTPUT)
    elseif command == "cat" then
        self:cmd_cat(parts[2])
    elseif command == "clear" then
        self.lines = {}
        self.scroll_offset = 0
    elseif command == "run" then
        self:cmd_run(parts[2])
    elseif command == "mem" then
        self:cmd_mem()
    elseif command == "exit" then
        ScreenManager.pop()
        return
    else
        -- Try to execute as Lua
        self:execute_lua(cmd)
    end
end

function Terminal:cmd_help()
    self:print_line("Built-in commands:", self.COLOR_INFO)
    self:print_line("  help        - Show this help", self.COLOR_OUTPUT)
    self:print_line("  ls [path]   - List directory", self.COLOR_OUTPUT)
    self:print_line("  cd <path>   - Change directory", self.COLOR_OUTPUT)
    self:print_line("  pwd         - Print working directory", self.COLOR_OUTPUT)
    self:print_line("  cat <file>  - Display file contents", self.COLOR_OUTPUT)
    self:print_line("  run <file>  - Execute Lua script", self.COLOR_OUTPUT)
    self:print_line("  mem         - Show memory usage", self.COLOR_OUTPUT)
    self:print_line("  clear       - Clear screen", self.COLOR_OUTPUT)
    self:print_line("  exit        - Exit terminal", self.COLOR_OUTPUT)
    self:print_line("", self.COLOR_OUTPUT)
    self:print_line("Or type Lua code directly:", self.COLOR_INFO)
    self:print_line("  1 + 1", self.COLOR_OUTPUT)
    self:print_line("  print('hello')", self.COLOR_OUTPUT)
    self:print_line("  ez.system.get_time()", self.COLOR_OUTPUT)
end

function Terminal:resolve_path(path)
    if not path then return self.cwd end

    -- Absolute path
    if path:sub(1, 1) == "/" then
        return path
    end

    -- Handle .. and .
    if path == ".." then
        local parent = self.cwd:match("(.+)/[^/]+$")
        return parent or "/"
    elseif path == "." then
        return self.cwd
    end

    -- Relative path
    if self.cwd == "/" then
        return "/" .. path
    else
        return self.cwd .. "/" .. path
    end
end

function Terminal:cmd_ls(path)
    local target = self:resolve_path(path)

    -- Try to list directory
    local entries = ez.storage.list_dir(target)
    if not entries then
        self:print_line("Cannot access: " .. target, self.COLOR_ERROR)
        return
    end

    if #entries == 0 then
        self:print_line("(empty)", self.COLOR_INFO)
        return
    end

    -- Sort: directories first, then files
    table.sort(entries, function(a, b)
        if a.is_dir ~= b.is_dir then
            return a.is_dir
        end
        return a.name < b.name
    end)

    for _, entry in ipairs(entries) do
        local suffix = entry.is_dir and "/" or ""
        local color = entry.is_dir and self.COLOR_INFO or self.COLOR_OUTPUT
        local size_str = ""
        if not entry.is_dir and entry.size then
            if entry.size < 1024 then
                size_str = string.format(" %dB", entry.size)
            else
                size_str = string.format(" %dK", math.floor(entry.size / 1024))
            end
        end
        self:print_line(entry.name .. suffix .. size_str, color)
    end
end

function Terminal:cmd_cd(path)
    if not path then
        self:print_line("Usage: cd <path>", self.COLOR_ERROR)
        return
    end

    local target = self:resolve_path(path)

    -- Verify directory exists
    local entries = ez.storage.list_dir(target)
    if entries then
        self.cwd = target
        self:print_line(self.cwd, self.COLOR_INFO)
    else
        self:print_line("Not a directory: " .. target, self.COLOR_ERROR)
    end
end

function Terminal:cmd_cat(path)
    if not path then
        self:print_line("Usage: cat <file>", self.COLOR_ERROR)
        return
    end

    local target = self:resolve_path(path)
    local content = ez.storage.read_file(target)

    if not content then
        self:print_line("Cannot read: " .. target, self.COLOR_ERROR)
        return
    end

    -- Print each line
    for line in content:gmatch("([^\n]*)\n?") do
        if line ~= "" or content:find("\n") then
            self:print_line(line, self.COLOR_OUTPUT)
        end
    end
end

function Terminal:cmd_run(path)
    if not path then
        self:print_line("Usage: run <script.lua>", self.COLOR_ERROR)
        return
    end

    local target = self:resolve_path(path)

    -- Check if file exists
    local content = ez.storage.read_file(target)
    if not content then
        self:print_line("Cannot read: " .. target, self.COLOR_ERROR)
        return
    end

    self:print_line("Running: " .. target, self.COLOR_INFO)

    -- Execute in a coroutine so async functions work
    local self_ref = self
    spawn(function()
        -- Create a custom print function for this script
        local old_print = _G.print
        _G.print = function(...)
            local args = {...}
            local parts = {}
            for i = 1, select('#', ...) do
                parts[i] = tostring(args[i])
            end
            self_ref:print_line(table.concat(parts, "\t"), self_ref.COLOR_OUTPUT)
            ScreenManager.invalidate()
        end

        -- Load and run the script
        local fn, err = load(content, target, "t")
        if not fn then
            self_ref:print_line("Load error: " .. tostring(err), self_ref.COLOR_ERROR)
            _G.print = old_print
            ScreenManager.invalidate()
            return
        end

        local ok, result = pcall(fn)
        if not ok then
            self_ref:print_line("Error: " .. tostring(result), self_ref.COLOR_ERROR)
        elseif result ~= nil then
            self_ref:print_line("= " .. tostring(result), self_ref.COLOR_RESULT)
        end

        _G.print = old_print
        ScreenManager.invalidate()
    end)
end

function Terminal:cmd_mem()
    local info = ez.system.memory_info()
    if info then
        self:print_line(string.format("Free heap: %d KB", math.floor(info.free_heap / 1024)), self.COLOR_OUTPUT)
        self:print_line(string.format("Free PSRAM: %d KB", math.floor(info.free_psram / 1024)), self.COLOR_OUTPUT)
        self:print_line(string.format("Lua mem: %d KB", math.floor((info.lua_memory or 0) / 1024)), self.COLOR_OUTPUT)
    else
        self:print_line("Memory info not available", self.COLOR_ERROR)
    end
end

function Terminal:execute_lua(code)
    -- Try as expression first (return value)
    local fn, err = load("return " .. code, "=stdin", "t")
    if not fn then
        -- Try as statement
        fn, err = load(code, "=stdin", "t")
    end

    if not fn then
        self:print_line("Syntax error: " .. tostring(err), self.COLOR_ERROR)
        return
    end

    -- Execute in coroutine for async support
    local self_ref = self
    spawn(function()
        -- Redirect print
        local old_print = _G.print
        _G.print = function(...)
            local args = {...}
            local parts = {}
            for i = 1, select('#', ...) do
                parts[i] = tostring(args[i])
            end
            self_ref:print_line(table.concat(parts, "\t"), self_ref.COLOR_OUTPUT)
            ScreenManager.invalidate()
        end

        local results = {pcall(fn)}
        local ok = results[1]

        if not ok then
            self_ref:print_line("Error: " .. tostring(results[2]), self_ref.COLOR_ERROR)
        else
            -- Print return values
            for i = 2, #results do
                if results[i] ~= nil then
                    local val = results[i]
                    local str
                    if type(val) == "table" then
                        -- Simple table display
                        local parts = {}
                        local count = 0
                        for k, v in pairs(val) do
                            count = count + 1
                            if count > 10 then
                                table.insert(parts, "...")
                                break
                            end
                            table.insert(parts, tostring(k) .. "=" .. tostring(v))
                        end
                        str = "{" .. table.concat(parts, ", ") .. "}"
                    else
                        str = tostring(val)
                    end
                    self_ref:print_line("= " .. str, self_ref.COLOR_RESULT)
                end
            end
        end

        _G.print = old_print
        ScreenManager.invalidate()
    end)
end

function Terminal:render(display)
    local w = display.width
    local h = display.height

    -- Background
    display.fill_rect(0, 0, w, h, 0x0000)  -- Black

    -- Title bar
    TitleBar.draw(display, self.title .. " [" .. self.cwd .. "]")

    local y_start = 26
    local x_margin = 4
    local max_width = w - x_margin * 2

    display.set_font_size(self.FONT_SIZE)

    -- Draw output lines
    local y = y_start
    local start_idx = self.scroll_offset + 1
    local line_count = 0

    for i = start_idx, #self.lines do
        if line_count >= self.VISIBLE_LINES - 1 then break end  -- Leave room for input

        local line = self.lines[i]
        display.draw_text(x_margin, y, line.text, line.color)
        y = y + self.LINE_HEIGHT
        line_count = line_count + 1
    end

    -- Draw input line at bottom
    local input_y = y_start + (self.VISIBLE_LINES - 1) * self.LINE_HEIGHT
    local input_text = self.PROMPT .. self.input
    display.draw_text(x_margin, input_y, input_text, self.COLOR_PROMPT)

    -- Draw cursor
    self.cursor_timer = (self.cursor_timer + 1) % 30
    if self.cursor_timer < 15 then
        local cursor_x = x_margin + display.text_width(self.PROMPT .. self.input:sub(1, self.cursor_pos))
        display.fill_rect(cursor_x, input_y, 2, self.LINE_HEIGHT - 2, self.COLOR_PROMPT)
    end

    -- Scrollbar if needed
    local total_lines = #self.lines + 1
    if total_lines > self.VISIBLE_LINES then
        local sb_x = w - 6
        local sb_height = h - y_start - 4
        local thumb_height = math.max(10, math.floor(sb_height * self.VISIBLE_LINES / total_lines))
        local thumb_y = y_start + math.floor(self.scroll_offset * (sb_height - thumb_height) / (total_lines - self.VISIBLE_LINES))

        display.fill_rect(sb_x, y_start, 4, sb_height, 0x2104)  -- Dark gray track
        display.fill_rect(sb_x, thumb_y, 4, thumb_height, 0x7BEF)  -- Light gray thumb
    end
end

function Terminal:handle_key(key)
    -- Special keys
    if key.special == "ESCAPE" then
        ScreenManager.pop()
        return "continue"
    end

    if key.special == "ENTER" then
        local cmd = self.input
        self.input = ""
        self.cursor_pos = 0
        self:execute(cmd)
        ScreenManager.invalidate()
        return "continue"
    end

    if key.special == "BACKSPACE" then
        if self.cursor_pos > 0 then
            self.input = self.input:sub(1, self.cursor_pos - 1) .. self.input:sub(self.cursor_pos + 1)
            self.cursor_pos = self.cursor_pos - 1
        end
        ScreenManager.invalidate()
        return "continue"
    end

    if key.special == "DELETE" then
        if self.cursor_pos < #self.input then
            self.input = self.input:sub(1, self.cursor_pos) .. self.input:sub(self.cursor_pos + 2)
        end
        ScreenManager.invalidate()
        return "continue"
    end

    if key.special == "LEFT" then
        if self.cursor_pos > 0 then
            self.cursor_pos = self.cursor_pos - 1
        end
        ScreenManager.invalidate()
        return "continue"
    end

    if key.special == "RIGHT" then
        if self.cursor_pos < #self.input then
            self.cursor_pos = self.cursor_pos + 1
        end
        ScreenManager.invalidate()
        return "continue"
    end

    if key.special == "UP" then
        -- Command history navigation
        if #self.history > 0 then
            if self.history_idx == 0 then
                self.saved_input = self.input
            end
            if self.history_idx < #self.history then
                self.history_idx = self.history_idx + 1
                self.input = self.history[#self.history - self.history_idx + 1]
                self.cursor_pos = #self.input
            end
        end
        ScreenManager.invalidate()
        return "continue"
    end

    if key.special == "DOWN" then
        if self.history_idx > 0 then
            self.history_idx = self.history_idx - 1
            if self.history_idx == 0 then
                self.input = self.saved_input or ""
            else
                self.input = self.history[#self.history - self.history_idx + 1]
            end
            self.cursor_pos = #self.input
        end
        ScreenManager.invalidate()
        return "continue"
    end

    -- Page up/down for scrolling output
    if key.special == "PAGE_UP" or (key.ctrl and key.character == "u") then
        self.scroll_offset = math.max(0, self.scroll_offset - self.VISIBLE_LINES)
        ScreenManager.invalidate()
        return "continue"
    end

    if key.special == "PAGE_DOWN" or (key.ctrl and key.character == "d") then
        local max_scroll = math.max(0, #self.lines + 1 - self.VISIBLE_LINES)
        self.scroll_offset = math.min(max_scroll, self.scroll_offset + self.VISIBLE_LINES)
        ScreenManager.invalidate()
        return "continue"
    end

    -- Tab completion (basic)
    if key.special == "TAB" then
        self:tab_complete()
        ScreenManager.invalidate()
        return "continue"
    end

    -- Character input
    if key.character and #key.character == 1 then
        self.input = self.input:sub(1, self.cursor_pos) .. key.character .. self.input:sub(self.cursor_pos + 1)
        self.cursor_pos = self.cursor_pos + 1
        ScreenManager.invalidate()
    end

    return "continue"
end

function Terminal:tab_complete()
    -- Simple path completion
    local parts = {}
    for part in self.input:gmatch("%S+") do
        table.insert(parts, part)
    end

    if #parts == 0 then return end

    local last = parts[#parts]
    local dir, prefix

    if last:find("/") then
        dir = last:match("(.*/)")
        prefix = last:match(".*/(.*)$") or ""
        dir = self:resolve_path(dir)
    else
        dir = self.cwd
        prefix = last
    end

    local entries = ez.storage.list_dir(dir)
    if not entries then return end

    -- Find matches
    local matches = {}
    for _, entry in ipairs(entries) do
        if entry.name:sub(1, #prefix) == prefix then
            table.insert(matches, entry.name .. (entry.is_dir and "/" or ""))
        end
    end

    if #matches == 1 then
        -- Single match - complete it
        local completion = matches[1]:sub(#prefix + 1)
        self.input = self.input .. completion
        self.cursor_pos = #self.input
    elseif #matches > 1 then
        -- Multiple matches - show them
        self:print_line("", self.COLOR_OUTPUT)
        for _, m in ipairs(matches) do
            self:print_line(m, self.COLOR_INFO)
        end
    end
end

return Terminal
