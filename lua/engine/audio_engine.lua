-- Tiny audio engine for game SFX.
--
-- Composes sounds out of a sequence of "segments". Each segment has a
-- pitch curve (a function t∈[0,1] → frequency in Hz), a duration in
-- milliseconds, optional fade-in / fade-out, and a peak volume. The
-- engine plays them back by driving the ez.audio tone generator: a
-- single always-on tone whose frequency and global volume are updated
-- at ~40 Hz as we step through the segments.
--
-- Monophonic — a new play() cancels the current one. For a shooter
-- that's the right behaviour (the most recent event is the interesting
-- one, layered bleeps would fight for airtime).
--
-- Usage:
--   local audio = require("engine.audio_engine")
--   audio.play({
--       { curve = audio.curves.linear(1400, 300),
--         duration = 90, fade_out_ms = 30, volume = 0.8 },
--   })
--
-- For ready-made sounds, see `audio.sounds.*` at the bottom.

local M = {}

-- ---------------------------------------------------------------------------
-- Pitch curves — each returns a function(t) where t ∈ [0, 1] and the
-- return value is the frequency in Hz. All are deterministic except
-- `noise`, which injects random jitter for crashy effects.
-- ---------------------------------------------------------------------------

M.curves = {}

-- Constant frequency.
function M.curves.const(freq)
    return function(_) return freq end
end

-- Linear sweep from f0 to f1 across the segment.
function M.curves.linear(f0, f1)
    return function(t) return f0 + (f1 - f0) * t end
end

-- Exponential sweep — faster at first (k>0) or at the end (k<0).
-- Reads roughly like a laser or a falling-pitch decay depending on
-- whether f1 < f0 or f1 > f0.
function M.curves.exp(f0, f1, k)
    k = k or 3
    local denom = 1 - math.exp(-k)
    if math.abs(denom) < 1e-6 then denom = 1 end
    return function(t)
        local u = (1 - math.exp(-k * t)) / denom
        return f0 + (f1 - f0) * u
    end
end

-- Sine vibrato centred on `center` with ±depth amplitude, `rate`
-- cycles over the segment (so 3 gives three full wobbles).
function M.curves.vibrato(center, depth, rate)
    rate = rate or 2
    return function(t)
        return center + depth * math.sin(2 * math.pi * rate * t)
    end
end

-- Pitched noise — linear base sweep with random jitter on every
-- sample. Good for crunchy effects (explosions, impacts) where a pure
-- sine would sound too clean.
function M.curves.noise(f0, f1, jitter)
    jitter = jitter or 0.3
    local range = math.abs(f0 - f1) * jitter + 50
    return function(t)
        return f0 + (f1 - f0) * t + (math.random() - 0.5) * 2 * range
    end
end

-- Step / square: fixed-frequency chunks that flip between f0 and f1
-- `n_steps` times over the segment. Perceived as a chirpy alarm.
function M.curves.step(f0, f1, n_steps)
    n_steps = n_steps or 4
    return function(t)
        local idx = math.floor(t * n_steps)
        return (idx % 2 == 0) and f0 or f1
    end
end

-- ---------------------------------------------------------------------------
-- Player state. Monophonic — one sound at a time.
-- ---------------------------------------------------------------------------

local TICK_MS = 25     -- step rate for pitch/volume updates (40 Hz)
local MIN_FREQ, MAX_FREQ = 80, 18000

local state = {
    playing = nil,          -- current sound (table of segments)
    step_timer = nil,
    segment_i = 0,
    segment_start_ms = 0,
    base_volume = 80,       -- 0..100, supplied by caller
    muted = false,
}

-- Compute fade-envelope volume in [0, 1] for an elapsed-within-segment
-- time `elapsed` (ms) inside a segment of duration `dur` (ms).
local function fade_env(seg, elapsed, dur)
    local f = 1.0
    if seg.fade_in_ms and elapsed < seg.fade_in_ms then
        f = elapsed / seg.fade_in_ms
    end
    if seg.fade_out_ms and elapsed > dur - seg.fade_out_ms then
        local g = (dur - elapsed) / seg.fade_out_ms
        if g < f then f = g end
    end
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    return f
end

local function clamp_freq(f)
    if f < MIN_FREQ then return MIN_FREQ end
    if f > MAX_FREQ then return MAX_FREQ end
    return f
end

local function tick()
    local s = state.playing
    if not s then M.stop(); return end
    local seg = s[state.segment_i]
    if not seg then M.stop(); return end
    local now = ez.system.millis()
    local elapsed = now - state.segment_start_ms

    -- Segment boundary: advance.
    while seg and elapsed >= seg.duration do
        state.segment_i = state.segment_i + 1
        state.segment_start_ms = state.segment_start_ms + seg.duration
        seg = s[state.segment_i]
        if not seg then M.stop(); return end
        elapsed = now - state.segment_start_ms
    end

    local dur = seg.duration
    local t = elapsed / dur
    if t < 0 then t = 0 elseif t > 1 then t = 1 end

    local freq = clamp_freq(seg.curve(t))
    local env  = fade_env(seg, elapsed, dur) * (seg.volume or 1.0)
    local vol  = math.floor(state.base_volume * env)
    if vol < 0 then vol = 0 elseif vol > 100 then vol = 100 end

    ez.audio.set_frequency(math.floor(freq))
    ez.audio.set_volume(vol)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Begin playing `sound` (a list of segments). Cancels any in-flight
