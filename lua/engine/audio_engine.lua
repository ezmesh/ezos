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
-- Chiptune helpers: named-note pitches + arpeggios. The single-voice
-- tone hardware can't actually play a chord, so chip-era games faked
-- one by cycling between three notes faster than the ear can resolve
-- them — typically every 1-2 ticks at 60 Hz. Same trick here: arp()
-- builds a curve that snaps between a list of named notes on a fixed
-- ms period, perceived as a chord with a characteristic rasp.
-- ---------------------------------------------------------------------------

-- Equal-temperament frequency for "<letter><accidental?><octave>".
-- Examples: "A4" = 440, "C5" = ~523.25, "Fs4" = F#4, "Bb3" = Bb3.
-- Returns nil for unparseable strings so a typo in a sound table
-- surfaces as "no note" rather than a corrupted segment.
local NOTE_OFFSET = {
    C = -9, D = -7, E = -5, F = -4, G = -2, A = 0, B = 2,
}
local function note_freq(name)
    if type(name) ~= "string" then return nil end
    local letter = name:sub(1, 1):upper()
    local off = NOTE_OFFSET[letter]
    if not off then return nil end
    local i = 2
    local accidental = name:sub(i, i)
    if accidental == "s" or accidental == "#" then off = off + 1; i = i + 1
    elseif accidental == "b" then off = off - 1; i = i + 1 end
    local octave = tonumber(name:sub(i))
    if not octave then return nil end
    -- A4 = 440 Hz is the anchor; shift by semitones from there.
    local semitones = off + (octave - 4) * 12
    return 440.0 * (2 ^ (semitones / 12))
end

M.note_freq = note_freq

-- Constant pitch at a named note. Sugar over c.const(note_freq(name)).
function M.curves.note(name)
    return M.curves.const(note_freq(name) or 440)
end

-- Arpeggio: cycle through a list of named notes, holding each for
-- `period_ms`. The cycle restarts every `#notes * period_ms`. Used to
-- simulate chords on the single-voice tone — the rapid swap reads as
-- a single rich timbre at typical chip rates (12-25 ms per note).
function M.curves.arp(notes, period_ms)
    period_ms = period_ms or 18
    local freqs = {}
    for i, n in ipairs(notes) do
        freqs[i] = note_freq(n) or 440
    end
    local n = #freqs
    if n == 0 then return M.curves.const(440) end
    -- The engine passes `elapsed_ms` as the second arg — drive the
    -- cycle off that so the period stays correct regardless of how
    -- long the segment runs. Falls back to `t`-based cycling for
    -- forward-compat with any caller that ignores the new arg.
    return function(t, elapsed_ms)
        local ms = elapsed_ms or (t * 1000)
        local idx = math.floor(ms / period_ms) % n
        return freqs[idx + 1]
    end
end

-- Pitch bend between two named notes, exponential profile so it reads
-- as a swoop rather than a smooth slide.
function M.curves.bend(from_note, to_note, k)
    local f0 = note_freq(from_note) or 440
    local f1 = note_freq(to_note) or 440
    return M.curves.exp(f0, f1, k or 4)
end

-- Pseudo-noise burst: rapid uniform random in [lo, hi]. Cheaper to
-- evaluate than the perlin-ish curves.noise() and reads as percussion
-- when wrapped in a short envelope.
function M.curves.burst(lo, hi)
    return function(_) return lo + math.random() * (hi - lo) end
end

-- ---------------------------------------------------------------------------
-- Player state. Monophonic — one sound at a time.
-- ---------------------------------------------------------------------------

-- Step rate. Bumped from 40 Hz to ~60 Hz to match NES/Game Boy audio
-- vsync — arpeggios stop sounding muddy and noise bursts get crispier
-- because each "frame" is closer to one tick of a 60 Hz video chip.
local TICK_MS = 16
local MIN_FREQ, MAX_FREQ = 80, 18000

local PREF_VOLUME = "audio_volume"

local state = {
    playing = nil,          -- current sound (table of segments)
    step_timer = nil,
    segment_i = 0,
    segment_start_ms = 0,
    base_volume = 80,       -- 0..100, supplied by caller per play()
    master = 100,           -- 0..100, user-set volume scaler
    muted = false,
}

