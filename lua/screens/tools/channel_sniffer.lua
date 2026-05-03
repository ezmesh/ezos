-- Channel Sniffer: passive view of every GRP_TXT channel hash on the
-- air, with packet count + last-seen RSSI / age. Useful when traffic
-- isn't landing in any channel you're subscribed to and you need to
-- figure out which channel hash the local community is actually
-- using before chasing PSKs.
--
-- The sniffer only reads. Decoding the contents of any unknown hash
-- still requires the matching key, which can't be derived from a
-- 1-byte hash alone -- this screen just tells you what to ask for.

local ui    = require("ezui")
local theme = require("ezui.theme")
local channels_svc = require("services.channels")

local Sniffer = { title = "Channel Sniffer" }

-- Aggregated table: { [hash] = { count, last_rssi, last_snr,
--                                last_seen_ms, joined } }
local seen
local sub_id

local function fmt_age(ms)
    if not ms then return "" end
    local now = ez.system.millis()
    local age = math.max(0, math.floor((now - ms) / 1000))
    if age < 60   then return age .. "s" end
    if age < 3600 then return math.floor(age / 60) .. "m" end
    return math.floor(age / 3600) .. "h"
end

-- Look up whether we're already subscribed to a channel matching this
-- hash. Mostly cosmetic ("ok, I have this one" vs "huh, what's that?")
-- but it also lets us suppress the "join with a custom name" prompt
-- for hashes we'd just be re-adding.
local function find_joined(hash)
    if not channels_svc.get_list then return nil end
    for _, info in ipairs(channels_svc.get_list()) do
        if info.hash == hash then return info.name end
    end
    return nil
end

function Sniffer.initial_state()
    return {}
end

function Sniffer:on_enter()
    seen = {}
    sub_id = ez.bus.subscribe("mesh/group_packet", function(_topic, pkt)
        if not pkt or type(pkt) ~= "table" then return end
        local h = pkt.channel_hash
        if not h then return end
        local row = seen[h]
        if not row then
            row = { count = 0 }
            seen[h] = row
        end
        row.count        = row.count + 1
        row.last_rssi    = pkt.rssi
        row.last_snr     = pkt.snr
        row.last_seen_ms = ez.system.millis()
    end)
end

function Sniffer:on_exit()
    if sub_id then
        ez.bus.unsubscribe(sub_id)
        sub_id = nil
    end
    seen = nil
end

function Sniffer:update()
    -- Cheap rebuild every second so the age column ticks up and any
    -- new packet that landed since the last frame becomes visible
    -- without needing a key press.
    local now = ez.system.millis()
    if (now - (self._last_refresh or 0)) > 1000 then
        self._last_refresh = now
        self:set_state({})
    end
end

local function rows_sorted_by_recent()
    local rows = {}
    if not seen then return rows end
    for hash, r in pairs(seen) do
        rows[#rows + 1] = {
            hash = hash, count = r.count,
            last_rssi = r.last_rssi, last_snr = r.last_snr,
            last_seen_ms = r.last_seen_ms,
            joined = find_joined(hash),
        }
    end
    table.sort(rows, function(a, b)
        return (a.last_seen_ms or 0) > (b.last_seen_ms or 0)
    end)
    return rows
end

function Sniffer:build(state)
    local content = {}

    content[#content + 1] = ui.padding({ 8, 8, 4, 8 },
        ui.text_widget("Live channel hashes",
            { color = "ACCENT", font = "small_aa" })
    )

    content[#content + 1] = ui.padding({ 0, 8, 6, 8 },
        ui.text_widget(
            "Each row is a unique channel_hash byte from received " ..
            "GRP_TXT packets. Decoding the body still needs the " ..
            "matching PSK; this screen just tells you which channels " ..
            "are alive in radio range.",
            { color = "TEXT_MUTED", font = "tiny_aa", wrap = true })
    )

    local rows = rows_sorted_by_recent()
    if #rows == 0 then
        content[#content + 1] = ui.padding({ 12, 8, 4, 8 },
            ui.text_widget("Listening...  (no GRP_TXT seen yet)",
                { color = "TEXT_MUTED", font = "small_aa" })
        )
    else
        for _, r in ipairs(rows) do
            local title = string.format("0x%02X  (%d)", r.hash, r.hash)
            local sub_parts = {}
            sub_parts[#sub_parts + 1] = r.count .. " pkt"
            sub_parts[#sub_parts + 1] = (r.last_rssi and (r.last_rssi .. " dBm")) or "?"
            sub_parts[#sub_parts + 1] = fmt_age(r.last_seen_ms) .. " ago"
            if r.joined then
                sub_parts[#sub_parts + 1] = "joined as " .. r.joined
            end
            content[#content + 1] = ui.list_item({
                title    = title,
                subtitle = table.concat(sub_parts, "  --  "),
            })
        end
    end

    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Channel Sniffer", { back = true }),
        ui.scroll({ grow = 1 }, ui.vbox({ gap = 0 }, content)),
    })
end

function Sniffer:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Sniffer
