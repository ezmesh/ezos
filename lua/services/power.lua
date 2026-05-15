-- services/power: battery-aware radio + display duty cycle.
--
-- Three tiers based on battery percentage with hysteresis:
--
--   normal   -- default; everything runs at full cadence.
--   frugal   -- enter at <= 30 %, leave at >= 35 %.
--              ADVERT period halved, hourly GPS sync skipped, NTP
--              poll interval stretched, screensaver dim faster.
--   survival -- enter at <= 10 %, leave at >= 15 %.
--              ADVERT period quartered, GPS/NTP suppressed, non-DM
--              custom packets suppressed, display brightness clamped
--              to <= 30 %, radio TX power dropped one notch.
--
-- Two prefs gate the policy from settings:
--   pwr_always_norm  "0"/"1"  Pin to normal regardless of battery.
--   pwr_force_surv   "0"/"1"  Pin to survival regardless of battery.
--
-- The two prefs cannot both be on; the setter clears the other.
--
-- On a transition, the service:
--   * applies the new policy to mesh / radio / display knobs,
--   * posts a one-shot notification (source = "power"),
--   * emits the bus event "power/mode_changed" with the new mode.
--
-- Consumers that need to react in their own loops (gps, ntp,
-- custom_packets) read `power.gps_allowed()` / `power.ntp_allowed()`
-- / `power.allow_non_dm()` rather than subscribing to the event --
-- they already poll their own state; an extra subscription would
-- duplicate the gate.
--
-- The status bar reads `power.short_indicator()` to render a small
-- "lp" / "LP" badge so the user sees the active tier without having
-- to open Settings.

local power = {}

-- Tier definitions. `enter` is "<= this and the next-tier exit didn't
-- already fire"; `exit` is the hysteresis floor when leaving the tier.
local TIERS = {
    survival = { enter = 10, exit = 15 },
    frugal   = { enter = 30, exit = 35 },
}

local NORMAL_ANNOUNCE_MS   = 120 * 1000   -- 2 min, matches default
local NORMAL_TX_POWER_DBM  = 22           -- max
local FRUGAL_TX_POWER_DBM  = 22           -- unchanged in frugal
local SURVIVAL_TX_POWER_DBM = 17          -- one notch down from max
local SURVIVAL_BRIGHT_CAP  = 80           -- 80/255 ~ 30 %

local POLL_MS = 30 * 1000

local _mode       = "normal"
local _started    = false
local _normal_brightness = nil  -- cached on entry to survival so we can restore

local function pref_bool(key, default)
    if not (ez and ez.storage and ez.storage.get_pref) then return default end
    local v = ez.storage.get_pref(key, default and "1" or "0")
    return v == "1" or v == 1 or v == true
end

local function set_pref_bool(key, v)
    if not (ez and ez.storage and ez.storage.set_pref) then return end
    ez.storage.set_pref(key, v and "1" or "0")
end

local function safe_set_announce(ms)
    if ez and ez.mesh and ez.mesh.set_announce_interval then
        pcall(ez.mesh.set_announce_interval, ms)
    end
end

local function safe_set_tx_power(dbm)
    if ez and ez.radio and ez.radio.set_tx_power then
        pcall(ez.radio.set_tx_power, dbm)
    end
end

local function user_brightness()
    if not (ez and ez.storage and ez.storage.get_pref) then return 200 end
    local v = ez.storage.get_pref("screen_bright", 200)
    return tonumber(v) or 200
end

local function safe_set_brightness(level)
    if ez and ez.display and ez.display.set_brightness then
        pcall(ez.display.set_brightness, level)
    end
end

-- Read battery; returns nil when the read is unavailable so the
-- evaluator can treat "unknown" as "stay where we are".
local function read_battery()
    if not (ez and ez.system and ez.system.get_battery_percent) then return nil end
    local pct = ez.system.get_battery_percent()
    if not pct or pct < 0 then return nil end
    return pct
end

local function is_charging()
    if not (ez and ez.system and ez.system.is_charging) then return false end
    return ez.system.is_charging() and true or false
end

-- Decide which tier the device should be in given current battery,
-- charging state, manual prefs, and the current tier (for hysteresis).
local function decide(pct, charging, current)
    if pref_bool("pwr_always_norm", false) then return "normal" end
    if pref_bool("pwr_force_surv",  false) then return "survival" end
    -- Plugged in: act as if the battery is full. Don't snap straight to
    -- normal if we were in survival -- treat the transition like the
    -- normal exit so any one-shot notification path still fires.
    if charging then
        if current == "survival" then return "frugal" end
        return "normal"
    end
    if pct == nil then return current end
    -- Hysteresis: only enter a more-severe tier when we cross the entry
    -- threshold; only leave when we cross the higher exit threshold.
    if current == "survival" then
        if pct >= TIERS.survival.exit then
            -- left survival; pick frugal or normal based on the frugal
            -- entry threshold so we don't immediately re-trip if we
            -- popped just barely above 15 %.
            if pct < TIERS.frugal.exit then return "frugal" end
            return "normal"
        end
        return "survival"
    elseif current == "frugal" then
        if pct <= TIERS.survival.enter then return "survival" end
        if pct >= TIERS.frugal.exit then return "normal" end
        return "frugal"
    else  -- normal
        if pct <= TIERS.survival.enter then return "survival" end
        if pct <= TIERS.frugal.enter   then return "frugal" end
        return "normal"
    end
end

local function safe_ntp_stop()
    local ok, ntp = pcall(require, "services.ntp")
    if ok and ntp and ntp.stop then pcall(ntp.stop) end
end

