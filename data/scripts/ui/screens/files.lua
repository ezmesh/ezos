-- files.lua - Basic file explorer
-- Browse files, run Lua scripts, edit text files

local TextUtils = load_module("/scripts/ui/text_utils.lua")

local Files = {
    title = "Files",
    current_path = "/",
    entries = {},
    selected = 1,
    scroll = 0,
    message = nil,
    message_time = 0,
    clipboard_path = nil,
    clipboard_mode = nil  -- "copy" or "cut"
}

function Files:new(start_path)
    local o = {
        title = "Files",
        current_path = start_path or "/",
        entries = {},
        selected = 1,
        scroll = 0,
        message = nil,
        message_time = 0,
        clipboard_path = nil,
        clipboard_mode = nil
    }
    setmetatable(o, {__index = Files})
    return o
end

function Files:on_enter()
    run_gc("collect", "files-enter")
    self:load_directory(self.current_path)
end

function Files:on_exit()
    -- Clear entries to free memory
    self.entries = {}
    self.clipboard_path = nil
    run_gc("collect", "files-exit")
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
            spawn(function()
                local ok, FileEdit = pcall(load_module, "/scripts/ui/screens/file_edit.lua")
                if ok and FileEdit then
                    ScreenManager.push(FileEdit:new(path))
                end
            end)
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
            ScreenManager.push(screen)
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

    if tdeck.storage.delete(path) then
        self:show_message("Deleted: " .. entry.name)
        self:load_directory(self.current_path)
    else
        self:show_message("Delete failed!")
    end
end

function Files:copy_entry()
    if #self.entries == 0 then return end
    local entry = self.entries[self.selected]
    if entry.name == ".." or entry.is_dir then
        self:show_message("Cannot copy directory")
        return
    end
    self.clipboard_path = self:get_full_path(entry)
    self.clipboard_mode = "copy"
    self:show_message("Copied: " .. entry.name)
end

function Files:cut_entry()
    if #self.entries == 0 then return end
    local entry = self.entries[self.selected]
    if entry.name == ".." or entry.is_dir then
        self:show_message("Cannot cut directory")
        return
    end
    self.clipboard_path = self:get_full_path(entry)
    self.clipboard_mode = "cut"
    self:show_message("Cut: " .. entry.name)
end

function Files:paste_entry()
    if not self.clipboard_path then
        self:show_message("Nothing to paste")
        return
    end

    local src_name = self.clipboard_path:match("([^/]+)$")
    local dest_path = self.current_path
    if dest_path ~= "/" then
        dest_path = dest_path .. "/"
    end
    dest_path = dest_path .. src_name

    -- Read source file
    local content = tdeck.storage.read_file(self.clipboard_path)
    if not content then
        self:show_message("Read failed!")
        return
    end

    -- Write to destination
    if not tdeck.storage.write_file(dest_path, content) then
        self:show_message("Write failed!")
        return
    end

    -- If cut mode, delete source
    if self.clipboard_mode == "cut" then
        tdeck.storage.delete(self.clipboard_path)
        self.clipboard_path = nil
        self.clipboard_mode = nil
    end

    self:show_message("Pasted: " .. src_name)
    self:load_directory(self.current_path)
end

function Files:rename_entry()
    if #self.entries == 0 then return end
    local entry = self.entries[self.selected]
    if entry.name == ".." then
        self:show_message("Cannot rename ..")
        return
    end

    -- For now show message - would need input screen for new name
    self:show_message("Rename: use Edit to modify")
end

function Files:new_file()
    local new_path = self.current_path
    if new_path ~= "/" then
        new_path = new_path .. "/"
    end
    new_path = new_path .. "new.lua"

    spawn(function()
        local ok, FileEdit = pcall(load_module, "/scripts/ui/screens/file_edit.lua")
        if ok and FileEdit then
            ScreenManager.push(FileEdit:new(new_path))
        end
    end)
end

