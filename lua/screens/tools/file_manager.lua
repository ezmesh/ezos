-- File Manager: Browse and manage files on LittleFS and SD card
-- TAB: switch storage, ENTER: open/actions (images: view),
-- M: actions menu for current item, BACKSPACE: go up, Q: quit
-- Two layouts: list (default, hover-preview the image bottom-right) and
-- grid (icons + inline image thumbnails). The active layout is persisted
-- in the `fm_view` NVS pref and toggled via the Alt+M global menu.

local ui = require("ezui")
local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")
local focus_mod = require("ezui.focus")
local icons = require("ezui.icons")
local apps = require("services.apps")

local FileMgr = { title = "Files" }

local function is_image_name(name)
    local l = name:lower()
    return l:match("%.jpe?g$") ~= nil or l:match("%.png$") ~= nil
end

local function get_ext(name)
    local ext = name:match("%.([^./]+)$")
    return ext and ext:upper() or ""
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

-- ---------------------------------------------------------------------------
-- Grid view: thumbnail cache and file_tile node
-- ---------------------------------------------------------------------------

-- Tile metrics. Tuned for a 4-column grid on a 320 px screen with 4 px
-- padding either side -- 4 * 72 = 288 + 3 * 8 (gaps) = 312, leaving the
-- last 8 px for the scrollbar track. The icon area is the top square of
-- the tile; the label occupies the remaining strip below it.
local GRID_COLS    = 4
local TILE_W       = 72
local TILE_ICON    = 48
local TILE_H       = 76
local TILE_GAP_X   = 8
local TILE_GAP_Y   = 6
local TILE_PAD_X   = 4

