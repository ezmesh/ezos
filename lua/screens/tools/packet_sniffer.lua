-- Packet sniffer: live view of every packet the radio decodes.
--
-- Subscribes to the `mesh/packet` bus topic, which is posted by
-- mesh_bindings.cpp for *every* incoming packet (after header parse,
-- before any per-payload-type routing). The companion
-- screens/tools/channel_sniffer.lua is narrower -- it only counts
-- GRP_TXT packets and groups them by channel hash. This screen
-- shows the raw flow so you can see ADVERTs, ACKs, TXT_MSG (DM),
-- traces, and anything else.
--
-- Each entry shows: time-since-last (ms), payload-type label,
-- route-type, RSSI, payload size, and the first few payload bytes
-- as hex. Newest packets at the top; the list scrolls under
-- pressure -- 60 entries kept, oldest dropped.
--
-- The page is purely passive -- it does not transmit, advert, or
-- acknowledge anything. Receiving is independent of adverting; the
-- radio's RX path runs even when auto-advert is off, so this screen
-- works regardless of the Radio settings.

local ui    = require("ezui")
local node  = require("ezui.node")
local theme = require("ezui.theme")

local Sniffer = { title = "Packet Sniffer" }

local MAX_ENTRIES = 60

-- MeshCore payload-type constants. Mirrors src/mesh/packet.h.
local PAYLOAD_LABELS = {
    [0x00] = "REQ",
    [0x01] = "RESP",
    [0x02] = "TXT_MSG",
    [0x03] = "ACK",
    [0x04] = "ADVERT",
    [0x05] = "GRP_TXT",
    [0x06] = "GRP_DATA",
    [0x07] = "ANON_REQ",
    [0x08] = "PATH",
    [0x09] = "TRACE",
}
local ROUTE_LABELS = {
    [0x00] = "TFLOOD",
    [0x01] = "FLOOD",
    [0x02] = "DIRECT",
    [0x03] = "TDIRECT",
}

local function payload_label(t)
    return PAYLOAD_LABELS[t] or string.format("0x%X", t)
end
local function route_label(t)
    return ROUTE_LABELS[t] or string.format("0x%X", t)
end

local function hex_preview(bytes, max_bytes)
    if not bytes or #bytes == 0 then return "" end
    local n = math.min(#bytes, max_bytes or 8)
    local out = {}
    for i = 1, n do
        out[i] = string.format("%02X", bytes:byte(i))
    end
    if #bytes > n then out[#out + 1] = "..." end
    return table.concat(out, " ")
end

-- Custom node that paints the rolling packet list. We render here
-- (rather than building list_items per packet) because the list is
-- updated on every received packet and a full vbox rebuild would
-- thrash GC for high-traffic scenarios.
if not node.handler("packet_sniffer_view") then
    node.register("packet_sniffer_view", {
        focusable = false,
        measure = function(n, max_w, max_h)
            return max_w, max_h
        end,
        draw = function(n, d, x, y, w, h)
            d.fill_rect(x, y, w, h, theme.color("BG"))

            local entries = n.entries or {}
            local total   = n.total or 0

            -- Header strip with running totals.
            theme.set_font("small_aa")
            local fh = theme.font_height()
            d.fill_rect(x, y, w, fh + 6, theme.color("SURFACE"))
            d.fill_rect(x, y + fh + 5, w, 1, theme.color("BORDER"))
            local hdr = string.format(
                "Total seen: %d   Showing %d most recent",
                total, #entries)
            d.draw_text(x + 6, y + 3, hdr, theme.color("TEXT"))

            -- Rows. Each row gets two lines:
            --   line 1: TYPE | ROUTE | RSSI | size
            --   line 2: hex preview (first 8 payload bytes)
            theme.set_font("tiny_aa")
            local tfh = theme.font_height()
            local row_h = tfh * 2 + 4
            local row_y = y + fh + 8

            for i, e in ipairs(entries) do
                if row_y + row_h > y + h then break end
                -- Alternating row tint for readability.
                if i % 2 == 0 then
                    d.fill_rect(x, row_y, w, row_h, theme.color("SURFACE_ALT"))
                end
                local line1 = string.format(
                    "%-8s  %-7s  RSSI %3d  %3dB",
                    payload_label(e.payload_type),
                    route_label(e.route_type),
                    math.floor(e.rssi or 0),
                    e.size or 0)
                d.draw_text(x + 6, row_y + 1, line1, theme.color("TEXT"))
                d.draw_text(x + 6, row_y + tfh + 2, e.hex,
                    theme.color("TEXT_MUTED"))
                row_y = row_y + row_h
            end

            if #entries == 0 then
                local msg = "Waiting for packets..."
                local mw = theme.text_width(msg)
                d.draw_text(x + (w - mw) // 2,
                    y + h // 2 - tfh // 2, msg,
                    theme.color("TEXT_MUTED"))
            end
        end,
    })
end

function Sniffer.initial_state()
    return {}
end

function Sniffer:on_enter()
    self._view = self._view or { type = "packet_sniffer_view" }
    self._view.entries = {}
    self._view.total   = 0
    local me = self
    self._sub = ez.bus.subscribe("mesh/packet", function(_, data)
        if type(data) ~= "table" then return end
        me._view.total = (me._view.total or 0) + 1
        local entry = {
            ms           = ez.system.millis(),
            route_type   = data.route_type or 0,
            payload_type = data.payload_type or 0,
            rssi         = data.rssi or 0,
            snr          = data.snr or 0,
            size         = data.payload and #data.payload or 0,
            hex          = hex_preview(data.payload, 12),
        }
        table.insert(me._view.entries, 1, entry)
        while #me._view.entries > MAX_ENTRIES do
            table.remove(me._view.entries)
        end
        require("ezui.screen").invalidate()
    end)
end

function Sniffer:on_exit()
    if self._sub then ez.bus.unsubscribe(self._sub); self._sub = nil end
end

function Sniffer:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Packet Sniffer", { back = true }),
        self._view,
    })
end

function Sniffer:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    -- `c` clears the list so the user can mark a baseline.
    if key.character == "c" or key.character == "C" then
        self._view.entries = {}
        self._view.total   = 0
        require("ezui.screen").invalidate()
        return "handled"
    end
    return nil
end

return Sniffer
