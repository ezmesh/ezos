-- File Manager: Browse and manage files on LittleFS and SD card
-- TAB: switch storage, ENTER: open/actions (images: view),
-- M: actions menu for current item, BACKSPACE: go up, Q: quit
-- Hovering an image for ~400ms previews it in the bottom-right corner.

local ui = require("ezui")
local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")

local FileMgr = { title = "Files" }

local function is_image_name(name)
    local l = name:lower()
    return l:match("%.jpe?g$") ~= nil or l:match("%.png$") ~= nil
end

-- Shared hover-preview state. A single file manager instance lives at a time
-- so we can keep this at module scope; the custom node reads from here.
local preview_path    -- path currently being hovered (nil when not over an image)
local preview_data    -- image bytes, nil while still loading
local preview_w       -- image dimensions (if header parsed)
local preview_h
local preview_loading -- true while async_read is in flight
local THUMB_MAX = 72
local HOVER_DELAY_MS = 400

if not node_mod.handler("thumb_overlay") then
    node_mod.register("thumb_overlay", {
        measure = function(n, mw, mh) return mw, mh end,
        draw = function(n, d, x, y, w, h)
            if not preview_path then return end
            local box_w = THUMB_MAX + 4
            local box_h = THUMB_MAX + 4
            local bx = x + w - box_w - 4
            local by = y + h - box_h - 4

            -- Frame (drawn even while loading so the user sees the intent)
            d.fill_rect(bx, by, box_w, box_h, theme.color("SURFACE"))
            d.draw_rect(bx, by, box_w, box_h, theme.color("ACCENT"))

            if not preview_data then
                theme.set_font("tiny_aa")
                local msg = "..."
                local tw = theme.text_width(msg)
                d.draw_text(bx + math.floor((box_w - tw) / 2),
                            by + math.floor(box_h / 2) - 4,
                            msg, theme.color("TEXT_MUTED"))
                return
            end

            -- Fit the image into the box while preserving aspect ratio
            local scale = 1.0
            if preview_w and preview_h and preview_w > 0 and preview_h > 0 then
                scale = math.min(THUMB_MAX / preview_w, THUMB_MAX / preview_h)
            end
            local drawn_w = math.floor((preview_w or THUMB_MAX) * scale)
            local drawn_h = math.floor((preview_h or THUMB_MAX) * scale)
            local dx = bx + 2 + math.floor((THUMB_MAX - drawn_w) / 2)
            local dy = by + 2 + math.floor((THUMB_MAX - drawn_h) / 2)

            d.set_clip_rect(bx + 2, by + 2, THUMB_MAX, THUMB_MAX)
            if preview_path:lower():match("%.png$") then
                d.draw_png(dx, dy, preview_data, scale, scale)
            else
                d.draw_jpeg(dx, dy, preview_data, scale, scale)
            end
            d.clear_clip_rect()
        end,
    })
end

local function format_size(bytes)
    if bytes >= 1048576 then
        return string.format("%.1f MB", bytes / 1048576)
    elseif bytes >= 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return bytes .. " B"
    end
end

