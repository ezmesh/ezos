-- Developer OTA push: toggle a small HTTP server (port 8080) that
-- accepts a streaming firmware upload from a host on the same WiFi.
--
-- The token is persisted across reboots (NVS, see ota_bindings.cpp).
-- The on/off toggle is also persisted under the "dev_ota_enabled"
-- pref so a host workflow that depends on the server staying up
-- across reboots (the mesh push bot, automated OTA loops) does not
-- have to keep re-enabling it manually after every flash.

local ui = require("ezui")

local DevOTA = { title = "Dev OTA" }

-- Cached on enter and refreshed by update() so build() stays cheap.
local function read_status()
    local s = ez.ota.dev_server_status() or {}
    s.wifi_connected = ez.wifi.is_connected and ez.wifi.is_connected() or false
    return s
end

function DevOTA.initial_state()
    local s = read_status()
    s.progress_bytes = s.bytes_received or 0
    s.progress_phase = nil
    return s
end

function DevOTA:on_enter()
    -- Subscribe to progress events. The push handler runs on the main
    -- loop (not a worker task) so events arrive in step with redraws,
    -- but we still subscribe so we don't have to poll at frame rate.
    self._sub = ez.bus.subscribe("ota/progress", function(_topic, data)
        if type(data) ~= "table" then return end
        self:set_state({
            progress_phase = data.phase,
            progress_bytes = data.bytes or 0,
            progress_error = data.error,
        })
    end)
end

function DevOTA:on_exit()
    if self._sub then ez.bus.unsubscribe(self._sub); self._sub = nil end
end

function DevOTA:update()
    -- Cheap status refresh once a second so toggling WiFi off/on or
    -- a reboot mid-upload show up without the user having to leave
    -- and re-enter the screen.
    local now = ez.system.millis()
    if (now - (self._last_refresh or 0)) > 1000 then
        self._last_refresh = now
        local s = read_status()
        self:set_state({
            running        = s.running,
            port           = s.port,
            token          = s.token,
            ip             = s.ip,
            in_progress    = s.in_progress,
            bytes_received = s.bytes_received,
            last_result    = s.last_result,
            last_error     = s.last_error,
            wifi_connected = s.wifi_connected,
        })
    end
end

local function format_bytes(n)
    n = n or 0
    if n < 1024 then return tostring(n) .. " B" end
    if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
    return string.format("%.2f MB", n / (1024 * 1024))
end

local function status_line(state)
    if not state.wifi_connected then
        return "Not connected to WiFi -- enable WiFi first."
    end
    if state.running then
        return "Listening on " .. (state.ip or "?") .. ":" .. (state.port or 0)
    end
    return "Server stopped."
end

local function last_result_line(state)
    if state.last_result == 1 then
        return "Last upload: " .. (state.last_error or "ok")
    elseif state.last_result == -1 then
        return "Last upload failed: " .. (state.last_error or "?")
    end
    return nil
end

function DevOTA:build(state)
    local content = {}
    local can_run = state.wifi_connected

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Push firmware over WiFi", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 4, 8, 4, 8 },
        ui.toggle("Enable WiFi OTA", state.running and true or false, {
            disabled = not can_run,
            on_change = function(v)
                if v then
                    if not can_run then return end
                    local r = ez.ota.dev_server_start()
                    ez.storage.set_pref("dev_ota_enabled", true)
                    self:set_state({
                        running = r.ok, port = r.port,
                        token = r.token, ip = r.ip,
                    })
                else
                    ez.ota.dev_server_stop()
                    ez.storage.set_pref("dev_ota_enabled", false)
                    self:set_state({
                        running = false, port = 0, token = "",
                        in_progress = false,
                    })
                end
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 8, 6, 8 },
        ui.text_widget(status_line(state),
            { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
    )

    if state.running then
        content[#content + 1] = ui.padding({ 8, 8, 2, 8 },
            ui.text_widget("Token", { color = "ACCENT", font = "small_aa" })
        )
        content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
            ui.text_widget(state.token or "?", { font = "default" })
        )

        -- The token is persisted across reboots so the user only has
        -- to copy it once. Regenerate invalidates the old one and
        -- updates the screen + the running server in one shot.
        content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
            ui.button("Regenerate token", {
                on_press = function()
                    local new_token = ez.ota.regenerate_token()
                    self:set_state({ token = new_token })
                end,
            })
        )

        content[#content + 1] = ui.padding({ 6, 8, 2, 8 },
            ui.text_widget("Push from host", { color = "ACCENT", font = "small_aa" })
        )
        local cmd = "python tools/dev/push_ota.py " ..
                    (state.ip or "?") .. " " ..
                    (state.token or "?") ..
                    " .pio/build/t-deck-plus/firmware.bin"
        content[#content + 1] = ui.padding({ 0, 8, 4, 8 },
            ui.text_widget(cmd, { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
        )

        if state.in_progress then
            content[#content + 1] = ui.padding({ 6, 8, 2, 8 },
                ui.text_widget("Receiving: " .. format_bytes(state.progress_bytes),
                    { color = "ACCENT", font = "small_aa" })
            )
        end
    end

    local last = last_result_line(state)
    if last then
        content[#content + 1] = ui.padding({ 6, 8, 4, 8 },
            ui.text_widget(last, { wrap = true, color = "TEXT_MUTED", font = "small_aa" })
        )
    end

    -- Reboot button when an image is staged but not yet booted. Tucked
    -- below the rest so a user who just finished an upload sees the
    -- obvious next step.
    local pending = ez.ota.pending_partition()
    if pending then
        content[#content + 1] = ui.padding({ 10, 8, 4, 8 },
            ui.text_widget("New firmware staged (" .. pending .. "). Reboot to apply.",
                { wrap = true, color = "ACCENT", font = "small_aa" })
        )
        content[#content + 1] = ui.padding({ 2, 8, 8, 8 },
            ui.button("Reboot now", {
                on_press = function() ez.system.restart() end,
            })
        )
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Dev OTA", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function DevOTA:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return DevOTA
