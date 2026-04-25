-- WiFi tester screen
--
-- Proves the SoftAP bindings actually carry traffic between two T-Decks.
-- One device runs Host mode — brings up a SoftAP on a fixed SSID, plus a
-- UDP echo server on port 4242 so the other side can bounce packets off
-- it. The other runs Join mode — associates with that SSID, then fires a
-- UDP round-trip every second and charts the RTT.
--
-- The UDP echo server is also started on the Join side, so if the Host
-- ever decides to run its own probe it has a target to hit. Keeping the
-- pair symmetric makes the test useful in both directions with the same
-- screen logic.
--
-- Configuration is intentionally hardcoded — this is a hardware bring-up
-- tool, not a general WiFi utility. For production use, build a proper
-- settings UI on top of these bindings.

local ui         = require("ezui")
local node       = require("ezui.node")
local theme      = require("ezui.theme")
local screen_mod = require("ezui.screen")

-- Shared parameters. Both devices MUST match; the whole point of the
-- test is that Host advertises what Join is configured to expect.
local TEST_SSID = "tdeck-test"
local TEST_PASS = "tdeckpass"
local TEST_PORT = 4242
local PROBE_INTERVAL_MS = 1000
local PROBE_TIMEOUT_MS = 1500
local MAX_SAMPLES = 90        -- 90 × 1 s = 1.5 min of RTT history
local CHART_WINDOW_MS = 90000

-- ---------------------------------------------------------------------------
-- RTT chart (custom node type). Y axis is linear RTT in ms, auto-scaled to
-- max(30, last_max_rtt). Timeouts are rendered as a red tick at the top of
-- the chart so a loss run is immediately visible.
-- ---------------------------------------------------------------------------

local RTT_MIN_MS = 0
local RTT_DEFAULT_MAX_MS = 30    -- small default so a healthy 5-10 ms
                                 -- link uses most of the chart height

local CHART_LEFT_PAD = 26
local CHART_RIGHT_PAD = 4
local CHART_TOP_PAD = 4
local CHART_BOT_PAD = 4

node.register("rtt_chart", {
    measure = function(n, max_w, max_h)
        return max_w, n.height or 110
    end,

    draw = function(n, d, x, y, w, h)
        d.fill_rect(x, y, w, h, theme.color("SURFACE"))
        d.draw_rect(x, y, w, h, theme.color("BORDER"))

        local plot_x = x + CHART_LEFT_PAD
        local plot_y = y + CHART_TOP_PAD
        local plot_w = w - CHART_LEFT_PAD - CHART_RIGHT_PAD
        local plot_h = h - CHART_TOP_PAD - CHART_BOT_PAD
        if plot_w < 4 or plot_h < 4 then return end

        local samples = n.samples or {}
        local now_ms = n.now_ms or ez.system.millis()
        local window = n.window_ms or CHART_WINDOW_MS
        local start_ms = now_ms - window

        -- Auto-scale Y to the largest RTT we've seen in the window, with
        -- a floor so a healthy sub-10 ms link uses meaningful chart
        -- height instead of collapsing to a flat line at the bottom.
        local y_max = RTT_DEFAULT_MAX_MS
        for _, s in ipairs(samples) do
            if s.t_ms >= start_ms and s.rtt and s.rtt > y_max then
                y_max = s.rtt
            end
        end

        local function y_for(ms)
            local norm = (ms - RTT_MIN_MS) / (y_max - RTT_MIN_MS)
            if norm < 0 then norm = 0 end
            if norm > 1 then norm = 1 end
            return plot_y + plot_h - math.floor(norm * plot_h)
        end

        -- 3 reference lines: 25%, 50%, 75% of current Y max, labelled.
        theme.set_font("tiny_aa")
        for _, frac in ipairs({0.25, 0.5, 0.75}) do
            local ref_ms = math.floor(y_max * frac)
            local ry = y_for(ref_ms)
            local seg_x = plot_x
            while seg_x < plot_x + plot_w do
                local seg_end = math.min(seg_x + 4, plot_x + plot_w)
                d.draw_hline(seg_x, ry, seg_end - seg_x, theme.color("BORDER"))
                seg_x = seg_x + 7
            end
            d.draw_text(x + 2, ry - 4, tostring(ref_ms), theme.color("TEXT_MUTED"))
        end

        local function x_for(t_ms)
            local norm = (t_ms - start_ms) / window
            if norm < 0 then norm = 0 end
            if norm > 1 then norm = 1 end
            return plot_x + math.floor(norm * plot_w)
        end

        local prev_x, prev_y
        for _, s in ipairs(samples) do
            if s.t_ms < start_ms then
                -- Off the left edge: still used as previous point for
                -- the next visible segment, but don't draw it.
                prev_x, prev_y = nil, nil
            elseif s.rtt then
                local sx, sy = x_for(s.t_ms), y_for(s.rtt)
                if prev_x then
                    d.draw_line(prev_x, prev_y, sx, sy, theme.color("SUCCESS"))
                end
                d.fill_rect(sx - 1, sy - 1, 3, 3, theme.color("SUCCESS"))
                prev_x, prev_y = sx, sy
            else
                -- Timeout / loss: red tick at the top, break the line.
                local sx = x_for(s.t_ms)
                d.fill_rect(sx - 1, plot_y, 3, 4, theme.color("ERROR"))
                prev_x, prev_y = nil, nil
            end
        end

        d.fill_rect(plot_x + plot_w - 1, plot_y, 1, plot_h,
            theme.color("TEXT_MUTED"))
    end,
})

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

