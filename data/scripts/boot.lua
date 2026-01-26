-- T-Deck OS Boot Script
-- Entry point for the Lua UI shell

local function mem()
    return math.floor(tdeck.system.get_free_heap() / 1024)
end

-- Global helper to load modules with GC before and after
-- This helps reduce memory fragmentation from dofile parsing
-- Tracks loaded modules for potential unloading
_G.loaded_modules = {}

function _G.load_module(path)
    collectgarbage("collect")
    local result = dofile(path)
    collectgarbage("collect")
    -- Track the module
    _G.loaded_modules[path] = true
    return result
end

-- Unload a previously loaded module to free memory
function _G.unload_module(path)
    if _G.loaded_modules[path] then
        _G.loaded_modules[path] = nil
        -- Clear from package.loaded if present
        package.loaded[path] = nil
        collectgarbage("collect")
    end
end

tdeck.system.log("[Boot] Start, free=" .. mem() .. "KB")

-- Ensure keyboard is in normal mode (in case of crash while in raw mode)
tdeck.keyboard.set_mode("normal")

-- Disable key repeat at boot (can be enabled in testing menu)
tdeck.keyboard.set_repeat_enabled(false)

-- Load only essential modules at boot (defer others to save memory)
tdeck.system.log("[Boot] Loading Scheduler...")
local Scheduler = dofile("/scripts/services/scheduler.lua")
tdeck.system.log("[Boot] Scheduler loaded, free=" .. mem() .. "KB")

tdeck.system.log("[Boot] Loading Overlays...")
local Overlays = dofile("/scripts/ui/overlays.lua")
tdeck.system.log("[Boot] Overlays loaded, free=" .. mem() .. "KB")

tdeck.system.log("[Boot] Loading StatusBar...")
local StatusBar = dofile("/scripts/ui/status_bar.lua")
tdeck.system.log("[Boot] StatusBar loaded, free=" .. mem() .. "KB")

tdeck.system.log("[Boot] Loading ThemeManager...")
local ThemeManager = dofile("/scripts/services/theme.lua")
tdeck.system.log("[Boot] ThemeManager loaded, free=" .. mem() .. "KB")

tdeck.system.log("[Boot] Loading TitleBar...")
local TitleBar = dofile("/scripts/ui/title_bar.lua")
tdeck.system.log("[Boot] TitleBar loaded, free=" .. mem() .. "KB")

tdeck.system.log("[Boot] Loading ScreenManager...")
local ScreenManager = dofile("/scripts/services/screen_manager.lua")
tdeck.system.log("[Boot] ScreenManager loaded, free=" .. mem() .. "KB")

tdeck.system.log("[Boot] Loading MainLoop...")
local MainLoop = dofile("/scripts/services/main_loop.lua")
tdeck.system.log("[Boot] MainLoop loaded, free=" .. mem() .. "KB")

tdeck.system.log("[Boot] Loading Logger...")
local Logger = dofile("/scripts/services/logger.lua")
Logger.init()
tdeck.system.log("[Boot] Logger loaded, free=" .. mem() .. "KB")

-- Make commonly used modules globally available
_G.Scheduler = Scheduler
_G.Overlays = Overlays
_G.StatusBar = StatusBar
_G.ScreenManager = ScreenManager
_G.MainLoop = MainLoop
_G.ThemeManager = ThemeManager
_G.TitleBar = TitleBar
_G.Logger = Logger

-- Icons module is lazy-loaded by main_menu when needed
_G.Icons = nil

-- Initialize theme manager (load wallpaper and icon theme preferences)
ThemeManager.init()

-- Initialize main loop with screen manager (must be before registering callbacks!)
MainLoop.init(ScreenManager)

-- Register status bar as an overlay (after MainLoop.init)
StatusBar.register()

-- App menu is lazy-loaded on first shift+shift
_G.AppMenu = nil

-- Load MessageBox overlay
tdeck.system.log("[Boot] Loading MessageBox...")
local MessageBox = dofile("/scripts/ui/messagebox.lua")
_G.MessageBox = MessageBox
MessageBox.init()
tdeck.system.log("[Boot] MessageBox loaded, free=" .. mem() .. "KB")