-- Restore the user's saved volume on first import. NVS may return nil
-- on a fresh device, in which case we keep the in-memory default.
do
    local saved = tonumber(ez.storage.get_pref(PREF_VOLUME, 100))
    if saved then
        if saved < 0 then saved = 0 end
        if saved > 100 then saved = 100 end
        state.master = saved
    end
end

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

    -- Curves get both the [0,1] segment-fraction and the absolute
    -- elapsed-within-segment in ms. The second arg is optional; the
    -- existing curves (linear/exp/vibrato/noise/step) ignore it. The
    -- chiptune helpers (arp, burst) use it to drive period-based
    -- cycling that doesn't depend on the segment's duration.
    local freq = clamp_freq(seg.curve(t, elapsed))
    local env  = fade_env(seg, elapsed, dur) * (seg.volume or 1.0)
    -- Scale by both the per-effect base volume and the user's master
    -- volume. Each is 0..100 in its own scale; combine in float space
    -- and clamp so a high effect-volume can't punch past the mixer.
    local vol  = math.floor(state.base_volume * env * (state.master / 100))
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

function M.is_muted()
    return state.muted
end

function M.toggle_muted()
    M.set_muted(not state.muted)
    return state.muted
end

-- Master-volume controls. The pause-menu volume slider in the games
-- reads/writes through these so a single source of truth lives here.
-- Persisted to NVS under "audio_volume" so the choice survives a
-- reboot.
function M.set_master_volume(v)
    v = tonumber(v) or 0
    if v < 0 then v = 0 elseif v > 100 then v = 100 end
    state.master = v
    ez.storage.set_pref(PREF_VOLUME, v)
    -- Live-apply: if a sound is currently playing, drop the hardware
    -- volume immediately so a slider tweak is audible without waiting
    -- for the next tick. set_frequency is left alone — the next tick
    -- will refresh it through the regular envelope path.
    if state.playing then
        ez.audio.set_volume(math.floor(state.base_volume * (state.master / 100)))
    end
end

function M.get_master_volume()
    return state.master
end

-- ---------------------------------------------------------------------------
-- Pre-baked sounds. Each is an array of segments expressed with the
-- curve builders above. Designed to sound distinct at a glance: each
-- event in the shooter should be identifiable from the SFX alone.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Chiptune SFX bank.
--
-- The earlier sound table relied entirely on smooth pitch sweeps,
-- which on a square-wave tone generator reads as siren-y rather than
-- gamey. The replacements below lean on three NES-era idioms:
--   1. Discrete chromatic notes instead of continuous slides.
--   2. Two-three-note arpeggios to fake polyphony on a mono voice.
--   3. Short percussive envelopes (5-25 ms attack, fast decay).
-- The aim is for each event to read as a distinct chip-tune blip
-- rather than blending into a generic "beep".
-- ---------------------------------------------------------------------------

