-- Signal tester screen
--
-- Pings a selected contact at a fixed interval and charts the RSSI of the
-- received replies against time. Two transports:
--   Direct — services.signal_test "SIGT" custom packet, not forwarded by
--            stock MeshCore repeaters, so the chart reflects raw direct
--            radio link quality between the two devices.
--   DM     — encrypted TXT_MSG through the normal DM path, which WILL go
--            through repeaters if the peer is out of direct range. The
--            RSSI then represents the last hop, not end-to-end; that
--            contrast with Direct mode is the whole reason both exist.
--
-- Depends on lua/services/signal_test.lua being initialized at boot, which
-- installs the responder hooks on every firmware-flashed peer.

local ui            = require("ezui")
local node          = require("ezui.node")
local theme         = require("ezui.theme")
local screen_mod    = require("ezui.screen")
local contacts_svc  = require("services.contacts")
local signal_test   = require("services.signal_test")

-- ---------------------------------------------------------------------------
-- Chart widget (registered once on module load)
-- ---------------------------------------------------------------------------

-- Y-axis bounds. The low end is just past where stock LoRa with high SF /
-- low coding rate still squeaks through (-120 dBm) and the high end is
-- comfortably above line-of-sight close-range (-30 dBm). Any sample
-- outside this range gets clipped to the nearest edge so the trace never
-- escapes the chart box.
local CHART_MIN_DBM = -130
local CHART_MAX_DBM = -30

-- Reference lines. Labels correspond to the working-guide numbers the
-- user is calibrating against:
--   -60  line-of-sight close range
--   -80  solid
--   -100 getting thin
--   -120 where SF / coding rate start earning their keep
local CHART_REFS = {
    { dbm = -60,  label = "-60 LOS",   color = "SUCCESS" },
    { dbm = -80,  label = "-80 solid", color = "INFO" },
    { dbm = -100, label = "-100 thin", color = "WARNING" },
    { dbm = -120, label = "-120 edge", color = "ERROR" },
}

local CHART_LEFT_PAD = 26  -- room for axis labels ("-120")
local CHART_RIGHT_PAD = 4
local CHART_TOP_PAD = 4
local CHART_BOT_PAD = 4

local function rssi_color(rssi)
    if rssi >= -60  then return theme.color("SUCCESS") end
    if rssi >= -80  then return theme.color("INFO") end
    if rssi >= -100 then return theme.color("WARNING") end
    return theme.color("ERROR")
end

node.register("sig_chart", {
    measure = function(n, max_w, max_h)
        return max_w, n.height or 120
    end,

    draw = function(n, d, x, y, w, h)
        -- Background
        d.fill_rect(x, y, w, h, theme.color("SURFACE"))
        d.draw_rect(x, y, w, h, theme.color("BORDER"))

        local plot_x = x + CHART_LEFT_PAD
        local plot_y = y + CHART_TOP_PAD
        local plot_w = w - CHART_LEFT_PAD - CHART_RIGHT_PAD
        local plot_h = h - CHART_TOP_PAD - CHART_BOT_PAD
        if plot_w < 4 or plot_h < 4 then return end

        local span_dbm = CHART_MAX_DBM - CHART_MIN_DBM

        local function y_for(dbm)
            if dbm > CHART_MAX_DBM then dbm = CHART_MAX_DBM end
            if dbm < CHART_MIN_DBM then dbm = CHART_MIN_DBM end
            local norm = (dbm - CHART_MIN_DBM) / span_dbm
            return plot_y + plot_h - math.floor(norm * plot_h)
        end

        -- Reference lines + axis labels. Dashed horizontal lines at each
        -- guide-book threshold so the live trace can be read against the
        -- field-strength rubric at a glance.
        theme.set_font("tiny_aa")
        local label_x = x + 2
        for _, ref in ipairs(CHART_REFS) do
            local ry = y_for(ref.dbm)
            local col = theme.color(ref.color)
            -- 4-on/3-off dashed hline so the reference is visible but
            -- doesn't compete with the trace for attention.
            local seg_x = plot_x
            while seg_x < plot_x + plot_w do
                local seg_end = math.min(seg_x + 4, plot_x + plot_w)
                d.draw_hline(seg_x, ry, seg_end - seg_x, col)
                seg_x = seg_x + 7
            end
            d.draw_text(label_x, ry - 4, tostring(ref.dbm), col)
        end

        -- Trace. Samples carry absolute t_ms; window_ms and now_ms are
        -- passed by the screen so the chart slides continuously without
        -- the node having to touch the clock.
        local samples  = n.samples or {}
        local now_ms   = n.now_ms or ez.system.millis()
        local window   = n.window_ms or 60000
        local start_ms = now_ms - window

        local function x_for(t_ms)
            local norm = (t_ms - start_ms) / window
            if norm < 0 then norm = 0 end
            if norm > 1 then norm = 1 end
            return plot_x + math.floor(norm * plot_w)
        end

        local prev_x, prev_y
        for _, s in ipairs(samples) do
            if s.t_ms >= start_ms and s.rssi then
                local sx, sy = x_for(s.t_ms), y_for(s.rssi)
                local col = rssi_color(s.rssi)
                if prev_x then
                    d.draw_line(prev_x, prev_y, sx, sy, col)
                end
                d.fill_rect(sx - 1, sy - 1, 3, 3, col)
                prev_x, prev_y = sx, sy
            else
                -- A sample that falls off the left edge still informs
                -- the next segment's starting point, so advance prev
                -- without drawing.
                prev_x, prev_y = nil, nil
            end
        end

        -- "Now" tick on the right edge so it's obvious which way time flows.
        d.fill_rect(plot_x + plot_w - 1, plot_y, 1, plot_h,
            theme.color("TEXT_MUTED"))
    end,
})

