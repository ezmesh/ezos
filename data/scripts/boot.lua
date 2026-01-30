-- T-Deck OS Boot Script
-- Entry point for the Lua UI shell

local function mem()
    return math.floor(tdeck.system.get_free_heap() / 1024)
end

-- Global GC helper that logs memory before/after
-- @param mode "collect" (full) or "step" (incremental)
-- @param context Optional string describing why GC is being called
-- @param arg Optional argument for step mode
function _G.run_gc(mode, context, arg)
    local before = mem()
    if mode == "step" then
        collectgarbage("step", arg or 10)
    else
        collectgarbage("collect")
    end
    local after = mem()
    local freed = after - before
    local ctx = context and (" [" .. context .. "]") or ""
    if freed ~= 0 then
        tdeck.system.log(string.format("[GC]%s %dKB -> %dKB (%+dKB)", ctx, before, after, freed))
    end
end

-- Track loaded modules for potential unloading
_G.loaded_modules = {}

-- Load a module using async I/O (must be called from within a coroutine)
-- Uses async_read which yields until the file is loaded
-- Returns the module result directly (no callback needed)
function _G.load_module(path)
    -- Show loading indicator if StatusBar is available
    if _G.StatusBar and _G.StatusBar.show_loading then
        _G.StatusBar.show_loading(true)
    end

    run_gc("collect", "pre-load " .. path)

    -- Read file asynchronously - yields here, resumes when file is read
    -- Note: async_read returns instantly for embedded scripts (no actual I/O)
    local content = async_read(path)

    -- Hide loading indicator
    if _G.StatusBar and _G.StatusBar.hide_loading then
        _G.StatusBar.hide_loading()
    end

    if not content then
        error("Failed to read: " .. path)
    end

    -- Compile the Lua code
    local chunk, err = load(content, "@" .. path)
    if not chunk then
        error("Parse error in " .. path .. ": " .. tostring(err))
    end

    -- Execute the chunk
    local ok, result = pcall(chunk)
    if not ok then
        error("Execute error in " .. path .. ": " .. tostring(result))
    end

    _G.loaded_modules[path] = true
    run_gc("collect", "post-load " .. path)

    return result
end

-- Unload a previously loaded module to free memory
function _G.unload_module(path)
    if _G.loaded_modules[path] then
        _G.loaded_modules[path] = nil
        run_gc("collect", "unload " .. path)
    end
end

-- Spawn a coroutine and immediately resume it
-- Use this to run async code (like load_module) from event handlers
-- @param fn Function to run in the coroutine
-- @return The coroutine object
function _G.spawn(fn)
    local co = coroutine.create(fn)
    coroutine.resume(co)
    return co
end

-- Override dofile to prevent accidental use - use load_module instead
function _G.dofile(path)
    error("dofile() is deprecated. Use load_module() instead (must be called from a coroutine). Path: " .. tostring(path))
end

