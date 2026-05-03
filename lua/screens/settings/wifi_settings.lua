-- WiFi settings: scan, connect, persist.
--
-- Saves the last successfully-connected SSID/password into prefs
-- (wifi_ssid / wifi_password) so boot.lua can auto-reconnect on
-- startup. Only one network is remembered at a time -- multi-network
-- profiles can be layered on later if needed.
--
-- ez.wifi.scan() is synchronous (~2-3 s). The scan path shows a
-- "Scanning..." line and lets the call block; the scheduler still
-- runs other tasks during the freeze, so the radio / mesh stay alive.

local ui     = require("ezui")
local icons  = require("ezui.icons")
local dialog = require("ezui.dialog")

local WiFi = { title = "WiFi" }

local PREF_SSID = "wifi_ssid"
local PREF_PASS = "wifi_password"

local function rssi_label(rssi)
    if rssi == nil then return "" end
    if rssi >= -55 then return "excellent" end
    if rssi >= -67 then return "good" end
    if rssi >= -75 then return "fair" end
    return "weak"
end

local function read_status()
    local connected = ez.wifi.is_connected and ez.wifi.is_connected() or false
    return {
        connected = connected,
        ssid      = connected and (ez.wifi.get_ssid and ez.wifi.get_ssid() or "") or "",
        ip        = connected and (ez.wifi.get_ip and ez.wifi.get_ip() or "") or "",
        rssi      = connected and (ez.wifi.get_rssi and ez.wifi.get_rssi() or 0) or 0,
    }
end

function WiFi.initial_state()
    local s = read_status()
    s.networks  = nil      -- nil = not scanned yet, {} = scanned and empty
    s.scanning  = false
    s.connecting_to = nil
    s.message   = nil
    return s
end

function WiFi:update()
    -- Poll connection status once a second so the screen reflects an
    -- async (re)connect without the user having to press anything.
    local now = ez.system.millis()
    if (now - (self._last_refresh or 0)) > 1000 then
        self._last_refresh = now
        local s = read_status()
        if s.connected ~= self._state.connected
           or s.ssid ~= self._state.ssid
           or s.rssi ~= self._state.rssi then
            self:set_state(s)
        end
    end
end

