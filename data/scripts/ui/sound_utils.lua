-- SoundUtils - UI sound effects for T-Deck OS
-- Uses pre-generated PCM samples for high-quality audio feedback
-- Samples are stored in /sounds/*.pcm (16-bit signed, 22050Hz mono)

local SoundUtils = {
    enabled = false,
    volume = 50,  -- 0-100
    use_samples = true,  -- Use PCM samples if available
}

-- Sound name to PCM file mapping
local SOUND_FILES = {
    click = "click",
    confirm = "confirm",
    error = "error",
    notify = "notify",
    navigate = "scroll",  -- scroll.pcm for navigation
    back = "back",
    transition = "click",  -- Reuse click for transitions
    message = "message",
    low_battery = "error"  -- Reuse error for low battery
}

-- Fallback tone definitions if PCM not available
local FALLBACK_TONES = {
    click = {600, 8},
    confirm = {880, 25},
    error = {180, 60},
    notify = {659, 40},
    navigate = {300, 6},
    back = {280, 15},
    transition = {400, 12},
    message = {988, 50},
    low_battery = {220, 100}
}

-- Initialize from saved preferences
function SoundUtils.init()
    local enabled = ez.storage.get_pref("uiSoundsEnabled")
    if enabled ~= nil then
        SoundUtils.enabled = enabled
    end

    local vol = ez.storage.get_pref("uiSoundsVolume")
    if vol then
        SoundUtils.volume = vol
    end

    -- Apply volume to audio system
    if ez.audio and ez.audio.set_volume then
        ez.audio.set_volume(SoundUtils.volume)
    end
end

-- Enable/disable sounds
function SoundUtils.set_enabled(enabled)
    SoundUtils.enabled = enabled
    ez.storage.set_pref("uiSoundsEnabled", enabled)
end

function SoundUtils.is_enabled()
    return SoundUtils.enabled
end

-- Set volume (0-100)
function SoundUtils.set_volume(level)
    level = math.max(0, math.min(100, level))
    SoundUtils.volume = level
    ez.storage.set_pref("uiSoundsVolume", level)

    if ez.audio and ez.audio.set_volume then
        ez.audio.set_volume(level)
    end
end

function SoundUtils.get_volume()
    return SoundUtils.volume
end

-- Play a named sound
function SoundUtils.play(sound_name)
    if not SoundUtils.enabled then return end
    if not ez.audio then return end

    -- Apply volume before playing
    if ez.audio.set_volume then
        ez.audio.set_volume(SoundUtils.volume)
    end

    -- Try PCM sample first
    if SoundUtils.use_samples and ez.audio.play_sample then
        local filename = SOUND_FILES[sound_name]
        if filename then
            local ok = ez.audio.play_sample(filename)
            if ok then return end
        end
    end

    -- Fallback to tone generation
    if ez.audio.play_tone then
        local tone = FALLBACK_TONES[sound_name]
        if tone then
            ez.audio.play_tone(tone[1], tone[2])
        end
    end
end

-- Convenience functions for common sounds
function SoundUtils.click()
    SoundUtils.play("click")
end

function SoundUtils.confirm()
    SoundUtils.play("confirm")
end

function SoundUtils.error()
    SoundUtils.play("error")
end

function SoundUtils.notify()
    SoundUtils.play("notify")
end

function SoundUtils.navigate()
    SoundUtils.play("navigate")
end

function SoundUtils.back()
    SoundUtils.play("back")
end

function SoundUtils.transition()
    SoundUtils.play("transition")
end

function SoundUtils.message()
    SoundUtils.play("message")
end

-- Get list of available sounds (for settings/testing)
function SoundUtils.get_sound_names()
    local names = {}
    for name, _ in pairs(SOUND_FILES) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

return SoundUtils