local c = M.curves
M.sounds = {
    -- Blaster: pitched zap. Down-bend across an octave (E6→E5) for a
    -- crisp pew, percussive 60 ms tail.
    blaster = {
        { curve = c.bend("E6", "E5", 5), duration = 60,
          fade_out_ms = 40, volume = 0.85 },
    },

    -- Rapid: minor-third arpeggio so the staccato fire reads as
    -- "tick-tick-tick" with movement, not a flat tone.
    rapid = {
        { curve = c.arp({ "B6", "D7", "Fs7" }, 8), duration = 36,
          fade_out_ms = 18, volume = 0.55 },
    },

    -- Spread: stacked major triad, very short, gives the shotgun-y
    -- feel of multiple bullets leaving at once.
    spread = {
        { curve = c.arp({ "C5", "E5", "G5" }, 6), duration = 70,
          fade_out_ms = 30, volume = 0.75 },
    },

    -- Missile: slow rumbling launch — low arp with vibrato tail.
    missile = {
        { curve = c.arp({ "A3", "C4", "E4" }, 22), duration = 200,
          fade_in_ms = 20, volume = 0.7 },
        { curve = c.vibrato(note_freq("A3"), 18, 6), duration = 160,
          fade_out_ms = 100, volume = 0.5 },
    },

    -- Enemy hit: brief mid-band noise burst, tight envelope. Reads as
    -- "thunk".
    enemy_hit = {
        { curve = c.burst(380, 700), duration = 60,
          fade_out_ms = 40, volume = 0.85 },
    },

    -- Enemy destroyed: descending arp into a wider noise tail.
    enemy_pop = {
        { curve = c.arp({ "D5", "Bb4", "F4" }, 14), duration = 90,
          volume = 0.85 },
        { curve = c.burst(180, 420), duration = 180,
          fade_out_ms = 130, volume = 0.6 },
    },

    -- Heavy explosion: sub-bass thump + long noise tail. The first
    -- low arp lands like a kick drum, the second stage is the boom.
    explosion = {
        { curve = c.arp({ "E2", "Cs2", "A1" }, 18), duration = 120,
          volume = 1.0 },
        { curve = c.burst(110, 320), duration = 320,
          fade_out_ms = 220, volume = 0.75 },
    },

    -- Player hurt: dissonant dyad clash, descending half-step. Reads
    -- as "ow" without any sample data.
    hurt = {
        { curve = c.arp({ "F4", "B4" }, 18), duration = 60,
          volume = 0.9 },
        { curve = c.bend("E4", "C4", 3), duration = 120,
          fade_out_ms = 80, volume = 0.7 },
    },

    -- Pickup: classic two-step "ding" — perfect fifth jump, the
    -- shape Mario-era games use for coin/star.
    pickup = {
        { curve = c.note("C6"),  duration = 50,
          fade_out_ms = 12, volume = 0.7 },
        { curve = c.note("G6"),  duration = 110,
          fade_out_ms = 40, volume = 0.7 },
    },

    -- Power-up: rising major arpeggio, double-octave finish for the
    -- "got the big thing" feel.
    powerup = {
        { curve = c.note("C5"), duration = 45, volume = 0.65 },
        { curve = c.note("E5"), duration = 45, volume = 0.65 },
        { curve = c.note("G5"), duration = 45, volume = 0.65 },
        { curve = c.note("C6"), duration = 60, volume = 0.7 },
        { curve = c.arp({ "C6", "E6", "G6" }, 14), duration = 220,
          fade_out_ms = 140, volume = 0.7 },
    },

    -- Gun cycle: tight two-note bounce, distinct from pickup so the
    -- player can tell pickup vs gun-swap from the SFX alone.
    gun_up = {
        { curve = c.note("E5"), duration = 35, volume = 0.6 },
        { curve = c.note("B5"), duration = 70,
          fade_out_ms = 30, volume = 0.7 },
    },

    -- Game over: slow descending minor-key motif with vibrato decay.
    game_over = {
        { curve = c.note("E4"),  duration = 180, volume = 0.85 },
        { curve = c.note("D4"),  duration = 180, volume = 0.85 },
        { curve = c.note("C4"),  duration = 180, volume = 0.85 },
        { curve = c.vibrato(note_freq("A3"), 12, 5), duration = 480,
          fade_out_ms = 360, volume = 0.9 },
    },

    -- Wave up: bright C-major fanfare, three ascending notes plus a
    -- held arp on the top — "level cleared" idiom.
    wave_up = {
        { curve = c.note("G5"),  duration = 60, volume = 0.7 },
        { curve = c.note("C6"),  duration = 60, volume = 0.7 },
        { curve = c.note("E6"),  duration = 80, volume = 0.75 },
        { curve = c.arp({ "C6", "E6", "G6" }, 10), duration = 200,
          fade_out_ms = 120, volume = 0.8 },
    },

    -- Menu navigation tick — used by the in-game pause menu. Tiny so
    -- it doesn't fight the gameplay SFX during a busy moment.
    ui_tick = {
        { curve = c.note("B5"), duration = 25,
          fade_out_ms = 15, volume = 0.55 },
    },

    -- Menu confirm — slightly bigger ding for "selected".
    ui_confirm = {
        { curve = c.note("E6"), duration = 30, volume = 0.7 },
        { curve = c.note("B6"), duration = 60,
          fade_out_ms = 30, volume = 0.7 },
    },
}

return M