-- The actual boot sequence runs inside a coroutine so load_module can yield
local function boot_sequence()
    tdeck.system.log("[Boot] Start, free=" .. mem() .. "KB")

    -- Ensure keyboard is in normal mode (in case of crash while in raw mode)
    tdeck.keyboard.set_mode("normal")

    -- Disable key repeat at boot (can be enabled in testing menu)
    tdeck.keyboard.set_repeat_enabled(false)

    -- Load only essential modules at boot (defer others to save memory)
    tdeck.system.log("[Boot] Loading Scheduler...")
    local Scheduler = load_module("/scripts/services/scheduler.lua")
    tdeck.system.log("[Boot] Scheduler loaded, free=" .. mem() .. "KB")

    tdeck.system.log("[Boot] Loading Overlays...")
    local Overlays = load_module("/scripts/ui/overlays.lua")
    tdeck.system.log("[Boot] Overlays loaded, free=" .. mem() .. "KB")

    tdeck.system.log("[Boot] Loading StatusBar...")
    local StatusBar = load_module("/scripts/ui/status_bar.lua")
    tdeck.system.log("[Boot] StatusBar loaded, free=" .. mem() .. "KB")

    tdeck.system.log("[Boot] Loading ThemeManager...")
    local ThemeManager = load_module("/scripts/services/theme.lua")
    tdeck.system.log("[Boot] ThemeManager loaded, free=" .. mem() .. "KB")

    tdeck.system.log("[Boot] Loading TitleBar...")
    local TitleBar = load_module("/scripts/ui/title_bar.lua")
    tdeck.system.log("[Boot] TitleBar loaded, free=" .. mem() .. "KB")

    tdeck.system.log("[Boot] Loading ScreenManager...")
    local ScreenManager = load_module("/scripts/services/screen_manager.lua")
    tdeck.system.log("[Boot] ScreenManager loaded, free=" .. mem() .. "KB")

    tdeck.system.log("[Boot] Loading MainLoop...")
    local MainLoop = load_module("/scripts/services/main_loop.lua")
    tdeck.system.log("[Boot] MainLoop loaded, free=" .. mem() .. "KB")

    tdeck.system.log("[Boot] Loading Logger...")
    local Logger = load_module("/scripts/services/logger.lua")
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

    -- Global timer helpers (wraps Scheduler methods for convenience)
    function _G.set_timeout(callback, delay_ms)
        return Scheduler.set_timer(delay_ms, callback)
    end

    function _G.clear_timeout(timer_id)
        return Scheduler.cancel_timer(timer_id)
    end

    function _G.set_interval(callback, interval_ms)
        return Scheduler.set_interval(interval_ms, callback)
    end

    function _G.clear_interval(timer_id)
        return Scheduler.cancel_timer(timer_id)
    end

    -- Global error display function (can be called from C++ or Lua)
    -- Shows the error screen with the given message
    -- Note: Uses spawn since load_module requires a coroutine context
    function _G.show_error(message, source)
        tdeck.system.log("[Error] " .. tostring(message))
        spawn(function()
            local ok, ErrorScreen = pcall(load_module, "/scripts/ui/screens/error_screen.lua")
            if ok and ErrorScreen and _G.ScreenManager then
                _G.ScreenManager.push(ErrorScreen:new(message, source or "unknown"))
            end
        end)
    end

    -- Initialize theme manager (load wallpaper and icon theme preferences)
    ThemeManager.init()

    -- Initialize main loop with screen manager (must be before registering callbacks!)
    MainLoop.init(ScreenManager)

    -- Register status bar as an overlay (after MainLoop.init)
    StatusBar.register()

    -- Load AppMenu overlay
    tdeck.system.log("[Boot] Loading AppMenu...")
    local AppMenu = load_module("/scripts/ui/screens/app_menu.lua")
    _G.AppMenu = AppMenu
    AppMenu.init()
    tdeck.system.log("[Boot] AppMenu loaded, free=" .. mem() .. "KB")

    -- Load MessageBox overlay
    tdeck.system.log("[Boot] Loading MessageBox...")
    local MessageBox = load_module("/scripts/ui/messagebox.lua")
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

        -- Trackball mode (polling or interrupt)
        local tb_mode = get_pref("tbMode", "polling")
        if tdeck.keyboard and tdeck.keyboard.set_trackball_mode then
            tdeck.keyboard.set_trackball_mode(tb_mode)
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

        -- Mesh path check (skip packets where our hash is in path)
        local path_check = get_pref("pathCheck", true)
        if tdeck.mesh and tdeck.mesh.set_path_check then
            tdeck.mesh.set_path_check(path_check)
        end

        -- UI Sounds (lazy-loaded when enabled)
        local ui_sounds = get_pref("uiSoundsEnabled", false)
        if ui_sounds then
            _G.SoundUtils = load_module("/scripts/ui/sound_utils.lua")
            _G.SoundUtils.init()
        end

        -- Timezone (apply POSIX string directly)
        local tz_posix = get_pref("timezonePosix", nil)
        if tz_posix and tdeck.system and tdeck.system.set_timezone then
            tdeck.system.set_timezone(tz_posix)
        end

        tdeck.system.log("[Boot] Settings applied")
    end

    apply_saved_settings()

    -- Show splash screen (loads, displays, and unloads itself)
    load_module("/scripts/ui/splash.lua")
    run_gc("collect", "post-splash")

    -- Load and start status bar update services
    tdeck.system.log("[Boot] Loading StatusServices, free=" .. mem() .. "KB")
    local StatusServices = load_module("/scripts/services/status_services.lua")
    _G.StatusServices = StatusServices
    tdeck.system.log("[Boot] StatusServices loaded, free=" .. mem() .. "KB")
    if StatusServices and StatusServices.init_all then
        StatusServices.init_all()
    end

    -- Load and initialize Contacts service (handles contact persistence, node cache, auto time sync)
    tdeck.system.log("[Boot] Loading Contacts, free=" .. mem() .. "KB")
    local Contacts = load_module("/scripts/services/contacts.lua")
    _G.Contacts = Contacts
    Contacts.init()
    tdeck.system.log("[Boot] Contacts initialized, free=" .. mem() .. "KB")

    -- Load and initialize DirectMessages service (handles direct messaging over MeshCore)
    tdeck.system.log("[Boot] Loading DirectMessages, free=" .. mem() .. "KB")
    local DirectMessages = load_module("/scripts/services/direct_messages.lua")
    _G.DirectMessages = DirectMessages
    DirectMessages.init()
    tdeck.system.log("[Boot] DirectMessages initialized, free=" .. mem() .. "KB")

    -- Load and initialize Screen Timeout service (dims and turns off screen after inactivity)
    tdeck.system.log("[Boot] Loading ScreenTimeout, free=" .. mem() .. "KB")
    local ScreenTimeout = load_module("/scripts/services/screen_timeout.lua")
    _G.ScreenTimeout = ScreenTimeout
    ScreenTimeout.init()
    ScreenTimeout.register()
    tdeck.system.log("[Boot] ScreenTimeout initialized, free=" .. mem() .. "KB")

    -- Load and push main menu
    tdeck.system.log("[Boot] Loading MainMenu, free=" .. mem() .. "KB")
    local MainMenu = load_module("/scripts/ui/screens/main_menu.lua")
    tdeck.system.log("[Boot] MainMenu loaded, free=" .. mem() .. "KB")
    ScreenManager.push(MainMenu:new())
    tdeck.system.log("[Boot] MainMenu pushed, free=" .. mem() .. "KB")

    -- Start the Lua main loop
    -- This takes over from C++ and handles all input/rendering
    MainLoop.start()

    tdeck.system.log("[Boot] Boot complete, free=" .. mem() .. "KB")
end

-- Start boot sequence in a coroutine so load_module can yield for async I/O
-- The C++ AsyncIO system will resume this coroutine when files are loaded
local boot_co = coroutine.create(boot_sequence)
local ok, err = coroutine.resume(boot_co)
if not ok then
    -- Boot failed - try to show error
    tdeck.system.log("[Boot] FATAL: " .. tostring(err))
    -- Can't use show_error here since it needs load_module
    -- Just log the error - C++ will handle display
end
