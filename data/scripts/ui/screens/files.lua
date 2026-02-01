-- files.lua - File browser with VerticalList
-- Browse files with copy/move/rename/mkdir operations

local TextUtils = load_module("/scripts/ui/text_utils.lua")
local ListMixin = load_module("/scripts/ui/list_mixin.lua")
local VerticalList = load_module("/scripts/ui/components/vertical_list.lua")

local Files = {
    title = "Files"
}

function Files:new(start_path)
    local o = {
        title = "Files",
        current_path = start_path or "/",
        list = nil,
        message = nil,
        message_time = 0,
        clipboard_path = nil,
        clipboard_mode = nil,  -- "copy" or "cut"
        input_mode = nil,      -- nil, "rename", "mkdir", "newfile"
        input_buffer = "",
        input_target = nil,    -- Original entry for rename
    }
    setmetatable(o, {__index = Files})
    return o
end

function Files:on_enter()
    run_gc("collect", "files-enter")

    local self_ref = self

    -- Custom item renderer for file entries
    local function render_file_item(display, item, x, y, width, height, is_selected, colors)
        -- Selection background
        if is_selected then
            display.fill_rect(x, y, width, height - 2, colors.SURFACE_ALT)
            if _G.Icons and _G.Icons.draw_chevron_right then
                local chevron_y = y + math.floor((height - 9) / 2)
                _G.Icons.draw_chevron_right(display, x + 2, chevron_y, colors.ACCENT, colors.SURFACE_ALT)
            end
        end

        -- Icon/prefix based on type
        local icon_x = x + 14
        local icon_y = y + math.floor((height - 16) / 2)
        local icon_color = is_selected and colors.ACCENT or (item.is_dir and colors.WARNING or colors.TEXT)

        if item.name == ".." then
            -- Draw back arrow as text
            display.draw_text(icon_x, y + 2, "<", icon_color)
        elseif item.is_mountpoint then
            -- Mountpoint (SD card) - use distinct icon
            if _G.Icons then
                _G.Icons.draw("files", display, icon_x, icon_y, 16, colors.SUCCESS)
            else
                display.draw_text(icon_x, y + 2, "@", colors.SUCCESS)
            end
        elseif item.is_dir then
            -- Use files icon for folders
            if _G.Icons then
                _G.Icons.draw("files", display, icon_x, icon_y, 16, icon_color)
            else
                display.draw_text(icon_x, y + 2, "/", icon_color)
            end
        elseif self_ref:is_lua_file(item.name) then
            -- Lua files get asterisk
            display.draw_text(icon_x + 2, y + 2, "*", colors.SUCCESS)
        else
            -- Regular files get dot
            display.draw_text(icon_x + 4, y + 2, ".", icon_color)
        end

        -- Name (truncated if needed)
        local name_x = x + 36
        local name_max_width = width - 80
        local name = TextUtils.truncate(item.name, name_max_width, display)
        local name_color = is_selected and colors.ACCENT or colors.TEXT
        display.draw_text(name_x, y + 2, name, name_color)

        -- Size for files (right-aligned)
        if not item.is_dir and item.size then
            local size_str = self_ref:format_size(item.size)
            display.set_font_size("small")
            local size_width = display.text_width(size_str)
            display.draw_text(x + width - size_width - 8, y + 4, size_str, colors.TEXT_MUTED)
            display.set_font_size("medium")
        end

        -- Cut indicator
        if self_ref.clipboard_mode == "cut" and self_ref.clipboard_path == self_ref:get_full_path(item) then
            display.set_font_size("small")
            display.draw_text(name_x, y + 14, "[cut]", colors.WARNING)
            display.set_font_size("medium")
        end
    end

    -- Create VerticalList with custom renderer
    self.list = VerticalList:new({
        items = {},
        visible_rows = 6,
        row_height = 28,
        render_item = render_file_item,
        on_select = function(idx, item)
            -- Open app menu on enter/click instead of directly opening
            if _G.AppMenu and _G.AppMenu.show then
                _G.AppMenu.show()
            end
        end
    })

    self:load_directory(self.current_path)
end

