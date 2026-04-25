-- Main menu screen (accessible from desktop via Tab or More icon)

local ui        = require("ezui")
local icons     = require("ezui.icons")
local theme     = require("ezui.theme")
local transient = require("ezui.transient")
local focus_mod = require("ezui.focus")

local Menu = { title = "Menu" }

-- Transient key for "last place the user was at in the menu" — the
-- focused item and the scroll offset. Saved on on_leave (push to a
-- sub-screen) and on on_exit (menu popped back to desktop), restored
-- from on_enter. Survives close/reopen within a boot.
local MENU_STATE_KEY = "menu"

function Menu:build(state)
    local items = {}

    items[#items + 1] = ui.title_bar("Menu", { back = true })

    local content_items = {}

    -- Section: Communication
    content_items[#content_items + 1] = ui.padding({ 10, 8, 2, 8 },
        ui.text_widget("Communication", { color = "TEXT_MUTED", font = "tiny_aa" })
    )

    local comm_entries = {
        { title = "Messages",  subtitle = "Private & channels",   icon = icons.mail,    screen = "$screens/chat/messages.lua" },
        { title = "Contacts",  subtitle = "Known nodes",          icon = icons.users,   mod = "screens.chat.contacts" },
    }

    for _, entry in ipairs(comm_entries) do
        content_items[#content_items + 1] = self:_make_item(entry)
    end

    -- Section: Tools
    content_items[#content_items + 1] = ui.padding({ 10, 8, 2, 8 },
        ui.text_widget("Tools", { color = "TEXT_MUTED", font = "tiny_aa" })
    )

    local tool_entries = {
        { title = "Help",        subtitle = "On-device manual + API",icon = icons.info,     mod = "screens.tools.help" },
        { title = "Map",         subtitle = "Offline maps",          icon = icons.map,      mod = "screens.tools.map_loader" },
        { title = "Files",       subtitle = "Flash & SD browser",    icon = icons.folder,   mod = "screens.tools.file_manager" },
        { title = "Terminal",    subtitle = "Shell: cd, ls, run",    icon = icons.terminal, mod = "screens.tools.terminal" },
        { title = "Signal Test", subtitle = "RSSI pingpong vs time", icon = icons.grid,     mod = "screens.tools.signal_test" },
        { title = "WiFi Test",   subtitle = "SoftAP host + join UDP RTT", icon = icons.grid, mod = "screens.tools.wifi_test" },
        { title = "HTTP Test",   subtitle = "Host a status page on :80", icon = icons.grid, mod = "screens.tools.http_test" },
    }

    for _, entry in ipairs(tool_entries) do
        content_items[#content_items + 1] = self:_make_item(entry)
    end

    -- Section: Games
    content_items[#content_items + 1] = ui.padding({ 10, 8, 2, 8 },
        ui.text_widget("Games", { color = "TEXT_MUTED", font = "tiny_aa" })
    )

    content_items[#content_items + 1] = self:_make_item({
        title = "Solitaire",
        subtitle = "Klondike card game",
        icon = icons.grid,
        mod = "screens.games.solitaire",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Minesweeper",
        subtitle = "Classic puzzle",
        icon = icons.grid,
        mod = "screens.games.minesweeper",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Sudoku",
        subtitle = "Number puzzle",
        icon = icons.grid,
        mod = "screens.games.sudoku",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Wasteland",
        subtitle = "Outdoor zombie 3D shooter",
        icon = icons.grid,
        mod = "screens.games.wasteland",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Breakout",
        subtitle = "Paddle bricks across 5 levels",
        icon = icons.grid,
        mod = "screens.games.breakout",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Tetris",
        subtitle = "Top-5 high scores (local)",
        icon = icons.grid,
        mod = "screens.games.tetris",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Pong (2P WiFi)",
        subtitle = "Head-to-head over SoftAP + UDP",
        icon = icons.grid,
        mod = "screens.games.pong",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Starshot",
        subtitle = "Space shooter, guns+items (2P)",
        icon = icons.grid,
        mod = "screens.games.shooter",
    })

    -- Section: System
    content_items[#content_items + 1] = ui.padding({ 10, 8, 2, 8 },
        ui.text_widget("System", { color = "TEXT_MUTED", font = "tiny_aa" })
    )

    local sys_entries = {
        { title = "Settings",  subtitle = "Device configuration", icon = icons.settings, mod = "screens.settings.settings" },
        { title = "Pixel Fix", subtitle = "Clear screen ghosting", icon = icons.grid,    mod = "screens.tools.pixel_fix" },
        { title = "About",     subtitle = "Credits, attributions, version", icon = icons.info, mod = "screens.about" },
    }

    for _, entry in ipairs(sys_entries) do
        content_items[#content_items + 1] = self:_make_item(entry)
    end

    -- Section: Developer — scratch space for widget smoke tests. Left in
    -- the main menu so it's easy to reach while iterating on ezui.
    content_items[#content_items + 1] = ui.padding({ 10, 8, 2, 8 },
        ui.text_widget("Developer", { color = "TEXT_MUTED", font = "tiny_aa" })
    )

    content_items[#content_items + 1] = self:_make_item({
        title = "Widget kitchen sink",
        subtitle = "Every widget on one screen",
        icon = icons.terminal,
        mod = "screens.dev.kitchen_sink",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Prefs Editor",
        subtitle = "Browse, edit, reset, or add NVS prefs",
        icon = icons.settings,
        mod = "screens.dev.prefs_editor",
    })

    local content = ui.vbox({ gap = 0 }, content_items)
    items[#items + 1] = ui.scroll({ grow = 1, scroll_offset = state.scroll or 0 }, content)

    return ui.vbox({ gap = 0, bg = "BG" }, items)
end

function Menu.initial_state()
    local saved = transient.load(MENU_STATE_KEY, {})
    return {
        scroll = saved.scroll or 0,
    }
end

-- Capture the focused item and scroll offset so returning to the menu
-- lands back on the same row the user launched a sub-screen from.
-- Called both when the menu pauses under a pushed screen (on_leave)
-- and when it's popped off the stack (on_exit), so either flow
-- survives through the transient store.
function Menu:_remember()
    local scroll_off = 0
    if self._tree and self._tree.children and self._tree.children[2] then
        scroll_off = self._tree.children[2].scroll_offset or 0
    end
    transient.save(MENU_STATE_KEY, {
        focus  = focus_mod.index,
        scroll = scroll_off,
    })
end

function Menu:on_leave() self:_remember() end
function Menu:on_exit()  self:_remember() end

function Menu:on_enter()
    local saved = transient.load(MENU_STATE_KEY)
    if not saved then return end
    if saved.focus then
        -- focus.rebuild runs after this method (via _rebuild) and will
        -- clamp against the fresh chain length, so a value out of
        -- range after menu restructuring degrades gracefully.
        focus_mod.index = saved.focus
    end
end

function Menu:_make_item(entry)
    local on_press
    if entry.screen then
        on_press = function()
            local u = require("ezui")
            u.push_screen(entry.screen)
        end
    elseif entry.mod then
        on_press = function()
            local screen_mod = require("ezui.screen")
            local ScreenDef = require(entry.mod)
            local init = ScreenDef.initial_state and ScreenDef.initial_state() or {}
            local inst = screen_mod.create(ScreenDef, init)
            screen_mod.push(inst)
        end
    end
    return ui.list_item({
        title = entry.title,
        subtitle = entry.subtitle,
        icon = entry.icon,
        disabled = entry.disabled,
        on_press = on_press,
    })
end

return Menu