-- De-duplicate a raw scan list by SSID, keeping the strongest entry
-- per SSID, then sort strongest-first. Scans on a saturated band
-- typically return the same network multiple times (different BSSIDs
-- from mesh / band steering); a single row reads better.
local function dedupe_and_sort(list)
    local seen = {}
    local uniq = {}
    for _, net in ipairs(list) do
        if net.ssid and net.ssid ~= "" then
            local prev = seen[net.ssid]
            if not prev or net.rssi > prev.rssi then
                seen[net.ssid] = net
            end
        end
    end
    for _, net in pairs(seen) do uniq[#uniq + 1] = net end
    table.sort(uniq, function(a, b) return (a.rssi or -100) > (b.rssi or -100) end)
    return uniq
end

local function start_scan(self)
    -- Async kick-off + per-tick poll so the UI stays interactive
    -- across the 2-3 s sweep. ez.wifi.scan() (synchronous) is still
    -- available for scripts that want a one-shot, but we don't use
    -- it in the UI -- it freezes input and the title bar's spinner.
    if self._scan_timer then
        ez.system.cancel_timer(self._scan_timer)
        self._scan_timer = nil
    end
    self:set_state({ scanning = true, networks = nil, message = nil })
    require("ezui.screen").invalidate()

    if not (ez.wifi.scan_start and ez.wifi.scan_status and ez.wifi.scan_results) then
        -- Old firmware without the async bindings: fall back to the
        -- legacy blocking call so the UI at least still works.
        spawn(function()
            local list = ez.wifi.scan() or {}
            self:set_state({ networks = dedupe_and_sort(list), scanning = false })
        end)
        return
    end

    ez.wifi.scan_start()

    -- Poll on a 250 ms interval. The Arduino-ESP32 scan typically
    -- finishes in ~2 s, so 8-12 polls is normal; anything past 12 s
    -- we treat as a failure rather than a stuck UI.
    local started_ms = ez.system.millis()
    self._scan_timer = ez.system.set_interval(250, function()
        local status = ez.wifi.scan_status()
        if status == "running" then
            if ez.system.millis() - started_ms > 12000 then
                ez.system.cancel_timer(self._scan_timer)
                self._scan_timer = nil
                self:set_state({ scanning = false,
                    message = "Scan timed out" })
            end
            return
        end

        ez.system.cancel_timer(self._scan_timer)
        self._scan_timer = nil

        if status == "failed" then
            self:set_state({ scanning = false,
                message = "Scan failed" })
            return
        end

        local list = ez.wifi.scan_results() or {}
        self:set_state({ networks = dedupe_and_sort(list), scanning = false })
    end)
end

local function connect_to(self, ssid, password)
    self:set_state({ connecting_to = ssid, message = "Connecting to " .. ssid .. "..." })
    require("ezui.screen").invalidate()

    spawn(function()
        ez.wifi.connect(ssid, password or "")
        local ok = ez.wifi.wait_connected and ez.wifi.wait_connected(15) or false
        if ok then
            ez.storage.set_pref(PREF_SSID, ssid)
            ez.storage.set_pref(PREF_PASS, password or "")
            local s = read_status()
            s.connecting_to = nil
            s.message = "Connected. IP: " .. s.ip
            self:set_state(s)
        else
            self:set_state({
                connecting_to = nil,
                message = "Failed to connect to " .. ssid,
            })
        end
    end)
end

local function tap_network(self, net)
    if net.secure then
        dialog.prompt({
            title       = net.ssid,
            message     = "Password",
            placeholder = "WiFi password",
        }, function(pwd) connect_to(self, net.ssid, pwd) end)
    else
        connect_to(self, net.ssid, "")
    end
end

local function forget_current(self)
    ez.wifi.disconnect()
    ez.storage.set_pref(PREF_SSID, "")
    ez.storage.set_pref(PREF_PASS, "")
    self:set_state({
        connected = false, ssid = "", ip = "", rssi = 0,
        message = "Disconnected and forgotten.",
    })
end

function WiFi:build(state)
    local content = {}

    -- Status header.
    if state.connected then
        content[#content + 1] = ui.padding({ 8, 8, 2, 8 },
            ui.text_widget("Connected", { color = "ACCENT", font = "small_aa" }))
        content[#content + 1] = ui.padding({ 0, 8, 2, 8 },
            ui.text_widget(state.ssid))
        content[#content + 1] = ui.padding({ 0, 8, 2, 8 },
            ui.text_widget(
                state.ip .. "  --  " .. state.rssi .. " dBm  (" .. rssi_label(state.rssi) .. ")",
                { color = "TEXT_MUTED", font = "small_aa" }))
        content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
            ui.list_item({
                title    = "Forget this network",
                subtitle = "Disconnect and clear saved password",
                icon     = icons.settings,
                on_press = function() forget_current(self) end,
            }))
    else
        content[#content + 1] = ui.padding({ 8, 8, 2, 8 },
            ui.text_widget("Not connected", { color = "ACCENT", font = "small_aa" }))
        local saved = ez.storage.get_pref(PREF_SSID, "")
        if saved and saved ~= "" then
            content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
                ui.text_widget("Last used: " .. saved,
                    { color = "TEXT_MUTED", font = "small_aa" }))
        end
    end

    if state.message then
        content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
            ui.text_widget(state.message, {
                color = "TEXT_MUTED", font = "small_aa", wrap = true,
            }))
    end

    -- Scan trigger.
    content[#content + 1] = ui.padding({ 8, 8, 2, 8 },
        ui.text_widget("Networks", { color = "ACCENT", font = "small_aa" }))
    content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
        ui.list_item({
            title    = state.scanning and "Scanning..." or "Scan for networks",
            subtitle = state.scanning and "Hold tight (~2 s)"
                                       or "Discover nearby access points",
            icon     = icons.radio_tower,
            on_press = function()
                if not state.scanning then start_scan(self) end
            end,
        }))

    -- Results list.
    if state.networks then
        if #state.networks == 0 then
            content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
                ui.text_widget("No networks found.",
                    { color = "TEXT_MUTED", font = "small_aa" }))
        else
            for _, net in ipairs(state.networks) do
                local subtitle = string.format("%d dBm  (%s)%s",
                    net.rssi or 0,
                    rssi_label(net.rssi),
                    net.secure and "  - secured" or "  - open")
                local trailing = (state.connected and net.ssid == state.ssid) and "Connected" or nil
                content[#content + 1] = ui.list_item({
                    title    = net.ssid,
                    subtitle = subtitle,
                    icon     = net.secure and icons.settings or icons.radio_tower,
                    trailing = trailing,
                    on_press = function() tap_network(self, net) end,
                })
            end
        end
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("WiFi", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function WiFi:on_exit()
    -- Cancel an in-flight scan poll so we don't keep ticking after
    -- the user has navigated away.
    if self._scan_timer then
        ez.system.cancel_timer(self._scan_timer)
        self._scan_timer = nil
    end
end

function WiFi:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return WiFi
