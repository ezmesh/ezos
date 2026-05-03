-- services/ui_sounds: SND01 UI feedback sounds.
--
-- Pref key is `ui_sounds_on` (not the more obvious `ui_sounds_enabled`)
-- because NVS caps key names at 15 chars. The longer name silently
-- fails to persist -- nvs_set_*() rejects it but Preferences::putBool
-- swallows the error, so the toggle in Settings appeared to work but
-- forgot the choice on the next boot.
--
-- Samples ship in /sounds/snd01/*.pcm (22050 Hz mono s16le). On init() we
-- preload every event sample into PSRAM via ez.audio.preload and remember
-- its handle. play(event) fires the handle through the non-blocking
-- play_preloaded_async binding so firing a sound never stalls the VM.
--
-- The service is gated on the `ui_sounds_on` preference; when the
-- user flips the toggle in Settings the pref is re-read and honoured on
-- the next play() call. Preloading still happens at boot so enabling the
-- toggle takes effect immediately without the latency of a filesystem
-- load.
--
-- Attribution: SND01 "Sine" by Yasuhiro Tsuchiya / Dentsu (https://snd.dev).
-- See data/sounds/snd01/CREDITS.md and screens/about.lua.

local ui_sounds = {}

local PREF_ENABLED = "ui_sounds_on"
local SOUND_DIR    = "snd01/"

-- Map each UI event to either one sample file or a table of variants that
-- are picked in round-robin order. Using multiple tap/swipe/type variants
-- keeps rapid-fire feedback from sounding monotonous.
local EVENTS = {
    tap             = { "tap_01", "tap_02", "tap_03", "tap_04", "tap_05" },
    button          = "button",
    disabled        = "disabled",
    select          = "select",
    toggle_on       = "toggle_on",
    toggle_off      = "toggle_off",
    swipe           = { "swipe_01", "swipe_02", "swipe_03", "swipe_04", "swipe_05" },
    transition_up   = "transition_up",
    transition_down = "transition_down",
    type            = { "type_01", "type_02", "type_03", "type_04", "type_05" },
    notification    = "notification",
    caution         = "caution",
    celebration     = "celebration",
}

-- Per-event state: preloaded handles + rotation index for variant packs.
local handles = {}   -- event -> handle | { handle1, handle2, ... }
local indices = {}   -- event -> next variant index (1-based)

local _initialized = false

-- Read the stored enabled flag once per call so toggling the setting
-- takes effect without restarting the service.
local function pref_enabled()
    local v = ez.storage.get_pref(PREF_ENABLED, true)
    if type(v) == "boolean" then return v end
    if type(v) == "number"  then return v ~= 0 end
    if type(v) == "string"  then return v == "1" or v == "true" end
    return true
end

local function preload_one(stem)
    local path = SOUND_DIR .. stem .. ".pcm"
    local handle = ez.audio.preload(path)
    if not handle then
        ez.log("[ui_sounds] preload failed: " .. path)
    end
    return handle
end

-- Preload every event sample. Safe to call repeatedly — already-loaded
-- handles are kept. Returns the count of successfully loaded samples.
function ui_sounds.init()
    if _initialized then return end
    _initialized = true

    for event, spec in pairs(EVENTS) do
        if type(spec) == "string" then
            handles[event] = preload_one(spec)
        else
            local variants = {}
            for i, stem in ipairs(spec) do
                variants[i] = preload_one(stem)
            end
            handles[event] = variants
            indices[event] = 1
        end
    end
    ez.log("[ui_sounds] preloaded")
end

function ui_sounds.is_enabled()
    return pref_enabled()
end

function ui_sounds.set_enabled(v)
    ez.storage.set_pref(PREF_ENABLED, v and true or false)
end

-- Play a named event. Silent (no-op) if the pref is off, the service has
-- not been init()'d, or the event has no valid handle.
function ui_sounds.play(event)
    if not _initialized or not pref_enabled() then return end
    local h = handles[event]
    if not h then return end

    if type(h) == "table" then
        -- Rotate through variants so rapid taps don't loop one file.
        local idx = indices[event] or 1
        local handle = h[idx]
        indices[event] = (idx % #h) + 1
        if handle then ez.audio.play_preloaded_async(handle) end
    else
        ez.audio.play_preloaded_async(h)
    end
end

return ui_sounds
