-- Shared GPS-share helpers used by both DM and channel chat screens.
-- Provides the share-card descriptor for bubble rendering and the
-- context-menu actions for "Show on map" / "Copy coordinates" on an
-- inbound location share. Mirrors the shape of time_share.lua.

local ui = require("ezui")
local dialog = require("ezui.dialog")
local sharing_svc = require("services.sharing")
local screen_mod = require("ezui.screen")

local gps_share = {}

-- Sanitize a peer-originated string to printable ASCII. The on-device
-- fonts only cover 0x20..0x7E (CLAUDE.md "On-device font character
-- set"); anything else paints as a `[]` box.
local function ascii_safe(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("[^\32-\126]", "?"))
end

local function format_coords(lat, lon)
    return string.format("%.4f, %.4f", lat or 0, lon or 0)
end

-- Resolve a chat message's location share, decrypting the DM variant
-- when sender_pub_key_hex is supplied. Returns the plaintext fields or
-- nil if the message doesn't carry a GPS share at all.
--
-- Result shape:
--   { lat, lon, label, encrypted }
--   ({ _err = "reason" } when an encrypted token is present but the
--   shared secret isn't derivable -- caller can show the failure)
local function resolve(msg, sender_pub_key_hex)
    local share = sharing_svc.parse(msg.text or "")
    if not share then return nil end

    if share.kind == "gps" then
        return {
            lat   = share.lat,
            lon   = share.lon,
            label = share.name or "",
            encrypted = false,
        }
    end

    if share.kind == "gps_dm" then
        if msg.is_self then
            -- We sent it, so we can't decrypt (the secret is keyed to the
            -- recipient, not us). Surface a self-shaped card instead.
            return { _self = true }
        end
        if not sender_pub_key_hex then
            return { _err = "no sender key" }
        end
        local decoded, err = sharing_svc.decode_gps_dm(share.token, sender_pub_key_hex)
        if not decoded then
            return { _err = err or "decrypt failed" }
        end
        return {
            lat   = decoded.lat,
            lon   = decoded.lon,
            label = decoded.label or "",
            encrypted = true,
        }
    end

    return nil
end

-- Build the share-card descriptor for chat_bubble rendering.
-- Returns nil for messages without a GPS share.
function gps_share.card_for_message(msg, sender_pub_key_hex)
    local r = resolve(msg, sender_pub_key_hex)
    if not r then return nil end

    if msg.is_self or r._self then
        return {
            kind_label = "LOCATION",
            title = "(location sent)",
            action_hint = "Sent in this message",
            disabled = true,
        }
    end

    if r._err then
        return {
            kind_label = "LOCATION",
            title = "(cannot open)",
            action_hint = r._err,
            disabled = true,
        }
    end

    local label = ascii_safe(r.label or "")
    local title = label ~= "" and label or "Shared location"
    return {
        kind_label = "LOCATION",
        title = title,
        action_hint = format_coords(r.lat, r.lon),
        disabled = false,
    }
end

-- Build context-menu action items for a GPS share.
-- Returns a list of list_item nodes (possibly empty).
function gps_share.build_actions(msg, sender_pub_key_hex)
    local r = resolve(msg, sender_pub_key_hex)
    if not r then return {} end

    local out = {}

    if msg.is_self or r._self then
        out[#out + 1] = ui.list_item({
            title = "Shared location",
            subtitle = "Sent in this message",
            disabled = true,
        })
        return out
    end

    if r._err then
        out[#out + 1] = ui.list_item({
            title = "Location share (cannot open)",
            subtitle = r._err,
            disabled = true,
        })
        return out
    end

    local label = ascii_safe(r.label or "")
    local sender = ascii_safe(msg.sender_name or "?")
    local coords = format_coords(r.lat, r.lon)

    out[#out + 1] = ui.list_item({
        title = label ~= "" and label or "Shared location",
        subtitle = "From " .. sender .. "  " .. coords,
        disabled = true,
    })

    out[#out + 1] = ui.list_item({
        title = "Show on map",
        subtitle = "Open Map centered on this point",
        on_press = function()
            local Map = require("screens.tools.map")
            local state = Map.initial_state()
            state.center_lat = r.lat
            state.center_lon = r.lon
            -- A high zoom for a hand-picked point; archives that
            -- don't cover this zoom clamp at on_enter().
            state.zoom = 14
            state.used_saved_view = true
            screen_mod.push(screen_mod.create(Map, state))
        end,
    })

    out[#out + 1] = ui.list_item({
        title = "Copy coordinates",
        subtitle = coords,
        on_press = function()
            -- No system clipboard on the T-Deck; bounce the coords
            -- through a confirmation dialog so the user can read them
            -- precisely (and re-type into another tool if needed).
            dialog.confirm({
                title = "Coordinates",
                message = coords .. (label ~= "" and ("\n" .. label) or ""),
                ok_label = "OK",
                cancel_label = "Close",
            }, function() screen_mod.pop() end)
        end,
    })

    return out
end

return gps_share