-- ---------------------------------------------------------------------------
-- Screen
-- ---------------------------------------------------------------------------

local MODE_DIRECT = "direct"
local MODE_DM     = "dm"

-- Rolling window of samples shown on the chart. Tuned to match the slower
-- 15 s ping cadence: a 4 min window at ~16 samples gives enough context
-- to see a walk-around trace without the chart feeling empty early on.
local MAX_SAMPLES  = 64
local CHART_WINDOW_MS = 4 * 60 * 1000

-- Returns true iff our node's pubkey sorts strictly below the peer's.
-- Used to pick a deterministic initiator when both peers have the tester
-- open: exactly one side sends pings, both sides chart the pingpong. If
-- either pubkey is unavailable (mesh not up yet, no peer selected), we
-- return false so nothing transmits and the test waits for the state.
local function is_initiator(state)
    local my = ez.mesh.get_public_key_hex and ez.mesh.get_public_key_hex()
    if not my or not state.peer_key then return false end
    return my < state.peer_key
end

-- Ping cadence, per transport. Direct (RAW_CUSTOM) is cheap — one
-- short packet hitting the peer's radio directly — so 15 s gives
-- dense coverage when walking around. DM mode rides the encrypted
-- TXT_MSG path with its own retries + possible repeater hops and is
-- genuinely costly on airtime; 60 s keeps that mode's footprint on
-- the mesh within reason. The active interval is picked from
-- PING_INTERVAL_MS[state.mode] when the test starts, and a mode
-- toggle stops the test so the next start picks up the new cadence.
local PING_INTERVAL_MS = {
    [MODE_DIRECT] = 15000,
    [MODE_DM]     = 60000,
}

-- Pending outgoing pings we haven't seen a reply for. Key = nonce, value
-- = send_ms. Used to compute round-trip time on reply (recorded into the
-- sample) and to drive the "lost" counter when a nonce is overwritten by
-- a newer ping without ever being matched.
local pending = {}

local function gen_nonce()
    -- 7 hex chars is plenty of entropy inside the 1 s interval window,
    -- and stays within lua_Integer range (0x7FFFFFFF) on the int32 Lua
    -- build the firmware ships with — math.random(0, 0xFFFFFFFF) overflows.
    return string.format("%07x", math.random(0, 0x7FFFFFFF))
end

local Screen = { title = "Signal Test" }

function Screen.initial_state()
    return {
        peer_key  = nil,  -- contact pub_key_hex
        peer_name = nil,
        mode      = MODE_DIRECT,
        running   = false,
        samples   = {},
        sent      = 0,
        received  = 0,
        last_rssi = nil,
    }
end

local function avg_rssi(samples)
    local sum, n = 0, 0
    for _, s in ipairs(samples) do
        if s.rssi then
            sum = sum + s.rssi
            n = n + 1
        end
    end
    if n == 0 then return nil end
    return sum / n