function Files:on_exit()
    self.list = nil
    self.clipboard_path = nil
    run_gc("collect", "files-exit")
end

function Files:show_message(msg)
    self.message = msg
    self.message_time = ez.system.millis()
end

function Files:load_directory(path)
    self.current_path = path
    local entries = {}

    -- Add parent directory entry (except for root)
    if path ~= "/" then
        table.insert(entries, {
            name = "..",
            label = "..",
            is_dir = true,
            size = 0
        })
    end

    -- At root, show /sd/ mountpoint if SD card is available
    if path == "/" and ez.storage.is_sd_available() then
        table.insert(entries, {
            name = "sd",
            label = "sd",
            is_dir = true,
            is_mountpoint = true,  -- Flag for special rendering
            size = 0
        })
    end

    -- List directory contents
    local items = ez.storage.list_dir(path)
    if items then
        -- Sort: directories first, then files
        local dirs = {}
        local files = {}

        for _, item in ipairs(items) do
            item.label = item.name  -- For VerticalList letter navigation
            if item.is_dir then
                table.insert(dirs, item)
            else
                table.insert(files, item)
            end
        end

        table.sort(dirs, function(a, b) return a.name < b.name end)
        table.sort(files, function(a, b) return a.name < b.name end)

        for _, item in ipairs(dirs) do table.insert(entries, item) end
        for _, item in ipairs(files) do table.insert(entries, item) end
    end

    self.list:set_items(entries)

    if #entries == 0 then
        self:show_message("Empty directory")
    end
end

function Files:get_full_path(entry)
    if not entry then return nil end
    if self.current_path == "/" then
        return "/" .. entry.name
    else
        return self.current_path .. "/" .. entry.name
    end
end

function Files:get_parent_path()
    if self.current_path == "/" then return "/" end
    -- Special case: /sd goes back to root
    if self.current_path == "/sd" then return "/" end
    local parent = self.current_path:match("(.+)/[^/]+$")
    -- If we're in /sd/something, parent might be /sd
    if parent == "" then return "/" end
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

function Files:is_image_file(name)
    local ext = name:match("%.([^.]+)$")
    if not ext then return false end
    ext = ext:lower()
    return ext == "png" or ext == "jpg" or ext == "jpeg" or ext == "bmp"
end

function Files:is_text_file(name)
    local ext = name:match("%.([^.]+)$")
    if not ext then return true end
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

function Files:open_entry(entry)
    if not entry then return end

    if entry.name == ".." then
        self:load_directory(self:get_parent_path())
    elseif entry.is_mountpoint then
        -- Special handling for mountpoints like /sd/
        self:load_directory("/" .. entry.name)
    elseif entry.is_dir then
        self:load_directory(self:get_full_path(entry))
    else
        local path = self:get_full_path(entry)
        if self:is_text_file(entry.name) then
            spawn_screen("/scripts/ui/screens/file_edit.lua", path)
        else
            self:show_message("Cannot open: " .. entry.name)
        end
    end
end

function Files:get_selected_entry()
    local _, item = self.list:get_selected()
    return item
end

-- File operations
function Files:copy_entry()
    local entry = self:get_selected_entry()
    if not entry or entry.name == ".." then
        self:show_message("Cannot copy")
        return
    end
    if entry.is_dir then
        self:show_message("Cannot copy directory")
        return
    end
    self.clipboard_path = self:get_full_path(entry)
    self.clipboard_mode = "copy"
    self:show_message("Copied: " .. entry.name)
end

function Files:cut_entry()
    local entry = self:get_selected_entry()
    if not entry or entry.name == ".." then
        self:show_message("Cannot cut")
        return
    end
    if entry.is_dir then
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
    if dest_path ~= "/" then dest_path = dest_path .. "/" end
    dest_path = dest_path .. src_name

    local content = ez.storage.read_file(self.clipboard_path)
    if not content then
        self:show_message("Read failed!")
        return
    end

    if not ez.storage.write_file(dest_path, content) then
        self:show_message("Write failed!")
        return
    end

    if self.clipboard_mode == "cut" then
        ez.storage.delete(self.clipboard_path)
        self.clipboard_path = nil
        self.clipboard_mode = nil
    end

    self:show_message("Pasted: " .. src_name)
    self:load_directory(self.current_path)
