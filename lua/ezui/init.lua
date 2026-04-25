-- ezui: Declarative UI framework for ezOS
-- Entry point that loads all modules and exports the public API.

local async   = require("ezui.async")
local theme   = require("ezui.theme")
local text    = require("ezui.text")
local node    = require("ezui.node")
local layout  = require("ezui.layout")
local widgets = require("ezui.widgets")
local focus   = require("ezui.focus")
local screen  = require("ezui.screen")

local ui = {}

-- Re-export modules
ui.async   = async
ui.theme   = theme
ui.text    = text
ui.node    = node
ui.focus   = focus
ui.screen  = screen

-- Re-export layout constructors
ui.vbox    = layout.vbox
ui.hbox    = layout.hbox
ui.zstack  = layout.zstack
ui.padding = layout.padding
ui.scroll  = layout.scroll
ui.spacer  = layout.spacer
ui.divider = layout.divider

-- Re-export widget constructors
ui.text_widget = widgets.text  -- "text" is also a layout concept, use explicit name
ui.button      = widgets.button
ui.toggle      = widgets.toggle
ui.text_input  = widgets.text_input
ui.dropdown    = widgets.dropdown
ui.list_item   = widgets.list_item
ui.progress    = widgets.progress
ui.status_bar  = widgets.status_bar
ui.title_bar   = widgets.title_bar
ui.spinner     = widgets.spinner
ui.slider      = widgets.slider
ui.rich_text   = widgets.rich_text

-- Markdown renderer (exposes ui.markdown). Loaded lazily so screens that
-- don't use it don't pay the parser's load cost.
local _markdown
function ui.markdown(source, opts)
    if not _markdown then _markdown = require("ezui.markdown") end
    return _markdown.render(source, opts)
end

-- Screen management
ui.push    = screen.push
ui.pop     = screen.pop
ui.replace = screen.replace

-- Create a screen instance from a screen definition + initial state
function ui.create_screen(def, state)
    return screen.create(def, state)
end

-- Convenience: load a screen module, create an instance, and push it.
-- Uses async.task so the status-bar spinner reflects LittleFS reads
-- on cold-loaded screen definitions.
function ui.push_screen(path, ...)
    local args = { ... }
    async.task(function()
        local ok, def = pcall(load_module, path)
        if not ok then
            ez.log("[ezui] Load error: " .. tostring(def))
            return
        end
        local inst
        if def.new then
            inst = def.new(def, table.unpack(args))
        else
            -- Respect the screen's own initial_state() so flags like
            -- `loading = true` or a saved last-view are honoured from
            -- the very first build(), not only after a set_state cycle.
            local init = def.initial_state and def.initial_state() or {}
            inst = screen.create(def, init)
        end
        screen.push(inst)
    end)
end

-- ---------------------------------------------------------------------------
-- Main loop
-- ---------------------------------------------------------------------------

local running = false
local mesh_last = 0
local mesh_interval = 50
local gc_last = 0
local gc_interval = 2000

function ui.start(opts)
    opts = opts or {}

    -- Apply theme
    if opts.theme then theme.set(opts.theme) end

    running = true

    -- Set the global main_loop that C++ calls every frame
    _G.main_loop = function()
        if not running then return end

        local now = ez.system.millis()

        -- Mesh networking update
        if now - mesh_last >= mesh_interval then
            if ez.mesh.is_initialized() then
                ez.mesh.update()
            end
            mesh_last = now
        end

        -- Screen manager update (input + render)
        screen.update()

        -- Incremental garbage collection
        if now - gc_last >= gc_interval then
            run_gc("step", nil, 10)
            gc_last = now
        end
    end

    ez.log("[ezui] Started")
end

function ui.stop()
    running = false
    _G.main_loop = nil
    ez.log("[ezui] Stopped")
end

return ui