-- Get parent directory path from a path like "/fs/wallpapers/"
local function get_parent(path)
    -- Remove trailing slash, then find last slash
    local trimmed = path:sub(1, #path - 1)
    local last = trimmed:match("^(.*/)") or "/"
    return last
end

-- Prompt for a name (used by New Folder and Rename)
local function prompt_name(title, default, callback)
    local PromptDef = { title = title }

    function PromptDef:build(state)
        local items = {}
        items[#items + 1] = ui.title_bar(title, { back = true })
        items[#items + 1] = ui.padding({ 10, 8, 4, 8 },
            ui.text_input({
                value = state.name or default or "",
                placeholder = "Enter name...",
                on_change = function(val) state.name = val end,
                on_submit = function(val)
                    if val and #val > 0 then
                        callback(val)
                        screen_mod.pop()
                    end
                end,
            })
        )
        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    function PromptDef:on_enter()
        -- Focus the text input
        local focus_mod = require("ezui.focus")
        if #focus_mod.chain > 0 then
            focus_mod.index = #focus_mod.chain
            focus_mod._update_marks()
        end
    end

    function PromptDef:handle_key(k)
        local focus_mod = require("ezui.focus")
        if not focus_mod.editing then
            if k.character == "q" or k.special == "ESCAPE" then
                return "pop"
            end
        end
        return nil
    end

    local inst = screen_mod.create(PromptDef, { name = default or "" })
    screen_mod.push(inst)
end

-- Context menu for a file entry
local function show_file_menu(mgr, path, file)
    local full_path = path .. file.name
    local MenuDef = { title = file.name }

    function MenuDef:build(state)
        local items = {}
        items[#items + 1] = ui.title_bar(file.name, { back = true })

        local actions = {}

        -- File info
        actions[#actions + 1] = ui.list_item({
            title = "Size: " .. format_size(file.size),
            disabled = true,
        })

        -- Set as wallpaper (for .jpg files)
        if file.name:lower():match("%.jpe?g$") then
            actions[#actions + 1] = ui.list_item({
                title = "Set as Wallpaper",
                subtitle = full_path,
                on_press = function()
                    ez.storage.set_pref("wallpaper_path", full_path)
                    ez.storage.set_pref("wallpaper", "")
                    screen_mod.pop()
                end,
            })
        end

        -- Rename
        actions[#actions + 1] = ui.list_item({
            title = "Rename",
            on_press = function()
                screen_mod.pop()
                prompt_name("Rename", file.name, function(new_name)
                    ez.storage.rename(full_path, path .. new_name)
                    mgr:set_state({ path = path })
                end)
            end,
        })

        -- Copy between storages
        local is_fs = path:sub(1, 4) == "/fs/"
        local other_root = is_fs and "/sd/" or "/fs/"
        local other_label = is_fs and "SD Card" or "Flash"
        actions[#actions + 1] = ui.list_item({
            title = "Copy to " .. other_label,
            subtitle = other_root .. file.name,
            on_press = function()
                ez.storage.copy_file(full_path, other_root .. file.name)
                screen_mod.pop()
            end,
        })

        -- Delete
        actions[#actions + 1] = ui.list_item({
            title = "Delete",
            subtitle = "Remove this file",
            on_press = function()
                ez.storage.remove(full_path)
                screen_mod.pop()
                mgr:set_state({ path = path })
            end,
        })

        local content = ui.vbox({ gap = 0 }, actions)
        items[#items + 1] = ui.scroll({ grow = 1 }, content)

        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    function MenuDef:handle_key(k)
        if k.character == "q" or k.special == "ESCAPE" then
            return "pop"
        end
        return nil
    end

    local inst = screen_mod.create(MenuDef, {})
    screen_mod.push(inst)
end

-- Context menu for a directory entry
local function show_dir_menu(mgr, path, dir_name)
    local full_path = path .. dir_name .. "/"
    local MenuDef = { title = dir_name }

    function MenuDef:build(state)
        local items = {}
        items[#items + 1] = ui.title_bar(dir_name .. "/", { back = true })

        local actions = {}

        actions[#actions + 1] = ui.list_item({
            title = "Open",
            on_press = function()
                screen_mod.pop()
                mgr:set_state({ path = full_path })
            end,
        })

        -- Rename
        actions[#actions + 1] = ui.list_item({
            title = "Rename",
            on_press = function()
                screen_mod.pop()
                prompt_name("Rename", dir_name, function(new_name)
                    ez.storage.rename(path .. dir_name, path .. new_name)
                    mgr:set_state({ path = path })
                end)
            end,
        })

        -- Delete (empty dir only)
        actions[#actions + 1] = ui.list_item({
            title = "Delete",
            subtitle = "Directory must be empty",
            on_press = function()
                ez.storage.remove(full_path)
                screen_mod.pop()
                mgr:set_state({ path = path })
            end,
        })

        local content = ui.vbox({ gap = 0 }, actions)
        items[#items + 1] = ui.scroll({ grow = 1 }, content)

        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    function MenuDef:handle_key(k)
        if k.character == "q" or k.special == "ESCAPE" then
            return "pop"
        end
        return nil
    end

    local inst = screen_mod.create(MenuDef, {})
    screen_mod.push(inst)
end

function FileMgr:build(state)
    local path = state.path or "/fs/"
    local items = {}

    -- Title showing current path, truncated if long
    local display_path = path
    if #display_path > 25 then
        display_path = "..." .. display_path:sub(#display_path - 22)
    end
    items[#items + 1] = ui.title_bar(display_path, { back = true })

    -- Storage info bar
    local is_fs = path:sub(1, 4) == "/fs/"
    local info = is_fs and ez.storage.get_flash_info() or ez.storage.get_sd_info()
    local info_text
    if info then
        info_text = format_size(info.used_bytes) .. " / " .. format_size(info.total_bytes)
            .. "  [TAB: " .. (is_fs and "SD" or "Flash") .. "]"
    else
        info_text = (is_fs and "Flash" or "SD not available")
            .. "  [TAB: " .. (is_fs and "SD" or "Flash") .. "]"
    end
    items[#items + 1] = ui.padding({ 2, 8, 2, 8 },
        ui.text_widget(info_text, { color = "TEXT_MUTED", font = "tiny_aa" })
    )

    local content_items = {}

    -- Parent directory entry (when not at root)
    if path ~= "/fs/" and path ~= "/sd/" then
        content_items[#content_items + 1] = ui.list_item({
            title = "..",
            compact = true,
            on_press = function()
                self:set_state({ path = get_parent(path) })
            end,
        })
    end

    -- New folder action
    content_items[#content_items + 1] = ui.list_item({
        title = "+ New Folder",
        compact = true,
        on_press = function()
            prompt_name("New Folder", "", function(name)
                ez.storage.mkdir(path .. name)
                self:set_state({ path = path })
            end)
        end,
    })

    -- List directory contents
    local files = ez.storage.list_dir(path)
    if files then
        -- Sort: directories first, then files alphabetically
        table.sort(files, function(a, b)
            if a.is_dir ~= b.is_dir then return a.is_dir end
            return a.name < b.name
        end)

        for _, f in ipairs(files) do
            if f.is_dir then
                content_items[#content_items + 1] = ui.list_item({
                    title = f.name .. "/",
                    compact = true,
                    on_press = function()
                        self:set_state({ path = path .. f.name .. "/" })
                    end,
                    on_long_press = function()
                        show_dir_menu(self, path, f.name)
                    end,
                })
            else
                local full = path .. f.name
                local image = is_image_name(f.name)
                content_items[#content_items + 1] = ui.list_item({
                    title = f.name,
                    trailing = format_size(f.size),
                    compact = true,
                    -- Extra fields read by FileMgr:update() to drive the hover preview
                    _file_path = full,
                    _is_image  = image,
                    on_press = function()
                        if image then
                            local IV = require("screens.tools.image_viewer")
                            screen_mod.push(screen_mod.create(IV, IV.initial_state(full)))
                        else
                            show_file_menu(self, path, f)
                        end
                    end,
                })
            end
        end
    end

    if not files or #files == 0 then
        content_items[#content_items + 1] = ui.padding({ 20, 10, 10, 10 },
            ui.text_widget("Empty directory", {
                color = "TEXT_MUTED",
                text_align = "center",
            })
        )
    end

    local content = ui.vbox({ gap = 0 }, content_items)
    local scroller = ui.scroll({ grow = 1, scroll_offset = state.scroll or 0 }, content)
    -- zstack: list scrolls underneath, thumbnail overlay sits on top
    items[#items + 1] = ui.zstack({ grow = 1 }, {
        scroller,
        { type = "thumb_overlay" },
    })

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

