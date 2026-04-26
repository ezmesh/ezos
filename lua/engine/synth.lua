-- engine.synth — multi-voice chiptune SFX bank.
--
-- Wraps ez.synth with a data-driven sound bank. Each entry in M.sfx is
-- a list of "layer" tables; play_sfx(name) iterates the list and fires
-- ez.synth.note_on(...) for each layer at roughly the same instant.
-- Each layer may target a different voice — that's the whole reason
-- the C++ engine has 4 of them, so a single SFX can stack a noise
-- crackle, a sub-bass thump, and a pitched ringing into one event.
--
-- Voice layout (from synth.h):
--   1 = pulse A   (variable duty)
--   2 = pulse B   (variable duty)
--   3 = triangle  (smooth body / sub)
--   4 = noise     (LFSR — period set by hz)
--
-- Layer fields (passed through to ez.synth.note_on):
--   voice         1..4
--   hz            base pitch / noise tap rate
--   vol           0..255
--   duty          (pulse only) 0.05..0.95
--   attack_ms / decay_ms / sustain / release_ms   ADSR (sustain 0..255)
--   sweep_hz, sweep_ms                           linear pitch sweep
--   vib_depth_hz, vib_rate_hz                    sinusoidal pitch wobble
--
-- For a one-shot percussion-like effect, set sustain=0 and skip the
-- release. The voice retires the moment decay completes, freeing it
-- for the next trigger.

local M = {}

-- Friendly voice constants — for callers that prefer names.
M.PULSE_A  = 1
M.PULSE_B  = 2
M.TRIANGLE = 3
M.NOISE    = 4

-- Master volume sugar. Persisted under "audio_volume" so the
-- existing Settings -> Sound slider continues to do something useful
-- even when games drive the synth instead of the legacy beeper.
local PREF_VOLUME = "audio_volume"

function M.set_master_pct(pct)
    pct = tonumber(pct) or 0
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    if ez.synth and ez.synth.set_master then
        -- Map 0..100 -> 0..255. Quadratic so a slider tweak in the
        -- low half feels meaningful (linear amplitude is perceived
        -- non-linearly in loudness).
        local v = math.floor((pct / 100) ^ 1.6 * 255)
        ez.synth.set_master(v)
    end
    ez.storage.set_pref(PREF_VOLUME, pct)
end

function M.get_master_pct()
    local v = tonumber(ez.storage.get_pref(PREF_VOLUME, 80))
    if v == nil then return 80 end
    if v < 0 then v = 0 elseif v > 100 then v = 100 end
    return v
end

-- Apply the saved volume to the engine. Called once on first require()
-- and again on demand from settings screens. Safe to call when the
-- synth bindings aren't present (graceful degradation).
function M.apply_saved_volume()
    M.set_master_pct(M.get_master_pct())
end

-- ---------------------------------------------------------------------------
-- SFX bank.
-- ---------------------------------------------------------------------------