end

-- Push a sample into state and trigger a rebuild. Called from the bus
-- handler; the subscribe callback passes (self) through the closure.
local function push_sample(self, sample)
    local st = self._state
    st.samples[#st.samples + 1] = sample
    while #st.samples > MAX_SAMPLES do
        table.remove(st.samples, 1)
    end
    st.received = st.received + 1
    st.last_rssi = sample.rssi
    self:set_state({})  -- rebuild with the mutated table
end

-- Fire off a single ping in the current mode. Also invalidates any
-- in-flight nonce for the same peer so the "lost" count reflects only
-- truly missed replies, not old pings that raced a new one.
local function do_ping(self)
    local st = self._state
    if not st.peer_key then return end
    local nonce = gen_nonce()
    pending[nonce] = ez.system.millis()
    st.sent = st.sent + 1

    if st.mode == MODE_DIRECT then
        signal_test.ping_direct(st.peer_key, nonce)
    else
        signal_test.ping_dm(st.peer_key, nonce)
    end
    self:set_state({})
end

local function start_running(self)
    if self._state.running then return end
    if not self._state.peer_key then return end
    self:set_state({ running = true })

    -- Only the initiator transmits; the responder's hooks (installed via
    -- signal_test.start() on on_enter) will echo incoming pings and post
    -- samples on the bus so this side still charts a trace. Without the
    -- role check both peers would ping each other at the same cadence
    -- and the airtime would double for no added information.
    if is_initiator(self._state) then
        do_ping(self)
        local cadence = PING_INTERVAL_MS[self._state.mode]
                     or PING_INTERVAL_MS[MODE_DIRECT]
        self._timer_id = ez.system.set_interval(cadence, function()
            do_ping(self)
        end)
    end
end

local function stop_running(self)
    if not self._state.running then return end
    self:set_state({ running = false })
    if self._timer_id then
        ez.system.cancel_timer(self._timer_id)
        self._timer_id = nil
    end
end

