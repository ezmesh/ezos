-- Map loader: pick a .tdmap archive from /sd/maps before opening the viewer.
--
-- Behavior:
--   * If a default archive pref is set, on_enter immediately replaces this
--     screen with the map viewer for that archive.
--   * Otherwise, lists every .tdmap under /sd/maps/. Enter opens; M shows
--     per-row actions (Open / Set as default / Clear default).
--
-- The viewer is reached via screen.replace so back from the map returns to
-- whatever pushed the loader (menu or desktop), not to the picker.

local ui         = require("ezui")
local screen_mod = require("ezui.screen")

local MAPS_DIR     = "/sd/maps/"
local DEFAULT_PREF = "map_default_archive"

local Loader = { title = "Maps" }

-- Build a Map screen instance for `path`. Centralized so both the auto-load
-- (when a default is set) and the picker rows construct it the same way.
local function open_map(path)
    local MapDef = require("screens.tools.map")
    local inst = screen_mod.create(MapDef, MapDef.initial_state(path))
    screen_mod.replace(inst)
end

local function format_size(bytes)
    if not bytes then return "" end
    if bytes >= 1048576 then
        return string.format("%.1f MB", bytes / 1048576)
    elseif bytes >= 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return bytes .. " B"
    end
end

-- Per-row actions menu (Enter on the focused row binds to Open; M opens this).
local function show_archive_menu(loader, path, name)
    local default_path = ez.storage.get_pref(DEFAULT_PREF, "")
    local is_default = default_path == path

    local MenuDef = { title = name }

    function MenuDef:build(_state)
        local items = {
            ui.title_bar(name, { back = true }),
        }
        local actions = {}

        actions[#actions + 1] = ui.list_item({
            title    = "Open",
            on_press = function()
                screen_mod.pop()
                open_map(path)
            end,
        })

        if is_default then
            actions[#actions + 1] = ui.list_item({
                title    = "Clear default",
                subtitle = "Always show picker on entry",
                on_press = function()
                    ez.storage.set_pref(DEFAULT_PREF, "")
                    screen_mod.pop()
                    loader:set_state({})
                end,
            })
        else
            actions[#actions + 1] = ui.list_item({
                title    = "Set as default",
                subtitle = "Skip picker next time",
                on_press = function()
                    ez.storage.set_pref(DEFAULT_PREF, path)
                    screen_mod.pop()
                    loader:set_state({})
                end,
            })
        end

        items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, actions))
        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    function MenuDef:handle_key(k)
        if k.character == "q" or k.special == "ESCAPE" then
            return "pop"
        end
        return nil
    end

    screen_mod.push(screen_mod.create(MenuDef, {}))
end

function Loader.initial_state()
    return {
        archives    = nil,   -- list of { path, name, size, region }, populated in on_enter
        scan_error  = nil,
        auto_loaded = false, -- true while we're replacing with the default archive
    }
end

function Loader:on_enter()
    -- on_enter fires again after we pop back from the map screen, so we need
    -- to re-scan (a new .tdmap might have been copied in via file manager).
    -- Skip the auto-default branch on re-entry: if we already replaced with
    -- the default once and the user explicitly came back here, they want to
    -- see the picker.
    local state = self._state
    if state.auto_loaded then
        state.auto_loaded = false
        return
    end

    local default_path = ez.storage.get_pref(DEFAULT_PREF, "")
    if default_path and default_path ~= "" then
        local size = ez.storage.file_size(default_path)
        if size and size > 0 then
            state.auto_loaded = true
            open_map(default_path)
            return
        end
        -- Default points at a missing archive; clear it and fall through
        -- to the picker so the user can choose another one.
        ez.storage.set_pref(DEFAULT_PREF, "")
    end

    -- Scan the maps directory. list_dir is synchronous and cheap; archive
    -- header peeks happen lazily per-row when the user focuses one. The
    -- trailing slash is stripped here because the SD driver returns an
    -- empty list for "/sd/maps/" but works for "/sd/maps".
    local files = ez.storage.list_dir((MAPS_DIR:gsub("/+$", "")))
    if not files then
        self:set_state({ scan_error = "Cannot open " .. MAPS_DIR })
        return
    end
    local archives = {}
    for _, f in ipairs(files) do
        if not f.is_dir and f.name:lower():match("%.tdmap$") then
            archives[#archives + 1] = {
                path = MAPS_DIR .. f.name,
                name = f.name,
                size = f.size,
            }
        end
    end
    table.sort(archives, function(a, b) return a.name < b.name end)
    self:set_state({ archives = archives, scan_error = nil })
end

function Loader:build(state)
    local items = { ui.title_bar("Maps", { back = true }) }

    if state.scan_error then
        items[#items + 1] = ui.padding({ 16, 12, 12, 12 },
            ui.text_widget(state.scan_error, { wrap = true, color = "ERROR" })
        )
        items[#items + 1] = ui.padding({ 8, 12, 12, 12 },
            ui.text_widget(
                "Insert an SD card with .tdmap archives under " .. MAPS_DIR .. ".",
                { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
        )
        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    local archives = state.archives or {}
    if #archives == 0 then
        items[#items + 1] = ui.padding({ 20, 12, 12, 12 },
            ui.text_widget("No .tdmap archives found.", { color = "TEXT_SEC" })
        )
        items[#items + 1] = ui.padding({ 8, 12, 12, 12 },
            ui.text_widget(
                "Generate one with tools/maps/pmtiles_to_tdmap.py and copy it to "
                .. MAPS_DIR .. ".",
                { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
        )
        return ui.vbox({ gap = 0, bg = "BG" }, items)
    end

    local default_path = ez.storage.get_pref(DEFAULT_PREF, "")

    local rows = {}
    for _, arc in ipairs(archives) do
        local subtitle = format_size(arc.size)
        if arc.path == default_path then
            subtitle = (subtitle ~= "" and subtitle .. "  |  " or "") .. "default"
        end
        rows[#rows + 1] = ui.list_item({
            title    = arc.name,
            subtitle = subtitle,
            -- _archive_path is read by handle_key("m") so the actions menu
            -- knows which row is focused without keeping a parallel index.
            _archive_path = arc.path,
            _archive_name = arc.name,
            on_press = function()
                open_map(arc.path)
            end,
        })
    end

    items[#items + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, rows))

    items[#items + 1] = ui.padding({ 4, 8, 2, 8 },
        ui.text_widget("ENTER: open  |  M: actions",
            { color = "TEXT_MUTED", font = "tiny_aa" })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Loader:handle_key(key)
    if key.character == "m" or key.character == "M" then
        local focus_mod = require("ezui.focus")
        local n = focus_mod.current()
        if n and n._archive_path then
            show_archive_menu(self, n._archive_path, n._archive_name)
            return "handled"
        end
    end
    return nil
end

return Loader