M.sfx = {
    -- Blaster: pulse zap with fast pitch sweep down. Reads as a tight
    -- "pew" without the smooth-sweep siren feel of the old beeper.
    blaster = {
        { voice = 1, hz = 1400, vol = 200, duty = 0.25,
          attack_ms = 0, decay_ms = 90, sustain = 0,
          sweep_hz = 350, sweep_ms = 90 },
    },

    -- Rapid: short tick at ~2.6 kHz with 12.5% duty for a thinner
    -- timbre vs the blaster.
    rapid = {
        { voice = 1, hz = 2600, vol = 170, duty = 0.125,
          attack_ms = 0, decay_ms = 40, sustain = 0,
          sweep_hz = 1400, sweep_ms = 40 },
    },

    -- Spread: two pulses an interval apart so the shotgun-y feel
    -- comes from real polyphony, not arpeggio fakery.
    spread = {
        { voice = 1, hz = 1100, vol = 160, duty = 0.5,
          attack_ms = 0, decay_ms = 70, sustain = 0,
          sweep_hz = 500, sweep_ms = 70 },
        { voice = 2, hz =  733, vol = 140, duty = 0.5,
          attack_ms = 0, decay_ms = 70, sustain = 0,
          sweep_hz = 333, sweep_ms = 70 },
    },

    -- Missile: low triangle rumble + pulse ring.
    missile = {
        { voice = 3, hz = 110, vol = 220,
          attack_ms = 30, decay_ms = 220, sustain = 0,
          sweep_hz = 60, sweep_ms = 220 },
        { voice = 1, hz = 880, vol = 90, duty = 0.125,
          attack_ms = 5, decay_ms = 180, sustain = 0,
          vib_depth_hz = 18, vib_rate_hz = 9 },
    },

    -- Enemy hit: tight noise burst, fast decay.
    enemy_hit = {
        { voice = 4, hz = 5500, vol = 200,
          attack_ms = 0, decay_ms = 70, sustain = 0,
          sweep_hz = 1500, sweep_ms = 70 },
    },

    -- Enemy destroyed: noise crunch + descending pulse for the "pop".
    enemy_pop = {
        { voice = 4, hz = 4000, vol = 220,
          attack_ms = 0, decay_ms = 220, sustain = 0,
          sweep_hz = 800, sweep_ms = 220 },
        { voice = 1, hz = 660, vol = 120, duty = 0.5,
          attack_ms = 0, decay_ms = 120, sustain = 0,
          sweep_hz = 220, sweep_ms = 120 },
    },

    -- Heavy explosion: textbook three-layer chiptune boom.
    --   Noise layer  — bright crackle sweeping down to rumble. Long
    --                  decay carries the tail.
    --   Triangle sub — 65 Hz dropping to 30 Hz over 80 ms; the body
    --                  thump you feel before the crackle.
    --   Pulse ring   — short 1.2 kHz squeak with quick down-sweep so
    --                  there's a glassy "shrapnel" overtone on the
    --                  attack. Lower volume so it doesn't dominate.
    -- Tunable: shrink decay/sweep_ms to half for a "small_explosion"
    -- patch, double them for a "boss_explosion".
    explosion = {
        { voice = 4, hz = 7500, vol = 230,
          attack_ms = 0, decay_ms = 450, sustain = 0,
          sweep_hz = 600, sweep_ms = 400 },
        { voice = 3, hz = 65,   vol = 250,
          attack_ms = 0, decay_ms = 130, sustain = 0,
          sweep_hz = 30, sweep_ms = 80 },
        { voice = 1, hz = 1200, vol = 100, duty = 0.125,
          attack_ms = 0, decay_ms = 50,  sustain = 0,
          sweep_hz = 200, sweep_ms = 40 },
    },

    -- Smaller "puff" explosion for cheap enemies. Same shape as
    -- explosion, scaled down so the big ones still feel big.
    small_explosion = {
        { voice = 4, hz = 5000, vol = 200,
          attack_ms = 0, decay_ms = 180, sustain = 0,
          sweep_hz = 700, sweep_ms = 160 },
        { voice = 3, hz = 90,   vol = 220,
          attack_ms = 0, decay_ms = 70, sustain = 0,
          sweep_hz = 45, sweep_ms = 60 },
    },

    -- Boss explosion: huge tail, layered sub + crackle + ring.
    boss_explosion = {
        { voice = 4, hz = 9000, vol = 240,
          attack_ms = 0, decay_ms = 900, sustain = 0,
          sweep_hz = 400, sweep_ms = 800 },
        { voice = 3, hz = 50,   vol = 255,
          attack_ms = 0, decay_ms = 260, sustain = 0,
          sweep_hz = 22, sweep_ms = 200 },
        { voice = 1, hz = 1500, vol = 130, duty = 0.125,
          attack_ms = 0, decay_ms = 200, sustain = 0,
          sweep_hz = 250, sweep_ms = 200 },
        { voice = 2, hz = 600,  vol = 110, duty = 0.5,
          attack_ms = 0, decay_ms = 320, sustain = 0,
          sweep_hz = 120, sweep_ms = 320,
          vib_depth_hz = 12, vib_rate_hz = 7 },
    },

    -- Player hurt: dissonant pulse stab + low triangle thud.
    hurt = {
        { voice = 1, hz = 520, vol = 200, duty = 0.5,
          attack_ms = 0, decay_ms = 160, sustain = 0,
          sweep_hz = 260, sweep_ms = 160 },
        { voice = 3, hz = 90, vol = 180,
          attack_ms = 0, decay_ms = 90, sustain = 0,
          sweep_hz = 50, sweep_ms = 90 },
    },

    -- Pickup: classic perfect-fifth ding (C6 -> G6).
    pickup = {
        { voice = 1, hz = 1046, vol = 180, duty = 0.25,
          attack_ms = 0, decay_ms = 60, sustain = 0 },
        { voice = 2, hz = 1568, vol = 180, duty = 0.25,
          attack_ms = 60, decay_ms = 110, sustain = 0 },
    },

    -- Power-up fanfare: ascending major triad arpeggio across both
    -- pulse voices, triangle reinforces the root.
    powerup = {
        { voice = 1, hz = 523, vol = 170, duty = 0.5,
          attack_ms = 0, decay_ms = 50, sustain = 0 },
        { voice = 2, hz = 659, vol = 170, duty = 0.5,
          attack_ms = 50, decay_ms = 50, sustain = 0 },
        { voice = 1, hz = 784, vol = 180, duty = 0.5,
          attack_ms = 100, decay_ms = 60, sustain = 0 },
        { voice = 2, hz = 1046, vol = 200, duty = 0.5,
          attack_ms = 160, decay_ms = 200, sustain = 0,
          vib_depth_hz = 6, vib_rate_hz = 8 },
        { voice = 3, hz = 261, vol = 160,
          attack_ms = 0, decay_ms = 360, sustain = 0 },
    },

    -- Gun cycle: short two-note pulse bounce.
    gun_up = {
        { voice = 1, hz = 880, vol = 170, duty = 0.25,
          attack_ms = 0, decay_ms = 35, sustain = 0 },
        { voice = 1, hz = 1320, vol = 200, duty = 0.25,
          attack_ms = 35, decay_ms = 90, sustain = 0 },
    },

    -- Game over: descending minor motif on triangle + decaying pulse.
    game_over = {
        { voice = 3, hz = 261, vol = 220,
          attack_ms = 0, decay_ms = 250, sustain = 0 },
        { voice = 3, hz = 220, vol = 220,
          attack_ms = 250, decay_ms = 250, sustain = 0 },
        { voice = 3, hz = 196, vol = 220,
          attack_ms = 500, decay_ms = 350, sustain = 0,
          vib_depth_hz = 6, vib_rate_hz = 5 },
        { voice = 1, hz = 261, vol = 120, duty = 0.125,
          attack_ms = 0, decay_ms = 850, sustain = 0,
          sweep_hz = 130, sweep_ms = 800 },
    },

    -- Wave up: bright C-major fanfare, three ascending notes plus a
    -- sustained pulse on top so the level-clear feels like a flourish
    -- rather than a status beep.
    wave_up = {
        { voice = 1, hz = 784, vol = 180, duty = 0.5,
          attack_ms = 0, decay_ms = 60, sustain = 0 },
        { voice = 1, hz = 1046, vol = 190, duty = 0.5,
          attack_ms = 60, decay_ms = 60, sustain = 0 },
        { voice = 2, hz = 1318, vol = 200, duty = 0.5,
          attack_ms = 120, decay_ms = 200, sustain = 0,
          vib_depth_hz = 4, vib_rate_hz = 6 },
        { voice = 3, hz = 392, vol = 160,
          attack_ms = 0, decay_ms = 320, sustain = 0 },
    },

    -- UI tick — quiet single pulse for menu navigation. Keeps it out
    -- of the way of bigger SFX.
    ui_tick = {
        { voice = 1, hz = 1500, vol = 90, duty = 0.5,
          attack_ms = 0, decay_ms = 25, sustain = 0 },
    },

    -- UI confirm — slightly bigger ding for "selected".
    ui_confirm = {
        { voice = 1, hz = 1320, vol = 150, duty = 0.5,
          attack_ms = 0, decay_ms = 30, sustain = 0 },
        { voice = 1, hz = 1976, vol = 180, duty = 0.5,
          attack_ms = 30, decay_ms = 70, sustain = 0 },
    },
}