-- Set initial status values
StatusBar.set_radio(tdeck.radio.is_initialized(), 0)
if tdeck.mesh.is_initialized() then
    local short_id = tdeck.mesh.get_short_id()
    if short_id then
        StatusBar.set_node_id(short_id)
    end
end
StatusBar.set_battery(tdeck.system.get_battery_percent())

-- Apply all saved settings from storage before splash
local function apply_saved_settings()
    local function get_pref(key, default)
        if tdeck.storage and tdeck.storage.get_pref then
            return tdeck.storage.get_pref(key, default)
        end
        return default
    end

    -- Display brightness
    local brightness = get_pref("brightness", 200)
    if tdeck.display and tdeck.display.set_brightness then
        tdeck.display.set_brightness(brightness)
    end

    -- Keyboard backlight
    local kb_backlight = get_pref("kbBacklight", 0)
    if tdeck.keyboard and tdeck.keyboard.set_backlight then
        tdeck.keyboard.set_backlight(kb_backlight)
    end

    -- Trackball sensitivity
    local tb_sens = get_pref("tbSens", 1)
    if tdeck.keyboard and tdeck.keyboard.set_trackball_sensitivity then
        tdeck.keyboard.set_trackball_sensitivity(tb_sens)
    end

    -- Tick-based scrolling (default: enabled with 20ms interval)
    local tick_scroll = get_pref("tickScroll", true)
    if tdeck.keyboard and tdeck.keyboard.set_tick_scrolling then
        tdeck.keyboard.set_tick_scrolling(tick_scroll)
    end

    -- Tick scroll interval
    local tick_interval = get_pref("tickInterval", 20)
    if tdeck.keyboard and tdeck.keyboard.set_scroll_tick_interval then
        tdeck.keyboard.set_scroll_tick_interval(tick_interval)
    end

    -- Mesh node name (if mesh is initialized)
    if tdeck.mesh and tdeck.mesh.is_initialized and tdeck.mesh.is_initialized() then
        local node_name = get_pref("nodeName", nil)
        if node_name and tdeck.mesh.set_node_name then
            tdeck.mesh.set_node_name(node_name)
        end
    end

    -- Radio TX power
    local tx_power = get_pref("txPower", 22)
    if tdeck.radio and tdeck.radio.set_tx_power then
        tdeck.radio.set_tx_power(tx_power)
    end

    -- UI Sounds (lazy-loaded when enabled)
    local ui_sounds = get_pref("uiSoundsEnabled", false)
    if ui_sounds then
        _G.SoundUtils = dofile("/scripts/ui/sound_utils.lua")
        _G.SoundUtils.init()
    end

    tdeck.system.log("[Boot] Settings applied")
end

apply_saved_settings()

-- Show splash screen (loads, displays, and unloads itself)
dofile("/scripts/ui/splash.lua")
collectgarbage("collect")

-- Load and start built-in services
tdeck.system.log("[Boot] Loading Builtin, free=" .. mem() .. "KB")
local Builtin = dofile("/scripts/services/builtin.lua")
tdeck.system.log("[Boot] Builtin loaded, free=" .. mem() .. "KB")
if Builtin and Builtin.init_all then
    Builtin.init_all()
    tdeck.system.log("[Boot] Builtin.init_all done, free=" .. mem() .. "KB")
end

-- Load and initialize Contacts service (handles contact persistence, node cache, auto time sync)
tdeck.system.log("[Boot] Loading Contacts, free=" .. mem() .. "KB")
local Contacts = dofile("/scripts/services/contacts.lua")
_G.Contacts = Contacts
Contacts.init()
tdeck.system.log("[Boot] Contacts initialized, free=" .. mem() .. "KB")

-- Load and push main menu
tdeck.system.log("[Boot] Loading MainMenu, free=" .. mem() .. "KB")
local MainMenu = dofile("/scripts/ui/screens/main_menu.lua")
tdeck.system.log("[Boot] MainMenu loaded, free=" .. mem() .. "KB")
ScreenManager.push(MainMenu:new())
tdeck.system.log("[Boot] MainMenu pushed, free=" .. mem() .. "KB")

-- Start the Lua main loop
-- This takes over from C++ and handles all input/rendering
MainLoop.start()

tdeck.system.log("[Boot] Boot complete, free=" .. mem() .. "KB")