-- sound. `base_volume` is 0-100 and scales the whole envelope; useful
-- for per-effect mixing (quieter UI clicks, louder explosions).
function M.play(sound, base_volume)
    if state.muted then return end
    if not sound or #sound == 0 then return end
    M.stop()
    state.playing = sound
    state.segment_i = 1
    state.segment_start_ms = ez.system.millis()
    state.base_volume = base_volume or 80
    ez.audio.set_volume(0)          -- start silent; first tick ramps in
    ez.audio.set_frequency(math.floor(clamp_freq(sound[1].curve(0))))
    ez.audio.start()
    state.step_timer = ez.system.set_interval(TICK_MS, tick)
    -- Run the first tick synchronously so the sound starts in the
    -- correct envelope state instead of waiting up to TICK_MS for the
    -- first scheduler fire.
    tick()
end

function M.stop()
    if state.step_timer then
        ez.system.cancel_timer(state.step_timer)
        state.step_timer = nil
    end
    state.playing = nil
    state.segment_i = 0
    ez.audio.stop()
end

function M.is_playing()
    return state.playing ~= nil
end

function M.set_muted(muted)
    state.muted = muted and true or false
    if state.muted then M.stop() end
end

-- ---------------------------------------------------------------------------
-- Pre-baked sounds. Each is an array of segments expressed with the
-- curve builders above. Designed to sound distinct at a glance: each
-- event in the shooter should be identifiable from the SFX alone.
-- ---------------------------------------------------------------------------

local c = M.curves
M.sounds = {
    -- Blaster: fast high-to-low sweep, tight exponential decay so the
    -- perceived "bang" lands in the first 20 ms.
    blaster = {
        { curve = c.exp(1800, 350, 5), duration = 80,
          fade_out_ms = 40, volume = 0.8 },
    },

    -- Rapid: shorter, higher-pitched blaster — distinct "tick-tick-tick".
    rapid = {
        { curve = c.exp(2400, 900, 6), duration = 40,
          fade_out_ms = 20, volume = 0.6 },
    },

    -- Spread: a brief chord feel via two stacked chirps.
    spread = {
        { curve = c.exp(1600, 600, 4), duration = 50,
          fade_out_ms = 20, volume = 0.7 },
        { curve = c.exp(1300, 400, 4), duration = 50,
          fade_out_ms = 30, volume = 0.6 },
    },

    -- Missile: slower downward whoosh with vibrato tail.
    missile = {
        { curve = c.linear(900, 400), duration = 180,
          fade_in_ms = 30, volume = 0.7 },
        { curve = c.vibrato(380, 30, 4), duration = 140,
          fade_out_ms = 80, volume = 0.5 },
    },

    -- Enemy hit: short crunch then decay. Noise-jittered curve gives
    -- it texture.
    enemy_hit = {
        { curve = c.noise(500, 200, 0.5), duration = 90,
          fade_out_ms = 40, volume = 0.8 },
    },

    -- Enemy destroyed: longer noisy decay, two-stage.
    enemy_pop = {
        { curve = c.noise(900, 400, 0.4), duration = 80,
          volume = 0.9 },
        { curve = c.noise(400, 120, 0.4), duration = 160,
          fade_out_ms = 100, volume = 0.7 },
    },

    -- Heavy / big explosion: really low with broad noise, long tail.
    explosion = {
        { curve = c.noise(700, 200, 0.5), duration = 120, volume = 1.0 },
        { curve = c.noise(250, 90, 0.6), duration = 260,
          fade_out_ms = 180, volume = 0.8 },
    },

    -- Player hurt: dissonant short stab. A falling major-second-ish
    -- downbeat reads as "bad thing happened".
    hurt = {
        { curve = c.linear(520, 260), duration = 110,
          fade_out_ms = 60, volume = 0.9 },
    },

    -- Pickup: two quick ascending beeps — classic "ding" feel.
    pickup = {
        { curve = c.const(900),  duration = 55,
          fade_out_ms = 15, volume = 0.7 },
        { curve = c.const(1400), duration = 85,
          fade_out_ms = 30, volume = 0.7 },
    },

    -- Power-up (shield/multi): longer arpeggio to signal something
    -- bigger than a health pickup.
    powerup = {
        { curve = c.const(700),  duration = 50, volume = 0.6 },
        { curve = c.const(950),  duration = 50, volume = 0.6 },
        { curve = c.const(1300), duration = 50, volume = 0.6 },
        { curve = c.const(1800), duration = 120,
          fade_out_ms = 60, volume = 0.7 },
    },

    -- Gun cycle: short two-note bounce, inverted from pickup so the
    -- two events don't sound identical.
    gun_up = {
        { curve = c.const(1200), duration = 40, volume = 0.6 },
        { curve = c.const(1700), duration = 80,
          fade_out_ms = 30, volume = 0.7 },
    },

    -- Game over: slow descending wail.
    game_over = {
        { curve = c.exp(600, 120, 2), duration = 900,
          fade_in_ms = 30, fade_out_ms = 400, volume = 0.9 },
    },

    -- Level / wave up: quick rising fanfare.
    wave_up = {
        { curve = c.const(800),  duration = 60, volume = 0.7 },
        { curve = c.const(1000), duration = 60, volume = 0.7 },
        { curve = c.const(1400), duration = 120,
          fade_out_ms = 60, volume = 0.8 },
    },
}

return M