-- ---------------------------------------------------------------------------
-- Public play() API. Schedules layered triggers so each layer fires
-- with its own attack offset relative to the call instant. Layers
-- whose attack_ms > 0 are scheduled via ez.system.set_timer; layers
-- with attack_ms == 0 fire immediately.
--
-- Implementation detail: we re-use attack_ms in note_on() as the
-- envelope attack, so a layer with attack_ms = 60 fades in after
-- triggering. To get a hard re-trigger 60 ms later (the chiptune
-- "second note in an arpeggio" pattern), we want a fresh note_on at
-- t+60 ms with attack_ms=0. play_sfx() distinguishes the two: if the
-- layer table has `_delay_ms` we schedule it; otherwise the layer
-- fires now and the engine handles the in-segment attack.
-- ---------------------------------------------------------------------------

local function fire_layer(layer)
    if not (ez.synth and ez.synth.note_on) then return end
    local opts = {
        duty = layer.duty,
        attack_ms = 0,
        decay_ms = layer.decay_ms,
        sustain = layer.sustain or 0,
        release_ms = layer.release_ms,
        sweep_hz = layer.sweep_hz,
        sweep_ms = layer.sweep_ms,
        vib_depth_hz = layer.vib_depth_hz,
        vib_rate_hz = layer.vib_rate_hz,
    }
    ez.synth.note_on(layer.voice, layer.hz, layer.vol, opts)
end

-- Treat `attack_ms` on a layer as a delay-from-trigger: layers with
-- attack_ms > 0 are scheduled via set_timer so a multi-layer SFX can
-- fire its second/third/fourth notes as discrete attacks rather than
-- slurred fade-ins. The synth engine's own attack semantics still
-- apply within each layer (we just zero them at the per-layer call).
function M.play(name)
    local sfx = M.sfx[name]
    if not sfx then return end
    for _, layer in ipairs(sfx) do
        local delay = layer.attack_ms or 0
        if delay <= 0 then
            fire_layer(layer)
        else
            local cap = layer
            ez.system.set_timer(delay, function() fire_layer(cap) end)
        end
    end
end

function M.silence()
    if ez.synth and ez.synth.silence then ez.synth.silence() end
end

-- Apply saved volume on first import so the engine starts at the
-- user's preferred level — matches the expectation that the volume
-- slider in Settings → Sound is the source of truth for both the
-- legacy beeper and the new synth.
M.apply_saved_volume()

return M
