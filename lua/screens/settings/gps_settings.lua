-- GPS settings screen
-- Power gate and time-sync cadence. Changes apply immediately through
-- services.gps; the hardware UART itself is always running (see main.cpp),
-- so disabling is a UI-level gate for now.

local ui      = require("ezui")
local gps_svc = require("services.gps")

local GPS = { title = "GPS" }

-- Human-readable labels for the sync_mode enum. Order matches index → value below.
local SYNC_LABELS = { "Never", "At boot", "Hourly" }
local SYNC_VALUES = { "never", "boot",   "hourly" }

local function sync_mode_index()
    local cur = gps_svc.get_sync_mode()
    for i, v in ipairs(SYNC_VALUES) do
        if v == cur then return i end
    end
    return 2  -- default "boot"
end

function GPS.initial_state()
    return {
        enabled    = gps_svc.is_enabled(),
        sync_index = sync_mode_index(),
    }
end

function GPS:build(state)
    local content = {}

    -- Section: Power
    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Power", { color = "ACCENT", font = "small" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.toggle("GPS enabled", state.enabled, {
            on_change = function(val)
                state.enabled = val
                gps_svc.set_enabled(val)
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 8, 4, 8 },
        ui.text_widget(
            "When off, the map hides your position and screens see no fix.",
            { wrap = true, color = "TEXT_MUTED", font = "small" })
    )

    -- Section: Clock sync
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Clock sync", { color = "ACCENT", font = "small" })
    )

    content[#content + 1] = ui.padding({ 2, 6, 2, 6 },
        ui.dropdown(SYNC_LABELS, {
            label = "Mode",
            value = state.sync_index,
            on_change = function(idx)
                state.sync_index = idx
                gps_svc.set_sync_mode(SYNC_VALUES[idx])
            end,
        })
    )

    content[#content + 1] = ui.padding({ 2, 8, 4, 8 },
        ui.text_widget(
            "At boot: sync once on first fix after boot. Hourly: re-sync every hour. "
            .. "The GPS clock is satellite-accurate, useful when no NTP server is available.",
            { wrap = true, color = "TEXT_MUTED", font = "small" })
    )

    -- Section: Status (live)
    content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
        ui.text_widget("Status", { color = "ACCENT", font = "small" })
    )

    local loc = ez.gps.get_location()
    local sats = ez.gps.get_satellites()
    local fix_line
    if loc and loc.valid then
        fix_line = string.format("Fix: %.5f, %.5f  (age %ds)", loc.lat, loc.lon, (loc.age or 0) // 1000)
    else
        fix_line = "Fix: none"
    end
    content[#content + 1] = ui.padding({ 2, 8, 2, 8 },
        ui.text_widget(fix_line, { font = "small", color = "TEXT_SEC" })
    )

    if sats then
        content[#content + 1] = ui.padding({ 2, 8, 2, 8 },
            ui.text_widget(
                string.format("Satellites: %d  |  HDOP: %.1f", sats.count or 0, sats.hdop or 99.9),
                { font = "small", color = "TEXT_SEC" })
        )
    end

    content[#content + 1] = ui.list_item({
        title = "Sync clock now",
        subtitle = "Requires a current fix",
        on_press = function()
            if ez.gps.sync_time() then
                self:set_state({})
            end
        end,
    })

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("GPS", { back = true }),
        ui.scroll({ grow = 1, scroll_offset = state._scroll or 0 },
            ui.vbox({ gap = 0 }, content)),
    })
end

function GPS:update()
    -- Keep the live status fresh (fix, sat count) while the screen is open.
    -- Throttle to ~1 Hz so we don't rebuild the tree every frame.
    local now = ez.system.millis()
    if (now - (self._last_refresh or 0)) > 1000 then
        self._last_refresh = now
        self:set_state({})
    end
end

function GPS:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then return "pop" end
    return nil
end

return GPS
