-- NTP server settings.
--
-- The user picks one preset to trust (pool / Google / Cloudflare /
-- NIST / Microsoft / a Custom hostname) and toggles the client on or
-- off. Choices persist via services.ntp; the Time settings screen
-- gets a "NTP source" entry that pushes us. Keeping the preset list
-- explicit (with hostnames visible in the labels) so the user can
-- see exactly which server they're handing the clock to instead of
-- a vague "Internet".

local ui     = require("ezui")
local dialog = require("ezui.dialog")
local ntp    = require("services.ntp")

local NTP = { title = "NTP server" }

local function preset_label(p)
    if p.id == "custom" then
        local host = ntp.get_custom_host()
        if host and host ~= "" then
            return "Custom: " .. host
        end
        return "Custom..."
    end
    if p.host then
        return p.label .. "  (" .. p.host .. ")"
    end
    return p.label
end

local function status_line()
    if not ez.ntp then return "NTP unavailable" end
    if not ntp.is_enabled() then return "Disabled" end
    if not ez.ntp.is_running() then return "Not running" end
    if ez.ntp.is_synced() then
        local last = ez.ntp.last_sync_ms and ez.ntp.last_sync_ms()
        if last then
            local age = math.max(0, math.floor((ez.system.millis() - last) / 1000))
            if age < 60 then
                return "Synced " .. age .. "s ago"
            elseif age < 3600 then
                return "Synced " .. math.floor(age / 60) .. "m ago"
            end
            return "Synced " .. math.floor(age / 3600) .. "h ago"
        end
        return "Synced"
    end
    return "Waiting for sync..."
end

function NTP.initial_state()
    return {
        enabled    = ntp.is_enabled(),
        preset_id  = ntp.get_preset_id(),
    }
end

function NTP:update()
    -- Refresh the status line every second so the "Waiting → Synced
    -- 2s ago → 12s ago" transition is visible without input.
    local now = ez.system.millis()
    if (now - (self._last_refresh or 0)) > 1000 then
        self._last_refresh = now
        self:set_state({})
    end
end

function NTP:_apply()
    -- Re-resolve servers from current state and (re)start the client
    -- if the toggle is on; stop it otherwise. Called on every UI
    -- change so the user sees status flip live without hunting for a
    -- "Save" button.
    if not ez.ntp then return end
    if self._state.enabled then
        ntp.start_if_enabled()
    else
        ntp.stop()
    end
end

local function prompt_custom(self)
    dialog.prompt({
        title       = "Custom NTP host",
        message     = "Hostname",
        value       = ntp.get_custom_host(),
        placeholder = "ntp.example.com",
    }, function(host)
        if not host or host == "" then return end
        host = host:gsub("^%s+", ""):gsub("%s+$", "")
        ntp.set_custom_host(host)
        ntp.set_preset_id("custom")
        self:set_state({ preset_id = "custom" })
        self:_apply()
    end)
end

function NTP:build(state)
    local content = {}

    -- Section: enable
    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Time sync over WiFi", { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.toggle("Use NTP", state.enabled, {
            on_change = function(v)
                state.enabled = v
                ntp.set_enabled(v)
                self:_apply()
            end,
        })
    )
    content[#content + 1] = ui.padding({ 2, 8, 8, 8 },
        ui.text_widget(status_line(),
            { font = "tiny_aa", color = "TEXT_MUTED", wrap = true })
    )

    -- Section: presets
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Source", { color = "ACCENT", font = "small_aa" })
    )

    for _, p in ipairs(ntp.PRESETS) do
        local selected = state.preset_id == p.id
        content[#content + 1] = ui.list_item({
            title    = preset_label(p),
            subtitle = selected and "Selected" or nil,
            on_press = function()
                if p.id == "custom" then
                    prompt_custom(self)
                else
                    ntp.set_preset_id(p.id)
                    self:set_state({ preset_id = p.id })
                    self:_apply()
                end
            end,
        })
    end

    content[#content + 1] = ui.padding({ 6, 8, 8, 8 },
        ui.text_widget(
            "All servers run SNTP on UDP/123. The device polls them " ..
            "in the background; the system clock updates the moment " ..
            "the first response lands.",
            { font = "tiny_aa", color = "TEXT_MUTED", wrap = true })
    )

    -- Section: manual sync
    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.button("Sync now", {
            disabled = not state.enabled,
            on_press = function()
                -- Restarting the client kicks an immediate poll
                -- rather than waiting for the next interval. No-op
                -- when the toggle is off so the button can't run a
                -- service the user just disabled.
                if state.enabled then
                    ntp.start_if_enabled()
                end
            end,
        })
    )

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("NTP server", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function NTP:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return NTP
