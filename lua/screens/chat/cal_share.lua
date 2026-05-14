-- Shared cal/v1 share-card helpers used by both DM and channel chat
-- screens. Provides the bubble descriptor and the context-menu actions
-- a receiver can take (add to reminders, show on map, copy details).

local ui = require("ezui")
local dialog = require("ezui.dialog")
local sharing_svc = require("services.sharing")
local reminders_svc = require("services.reminders")
local screen_mod = require("ezui.screen")

local cal_share = {}

-- Pretty-print HH:MM:SS UTC. The device doesn't expose gmtime; emit
-- raw 24h fields from the unix value the same way time_share.lua does
-- to keep both share cards visually consistent.
local function format_clock(ts)
    local h = math.floor(ts / 3600) % 24
    local m = math.floor(ts / 60) % 60
    return string.format("%02d:%02d UTC", h, m)
end

-- "in 2h 30m" / "tomorrow 18:00" / "starting now" / "ended" --
-- relative phrasing tuned for an upcoming-event card. Returns
-- (label, is_past_or_now).
local function relative_label(ts)
    local now = ez.system.get_time_unix()
    if not now or now == 0 then
        return format_clock(ts), false
    end
    local diff = ts - now
    if diff <= 0 then
        if diff > -60 then return "starting now", true end
        return "started " .. format_clock(ts), true
    end
    if diff < 60 then return "in <1 min", false end
    if diff < 3600 then return "in " .. math.floor(diff / 60) .. "m", false end
    if diff < 24 * 3600 then
        local h = math.floor(diff / 3600)
        local m = math.floor((diff % 3600) / 60)
        if m == 0 then return "in " .. h .. "h", false end
        return "in " .. h .. "h " .. m .. "m", false
    end
    local d = math.floor(diff / 86400)
    if d == 1 then return "tomorrow " .. format_clock(ts), false end
    return "in " .. d .. "d", false
end

-- Build the share-card descriptor for the chat_bubble node. Returns
-- nil when the message doesn't contain a cal/v1 share.
function cal_share.card_for_message(msg)
    local share = sharing_svc.parse(msg.text or "")
    if not share or share.kind ~= "cal" then return nil end

    if msg.is_self then
        return {
            kind_label = "EVENT",
            title = share.title,
            action_hint = "Sent in this message",
            disabled = true,
        }
    end

    local label, past = relative_label(share.timestamp)
    return {
        kind_label = "EVENT",
        title = share.title,
        action_hint = label,
        disabled = past,
    }
end

-- Build context-menu action items for a cal/v1 share. Empty when the
-- message isn't a cal share.
function cal_share.build_actions(msg)
    local share = sharing_svc.parse(msg.text or "")
    if not share or share.kind ~= "cal" then return {} end

    local out = {}
    local label, past = relative_label(share.timestamp)

    -- Header / status row. Disabled list_item shows the parsed event
    -- details so a user who opens the menu can confirm before acting.
    local subtitle
    if share.duration and share.duration > 0 then
        local mins = math.floor(share.duration / 60)
        if mins >= 60 then
            local h = math.floor(mins / 60)
            local rem = mins % 60
            subtitle = format_clock(share.timestamp) .. " - " .. h .. "h"
            if rem > 0 then subtitle = subtitle .. " " .. rem .. "m" end
        else
            subtitle = format_clock(share.timestamp) .. " - " .. mins .. "m"
        end
    else
        subtitle = format_clock(share.timestamp)
    end
    out[#out + 1] = ui.list_item({
        title = share.title,
        subtitle = subtitle .. " (" .. label .. ")",
        disabled = true,
    })

    if msg.is_self then
        return out
    end

    -- "Add to reminders" — only meaningful for future events.
    if past then
        out[#out + 1] = ui.list_item({
            title = "Event has started/ended",
            disabled = true,
        })
    elseif reminders_svc.has(share.timestamp, share.title) then
        out[#out + 1] = ui.list_item({
            title = "Already in reminders",
            disabled = true,
        })
    else
        out[#out + 1] = ui.list_item({
            title = "Add to reminders",
            subtitle = "Notify 10 min before + at start",
            on_press = function()
                dialog.confirm({
                    title = "Add reminder?",
                    message = share.title .. "\n" .. subtitle,
                    ok_label = "Add",
                    cancel_label = "Cancel",
                }, function()
                    reminders_svc.add({
                        ts = share.timestamp,
                        dur = share.duration,
                        title = share.title,
                        lat = share.lat,
                        lon = share.lon,
                    })
                    screen_mod.pop()
                end)
            end,
        })
    end

    -- "Show on map" — only when coords were embedded. Read the saved
    -- default-archive pref (map_loader.lua sets this) so we open the
    -- archive the user picked; falls back to the global world.tdmap
    -- the map screen already hard-defaults to.
    if share.lat and share.lon then
        out[#out + 1] = ui.list_item({
            title = "Show on map",
            subtitle = string.format("%.4f, %.4f", share.lat, share.lon),
            on_press = function()
                local Map = require("screens.tools.map")
                local default_path = ez.storage.get_pref("map_default_archive", "")
                if default_path == "" then default_path = "/sd/maps/world.tdmap" end
                local s = Map.initial_state(default_path)
                s.center_lat = share.lat
                s.center_lon = share.lon
                -- Tight enough to recognise the spot; the map screen
                -- clamps to the archive's range if narrower.
                s.zoom = 14
                s.used_saved_view = true
                screen_mod.push(screen_mod.create(Map, s))
            end,
        })
    end

    return out
end

return cal_share
