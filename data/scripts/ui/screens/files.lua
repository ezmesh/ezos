-- files.lua - Basic file explorer
-- Browse files, run Lua scripts, edit text files

local Files = {
    title = "Files",
    current_path = "/",
    entries = {},
    selected = 1,
    scroll = 0,
    message = nil,
    message_time = 0
}

function Files:new(start_path)
    local o = {
        title = "Files",
        current_path = start_path or "/",
        entries = {},
        selected = 1,
        scroll = 0,
        message = nil,
        message_time = 0
    }
    setmetatable(o, {__index = Files})
    return o
end

function Files:on_enter()
    self:load_directory(self.current_path)
end

function Files:show_message(msg)
    self.message = msg
    self.message_time = tdeck.system.millis()
end

function Files:load_directory(path)
    self.current_path = path
    self.entries = {}
    self.selected = 1
    self.scroll = 0

    -- Add parent directory entry (except for root)
    if path ~= "/" then
        table.insert(self.entries, {
            name = "..",
            is_dir = true,
            size = 0
        })
    end

    -- List directory contents
    local items = tdeck.storage.list_dir(path)
    if items then
        -- Sort: directories first, then files
        local dirs = {}
        local files = {}

        for _, item in ipairs(items) do
            if item.is_dir then
                table.insert(dirs, item)
            else
                table.insert(files, item)
            end
        end

        -- Sort each group alphabetically
        table.sort(dirs, function(a, b) return a.name < b.name end)
        table.sort(files, function(a, b) return a.name < b.name end)

        -- Add directories then files
        for _, item in ipairs(dirs) do
            table.insert(self.entries, item)
        end
        for _, item in ipairs(files) do
            table.insert(self.entries, item)
        end
    end

    if #self.entries == 0 then
        self:show_message("Empty directory")
    end
end

function Files:get_full_path(entry)
    if self.current_path == "/" then
        return "/" .. entry.name
    else
        return self.current_path .. "/" .. entry.name
    end
end

function Files:get_parent_path()
    if self.current_path == "/" then
        return "/"
    end
    local parent = self.current_path:match("(.+)/[^/]+$")
    return parent or "/"
end

function Files:format_size(size)
    if size < 1024 then
        return string.format("%dB", size)
    elseif size < 1024 * 1024 then
        return string.format("%.1fK", size / 1024)
    else
        return string.format("%.1fM", size / (1024 * 1024))
    end
end

function Files:is_lua_file(name)
    return name:match("%.lua$") ~= nil
end

function Files:is_text_file(name)
    local ext = name:match("%.([^.]+)$")
    if not ext then return true end  -- No extension = assume text
    ext = ext:lower()
    local text_exts = {
        lua = true, txt = true, md = true, json = true,
        xml = true, html = true, css = true, js = true,
        h = true, c = true, cpp = true, py = true,
        sh = true, ini = true, cfg = true, conf = true,
        log = true, csv = true
    }
    return text_exts[ext] or false
end

function Files:open_entry()
    if #self.entries == 0 then return end

    local entry = self.entries[self.selected]

    if entry.name == ".." then
        self:load_directory(self:get_parent_path())
    elseif entry.is_dir then
        self:load_directory(self:get_full_path(entry))
    else
        -- It's a file - offer options
        local path = self:get_full_path(entry)

        if self:is_text_file(entry.name) then
            -- Open in editor
            local Edit = dofile("/scripts/ui/screens/edit.lua")
            tdeck.screen.push(Edit:new(path))
        else
            self:show_message("Cannot open: " .. entry.name)
        end
    end
end

function Files:run_lua_file()
    if #self.entries == 0 then return end

    local entry = self.entries[self.selected]
    if entry.is_dir then
        self:show_message("Cannot run directory")
        return
    end

    if not self:is_lua_file(entry.name) then
        self:show_message("Not a Lua file")
        return
    end

    local path = self:get_full_path(entry)
    self:show_message("Running: " .. entry.name)

    -- Try to load and run the script
    local ok, result = pcall(dofile, path)
    if ok then
        if type(result) == "table" and result.new then
            -- It's a screen module, push it
            local screen = result:new()
            tdeck.screen.push(screen)
        else
            self:show_message("Script executed")
        end
    else
        self:show_message("Error: " .. tostring(result):sub(1, 30))
    end
end