-- LRU sprite cache for image thumbnails. Sprites live in PSRAM so the
-- cap is set by how many we want resident at once (~6 KB per 48x48 RGB565
-- sprite). 12 entries cover one full screen of the 4x3 visible grid plus
-- a few off-screen tiles the user just scrolled past.
local THUMB_CAP = 12
local thumb_cache = {}    -- path -> { sprite, w, h, last_used }
local thumb_loading = {}  -- path -> true while async_read is in flight
local thumb_failed = {}   -- path -> true if decode failed (don't retry every frame)

local function thumb_evict_oldest()
    local oldest_path, oldest_t
    for p, e in pairs(thumb_cache) do
        if not oldest_t or e.last_used < oldest_t then
            oldest_path, oldest_t = p, e.last_used
        end
    end
    if oldest_path then
        local sp = thumb_cache[oldest_path].sprite
        if sp then sp:destroy() end
        thumb_cache[oldest_path] = nil
    end
end

local function thumb_cache_count()
    local n = 0
    for _ in pairs(thumb_cache) do n = n + 1 end
    return n
end

-- Returns the cached sprite for `path` (touching its LRU stamp) or nil.
-- A nil return kicks off an async decode -- the caller is expected to
-- render a placeholder this frame and rely on screen_mod.invalidate() in
-- the loader to redraw once the sprite lands. Already-failed paths short-
-- circuit so a bad image doesn't block the worker on every paint.
local function request_thumb(path)
    if not path or path == "" then return nil end
    local entry = thumb_cache[path]
    if entry then
        entry.last_used = ez.system.millis()
        return entry
    end
    if thumb_loading[path] or thumb_failed[path] then return nil end
    thumb_loading[path] = true

    local async = require("ezui.async")
    async.task(function()
        local data = async_read(path)
        if not data or #data == 0 then
            thumb_loading[path] = nil
            thumb_failed[path] = true
            return
        end
        local w, h = ez.display.get_image_size(data)
        if not w or not h or w <= 0 or h <= 0 then
            thumb_loading[path] = nil
            thumb_failed[path] = true
            return
        end
        local scale = math.min(TILE_ICON / w, TILE_ICON / h)
        if scale > 1 then scale = 1 end  -- never upscale a small image
        local sw = math.max(1, math.floor(w * scale))
        local sh = math.max(1, math.floor(h * scale))
        local sp = ez.display.create_sprite(sw, sh)
        if not sp then
            thumb_loading[path] = nil
            thumb_failed[path] = true
            return
        end
        local ok
        if path:lower():match("%.png$") then
            ok = sp:draw_png(0, 0, data, scale, scale)
        else
            ok = sp:draw_jpeg(0, 0, data, scale, scale)
        end
        if not ok then
            sp:destroy()
            thumb_loading[path] = nil
            thumb_failed[path] = true
            return
        end
        while thumb_cache_count() >= THUMB_CAP do
            thumb_evict_oldest()
        end
        thumb_cache[path] = {
            sprite    = sp,
            w         = sw,
            h         = sh,
            last_used = ez.system.millis(),
        }
        thumb_loading[path] = nil
        screen_mod.invalidate()
    end)
    return nil
end

local function clear_thumb_cache()
    for _, e in pairs(thumb_cache) do
        if e.sprite then e.sprite:destroy() end
    end
    thumb_cache = {}
    thumb_loading = {}
    thumb_failed = {}
end

-- Extension-badge colors so the tile gives a hint about the file type
-- without needing a full icon set. Falls back to a neutral grey for the
-- long tail of less-common extensions.
local EXT_COLORS = {
    -- text-like
    TXT = 0x7BCF, MD = 0x7BCF, LOG = 0x7BCF, JSON = 0x7BCF, CSV = 0x7BCF,
    -- code
    LUA = 0x4ED4, C = 0x4ED4, H = 0x4ED4, CPP = 0x4ED4, PY = 0x4ED4, SH = 0x4ED4,
    -- audio
    WAV = 0xFBE0, MP3 = 0xFBE0, OGG = 0xFBE0,
    -- archive
    ZIP = 0xC618, GZ = 0xC618, TAR = 0xC618,
    -- binary / firmware
    BIN = 0x4208, ELF = 0x4208, FW = 0x4208,
    -- maps / app-specific
    TDMAP = 0x07E0, EZTRACK = 0x07E0,
}

-- `file_tile` is the focusable grid cell. It carries enough metadata in
-- its node table for on_press / on_long_press / draw to dispatch without
-- closing over per-frame state (the grid rebuilds on every set_state, so
-- closures here would create garbage on each scroll).
if not node_mod.handler("file_tile") then
    node_mod.register("file_tile", {
        focusable = true,

        measure = function(n, mw, mh) return TILE_W, TILE_H end,

        draw = function(n, d, x, y, w, h)
            local focused = n._focused
            local accent = theme.color("ACCENT")

            -- Selection plate behind the whole tile. SURFACE_ALT keeps
            -- the focus mark readable on both dark and light themes
            -- without painting an opaque block.
            if focused then
                d.fill_round_rect(x, y, w, h, 6, theme.color("SURFACE_ALT"))
                d.draw_round_rect(x, y, w, h, 6, accent)
            end

            -- Icon area: TILE_ICON x TILE_ICON, centered horizontally
            -- near the top of the tile.
            local icon_x = x + math.floor((w - TILE_ICON) / 2)
            local icon_y = y + 4
            local kind = n._kind

            if kind == "dir" then
                local icon = icons.folder
                if icon and icon.lg then
                    local plate = icon.color or theme.color("ACCENT_DIM")
                    local inset = icons._plate_inset or 4
                    local pw = icons._plate_size or (TILE_ICON - 2 * inset)
                    d.fill_round_rect(icon_x + inset - 1, icon_y + inset - 1,
                                      pw + 2, pw + 2,
                                      icons._plate_radius or 8, plate)
                    d.draw_png(icon_x, icon_y, icon.lg)
                    if icons._shim then
                        d.draw_png(icon_x, icon_y, icons._shim)
                    end
                end
            elseif kind == "image" then
                local thumb = request_thumb(n._file_path)
                -- Background plate behind the thumbnail so transparent /
                -- letterboxed images don't blend into the screen bg.
                d.fill_round_rect(icon_x, icon_y, TILE_ICON, TILE_ICON,
                                  4, theme.color("SURFACE"))
                d.draw_round_rect(icon_x, icon_y, TILE_ICON, TILE_ICON,
                                  4, theme.color("BORDER"))
                if thumb and thumb.sprite then
                    local tx = icon_x + math.floor((TILE_ICON - thumb.w) / 2)
                    local ty = icon_y + math.floor((TILE_ICON - thumb.h) / 2)
                    thumb.sprite:push(tx, ty)
                else
                    -- Loading or failed placeholder: dotted dashes
                    -- centered so the user knows a thumb is coming.
                    theme.set_font("tiny_aa")
                    local msg = thumb_failed[n._file_path] and "?" or "..."
                    local tw = theme.text_width(msg)
                    d.draw_text(icon_x + math.floor((TILE_ICON - tw) / 2),
                                icon_y + math.floor(TILE_ICON / 2) - 4,
                                msg, theme.color("TEXT_MUTED"))
                end
            else
                -- Extension badge: rounded rect with the upper-case
                -- extension. Long extensions are truncated to 4 chars
                -- so the label still fits horizontally inside the plate.
                local ext = n._ext or ""
                if #ext > 4 then ext = ext:sub(1, 4) end
                local plate = EXT_COLORS[ext] or theme.color("BORDER")
                local inset = icons._plate_inset or 4
                local pw = icons._plate_size or (TILE_ICON - 2 * inset)
                d.fill_round_rect(icon_x + inset, icon_y + inset,
                                  pw, pw,
                                  icons._plate_radius or 8, plate)
                if ext ~= "" then
                    theme.set_font("tiny_aa", "bold")
                    local tw = theme.text_width(ext)
                    local fh = theme.font_height()
                    d.draw_text(
                        icon_x + math.floor((TILE_ICON - tw) / 2),
                        icon_y + math.floor((TILE_ICON - fh) / 2),
                        ext, theme.color("TEXT"))
                end
            end

            -- Label below the icon. Two-line max via wrap-then-truncate
            -- so file extensions don't get hidden when names are long.
            theme.set_font("tiny_aa", focused and "bold" or "regular")
            local label = n._label or ""
            local fh = theme.font_height()
            local label_y = y + 4 + TILE_ICON + 2
            local max_w = w - 4
            -- Truncate with ellipsis if the name doesn't fit a single
            -- line at the tiny font size. The tile is too narrow to
            -- justify a second line + the focused state already widens
            -- the label slightly via the bold weight.
            local lw = theme.text_width(label)
            if lw > max_w then
                local trimmed = label
                while #trimmed > 1 and theme.text_width(trimmed .. "...") > max_w do
                    trimmed = trimmed:sub(1, #trimmed - 1)
                end
                label = trimmed .. "..."
                lw = theme.text_width(label)
            end
            local lx = x + math.floor((w - lw) / 2)
            d.draw_text(lx, label_y, label, theme.color("TEXT"))
        end,

        on_activate = function(n, key)
            if n.on_press then n.on_press() end
            return "handled"
        end,

        on_long_press = function(n)
            if n.on_long_press then n.on_long_press() end
            return "handled"
        end,

        on_press = function(n)
            if n.on_press then n.on_press() end
            return "handled"
        end,

        -- Grid navigation. LEFT/RIGHT step one tile; UP/DOWN step a full
        -- row (GRID_COLS tiles). The focus chain is built in row-major
        -- order so a fixed stride is correct as long as every row is
        -- full -- when the last row is short, UP/DOWN clamp at the
        -- chain ends, which is the same behaviour as a list.
        on_key = function(n, key)
            if key.special == "LEFT" then
                focus_mod.prev()
                return "handled"
            elseif key.special == "RIGHT" then
                focus_mod.next()
                return "handled"
            elseif key.special == "UP" then
                for _ = 1, GRID_COLS do focus_mod.prev() end
                return "handled"
            elseif key.special == "DOWN" then
                for _ = 1, GRID_COLS do focus_mod.next() end
                return "handled"
            end
            return nil
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

        -- Registered app handlers for this extension. The first one is
        -- the default, but we surface every handler so the user can
        -- pick explicitly when there's more than one.
        for _, app in ipairs(apps.handlers_for(full_path)) do
            actions[#actions + 1] = ui.list_item({
                title = "Open in " .. (app.label or app.id),
                on_press = function()
                    screen_mod.pop()
                    app.open(full_path)
                end,
            })
        end

        -- Set as wallpaper (for .jpg / .jpeg / .png files). The
        -- desktop loader detects the format from the file's magic
        -- bytes, so the file manager just needs to allow-list any
        -- extension the loader can decode.
        if file.name:lower():match("%.jpe?g$")
           or file.name:lower():match("%.png$") then
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

        -- Transfer over mesh. Opens a contact picker; the picked
        -- contact becomes the recipient. On a fresh device with no
        -- contacts, show a disabled row with a hint so the user
        -- knows why it's greyed out.
        local contacts_svc = require("services.contacts")
        local has_contacts = contacts_svc.count() > 0
        actions[#actions + 1] = ui.list_item({
            title    = "Transfer",
            subtitle = has_contacts and "Send over mesh"
                       or "Add a contact first",
            disabled = not has_contacts,
            on_press = function()
                screen_mod.pop()
                require("screens.tools.file_manager_xfer_picker")
                    .show(full_path, file.size)
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

-- Activate the file under `f` in `path`. Shared between list and grid
-- so the press/activate semantics match across both views: image files
-- open the viewer, registered app handlers take precedence over the
-- context menu, and unknown extensions fall through to the menu.
local function activate_file(mgr, path, f)
    local full = path .. f.name
    if is_image_name(f.name) then
        local IV = require("screens.tools.image_viewer")
        screen_mod.push(screen_mod.create(IV, IV.initial_state(full)))
    elseif apps.open(full) then
        -- A registered app handled the open. The registry is
        -- responsible for pushing the relevant screen.
    else
        show_file_menu(mgr, path, f)
    end
end

-- ---------------------------------------------------------------------------
-- List view: original layout, hover-preview an image in the bottom-right
-- ---------------------------------------------------------------------------

local function build_list_content(self, path, files)
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

    if files then
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
                    on_press = function() activate_file(self, path, f) end,
                    on_long_press = function() show_file_menu(self, path, f) end,
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

    return ui.vbox({ gap = 0 }, content_items)
end

-- ---------------------------------------------------------------------------
-- Grid view: 4-column tile layout with folder icons and image thumbnails
-- ---------------------------------------------------------------------------

-- Build a single row hbox of `tiles` padded with empty spacers to keep
-- the row width consistent when the last row isn't full. Letting an
-- incomplete row collapse to its natural width would make the trailing
-- column of tiles ride against the right edge instead of staying in the
-- grid alignment.
local function build_grid_row(tiles, cols)
    local children = {}
    for i = 1, cols do
        if tiles[i] then
            children[#children + 1] = tiles[i]
        else
            children[#children + 1] = { type = "spacer", w = TILE_W, grow = 0 }
        end
    end
    return ui.padding({ 0, TILE_PAD_X, 0, TILE_PAD_X },
        ui.hbox({ gap = TILE_GAP_X, w_grow = 0 }, children)
    )
end

local function build_grid_content(self, path, files)
    -- Linearise every interactive entry into a flat list first, then
    -- chunk it into rows. Building rows in one pass would couple
    -- ".."/folder/file handling to row boundaries and make adding new
    -- entry types in the future surgery instead of an append.
    local tiles = {}

    if path ~= "/fs/" and path ~= "/sd/" then
        tiles[#tiles + 1] = {
            type       = "file_tile",
            _label     = "..",
            _kind      = "dir",
            on_press   = function()
                self:set_state({ path = get_parent(path) })
            end,
        }
    end

    if files then
        for _, f in ipairs(files) do
            if f.is_dir then
                local name = f.name
                local sub  = path .. name .. "/"
                tiles[#tiles + 1] = {
                    type       = "file_tile",
                    _label     = name,
                    _kind      = "dir",
                    on_press   = function() self:set_state({ path = sub }) end,
                    on_long_press = function()
                        show_dir_menu(self, path, name)
                    end,
                }
            else
                local full  = path .. f.name
                local image = is_image_name(f.name)
                tiles[#tiles + 1] = {
                    type        = "file_tile",
                    _label      = f.name,
                    _kind       = image and "image" or "file",
                    _ext        = get_ext(f.name),
                    _file_path  = full,
                    _is_image   = image,
                    on_press    = function() activate_file(self, path, f) end,
                    on_long_press = function() show_file_menu(self, path, f) end,
                }
            end
        end
    end

    if #tiles == 0 then
        return ui.padding({ 20, 10, 10, 10 },
            ui.text_widget("Empty directory", {
                color = "TEXT_MUTED",
                text_align = "center",
            })
        )
    end

    local rows = {}
    for r = 1, math.ceil(#tiles / GRID_COLS) do
        local row_tiles = {}
        for c = 1, GRID_COLS do
            local idx = (r - 1) * GRID_COLS + c
            row_tiles[c] = tiles[idx]
        end
        rows[#rows + 1] = build_grid_row(row_tiles, GRID_COLS)
    end

    return ui.vbox({ gap = TILE_GAP_Y }, rows)
end

-- ---------------------------------------------------------------------------
-- FileMgr:build: shell + dispatch to list_view or grid_view
-- ---------------------------------------------------------------------------

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

    -- List directory contents (sort directories first, then alphabetically).
    -- Both views share the same sort + filter so toggling preserves order.
    local files = ez.storage.list_dir(path)
    if files then
        table.sort(files, function(a, b)
            if a.is_dir ~= b.is_dir then return a.is_dir end
            return a.name < b.name
        end)
    end

    local view = state.view or "list"
    local content
    if view == "grid" then
        content = build_grid_content(self, path, files)
    else
        content = build_list_content(self, path, files)
    end

    local scroller = ui.scroll({ grow = 1, scroll_offset = state.scroll or 0 }, content)
    if view == "grid" then
        -- Grid view does its own per-tile thumbnails; no bottom-right
        -- hover preview is needed (and it would partially occlude the
        -- last row of tiles).
        items[#items + 1] = scroller
    else
        -- List view: thumbnail overlay sits on top of the scroller.
        items[#items + 1] = ui.zstack({ grow = 1 }, {
            scroller,
            { type = "thumb_overlay" },
        })
    end

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

local function clear_preview()
    preview_path    = nil
    preview_data    = nil
    preview_w       = nil
    preview_h       = nil
    preview_loading = false
end

function FileMgr:on_enter()
    -- Restore the user's last-used view layout. Pref is read once on
    -- entry so the rebuild that follows a Tab-switch or directory
    -- change keeps the same layout without re-touching NVS.
    local saved = ez.storage.get_pref("fm_view", "list")
    if saved ~= "list" and saved ~= "grid" then saved = "list" end
    if self._state.view ~= saved then
        self:set_state({ view = saved })
    end
end

function FileMgr:update()
    -- Hover preview is a list-view-only affordance; the grid renders
    -- thumbnails inline on each tile, so we skip the hover machinery
    -- (and avoid stale `preview_path` leaking across a view switch).
    if (self._state.view or "list") ~= "list" then
        if self._hover_path then
            self._hover_path = nil
            clear_preview()
            screen_mod.invalidate()
        end
        return
    end

    -- Watch the focused node; when it's an image item, kick off an async
    -- load after a short hover delay and invalidate when the data arrives.
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
    -- The grid's thumbnail sprites live in PSRAM; release them when the
    -- file manager goes away. A return to file manager will repopulate
    -- the cache from the visible tiles -- cheap because async_read +
    -- decode happen off the main thread.
    clear_thumb_cache()
end

-- Global menu (Alt+M). Keeps menu items tied to the file-manager's
-- current folder, so "Receive file here" lands the incoming file
-- in whichever directory is visible. The view toggle lives here too
-- so it's discoverable without stealing a single-letter key.
function FileMgr:menu()
    local path = self._state.path or "/fs/"
    local view = self._state.view or "list"
    local ft = require("services.file_transfer")
    local armed, armed_path = ft.is_armed()
    local armed_here = armed and armed_path == path

    local items = {}

    items[#items + 1] = {
        title    = view == "grid" and "Switch to list view"
                   or "Switch to grid view",
        subtitle = view == "grid"
                   and "Show a single column with file sizes"
                   or "Show icons and image thumbnails in a 4-column grid",
        on_press = function()
            local next_view = view == "grid" and "list" or "grid"
            ez.storage.set_pref("fm_view", next_view)
            self:set_state({ view = next_view, scroll = 0 })
        end,
    }

    items[#items + 1] = {
        title    = "New folder",
        subtitle = "Create a folder in " .. path,
        on_press = function()
            prompt_name("New Folder", "", function(name)
                ez.storage.mkdir(path .. name)
                self:set_state({ path = path })
            end)
        end,
    }

    items[#items + 1] = {
        title    = armed_here and "Stop receiving" or "Receive file here",
        subtitle = armed_here and armed_path
                   or "Accept one incoming transfer into " .. path,
        on_press = function()
            if armed_here then
                ft.arm_receive(nil)
            else
                ft.arm_receive(path)
                -- Push a receiver screen so the user sees progress
                -- when the offer arrives. The screen subscribes to
                -- file/offer and updates from there.
                local FT = require("screens.tools.file_transfer")
                screen_mod.push(screen_mod.create(FT,
                    FT.initial_state("rx", nil, {})))
            end
        end,
    }
    return items
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