local function safe_ntp_start()
    local ok, ntp = pcall(require, "services.ntp")
    if ok and ntp and ntp.start_if_enabled then pcall(ntp.start_if_enabled) end
end

-- Apply the side effects of being in `mode`. Called on every
-- transition; idempotent within a tier so re-applying is harmless.
local function apply(mode)
    if mode == "survival" then
        safe_set_announce(NORMAL_ANNOUNCE_MS * 4)
        safe_set_tx_power(SURVIVAL_TX_POWER_DBM)
        safe_ntp_stop()
        local cur = user_brightness()
        if _normal_brightness == nil then _normal_brightness = cur end
        if cur > SURVIVAL_BRIGHT_CAP then
            safe_set_brightness(SURVIVAL_BRIGHT_CAP)
        end
    elseif mode == "frugal" then
        safe_set_announce(NORMAL_ANNOUNCE_MS * 2)
        safe_set_tx_power(FRUGAL_TX_POWER_DBM)
        safe_ntp_start()      -- in case we just left survival
        if _normal_brightness then
            safe_set_brightness(_normal_brightness)
            _normal_brightness = nil
        end
    else  -- normal
        safe_set_announce(NORMAL_ANNOUNCE_MS)
        safe_set_tx_power(NORMAL_TX_POWER_DBM)
        safe_ntp_start()
        if _normal_brightness then
            safe_set_brightness(_normal_brightness)
            _normal_brightness = nil
        end
    end
end

local function describe(mode)
    if mode == "survival" then
        return "Survival mode",
               "Battery low. Radio, GPS, and NTP backed off; display dimmed."
    elseif mode == "frugal" then
        return "Low power mode",
               "Battery low. ADVERT and NTP cadence reduced; GPS sync paused."
    end
    return nil
end

local function notify_transition(new_mode, charging)
    if new_mode == "normal" then
        -- Don't toast on the way back to normal; the user already
        -- knows they plugged in or charged up.
        return
    end
    if charging then
        -- Charging-induced step-up (e.g. survival -> frugal because
        -- the user plugged in). The "Battery low" framing would be
        -- misleading right after a plug-in, and the next 30 s tick
        -- will step us up to normal anyway.
        return
    end
    local ok, notifications = pcall(require, "services.notifications")
    if not ok or not notifications then return end
    local title, body = describe(new_mode)
    if not title then return end
    notifications.dismiss_source("power")
    notifications.post({
        title  = title,
        body   = body,
        source = "power",
    })
end

local function transition_to(new_mode, charging)
    if new_mode == _mode then return end
    _mode = new_mode
    apply(new_mode)
    notify_transition(new_mode, charging)
    if ez and ez.bus and ez.bus.post then
        ez.bus.post("power/mode_changed", { mode = new_mode })
    end
end

-- Re-evaluate the tier and apply any transition. Safe to call at any
-- time; the consumers (gps/ntp/custom_packets) consult predicates
-- rather than reacting to the event, so a missed evaluation just
-- means a stretched-by-30s policy update, not a stuck mode.
function power.evaluate()
    local pct = read_battery()
    local chg = is_charging()
    local next_mode = decide(pct, chg, _mode)
    transition_to(next_mode, chg)
end

function power.current_mode()
    return _mode
end

-- Predicates consumed by other services. Single-place truth table so
-- gps/ntp/custom_packets don't have to know the tier names.

-- Per-fix GPS reads are fine in every tier (the user might be looking
-- at the Map screen at 5 %). Only the periodic *clock sync* is gated.
function power.gps_sync_allowed()
    return _mode == "normal"
end

-- NTP is suppressed in survival; frugal stretches the interval rather
-- than blocking it outright. The NTP service consults the multiplier
-- via `ntp_interval_factor()` so the same loop covers both cases.
function power.ntp_allowed()
    return _mode ~= "survival"
end

function power.ntp_interval_factor()
    if _mode == "frugal" then return 6 end
    return 1
end

-- True when non-essential RAW_CUSTOM packets (signal test, gps share,
-- ping) should be suppressed in the current tier. DM traffic is NEVER
-- gated by power; people in trouble might be on 4 %.
function power.allow_non_dm()
    return _mode ~= "survival"
end

-- "" / "lp" / "LP". Status bar renders this verbatim. Tiny on
-- purpose -- the bar is crowded already.
function power.short_indicator()
    if     _mode == "frugal"   then return "lp"
    elseif _mode == "survival" then return "LP"
    end
    return ""
end

-- Settings sets these. Mutually exclusive: flipping one on flips the
-- other off so we never end up with both pref bits set and a confusing
-- "which one wins" question.
function power.set_always_normal(on)
    set_pref_bool("pwr_always_norm", on and true or false)
    if on then set_pref_bool("pwr_force_surv", false) end
    power.evaluate()
end

function power.set_force_survival(on)
    set_pref_bool("pwr_force_surv", on and true or false)
    if on then set_pref_bool("pwr_always_norm", false) end
    power.evaluate()
end

function power.always_normal_on() return pref_bool("pwr_always_norm", false) end
function power.force_survival_on() return pref_bool("pwr_force_surv",  false) end

-- Spawn the polling loop. Idempotent.
function power.start()
    if _started then return end
    _started = true

    -- Initial evaluation right away so the very first reading applies
    -- the policy. Subsequent ticks are quick (one ADC + one bool).
    power.evaluate()

    local set_timer = ez and ez.system and ez.system.set_timer
    if not set_timer then return end
    local function tick()
        power.evaluate()
        set_timer(POLL_MS, tick)
    end
    set_timer(POLL_MS, tick)
end

return power
