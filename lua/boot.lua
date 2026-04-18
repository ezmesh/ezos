-- ezOS Boot Script
-- Bootstraps the module system, loads the UI framework, and starts the shell.

-- Bootstrap: load core module infrastructure (provides load_module, spawn, run_gc)
local function bootstrap(path)
    local content = async_read(path)
    if not content then error("Failed to read: " .. path) end
    local chunk, err = load(content, "@" .. path)
    if not chunk then error("Parse error in " .. path .. ": " .. tostring(err)) end
    local ok, result = pcall(chunk)
    if not ok then error("Execute error in " .. path .. ": " .. tostring(result)) end
    return result
end

bootstrap("$core/modules.lua")

-- Hot reload: replace a module from a LittleFS file, bypassing embedded scripts.
-- Used by the remote tool during development to push changes without reflashing.
function _G.hot_reload(mod_name)
    local path = "/fs/" .. mod_name:gsub("%.", "/") .. ".lua"
    local code = ez.storage.read_file(path)
    if not code then
        return false, "file not found: " .. path
    end

    local fn, err = load(code, "@" .. path)
    if not fn then
        return false, "compile error: " .. tostring(err)
    end

    local ok, result = pcall(fn)
    if not ok then
        return false, "runtime error: " .. tostring(result)
    end

    -- Overwrite the cached module so future require() calls use this version
    package.loaded[mod_name] = result
    ez.log("[HotReload] " .. mod_name)

    -- If the reloaded module is the active screen's definition, swap it in
    local screen_ok, screen = pcall(require, "ezui.screen")
    if screen_ok and screen.peek() then
        local inst = screen.peek()
        if type(result) == "table" and result.build then
            -- Update the screen definition and rebind methods
            inst._def = result
            for k, v in pairs(result) do
                if type(v) == "function" and k ~= "new" and k ~= "build" then
                    inst[k] = v
                end
            end
        end
        inst:_rebuild()
        screen.invalidate()
    end

    return true
end

-- The boot sequence runs inside a coroutine so load_module can yield
local function boot_sequence()
    ez.log("[Boot] Starting ezOS v2")

    -- Clean up stale hot-reload files from LittleFS
    local function clean_hot_reload(dir)
        if not ez.storage.exists(dir) then return end
        local entries = ez.storage.list_dir(dir) or {}
        for _, e in ipairs(entries) do
            local path = dir .. "/" .. e.name
            if e.is_dir then
                clean_hot_reload(path)
                ez.storage.rmdir(path)
            elseif e.name:match("%.lua$") then
                ez.storage.remove(path)
            end
        end
    end
    clean_hot_reload("/fs/screens")
    clean_hot_reload("/fs/ezui")
    clean_hot_reload("/fs/services")
    clean_hot_reload("/fs/core")

    ez.keyboard.set_mode("normal")

    -- NVS prefs coerce types; normalize anything truthy-shaped to bool
    local function pref_bool(key, default)
        local v = ez.storage.get_pref(key, nil)
        if v == nil then return default end
        if type(v) == "boolean" then return v end
        if type(v) == "number"  then return v ~= 0 end
        if type(v) == "string"  then return v == "1" or v == "true" end
        return default
    end

    -- Apply saved keyboard/trackball prefs (defaults match prior behavior)
    ez.keyboard.set_repeat_enabled(pref_bool("kb_rep_enable", false))
    ez.keyboard.set_repeat_delay(tonumber(ez.storage.get_pref("kb_rep_delay", 400)) or 400)
    ez.keyboard.set_repeat_rate(tonumber(ez.storage.get_pref("kb_rep_rate", 50)) or 50)
    if pref_bool("kb_tb_intr", false) then
        ez.keyboard.set_trackball_mode("interrupt")
    end

    local ui = require("ezui")

    ez.log("[Boot] Framework loaded")

    -- Start background services
    local contacts_svc = require("services.contacts")
    contacts_svc.init()

    local channels_svc = require("services.channels")
    channels_svc.init()

    local dm_svc = require("services.direct_messages")
    dm_svc.init()

    ez.log("[Boot] Services started")

    -- Apply saved display settings
    local brightness = ez.storage.get_pref("display_brightness", 200)
    ez.display.set_brightness(brightness)
    local kb_backlight = ez.storage.get_pref("kb_backlight", 0)
    ez.keyboard.set_backlight(kb_backlight)

    -- Load and push the desktop home screen
    local Desktop = require("screens.desktop")
    local desktop = ui.create_screen(Desktop, {})
    ui.push(desktop)

    -- Start the framework main loop
    ui.start({ theme = "dark" })

    ez.log("[Boot] Boot complete")
end

-- Run boot in coroutine (async_read needs coroutine context for filesystem I/O)
if __SIMULATOR__ then
    local ok, err = pcall(boot_sequence)
    if not ok then
        _G._BOOT_ERROR = tostring(err)
        ez.log("[Boot] FATAL: " .. _G._BOOT_ERROR)
    end
else
    local co = coroutine.create(boot_sequence)
    local ok, err = coroutine.resume(co)
    if not ok then
        _G._BOOT_ERROR = tostring(err)
        ez.log("[Boot] FATAL: " .. _G._BOOT_ERROR)
    elseif coroutine.status(co) == "suspended" then
        _G._BOOT_ERROR = "boot coroutine suspended (stuck on yield)"
        ez.log("[Boot] WARNING: " .. _G._BOOT_ERROR)
    end
end