end

function Files:delete_entry()
    local entry = self:get_selected_entry()
    if not entry or entry.name == ".." then
        self:show_message("Cannot delete")
        return
    end

    local path = self:get_full_path(entry)
    if ez.storage.delete(path) then
        self:show_message("Deleted: " .. entry.name)
        self:load_directory(self.current_path)
    else
        self:show_message("Delete failed!")
    end
end

function Files:start_rename()
    local entry = self:get_selected_entry()
    if not entry or entry.name == ".." then
        self:show_message("Cannot rename")
        return
    end
    self.input_mode = "rename"
    self.input_buffer = entry.name
    self.input_target = entry
    ez.keyboard.set_mode("input")
end

function Files:start_mkdir()
    self.input_mode = "mkdir"
    self.input_buffer = ""
    self.input_target = nil
    ez.keyboard.set_mode("input")
end

function Files:start_newfile()
    self.input_mode = "newfile"
    self.input_buffer = "new.txt"
    self.input_target = nil
    ez.keyboard.set_mode("input")
end

function Files:confirm_input()
    if self.input_mode == "rename" and self.input_target then
        local old_path = self:get_full_path(self.input_target)
        local new_path = self.current_path
        if new_path ~= "/" then new_path = new_path .. "/" end
        new_path = new_path .. self.input_buffer

        if ez.storage.rename(old_path, new_path) then
            self:show_message("Renamed to: " .. self.input_buffer)
        else
            self:show_message("Rename failed!")
        end
    elseif self.input_mode == "mkdir" then
        local dir_path = self.current_path
        if dir_path ~= "/" then dir_path = dir_path .. "/" end
        dir_path = dir_path .. self.input_buffer

        if ez.storage.mkdir(dir_path) then
            self:show_message("Created: " .. self.input_buffer)
        else
            self:show_message("Mkdir failed!")
        end
    elseif self.input_mode == "newfile" then
        local file_path = self.current_path
        if file_path ~= "/" then file_path = file_path .. "/" end
        file_path = file_path .. self.input_buffer

        spawn_screen("/scripts/ui/screens/file_edit.lua", file_path)
        self.input_mode = nil
        self.input_buffer = ""
        ez.keyboard.set_mode("normal")
        return
    end

    self.input_mode = nil
    self.input_buffer = ""
    self.input_target = nil
    ez.keyboard.set_mode("normal")
    self:load_directory(self.current_path)
end

function Files:cancel_input()
    self.input_mode = nil
    self.input_buffer = ""
    self.input_target = nil
    ez.keyboard.set_mode("normal")
end

-- Menu items for app menu
function Files:get_menu_items()
    local self_ref = self
    local items = {}
    local entry = self:get_selected_entry()

    -- Open action (always first for any entry)
    if entry then
        table.insert(items, {
            label = "Open",
            action = function()
                self_ref:open_entry(entry)
            end
        })
    end

    if entry and entry.name ~= ".." then
        if not entry.is_dir then
            if self:is_lua_file(entry.name) then
                table.insert(items, {
                    label = "Run",
                    action = function()
                        local path = self_ref:get_full_path(entry)
                        local ok, result = pcall(dofile, path)
                        if ok and type(result) == "table" and result.new then
                            ScreenManager.push(result:new())
                        end
                    end
                })
            end
            table.insert(items, {label = "Copy", action = function() self_ref:copy_entry() end})
            table.insert(items, {label = "Cut", action = function() self_ref:cut_entry() end})
        end
        table.insert(items, {label = "Rename", action = function() self_ref:start_rename() end})
        table.insert(items, {label = "Del", action = function() self_ref:delete_entry() end})
    end

    if self.clipboard_path then
        table.insert(items, {label = "Paste", action = function() self_ref:paste_entry() end})
    end

    table.insert(items, {label = "New Dir", action = function() self_ref:start_mkdir() end})
    table.insert(items, {label = "New File", action = function() self_ref:start_newfile() end})

    return items
end