local function pick_contact(self)
    local contacts = contacts_svc.get_all()

    -- Stash the signal-test screen under a dedicated name. Inside
    -- Picker:build the implicit `self` rebinds to the picker instance
    -- (method-call convention), so without this alias the on_press
    -- handlers would write their set_state() onto the picker's own
    -- state table — which is why earlier builds left the tester's
    -- Peer row stuck on "<pick>" after selection.
    local tester = self

    local Picker = { title = "Pick peer" }
    function Picker:build(_state)
        local rows = {}
        rows[#rows + 1] = ui.title_bar("Pick peer", { back = true })
        if #contacts == 0 then
            rows[#rows + 1] = ui.padding({ 20, 10, 10, 10 },
                ui.text_widget("No contacts yet", {
                    color = "TEXT_MUTED", text_align = "center",
                })
            )
        else
            local items = {}
            for _, c in ipairs(contacts) do
                items[#items + 1] = ui.list_item({
                    title    = c.name,
                    subtitle = c.pub_key_hex:sub(1, 16) .. "...",
                    on_press = function()
                        -- Stopping any running test before the peer swap
                        -- avoids a stray reply from the old peer being
                        -- charted against the new peer's nonce space.
                        stop_running(tester)
                        tester:set_state({
                            peer_key  = c.pub_key_hex,
                            peer_name = c.name,
                            samples   = {},
                            sent      = 0,
                            received  = 0,
                            last_rssi = nil,
                        })
                        pending = {}
                        screen_mod.pop()
                    end,
                })
            end
            rows[#rows + 1] = ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, items))
        end
        return ui.vbox({ gap = 0, bg = "BG" }, rows)
    end
    function Picker:handle_key(k)
        if k.special == "BACKSPACE" or k.special == "ESCAPE" then return "pop" end
    end
    screen_mod.push(screen_mod.create(Picker, {}))
end

function Screen:build(state)
    local peer_text = state.peer_name
        and (state.peer_name .. "  " .. (state.peer_key or ""):sub(1, 8))
        or "Pick a contact..."

    local mode_label = (state.mode == MODE_DIRECT) and "Direct (no relay)"
                                                   or "DM (may relay)"
    local role = is_initiator(state) and "initiator" or "responder"

    local sample_count = #state.samples
    local last_str = state.last_rssi
        and string.format("%d dBm", math.floor(state.last_rssi))
        or "--"
    local avg = avg_rssi(state.samples)
    local avg_str = avg and string.format("%d dBm", math.floor(avg)) or "--"
    -- Loss is only meaningful on the initiator side, which tracks a
    -- sent-vs-received delta. The responder doesn't send; hide that
    -- field so it doesn't bogusly show the received count as "lost".
    local stats
    if is_initiator(state) then
        local lost = math.max(0, state.sent - state.received)
        stats = string.format("%s · %d rx · last %s · avg %s · lost %d",
            role, sample_count, last_str, avg_str, lost)
    else
        stats = string.format("%s · %d rx · last %s · avg %s",
            role, sample_count, last_str, avg_str)
    end

    local has_peer = state.peer_key ~= nil
    local start_label
    if not has_peer then
        start_label = "Pick peer first"
    elseif state.running then
        start_label = "Stop"
    else
        start_label = "Start"
    end

    -- Two rows up top, a chart in the middle, and a one-line footer with
    -- stats + the Start/Stop toggle. Compact list_items keep the top two
    -- rows tight so the chart has 115 px to work with on a 240 px screen.
    local rows = {
        ui.title_bar("Signal Test", { back = true }),

        ui.list_item({
            compact  = true,
            title    = "Peer: " .. (state.peer_name or "<pick>"),
            trailing = state.peer_key and state.peer_key:sub(1, 8) or nil,
            on_press = function() pick_contact(self) end,
        }),

        ui.list_item({
            compact  = true,
            title    = "Mode: " .. mode_label,
            on_press = function()
                stop_running(self)
                self:set_state({
                    mode      = (state.mode == MODE_DIRECT) and MODE_DM or MODE_DIRECT,
                    samples   = {},
                    sent      = 0,
                    received  = 0,
                    last_rssi = nil,
                })
                pending = {}
            end,
        }),

        ui.padding({ 4, 6, 2, 6 }, {
            type = "sig_chart",
            height = 115,
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
                    if not has_peer then
                        pick_contact(self)
                    elseif state.running then
                        stop_running(self)
                    else
                        start_running(self)
                    end
                end,
            })
        ),
    }

    return ui.vbox({ gap = 0, bg = "BG" }, rows)
end

function Screen:on_enter()
    -- Install the responder + DM hook only while the screen is open. The
    -- peer must also have this screen open (or at least have the service
    -- started) for pings to come back. No background traffic otherwise.
    signal_test.start()

    self._sub = ez.bus.subscribe("signal_test/sample", function(_t, s)
        if not s then return end
        -- Gate on `running` so samples only land on the chart during an
        -- active test. Without this, the responder would keep recording
        -- every incoming ping even after the operator hit Stop.
        if not self._state.running then return end
        if self._state.peer_key and s.pub_key_hex ~= self._state.peer_key then return end
        -- Only credit samples whose mode matches what we're currently
        -- testing. Otherwise a stale DM reply to a previous Direct run
        -- would show up on the fresh Direct chart (and vice versa).
        if s.mode ~= self._state.mode then return end
        if s.nonce and pending[s.nonce] then
            pending[s.nonce] = nil
        end
        push_sample(self, { t_ms = s.t_ms, rssi = s.rssi, snr = s.snr })
    end)

    -- Tick screen invalidation so the chart's rolling window slides even
    -- when no new samples arrived since the last frame.
    self._redraw_timer = ez.system.set_interval(500, function()
        screen_mod.invalidate()
    end)
end

function Screen:on_exit()
    stop_running(self)
    if self._sub then
        ez.bus.unsubscribe(self._sub)
        self._sub = nil
    end
    if self._redraw_timer then
        ez.system.cancel_timer(self._redraw_timer)
        self._redraw_timer = nil
    end
    -- Tear the responder down so the device stops answering SIGT pings
    -- and stops storing [SIGT] DM replies once the tester is closed.
    signal_test.stop()
end

function Screen:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    -- Convenience: 'p' purges any SIGT pings/replies that leaked into the
    -- DM conversation with the active peer. Useful after a DM-mode run.
    if key.character == "p" and self._state.peer_key then
        signal_test.purge_dm_history(self._state.peer_key)
        return "handled"
    end
    return nil
end

return Screen
