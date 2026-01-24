-- T-Deck OS Boot Script
-- Entry point for the Lua UI shell

tdeck.system.log("[Boot] T-Deck OS Lua Shell starting...")

-- Load core modules
local Theme = dofile("/scripts/ui/theme.lua")
local Components = dofile("/scripts/ui/components.lua")
local Scheduler = dofile("/scripts/services/scheduler.lua")
local Overlays = dofile("/scripts/ui/overlays.lua")
local StatusBar = dofile("/scripts/ui/status_bar.lua")

-- Make commonly used modules globally available
_G.Theme = Theme
_G.Components = Components
_G.Scheduler = Scheduler
_G.Overlays = Overlays
_G.StatusBar = StatusBar

-- Register status bar as an overlay
StatusBar.register()

-- Load and start built-in services
local Builtin = dofile("/scripts/services/builtin.lua")
if Builtin and Builtin.init_all then
    Builtin.init_all()
end

-- Load and push main menu
local MainMenu = dofile("/scripts/ui/screens/main_menu.lua")
tdeck.screen.push(MainMenu:new())

tdeck.system.log("[Boot] Boot complete!")