function Files:render(display)
    local colors = ListMixin.get_colors(display)

    ListMixin.draw_background(display)

    -- Title with path
    display.set_font_size("small")
    local title_max_width = display.width - 20
    local title = self.current_path
    if display.text_width(title) > title_max_width then
        while display.text_width("..." .. title) > title_max_width and #title > 1 do
            title = title:sub(2)
        end
        title = "..." .. title
    end
    TitleBar.draw(display, title)
    display.set_font_size("medium")

    -- File list
    local list_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31
    self.list:render(display, 0, list_y, display.width, true)

    -- Input mode overlay
    if self.input_mode then
        local input_h = 50
        local input_y = display.height - input_h - 20

        display.fill_rect(10, input_y, display.width - 20, input_h, colors.SURFACE)
        display.draw_rect(10, input_y, display.width - 20, input_h, colors.ACCENT)

        local prompt = "Name:"
        if self.input_mode == "mkdir" then prompt = "Directory:" end
        if self.input_mode == "newfile" then prompt = "Filename:" end

        display.draw_text(20, input_y + 8, prompt, colors.TEXT_SECONDARY)
        display.draw_text(20, input_y + 26, self.input_buffer .. "_", colors.ACCENT)
    end

    -- Status message
    if self.message and (ez.system.millis() - self.message_time) < 2000 then
        display.set_font_size("small")
        local msg_y = display.height - 16
        display.draw_text(8, msg_y, self.message, colors.TEXT_SECONDARY)
        display.set_font_size("medium")
    else
        self.message = nil
    end

    -- Clipboard indicator
    if self.clipboard_path and not self.input_mode then
        display.set_font_size("small")
        local clip_name = self.clipboard_path:match("([^/]+)$") or ""
        local clip_text = (self.clipboard_mode == "cut" and "Cut: " or "Clip: ") .. clip_name
        local clip_y = display.height - 16
        local clip_w = display.text_width(clip_text)
        display.draw_text(display.width - clip_w - 8, clip_y, clip_text, colors.WARNING)
        display.set_font_size("medium")
    end
end

function Files:handle_key(key)
    ScreenManager.invalidate()

    -- Input mode handling
    if self.input_mode then
        if key.special == "ESCAPE" then
            self:cancel_input()
        elseif key.special == "ENTER" then
            if #self.input_buffer > 0 then
                self:confirm_input()
            end
        elseif key.special == "BACKSPACE" then
            if #self.input_buffer > 0 then
                self.input_buffer = self.input_buffer:sub(1, -2)
            end
        elseif key.character and #key.character == 1 then
            -- Allow alphanumeric, dots, dashes, underscores
            local c = key.character
            if c:match("[%w%.%-%_]") then
                self.input_buffer = self.input_buffer .. c
            end
        end
        return "continue"
    end

    -- Normal mode
    if key.special == "ESCAPE" then
        return "pop"
    end

    if key.special == "BACKSPACE" then
        if self.current_path ~= "/" then
            self:load_directory(self:get_parent_path())
        end
        return "continue"
    end

    -- Hotkeys
    if key.character then
        local c = string.lower(key.character)
        if c == "q" then
            -- Go up a directory, or exit if at root
            if self.current_path == "/" then
                return "pop"
            else
                self:load_directory(self:get_parent_path())
            end
            return "continue"
        elseif c == "c" and key.ctrl then
            self:copy_entry()
            return "continue"
        elseif c == "x" and key.ctrl then
            self:cut_entry()
            return "continue"
        elseif c == "v" and key.ctrl then
            self:paste_entry()
            return "continue"
        elseif c == "d" and key.ctrl then
            self:delete_entry()
            return "continue"
        elseif c == "r" then
            self:start_rename()
            return "continue"
        elseif c == "m" then
            self:start_mkdir()
            return "continue"
        elseif c == "n" then
            self:start_newfile()
            return "continue"
        elseif c == "g" then
            self:load_directory("/")
            return "continue"
        end
    end

    -- Pass to list for navigation and letter-based jumping
    local result = self.list:handle_key(key)
    if result then
        return "continue"
    end

    return "continue"
end

return Files
