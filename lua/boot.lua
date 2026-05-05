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

    -- Apply saved timezone. Without this the clock runs in UTC, which
    -- makes status-bar readings confusing for users outside GMT.
    local tz = ez.storage.get_pref("tz_posix", nil)
    if tz and tz ~= "" and ez.system.set_timezone then
        ez.system.set_timezone(tz)
    end

    -- Apply saved mesh auto-advert interval (0 = disabled). Set on the
    -- mesh module so the C++ update loop starts the periodic announce
    -- right after radio init, matching what Settings > Radio reflects.
    local adv_ms = tonumber(ez.storage.get_pref("adv_interval_ms", 0)) or 0
    if adv_ms > 0 and ez.mesh and ez.mesh.set_announce_interval then
        ez.mesh.set_announce_interval(adv_ms)
    end

    -- Apply the saved LoRa carrier frequency. The onboarding wizard
    -- writes this on the region step; without persistence, every reboot
    -- would fall back to whatever the radio driver defaults to, which
    -- would silently take the device out of the user's chosen mesh.
    -- The value is persisted as a string because set_pref(float) lands
    -- in NVS as a blob with no matching float reader on the get side.
    local freq_mhz = tonumber(ez.storage.get_pref("radio_freq_mhz", "")) or 0
    if freq_mhz > 0 and ez.radio and ez.radio.set_frequency then
        ez.radio.set_frequency(freq_mhz)
    end

    -- Apply the saved radio protocol profile (meshcore | meshtastic).
    -- The chip is single-tuner so this is a real re-tune of modulation
    -- params + sync word; without it the device would always come up on
    -- the firmware default. Apply *after* set_frequency so the profile
    -- switch keeps the user's band choice.
    local profile = ez.storage.get_pref("radio_profile", "meshcore")
    if profile and profile ~= "meshcore" and ez.radio and ez.radio.set_profile then
        ez.radio.set_profile(profile)
    end

    -- Apply the saved TX throttle interval (queue send spacing). The
    -- driver default is 100 ms; the Settings UI and onboarding offer
    -- 50 / 100 / 200 / 400 ms. A missing pref just leaves the driver
    -- default in place.
    local tx_throttle = tonumber(ez.storage.get_pref("tx_throttle_ms", 0)) or 0
    if tx_throttle > 0 and ez.mesh and ez.mesh.set_tx_throttle then
        ez.mesh.set_tx_throttle(tx_throttle)
    end

    local ui = require("ezui")

    -- Touch -> widget bridge. Subscribes to the touch/down/move/up
    -- bus topics and turns single-finger taps into activations on
    -- whichever focusable list_item / button the user pressed, plus
    -- one-finger drag-to-scroll inside scroll containers. Loaded once
    -- at boot so it covers every screen automatically; no-ops if the
    -- GT911 didn't come up.
    local touch_input_ok, touch_input = pcall(require, "ezui.touch_input")
    if touch_input_ok then touch_input.init() end

    ez.log("[Boot] Framework loaded")

    -- Start background services
    local contacts_svc = require("services.contacts")
    contacts_svc.init()

    local channels_svc = require("services.channels")
    channels_svc.init()

    local dm_svc = require("services.direct_messages")
    dm_svc.init()

    -- Custom packets: P2P extension layer on RAW_CUSTOM. Subscribes
    -- after dm_svc so the DM internals it borrows are ready.
    -- register_demos() installs PING / PONG / GPS\0 handlers; remove
    -- that call to strip the demo subtypes in a production build.
    local custom = require("services.custom_packets")
    custom.init()
    custom.register_demos()

    -- File transfer rides on custom_packets+ACK. Registers its "FILE"
    -- subtype and listens for delivered/undelivered events so the
    -- sender pipeline advances chunk by chunk.
    local file_transfer = require("services.file_transfer")
    file_transfer.init()

    local ui_sounds = require("services.ui_sounds")
    ui_sounds.init()

    -- Notifications service + OTA hookup. The service is just an
    -- in-memory queue; the toast overlay in ezui.screen subscribes to
    -- "notifications/changed" and shows the latest one for a few
    -- seconds. Hooking ota/progress here means a successful OTA push
    -- announces itself wherever the user happens to be.
    local notifications = require("services.notifications")
    ez.bus.subscribe("ota/progress", function(_topic, data)
        if type(data) ~= "table" then return end
        if data.phase == "end" and not data.error then
            notifications.dismiss_source("ota")
            notifications.post({
                title  = "Firmware ready",
                body   = "Reboot to apply the new firmware.",
                source = "ota",
                sticky = true,
                action = {
                    label    = "Reboot",
                    on_press = function() ez.system.restart() end,
                },
            })
        elseif data.phase == "error" then
            notifications.post({
                title  = "OTA failed",
                body   = data.error or "unknown error",
                source = "ota",
            })
        end
    end)

    -- Apps registry: file-type → handler for the file manager. Built-in
    -- handlers register themselves here; screens opened from the registry
    -- are loaded lazily on first `open()` so unused apps don't pull their
    -- screen module into memory at boot.
    local apps = require("services.apps")
    apps.register({
        id    = "text_editor",
        label = "Text Editor",
        exts  = { "md", "txt", "log", "csv", "lua", "json", "ini", "conf" },
        open  = function(path)
            local ed = require("screens.tools.text_editor")
            ed.open(path)
        end,
    })

    -- Engage raw matrix mode. The C3 keyboard controller sometimes
    -- refuses the mode-switch command during the first ~200 ms after
    -- cold boot, so we retry with a short sleep between attempts.
    _G._BOOT_KB_STATE = { attempts = 0, ok = false, final_mode = "?" }
    for attempt = 1, 8 do
        _G._BOOT_KB_STATE.attempts = attempt
        if ez.keyboard.set_mode("raw") then
            _G._BOOT_KB_STATE.ok = true
            break
        end
        ez.system.delay(60)
    end
    _G._BOOT_KB_STATE.final_mode = ez.keyboard.get_mode()
    if not _G._BOOT_KB_STATE.ok then
        ez.log("[boot] Keyboard raw mode unavailable, using legacy path")
    end

    -- GPS: start the background clock-sync loop. Respects the user's
    -- "never / at boot / hourly" preference; does nothing if GPS is disabled.
    local gps_svc = require("services.gps")
    gps_svc.start_sync_loop()

    ez.log("[Boot] Services started")

    -- Apply saved display settings
    local brightness = ez.storage.get_pref("screen_bright", 200)
    ez.display.set_brightness(brightness)
    local kb_backlight = ez.storage.get_pref("kb_backlight", 0)
    ez.keyboard.set_backlight(kb_backlight)

    -- Apply saved audio volume. The settings screen persists this pref
    -- when the slider moves, but the audio driver always boots at 100;
    -- without this restore, every reboot resets the user's choice.
    if ez.audio and ez.audio.set_volume then
        local volume = tonumber(ez.storage.get_pref("audio_volume", 100)) or 100
        ez.audio.set_volume(volume)
    end

    -- Auto-connect to the last successful WiFi network if one was saved
    -- in Settings -> WiFi. Fire-and-forget: the connect call returns
    -- immediately, the radio reassociates in the background. We don't
    -- block boot waiting for it -- a network that's gone shouldn't keep
    -- the user staring at the splash.
    local saved_ssid = ez.storage.get_pref("wifi_ssid", "")
    if saved_ssid and saved_ssid ~= "" and ez.wifi and ez.wifi.connect then
        local saved_pass = ez.storage.get_pref("wifi_password", "")
        ez.log("[Boot] Auto-connecting WiFi: " .. saved_ssid)
        ez.wifi.connect(saved_ssid, saved_pass)
    end

    -- Kick the SNTP client once WiFi is up. Service polls the link
    -- itself so we don't block boot waiting for an association.
    do
        local ok, ntp_svc = pcall(require, "services.ntp")
        if ok and ntp_svc and ntp_svc.kick_after_wifi then
            ntp_svc.kick_after_wifi()
        end
    end

    -- Restore the Dev OTA push server if the user left it enabled.
    -- WiFi association takes a few seconds after connect(), so poll
    -- every 2s up to 30s; once the link is up we hand off to
    -- dev_server_start which itself loads the persisted bearer token.
    if pref_bool("dev_ota_enabled", false) and ez.ota and ez.ota.dev_server_start then
        local attempts_left = 15
        local function try_start()
            if ez.wifi and ez.wifi.is_connected and ez.wifi.is_connected() then
                ez.ota.dev_server_start()
                ez.log("[Boot] Dev OTA auto-started (persisted toggle)")
                return
            end
            attempts_left = attempts_left - 1
            if attempts_left <= 0 then
                ez.log("[Boot] Dev OTA: WiFi never came up, skipping auto-start")
                return
            end
            ez.system.set_timer(2000, try_start)
        end
        ez.system.set_timer(2000, try_start)
    end

    -- Load and push the desktop home screen
    local Desktop = require("screens.desktop")
    local desktop = ui.create_screen(Desktop, {})
    ui.push(desktop)

    -- First-run gate: if the user hasn't completed onboarding yet,
    -- push the wizard on top of the desktop. The wizard pops itself
    -- after the done step so the user lands directly on the desktop.
    local onboarding = require("screens.onboarding")
    if not onboarding.is_onboarded() then
        ez.log("[Boot] First run — entering onboarding wizard")
        onboarding.start()
    end

    -- Start the framework main loop. Honour the saved theme so the
    -- choice made in the wizard (or Settings → Display) survives a
    -- reboot; default to dark when no pref has been written yet.
    local theme_name = ez.storage.get_pref("theme", "dark")
    if theme_name ~= "dark" and theme_name ~= "light" then theme_name = "dark" end
    ui.start({ theme = theme_name })

    -- After a fresh OTA the new image boots in the "pending verify"
    -- state — the bootloader auto-rolls back if we crash too many
    -- times before marking it good. Defer the mark_valid() by a few
    -- seconds so we've actually rendered some frames before declaring
    -- the new firmware healthy. A boot loop in main_loop will hit the
    -- watchdog before this fires.
    if ez.ota and ez.ota.mark_valid then
        ez.system.set_timer(5000, function() ez.ota.mark_valid() end)
    end

    ez.log("[Boot] Boot complete")
end

-- Run boot in a coroutine — async_read needs coroutine context for filesystem I/O
local co = coroutine.create(boot_sequence)
local ok, err = coroutine.resume(co)
if not ok then
    _G._BOOT_ERROR = tostring(err)
    ez.log("[Boot] FATAL: " .. _G._BOOT_ERROR)
elseif coroutine.status(co) == "suspended" then
    _G._BOOT_ERROR = "boot coroutine suspended (stuck on yield)"
    ez.log("[Boot] WARNING: " .. _G._BOOT_ERROR)
end
