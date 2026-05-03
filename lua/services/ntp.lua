-- services/ntp: NTP server preset list + persistence + boot kickstart.
--
-- The C++ side (ez.ntp.start/stop/is_synced/...) is a thin wrapper
-- over lwIP's SNTP. This module owns the *policy* layer:
--
--   * the list of named server presets,
--   * a Custom slot the user can fill with their own hostname,
--   * the on/off toggle,
--   * the persisted choice (so a reboot resumes whatever the user
--     trusted last),
--   * boot-time start, gated on WiFi being up first.
--
-- Settings → Time → NTP server lets the user pick which preset is
-- trusted; the choice persists under `ntp_preset` (12 chars,
-- comfortably under the 15-char NVS cap) and the optional custom
-- host under `ntp_custom`.
--
-- Pref keys used:
--   ntp_on      bool  enabled
--   ntp_preset  str   one of "pool", "google", "cloudflare", "nist",
--                     "windows", "custom"
--   ntp_custom  str   hostname for the "custom" preset
--
-- All keys are <= 15 chars to dodge the silent-NVS-truncation trap
-- documented in ota_bindings.

local ntp = {}

local PREF_ON     = "ntp_on"
local PREF_PRESET = "ntp_preset"
local PREF_CUSTOM = "ntp_custom"

-- The default preset list. Order is the order they appear in the UI;
-- the first entry is the "use the default" choice. Each entry's
-- `host` is the primary, `fallbacks` are fed into ez.ntp.start as the
-- secondary/tertiary so a single dead host doesn't break sync.
ntp.PRESETS = {
    { id = "pool",       label = "pool.ntp.org (default)",
      host = "pool.ntp.org",
      fallbacks = { "0.pool.ntp.org", "1.pool.ntp.org" } },
    { id = "google",     label = "Google",
      host = "time.google.com",
      fallbacks = { "time2.google.com", "time3.google.com" } },
    { id = "cloudflare", label = "Cloudflare",
      host = "time.cloudflare.com",
      fallbacks = {} },
    { id = "nist",       label = "NIST (USA)",
      host = "time.nist.gov",
      fallbacks = {} },
    { id = "windows",    label = "Microsoft",
      host = "time.windows.com",
      fallbacks = {} },
    { id = "custom",     label = "Custom...",
      host = nil,
      fallbacks = {} },
}

-- Return the preset table for the given id, or nil. Cheap lookup --
-- the list is short enough that the linear scan is fine and avoids
-- keeping a separate index map in sync.
function ntp.find_preset(id)
    for _, p in ipairs(ntp.PRESETS) do
        if p.id == id then return p end
    end
    return nil
end

-- Read the persisted enabled flag. Default OFF: NTP only adjusts the
-- system clock when the user has explicitly opted in, so a fresh
-- device with bad WiFi doesn't end up making periodic outbound calls
-- the user didn't ask for.
function ntp.is_enabled()
    local v = ez.storage.get_pref(PREF_ON, nil)
    if v == nil then return false end
    if type(v) == "boolean" then return v end
    if type(v) == "number"  then return v ~= 0 end
    if type(v) == "string"  then return v == "1" or v == "true" end
    return false
end

function ntp.set_enabled(v)
    ez.storage.set_pref(PREF_ON, v and true or false)
end

function ntp.get_preset_id()
    local id = ez.storage.get_pref(PREF_PRESET, "pool")
    if not ntp.find_preset(id) then return "pool" end
    return id
end

function ntp.set_preset_id(id)
    if not ntp.find_preset(id) then return end
    ez.storage.set_pref(PREF_PRESET, id)
end

function ntp.get_custom_host()
    local s = ez.storage.get_pref(PREF_CUSTOM, "")
    if type(s) ~= "string" then return "" end
    return s
end

function ntp.set_custom_host(host)
    ez.storage.set_pref(PREF_CUSTOM, host or "")
end

-- Resolve the active server list from the persisted preset choice.
-- Returns an array of hostnames suitable for ez.ntp.start(...) -- up
-- to three entries; empty/whitespace fallbacks are dropped. For the
-- "custom" preset we fall back to pool.ntp.org if the user enabled
-- NTP but never typed a hostname; that's friendlier than silently
-- doing nothing.
function ntp.resolve_servers()
    local id = ntp.get_preset_id()
    local preset = ntp.find_preset(id) or ntp.find_preset("pool")
    local out = {}
    if id == "custom" then
        local host = ntp.get_custom_host()
        if host ~= "" then
            out[1] = host
        else
            out[1] = "pool.ntp.org"
        end
    else
        out[1] = preset.host
        if preset.fallbacks then
            for _, f in ipairs(preset.fallbacks) do
                if #out >= 3 then break end
                if f and f ~= "" then out[#out + 1] = f end
            end
        end
    end
    return out
end

-- Start NTP if enabled. Caller is expected to have WiFi already up;
-- ez.ntp.start works without WiFi (lwIP just won't get responses) so
-- it's not strictly an error, but the boot wrapper below polls the
-- WiFi link first to keep the logs clean.
function ntp.start_if_enabled()
    if not ntp.is_enabled() then return false end
    if not (ez.ntp and ez.ntp.start) then return false end
    local servers = ntp.resolve_servers()
    if not servers[1] then return false end
    ez.ntp.start(table.unpack(servers))
    return true
end

function ntp.stop()
    if ez.ntp and ez.ntp.stop then ez.ntp.stop() end
end

-- Boot helper. Called from boot.lua after WiFi auto-connect: polls
-- the link until it's up (capped at 30 s) and then kicks off NTP.
-- Same shape as the dev-OTA auto-start so the boot path stays
-- predictable.
function ntp.kick_after_wifi()
    if not ntp.is_enabled() then return end
    local attempts_left = 15
    local function try_start()
        if ez.wifi and ez.wifi.is_connected and ez.wifi.is_connected() then
            ntp.start_if_enabled()
            ez.log("[Boot] NTP auto-started")
            return
        end
        attempts_left = attempts_left - 1
        if attempts_left <= 0 then
            ez.log("[Boot] NTP: WiFi never came up, skipping")
            return
        end
        ez.system.set_timer(2000, try_start)
    end
    ez.system.set_timer(2000, try_start)
end

return ntp
