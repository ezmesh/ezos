-- Shared time-share helpers used by both DM and channel chat screens.
-- Provides the share-card descriptor for bubble rendering and the
-- context-menu actions for accepting a time share.

local ui = require("ezui")
local dialog = require("ezui.dialog")
local sharing_svc = require("services.sharing")
local screen_mod = require("ezui.screen")

local time_share = {}

-- Format a unix timestamp as a human-readable string.
local function format_time(ts)
    -- ez.system doesn't expose gmtime, so format from epoch fields.
    -- Use the device's own localtime conversion via a round-trip:
    -- temporarily set time, read it, then restore. Too invasive.
    -- Instead, just show the raw unix timestamp with the delta.
    local h = math.floor(ts / 3600) % 24
    local m = math.floor(ts / 60) % 60
    local s = ts % 60
    return string.format("%02d:%02d:%02d UTC", h, m, s)
end

-- How many seconds ago the shared timestamp was, relative to the
-- device's own clock. Returns nil if the local clock isn't set.
local function age_seconds(shared_ts)
    local now = ez.system.get_time_unix()
    if not now or now == 0 then return nil end
    return now - shared_ts
end

-- Human-readable age string with accuracy hint.
local function age_label(shared_ts)
    local age = age_seconds(shared_ts)
    if not age then return "local clock not set" end
    local abs_age = math.abs(age)
    if abs_age < 5 then return "just now - high accuracy" end
    if abs_age < 30 then return abs_age .. "s ago - good accuracy" end
    if abs_age < 120 then return math.floor(abs_age / 60) .. "m " .. (abs_age % 60) .. "s ago - fair" end
    return math.floor(abs_age / 60) .. "m ago - stale, may be inaccurate"
end

-- Build the share-card descriptor for the chat_bubble node.
-- Returns nil if the message doesn't contain a time share.
function time_share.card_for_message(msg)
    local share = sharing_svc.parse(msg.text or "")
    if not share or share.kind ~= "time" then return nil end

    if msg.is_self then
        return {
            kind_label = "TIME SHARE",
            title = format_time(share.timestamp),
            action_hint = "Sent in this message",
            disabled = true,
        }
    end

    local hint = age_label(share.timestamp)
    return {
        kind_label = "TIME SHARE",
        title = format_time(share.timestamp),
        action_hint = hint,
        disabled = false,
    }
end

-- Build context-menu action items for a time share.
-- Returns a list of list_item nodes (possibly empty).
function time_share.build_actions(msg)
    local share = sharing_svc.parse(msg.text or "")
    if not share or share.kind ~= "time" then return {} end

    local out = {}

    if msg.is_self then
        out[#out + 1] = ui.list_item({
            title = "Shared time: " .. format_time(share.timestamp),
            subtitle = "Sent in this message",
            disabled = true,
        })
        return out
    end

    local hint = age_label(share.timestamp)

    -- Info line
    local sender = msg.sender_name or "?"
    local rssi_str = msg.rssi and string.format("%d dBm", math.floor(msg.rssi)) or "?"
    out[#out + 1] = ui.list_item({
        title = "Time from " .. sender,
        subtitle = format_time(share.timestamp) .. " - " .. rssi_str,
        disabled = true,
    })

    out[#out + 1] = ui.list_item({
        title = "Accuracy: " .. hint,
        disabled = true,
    })

    -- Sync action (behind a confirmation dialog to prevent accidental taps).
    -- Capture the current time so we can compensate for the delay between
    -- opening the menu and pressing Sync.
    local menu_opened_ms = ez.system.millis()

    out[#out + 1] = ui.list_item({
        title = "Sync clock to this time",
        subtitle = "Adjusts for time since message was received",
        on_press = function()
            -- Compensate: add the seconds elapsed since the menu opened
            -- to the shared timestamp. This accounts for the user reading
            -- the menu, the confirmation dialog, etc.
            local elapsed_s = math.floor((ez.system.millis() - menu_opened_ms) / 1000)
            local adjusted = share.timestamp + elapsed_s
            dialog.confirm({
                title = "Sync clock?",
                message = "Set device time to " .. format_time(adjusted) ..
                    "?\n(+" .. elapsed_s .. "s adjustment)\n" .. hint,
                ok_label = "Sync",
                cancel_label = "Cancel",
            }, function()
                -- Re-compute at confirm time for maximum accuracy
                local final_elapsed = math.floor((ez.system.millis() - menu_opened_ms) / 1000)
                local final_ts = share.timestamp + final_elapsed
                ez.system.set_time_unix(final_ts)
                ez.log("[TimeShare] Clock synced to " .. tostring(final_ts) ..
                    " (shared=" .. tostring(share.timestamp) .. " +" .. final_elapsed .. "s)")
                screen_mod.pop()
            end)
        end,
    })

    return out
end

return time_share