-- Menu items for app menu integration
function Files:get_menu_items()
    local self_ref = self
    local items = {}
    local entry = self.entries[self.selected]

    -- File-specific options
    if entry and entry.name ~= ".." and not entry.is_dir then
        -- Run option for Lua files
        if self:is_lua_file(entry.name) then
            table.insert(items, {
                label = "Run",
                action = function()
                    self_ref:run_lua_file()
                    ScreenManager.invalidate()
                end
            })
        end

        -- Edit option for text files
        if self:is_text_file(entry.name) then
            table.insert(items, {
                label = "Edit",
                action = function()
                    local path = self_ref:get_full_path(entry)
                    spawn(function()
                        local ok, FileEdit = pcall(load_module, "/scripts/ui/screens/file_edit.lua")
                        if ok and FileEdit then
                            ScreenManager.push(FileEdit:new(path))
                        end
                    end)
                end
            })
        end

        -- Copy/Cut
        table.insert(items, {
            label = "Copy",
            action = function()
                self_ref:copy_entry()
                ScreenManager.invalidate()
            end
        })

        table.insert(items, {
            label = "Cut",
            action = function()
                self_ref:cut_entry()
                ScreenManager.invalidate()
            end
        })

        -- Delete
        table.insert(items, {
            label = "Delete",
            action = function()
                self_ref:delete_entry()
                ScreenManager.invalidate()
            end
        })
    end

    -- Paste option if clipboard has content
    if self.clipboard_path then
        table.insert(items, {
            label = "Paste",
            action = function()
                self_ref:paste_entry()
                ScreenManager.invalidate()
            end
        })
    end

    -- New file option
    table.insert(items, {
        label = "New",
        action = function()
            self_ref:new_file()
        end
    })

    return items
end

function Files:update_scroll(visible_rows)
    if self.selected <= self.scroll then
        self.scroll = self.selected - 1
    elseif self.selected > self.scroll + visible_rows then
        self.scroll = self.selected - visible_rows
    end
end

function Files:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    -- Truncate path if too long for title bar
    display.set_font_size("small")
    local title_max_width = display.width - 20
    local title = self.current_path
    if display.text_width(title) > title_max_width then
        while display.text_width("..." .. title) > title_max_width and #title > 1 do
            title = title:sub(2)
        end
        title = "..." .. title
    end

    -- Title bar
    TitleBar.draw(display, title)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    local visible_rows = display.rows - 4
    self:update_scroll(visible_rows)

    -- File list
    for i = 1, visible_rows do
        local idx = self.scroll + i
        local py = (i + 1) * fh

        if idx <= #self.entries then
            local entry = self.entries[idx]
            local is_selected = (idx == self.selected)

            -- Selection highlight
            if is_selected then
                display.fill_rect(fw, py, (display.cols - 2) * fw, fh, colors.SURFACE_ALT)
                -- Draw chevron selection indicator
                local chevron_y = py + math.floor((fh - 9) / 2)
                if _G.Icons and _G.Icons.draw_chevron_right then
                    _G.Icons.draw_chevron_right(display, fw, chevron_y, colors.ACCENT, colors.SURFACE_ALT)
                else
                    display.draw_text(fw, py, ">", colors.ACCENT)
                end
            end

            -- Icon/prefix
            local prefix = "  "
            local name_color = colors.TEXT
            if entry.is_dir then
                prefix = "/ "
                name_color = is_selected and colors.ACCENT or colors.WARNING
            elseif self:is_lua_file(entry.name) then
                prefix = "* "
                name_color = is_selected and colors.ACCENT or colors.SUCCESS
            end

            -- Name (truncate if needed using pixel measurement)
            local name_start_x = 4 * fw  -- After prefix
            local name_max_width = display.width - name_start_x - (8 * fw)  -- Leave room for size
            local name = TextUtils.truncate(entry.name, name_max_width, display)

            display.draw_text(2 * fw, py, prefix .. name, name_color)

            -- Size for files (right-aligned using pixel measurement)
            if not entry.is_dir and entry.size then
                local size_str = self:format_size(entry.size)
                local size_width = display.text_width(size_str)
                local size_x = display.width - size_width - fw
                display.draw_text(size_x, py, size_str, colors.TEXT_SECONDARY)
            end
        end
    end

    -- Status message only (no help bar - use app menu)
    if self.message and (tdeck.system.millis() - self.message_time) < 2000 then
        local status_y = (display.rows - 2) * fh
        display.draw_text(fw, status_y, self.message, colors.TEXT_SECONDARY)
    else
        self.message = nil
    end
end

function Files:handle_key(key)
    ScreenManager.invalidate()

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
                spawn(function()
                    local ok, FileEdit = pcall(load_module, "/scripts/ui/screens/file_edit.lua")
                    if ok and FileEdit then
                        ScreenManager.push(FileEdit:new(path))
                    end
                end)
            end
        end
    elseif key.character == "n" or key.character == "N" then
        -- New file - open editor with path in current directory
        local new_path = self.current_path
        if new_path ~= "/" then
            new_path = new_path .. "/"
        end
        new_path = new_path .. "new.lua"
        spawn(function()
            local ok, FileEdit = pcall(load_module, "/scripts/ui/screens/file_edit.lua")
            if ok and FileEdit then
                ScreenManager.push(FileEdit:new(new_path))
            end
        end)
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
