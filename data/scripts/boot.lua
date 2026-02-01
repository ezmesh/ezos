-- T-Deck OS Boot Script
-- Entry point for the Lua UI shell

-- Bootstrap: load core modules infrastructure first
-- Can't use load_module yet since it's defined in modules.lua
local function bootstrap(path)
    local content = async_read(path)
    if not content then
        error("Failed to read: " .. path)
    end
    local chunk, err = load(content, "@" .. path)
    if not chunk then
        error("Parse error in " .. path .. ": " .. tostring(err))
    end
    local ok, result = pcall(chunk)
    if not ok then
        error("Execute error in " .. path .. ": " .. tostring(result))
    end
    return result
end

-- Load core infrastructure (order matters!)
local Modules = bootstrap("/scripts/core/modules.lua")
local mem = Modules.mem

-- Load Class helper (makes it globally available)
bootstrap("/scripts/core/class.lua")

-- Load a module with logging
local function load(path)
    local mem_before = mem()
    local result = load_module(path)
    local mem_after = mem()
    ez.log("[Boot] Loaded " .. path .. ", free=" .. mem() .. "KB, +" .. (mem_before - mem_after) .. "KB")
    return result
end

-- The actual boot sequence runs inside a coroutine so load_module can yield
local function boot_sequence()
    ez.log("[Boot] Start, free=" .. mem() .. "KB")

    -- Ensure keyboard is in normal mode (in case of crash while in raw mode)
    ez.keyboard.set_mode("normal")

    -- Disable key repeat at boot (can be enabled in testing menu)
    ez.keyboard.set_repeat_enabled(false)

    -- Load core utilities
    local Timers = load("/scripts/core/timers.lua")
    _G.Utils = load("/scripts/core/utils.lua")

    -- Make commonly used modules globally available
    _G.Scheduler = load("/scripts/services/scheduler.lua")

    -- Initialize timer globals (set_timeout, set_interval, etc.)
    Timers.init(Scheduler)

    _G.Overlays = load("/scripts/ui/overlays.lua")
    _G.StatusBar = load("/scripts/ui/status_bar.lua")
    _G.ThemeManager = load("/scripts/services/theme.lua")
    _G.TitleBar = load("/scripts/ui/title_bar.lua")
    _G.ScreenManager = load("/scripts/services/screen_manager.lua")
    _G.MainLoop = load("/scripts/services/main_loop.lua")
    _G.Logger = load("/scripts/services/logger.lua")
    Logger.init()

    -- Icons module is loaded during splash screen
    _G.Icons = nil

    -- Global error display function (can be called from C++ or Lua)
    -- Shows the error screen with the given message
    -- Note: Uses spawn since load_module requires a coroutine context
    function _G.show_error(message, source)
        ez.log("[Error] " .. tostring(message))
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

    -- Load overlays
    _G.AppMenu = load("/scripts/ui/screens/app_menu.lua")
    AppMenu.init()

    _G.MessageBox = load("/scripts/ui/messagebox.lua")
    MessageBox.init()

    _G.Toast = load("/scripts/ui/toast.lua")
    Toast.init()

    -- Set initial status values
    StatusBar.set_radio(ez.radio.is_initialized(), 0)
    if ez.mesh.is_initialized() then
        local short_id = ez.mesh.get_short_id()
        if short_id then
            StatusBar.set_node_id(short_id)
        end
    end
    StatusBar.set_battery(ez.system.get_battery_percent())

    -- Apply all saved settings from storage before splash
    local function apply_saved_settings()
        local get_pref = Utils.get_pref

        -- Display brightness
        local brightness = get_pref("brightness", 200)
        if ez.display and ez.display.set_brightness then
            ez.display.set_brightness(brightness)
        end

        -- Keyboard backlight
        local kb_backlight = get_pref("kbBacklight", 0)
        if ez.keyboard and ez.keyboard.set_backlight then
            ez.keyboard.set_backlight(kb_backlight)
        end

        -- Trackball sensitivity
        local tb_sens = get_pref("tbSens", 1)
        if ez.keyboard and ez.keyboard.set_trackball_sensitivity then
            ez.keyboard.set_trackball_sensitivity(tb_sens)
        end

        -- Trackball mode (polling or interrupt)
        local tb_mode = get_pref("tbMode", "polling")
        if ez.keyboard and ez.keyboard.set_trackball_mode then
            ez.keyboard.set_trackball_mode(tb_mode)
        end

        -- Mesh node name (if mesh is initialized)
        if ez.mesh and ez.mesh.is_initialized and ez.mesh.is_initialized() then
            local node_name = get_pref("nodeName", nil)
            if node_name and ez.mesh.set_node_name then
                ez.mesh.set_node_name(node_name)
            end
        end

        -- Radio TX power
        local tx_power = get_pref("txPower", 22)
        if ez.radio and ez.radio.set_tx_power then
            ez.radio.set_tx_power(tx_power)
        end

        -- Mesh path check (skip packets where our hash is in path)
        local path_check = get_pref("pathCheck", true)
        if ez.mesh and ez.mesh.set_path_check then
            ez.mesh.set_path_check(path_check)
        end

        -- Auto-advert interval (default: Off)
        local auto_advert = tonumber(get_pref("autoAdvert", 1)) or 1
        if ez.mesh and ez.mesh.set_announce_interval then
            -- Convert option index to milliseconds: 1=Off, 2=1h, 3=4h, 4=8h, 5=12h, 6=24h
            local intervals = {0, 3600000, 14400000, 28800000, 43200000, 86400000}
            local ms = intervals[auto_advert] or 0
            ez.mesh.set_announce_interval(ms)
        end

        -- UI Sounds (lazy-loaded when enabled)
        local ui_sounds = get_pref("uiSoundsEnabled", false)
        if ui_sounds then
            _G.SoundUtils = load_module("/scripts/ui/sound_utils.lua")
            _G.SoundUtils.init()
        end

        -- Timezone (apply POSIX string directly)
        local tz_posix = get_pref("timezonePosix", nil)
        if tz_posix and ez.system and ez.system.set_timezone then
            ez.system.set_timezone(tz_posix)
        end

        ez.log("[Boot] Settings applied")
    end

    apply_saved_settings()

    -- Show splash screen (self-contained: loads, displays, unloads)
    load("/scripts/ui/splash.lua")
    run_gc("collect", "post-splash")

    -- Load services
    local StatusServices = load("/scripts/services/status_services.lua")
    _G.StatusServices = StatusServices
    StatusServices.init_all()

    local Contacts = load("/scripts/services/contacts.lua")
    _G.Contacts = Contacts
    Contacts.init()

    local DirectMessages = load("/scripts/services/direct_messages.lua")
    _G.DirectMessages = DirectMessages
    DirectMessages.init()

    local ScreenTimeout = load("/scripts/services/screen_timeout.lua")
    _G.ScreenTimeout = ScreenTimeout
    ScreenTimeout.init()
    ScreenTimeout.register()

    load("/scripts/services/debug.lua")

    local TimezoneSync = load("/scripts/services/timezone_sync.lua")
    TimezoneSync.init()

    -- Load and push main menu
    local MainMenu = load("/scripts/ui/screens/main_menu.lua")
    ScreenManager.push(MainMenu:new())

    -- Start the Lua main loop
    -- This takes over from C++ and handles all input/rendering
    MainLoop.start()

    ez.log("[Boot] Boot complete, free=" .. mem() .. "KB")
end

-- Start boot sequence
-- In simulator mode (__SIMULATOR__ is true), Wasmoon has issues with JS calls from coroutines,
-- so we run boot_sequence directly. async_read is synchronous in the simulator anyway.
-- On real hardware, we use a coroutine so load_module can yield for async I/O.
if __SIMULATOR__ then
    -- Simulator: run directly (async_read is synchronous)
    local ok, err = pcall(boot_sequence)
    if not ok then
        ez.log("[Boot] FATAL: " .. tostring(err))
    end
else
    -- Real hardware: use coroutine for async I/O
    local boot_co = coroutine.create(boot_sequence)
    local ok, err = coroutine.resume(boot_co)
    if not ok then
        -- Boot failed - try to show error
        ez.log("[Boot] FATAL: " .. tostring(err))
        -- Can't use show_error here since it needs load_module
        -- Just log the error - C++ will handle display
    end
end
