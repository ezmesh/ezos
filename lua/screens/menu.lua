-- Main menu screen (accessible from desktop via Tab or More icon)

local ui = require("ezui")
local icons = require("ezui.icons")
local theme = require("ezui.theme")

local Menu = { title = "Menu" }

function Menu:build(state)
    local items = {}

    items[#items + 1] = ui.title_bar("Menu", { back = true })

    local content_items = {}

    -- Section: Communication
    content_items[#content_items + 1] = ui.padding({ 10, 8, 2, 8 },
        ui.text_widget("Communication", { color = "TEXT_MUTED", font = "tiny" })
    )

    local comm_entries = {
        { title = "Messages",  subtitle = "Private & channels",   icon = icons.mail,    screen = "$screens/messages.lua" },
        { title = "Contacts",  subtitle = "Known nodes",          icon = icons.users,   mod = "screens.contacts" },
    }

    for _, entry in ipairs(comm_entries) do
        content_items[#content_items + 1] = self:_make_item(entry)
    end

    -- Section: Tools
    content_items[#content_items + 1] = ui.padding({ 10, 8, 2, 8 },
        ui.text_widget("Tools", { color = "TEXT_MUTED", font = "tiny" })
    )

    local tool_entries = {
        { title = "Map",       subtitle = "Offline maps",         icon = icons.map,      disabled = true },
        { title = "Files",     subtitle = "Flash & SD browser",   icon = icons.folder,   mod = "screens.file_manager" },
        { title = "Terminal",  subtitle = "Lua REPL",             icon = icons.terminal, disabled = true },
    }

    for _, entry in ipairs(tool_entries) do
        content_items[#content_items + 1] = self:_make_item(entry)
    end

    -- Section: Games
    content_items[#content_items + 1] = ui.padding({ 10, 8, 2, 8 },
        ui.text_widget("Games", { color = "TEXT_MUTED", font = "tiny" })
    )

    content_items[#content_items + 1] = self:_make_item({
        title = "Solitaire",
        subtitle = "Klondike card game",
        icon = icons.grid,
        mod = "screens.solitaire",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Minesweeper",
        subtitle = "Classic puzzle",
        icon = icons.grid,
        mod = "screens.minesweeper",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Sudoku",
        subtitle = "Number puzzle",
        icon = icons.grid,
        mod = "screens.sudoku",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Sand",
        subtitle = "Falling sand toy",
        icon = icons.grid,
        mod = "screens.sand",
    })

    content_items[#content_items + 1] = self:_make_item({
        title = "Raycaster",
        subtitle = "FPS dungeon shooter",
        icon = icons.grid,
        mod = "screens.raycaster",
    })

    -- Section: System
    content_items[#content_items + 1] = ui.padding({ 10, 8, 2, 8 },
        ui.text_widget("System", { color = "TEXT_MUTED", font = "tiny" })
    )

    local sys_entries = {
        { title = "Settings",  subtitle = "Device configuration", icon = icons.settings, mod = "screens.settings" },
        { title = "Pixel Fix", subtitle = "Clear screen ghosting", icon = icons.grid,    mod = "screens.pixel_fix" },
        { title = "About",     subtitle = "System info",          icon = icons.info,     disabled = true },
    }

    for _, entry in ipairs(sys_entries) do
        content_items[#content_items + 1] = self:_make_item(entry)
    end

    local content = ui.vbox({ gap = 0 }, content_items)
    items[#items + 1] = ui.scroll({ grow = 1, scroll_offset = state.scroll or 0 }, content)

    return ui.vbox({ gap = 0, bg = "BG" }, items)
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