local function clear_preview()
    preview_path    = nil
    preview_data    = nil
    preview_w       = nil
    preview_h       = nil
    preview_loading = false
end

function FileMgr:update()
    -- Watch the focused node; when it's an image item, kick off an async
    -- load after a short hover delay and invalidate when the data arrives.
    local focus_mod = require("ezui.focus")
    local n = focus_mod.current()

    if n and n._is_image and n._file_path then
        if self._hover_path ~= n._file_path then
            -- New hover target: reset timer and any in-flight load
            self._hover_path  = n._file_path
            self._hover_start = ez.system.millis()
            clear_preview()
            screen_mod.invalidate()
        elseif not preview_data and not preview_loading and
               (ez.system.millis() - self._hover_start) >= HOVER_DELAY_MS then
            preview_loading = true
            local load_path = n._file_path
            preview_path = load_path  -- shows the loading frame immediately
            local async = require("ezui.async")
            async.task(function()
                local data = async_read(load_path)
                -- Drop the result if the user moved to another file in the meantime
                if self._hover_path ~= load_path then return end
                if data and #data > 0 then
                    preview_data = data
                    local w, h = ez.display.get_image_size(data)
                    preview_w, preview_h = w, h
                end
                preview_loading = false
                screen_mod.invalidate()
            end)
        end
    elseif self._hover_path then
        self._hover_path = nil
        clear_preview()
        screen_mod.invalidate()
    end
end

function FileMgr:on_exit()
    clear_preview()
end

function FileMgr:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end

    -- TAB: switch between /fs/ and /sd/
    if key.special == "TAB" then
        local path = self._state.path or "/fs/"
        if path:sub(1, 4) == "/fs/" then
            self:set_state({ path = "/sd/", scroll = 0 })
        else
            self:set_state({ path = "/fs/", scroll = 0 })
        end
        return "handled"
    end

    -- Backspace: go up one level
    if key.special == "BACKSPACE" then
        local path = self._state.path or "/fs/"
        if path ~= "/fs/" and path ~= "/sd/" then
            self:set_state({ path = get_parent(path) })
        end
        return "handled"
    end

    -- M: show the actions menu for the focused item (primary way to reach
    -- rename/delete/wallpaper for images, since ENTER now opens the viewer).
    if key.character == "m" then
        local focus_mod = require("ezui.focus")
        local n = focus_mod.current()
        if n and n._file_path then
            local p = self._state.path or "/fs/"
            local name = n._file_path:sub(#p + 1)
            -- Rebuild a file entry for the menu helper
            show_file_menu(self, p, { name = name, size = 0, is_dir = false })
            return "handled"
        end
    end

    return nil
end

return FileMgr