local MODE_HOST = "host"
local MODE_JOIN = "join"

local Screen = { title = "WiFi Test" }

function Screen.initial_state()
    return {
        mode      = MODE_HOST,
        running   = false,
        samples   = {},          -- Join-mode RTT history
        sent      = 0,
        received  = 0,
        last_rtt  = nil,
        status    = "idle",      -- connection / AP status string
        info      = nil,         -- IP / SSID string for the current role
        clients   = 0,           -- Host-mode: current associated station count
    }
end

local function avg_rtt(samples)
    local sum, n = 0, 0
    for _, s in ipairs(samples) do
        if s.rtt then sum = sum + s.rtt; n = n + 1 end
    end
    if n == 0 then return nil end
    return sum / n
end

local function push_sample(self, rtt)
    local st = self._state
    st.samples[#st.samples + 1] = {
        t_ms = ez.system.millis(),
        rtt  = rtt,     -- nil = timeout, marks a loss tick
    }
    while #st.samples > MAX_SAMPLES do
        table.remove(st.samples, 1)
    end
    if rtt then
        st.received = st.received + 1
        st.last_rtt = rtt
    end
    self:set_state({})
end

-- Host role: start SoftAP + UDP echo server. No probing; Host just waits
-- for the other side to hit the echo server. SoftAP can fail on low
-- internal heap (the ESP32-S3 WiFi driver needs ~30-40 kB internal and
-- we're sharing with LoRa, Lua, LVGL framebuffer, etc.) — surface the
-- error to the UI rather than silently lying about the state.
local function start_host(self)
    local ok, err = ez.wifi.start_ap(TEST_SSID, TEST_PASS)
    if not ok then
        self:set_state({
            running = false,
            status  = "AP failed: " .. tostring(err or "unknown"),
            info    = nil,
        })
        return
    end
    ez.wifi.udp_echo_start(TEST_PORT)
    self:set_state({
        running = true,
        status  = "hosting",
        info    = ez.wifi.get_ap_ip(),
        samples = {},
        sent = 0, received = 0, last_rtt = nil,
    })
    -- Poll the client count every second; update the UI when it
    -- changes. A one-shot refresh isn't enough — the AP gains clients
    -- asynchronously as they associate.
    self._timer_id = ez.system.set_interval(1000, function()
        local n = ez.wifi.get_ap_client_count()
        if n ~= self._state.clients then
            self:set_state({ clients = n })
        else
            screen_mod.invalidate()
        end
    end)
end

local function stop_host(self)
    ez.wifi.udp_echo_stop()
    ez.wifi.stop_ap()
    if self._timer_id then
        ez.system.cancel_timer(self._timer_id)
        self._timer_id = nil
    end
    self:set_state({ running = false, status = "idle", clients = 0 })
end

-- Join role: connect to the hosted AP, then kick off a probe loop that
-- fires a UDP round-trip every PROBE_INTERVAL_MS. The probe itself runs
-- inside spawn() because ez.wifi.udp_probe blocks; spawning keeps the UI
-- paint + input responsive.
local function start_join(self)
    self:set_state({
        running = true,
        status  = "connecting",
        info    = nil,
        samples = {},
        sent = 0, received = 0, last_rtt = nil,
    })

    spawn(function()
        ez.wifi.connect(TEST_SSID, TEST_PASS)
        local ok = ez.wifi.wait_connected(15)
        if not ok then
            self:set_state({ status = "connect failed" })
            return
        end
        ez.wifi.udp_echo_start(TEST_PORT)
        self:set_state({
            status = "associated",
            info   = ez.wifi.get_ip(),
        })
    end)

    self._timer_id = ez.system.set_interval(PROBE_INTERVAL_MS, function()
        if not ez.wifi.is_connected() then return end
        spawn(function()
            -- Gateway IP is the SoftAP host (192.168.4.1 by default).
            -- Cache nothing — the gateway can technically change if the
            -- user restarts Host mode between probes.
            local gw = ez.wifi.get_gateway()
            if not gw or gw == "0.0.0.0" then return end
            self._state.sent = self._state.sent + 1
            local rtt = ez.wifi.udp_probe(gw, TEST_PORT, PROBE_TIMEOUT_MS)
            push_sample(self, rtt)
        end)
    end)
end

local function stop_join(self)
    if self._timer_id then
        ez.system.cancel_timer(self._timer_id)
        self._timer_id = nil
    end
    ez.wifi.udp_echo_stop()
    ez.wifi.disconnect()
    self:set_state({ running = false, status = "idle", info = nil })
end

local function start_running(self)
    if self._state.running then return end
    if self._state.mode == MODE_HOST then start_host(self) else start_join(self) end
end

local function stop_running(self)
    if not self._state.running then return end
    if self._state.mode == MODE_HOST then stop_host(self) else stop_join(self) end
end

function Screen:build(state)
    local mode_label = (state.mode == MODE_HOST) and "Host (start AP)"
                                                  or "Join (connect to AP)"

    local info_line
    if state.mode == MODE_HOST then
        if state.running then
            info_line = string.format("SSID '%s' · IP %s · %d client(s)",
                TEST_SSID, state.info or "-", state.clients or 0)
        else
            info_line = string.format("Will host SSID '%s'", TEST_SSID)
        end
    else
        if state.running then
            local rssi = ez.wifi.is_connected() and ez.wifi.get_rssi() or 0
            info_line = string.format("%s · %s · %d dBm",
                state.status or "?", state.info or "-", rssi or 0)
        else
            info_line = string.format("Will join SSID '%s'", TEST_SSID)
        end
    end

    local stats
    if state.mode == MODE_JOIN and state.running then
        local avg = avg_rtt(state.samples)
        local avg_str = avg and string.format("%.1f ms", avg) or "--"
        local last_str = state.last_rtt
            and string.format("%d ms", state.last_rtt)
            or "--"
        local lost = math.max(0, state.sent - state.received)
        stats = string.format("%d rx · last %s · avg %s · lost %d",
            state.received, last_str, avg_str, lost)
    else
        stats = string.format("UDP echo :%d", TEST_PORT)
    end

    local start_label
    if state.running then
        start_label = (state.mode == MODE_HOST) and "Stop Host" or "Stop Join"
    else
        start_label = (state.mode == MODE_HOST) and "Start Host" or "Start Join"
    end

    local rows = {
        ui.title_bar("WiFi Test", { back = true }),

        ui.list_item({
            compact  = true,
            title    = "Mode: " .. mode_label,
            on_press = function()
                stop_running(self)
                self:set_state({
                    mode = (state.mode == MODE_HOST) and MODE_JOIN or MODE_HOST,
                    samples = {},
                    sent = 0, received = 0, last_rtt = nil,
                    status = "idle", info = nil, clients = 0,
                })
            end,
        }),

        ui.padding({ 0, 8, 0, 8 },
            ui.text_widget(info_line, {
                color = "TEXT_SEC", font = "tiny_aa",
            })
        ),

        ui.padding({ 2, 6, 2, 6 }, {
            type = "rtt_chart",
            height = 110,
            samples = state.samples,
            now_ms = ez.system.millis(),
            window_ms = CHART_WINDOW_MS,
        }),

        ui.padding({ 0, 8, 0, 8 },
            ui.text_widget(stats, { color = "TEXT_SEC", font = "tiny_aa" })
        ),

        ui.padding({ 2, 8, 4, 8 },
            ui.button(start_label, {
                on_press = function()
                    if state.running then stop_running(self)
                    else                  start_running(self) end
                end,
            })
        ),
    }

    return ui.vbox({ gap = 0, bg = "BG" }, rows)
end

function Screen:on_enter()
    -- Keep the UI paint ticking so the RSSI line + client counter stay
    -- fresh even when no sample just arrived.
    self._redraw_timer = ez.system.set_interval(500, function()
        screen_mod.invalidate()
    end)
end

function Screen:on_exit()
    stop_running(self)
    if self._redraw_timer then
        ez.system.cancel_timer(self._redraw_timer)
        self._redraw_timer = nil
    end
end

function Screen:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Screen