function Files:delete_entry()
    if #self.entries == 0 then return end

    local entry = self.entries[self.selected]
    if entry.name == ".." then
        self:show_message("Cannot delete ..")
        return
    end

    local path = self:get_full_path(entry)

    -- For now just show a message - actual delete would need confirmation
    self:show_message("Delete not implemented (safety)")
end

function Files:update_scroll(visible_rows)
    if self.selected <= self.scroll then
        self.scroll = self.selected - 1
    elseif self.selected > self.scroll + visible_rows then
        self.scroll = self.selected - visible_rows
    end
end

function Files:render(display)
    local colors = display.colors

    -- Header with current path
    local title = self.current_path
    if #title > display.cols - 4 then
        title = "..." .. title:sub(-(display.cols - 7))
    end
    display.draw_box(0, 0, display.cols, display.rows - 1, title, colors.CYAN, colors.WHITE)

    local visible_rows = display.rows - 4
    self:update_scroll(visible_rows)

    -- File list
    for i = 1, visible_rows do
        local idx = self.scroll + i
        local py = i * display.font_height

        if idx <= #self.entries then
            local entry = self.entries[idx]
            local is_selected = (idx == self.selected)

            -- Selection highlight
            if is_selected then
                display.fill_rect(display.font_width, py,
                                (display.cols - 2) * display.font_width,
                                display.font_height, colors.SELECTION)
                display.draw_text(display.font_width, py, ">", colors.CYAN)
            end

            -- Icon/prefix
            local prefix = "  "
            local name_color = colors.TEXT
            if entry.is_dir then
                prefix = "/ "
                name_color = is_selected and colors.CYAN or colors.YELLOW
            elseif self:is_lua_file(entry.name) then
                prefix = "* "
                name_color = is_selected and colors.CYAN or colors.GREEN
            end

            -- Name (truncate if needed)
            local max_name_len = display.cols - 12
            local name = entry.name
            if #name > max_name_len then
                name = name:sub(1, max_name_len - 2) .. ".."
            end

            display.draw_text(2 * display.font_width, py, prefix .. name, name_color)

            -- Size for files
            if not entry.is_dir and entry.size then
                local size_str = self:format_size(entry.size)
                local size_x = (display.cols - #size_str - 1) * display.font_width
                display.draw_text(size_x, py, size_str, colors.TEXT_DIM)
            end
        end
    end

    -- Status/help bar
    local status_y = (display.rows - 2) * display.font_height
    local help_text

    if self.message and (tdeck.system.millis() - self.message_time) < 2000 then
        help_text = self.message
    else
        help_text = "[Enter]Open [R]Run [E]Edit [Esc]Back"
        self.message = nil
    end

    display.draw_text(display.font_width, status_y, help_text, colors.TEXT_DIM)
end

function Files:handle_key(key)
    tdeck.screen.invalidate()

    if key.special == "UP" then
        if self.selected > 1 then
            self.selected = self.selected - 1
        end
    elseif key.special == "DOWN" then
        if self.selected < #self.entries then
            self.selected = self.selected + 1
        end
    elseif key.special == "ENTER" then
        self:open_entry()
    elseif key.special == "ESCAPE" then
        return "pop"
    elseif key.special == "LEFT" or key.special == "BACKSPACE" then
        -- Go to parent directory
        if self.current_path ~= "/" then
            self:load_directory(self:get_parent_path())
        end
    elseif key.special == "RIGHT" then
        -- Enter directory or open file
        self:open_entry()
    elseif key.character == "r" or key.character == "R" then
        self:run_lua_file()
    elseif key.character == "e" or key.character == "E" then
        -- Edit current file
        if #self.entries > 0 then
            local entry = self.entries[self.selected]
            if not entry.is_dir then
                local path = self:get_full_path(entry)
                local Edit = dofile("/scripts/ui/screens/edit.lua")
                tdeck.screen.push(Edit:new(path))
            end
        end
    elseif key.character == "n" or key.character == "N" then
        -- New file - open editor with path in current directory
        local Edit = dofile("/scripts/ui/screens/edit.lua")
        local new_path = self.current_path
        if new_path ~= "/" then
            new_path = new_path .. "/"
        end
        new_path = new_path .. "new.lua"
        tdeck.screen.push(Edit:new(new_path))
    elseif key.character == "g" or key.character == "G" then
        -- Go to root
        self:load_directory("/")
    elseif key.character == "s" or key.character == "S" then
        -- Go to scripts
        self:load_directory("/scripts")
    end

    return "continue"
end

return Files
