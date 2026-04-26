// Multi-voice software synth implementation. See synth.h for the
// design overview.

#include "synth.h"

#include <math.h>
#include <algorithm>

namespace synth {

Engine g;

// Must match the I2S sample rate configured in audio_bindings.cpp. If
// that ever changes we'll need to bump this in lockstep — there's no
// compile-time link between the two right now because the audio task
// owns the I2S setup and the synth just gets handed a buffer.
static constexpr float SAMPLE_RATE = 44100.0f;
static constexpr float DT_MS = 1000.0f / SAMPLE_RATE;
static constexpr float TWO_PI = 6.28318530717958647692f;

// Output amplitude for a fully-modulated single voice. With 4 voices
// at full volume the headroom is `4 * VOICE_AMP`, which is set so the
// mix maxes out around 75% of int16 to leave a little space for the
// inevitable peak excursions when noise + pulses align.
static constexpr float VOICE_AMP = 6500.0f;

// -----------------------------------------------------------------------------
// Public setters. All sanity-clamp their inputs and bail out cleanly
// on bogus voice indices so a Lua-side typo can't crash the audio task.
// -----------------------------------------------------------------------------

void Engine::note_on(int idx, float hz, uint8_t vol) {
    if (idx < 0 || idx >= N_VOICES) return;
    Voice& v = voices_[idx];
    v.freq_hz = hz;
    v.volume = vol;
    v.env_phase = EnvPhase::Attack;
    v.env_pos_ms = 0;
    v.env_value = 0;
    v.sweeping = false;
    v.sweep_pos_ms = 0;
    v.sweep_start_hz = hz;
    v.vib_phase = 0;
    v.phase = 0;
    if (idx == VOICE_NOISE) {
        v.noise_counter = 0;
        // Period in samples derived from the requested hz. This is a
        // rough approximation — real NES noise tables are not linear
        // in frequency — but it gives the player a continuous knob
        // from "rumble" (low hz) to "hiss" (high hz).
        float clamped = hz < 30.0f ? 30.0f : hz;
        v.noise_period_samples = (int)(SAMPLE_RATE / clamped);
        if (v.noise_period_samples < 1) v.noise_period_samples = 1;
        v.lfsr = 0x4000;
        v.noise_sample = 0;
    }
    v.active = true;
}

void Engine::note_off(int idx) {
    if (idx < 0 || idx >= N_VOICES) return;
    Voice& v = voices_[idx];
    if (v.env_phase == EnvPhase::Idle) return;
    v.env_release_start = v.env_value;
    v.env_phase = EnvPhase::Release;
    v.env_pos_ms = 0;
}

void Engine::set_duty(int idx, float duty) {
    if (idx < 0 || idx >= N_VOICES) return;
    if (duty < 0.05f) duty = 0.05f;
    if (duty > 0.95f) duty = 0.95f;
    voices_[idx].duty = duty;
}

void Engine::set_envelope(int idx,
                          uint16_t a, uint16_t d,
                          uint8_t s, uint16_t r) {
    if (idx < 0 || idx >= N_VOICES) return;
    voices_[idx].attack_ms = a;
    voices_[idx].decay_ms = d;
    voices_[idx].sustain_lvl = s;
    voices_[idx].release_ms = r;
}

void Engine::set_sweep(int idx, float target_hz, uint16_t ms) {
    if (idx < 0 || idx >= N_VOICES) return;
    Voice& v = voices_[idx];
    v.sweep_target_hz = target_hz;
    v.sweep_ms = ms;
    v.sweep_pos_ms = 0;
    v.sweep_start_hz = v.freq_hz;
    v.sweeping = (ms > 0);
}

void Engine::set_vibrato(int idx, float depth_hz, float rate_hz) {
    if (idx < 0 || idx >= N_VOICES) return;
    voices_[idx].vib_depth_hz = depth_hz;
    voices_[idx].vib_rate_hz = rate_hz;
}

void Engine::set_master(uint8_t m) {
    master_ = m;
}

void Engine::silence_all() {
    for (int i = 0; i < N_VOICES; i++) {
        Voice& v = voices_[i];
        v.active = false;
        v.volume = 0;
        v.env_phase = EnvPhase::Idle;
        v.env_value = 0;
        v.sweeping = false;
    }
}

bool Engine::any_active() const {
    for (int i = 0; i < N_VOICES; i++) {
        if (voices_[i].active) return true;
    }
    return false;
}

// -----------------------------------------------------------------------------
// Per-sample envelope step. Returns the current envelope output 0..1.
// Updates v.env_phase and v.env_value as it advances. When the
// envelope finishes (Release reaches t=1), we flip active=false so the
// renderer can early-out on this voice next sample.
// -----------------------------------------------------------------------------

static inline float step_env(Voice& v) {
    switch (v.env_phase) {
    case EnvPhase::Attack: {
        if (v.attack_ms == 0) {
            v.env_value = 1.0f;
            v.env_phase = EnvPhase::Decay;
            v.env_pos_ms = 0;
        } else {
            v.env_pos_ms += DT_MS;
            float t = v.env_pos_ms / v.attack_ms;
            if (t >= 1.0f) {
                v.env_value = 1.0f;
                v.env_phase = EnvPhase::Decay;
                v.env_pos_ms = 0;
            } else {
                v.env_value = t;
            }
        }
        break;
    }
    case EnvPhase::Decay: {
        float sustain01 = v.sustain_lvl / 255.0f;
        if (v.decay_ms == 0) {
            v.env_value = sustain01;
            v.env_phase = EnvPhase::Sustain;
        } else {
            v.env_pos_ms += DT_MS;
            float t = v.env_pos_ms / v.decay_ms;
            if (t >= 1.0f) {
                v.env_value = sustain01;
                v.env_phase = EnvPhase::Sustain;
            } else {
                v.env_value = 1.0f - (1.0f - sustain01) * t;
            }
        }
        break;
    }
    case EnvPhase::Sustain:
        // Sustain at the configured level. If the user passed
        // sustain=0 the envelope effectively becomes AD-only and the
        // voice should now retire — that's the standard "one-shot"
        // behaviour for percussion. Without this, voices with no
        // release path would idle forever at silent volume.
        if (v.sustain_lvl == 0) {
            v.env_value = 0;
            v.env_phase = EnvPhase::Idle;
            v.active = false;
        } else {
            v.env_value = v.sustain_lvl / 255.0f;
        }
        break;
    case EnvPhase::Release: {
        if (v.release_ms == 0) {
            v.env_value = 0;
            v.env_phase = EnvPhase::Idle;
            v.active = false;
        } else {
            v.env_pos_ms += DT_MS;
            float t = v.env_pos_ms / v.release_ms;
            if (t >= 1.0f) {
                v.env_value = 0;
                v.env_phase = EnvPhase::Idle;
                v.active = false;
            } else {
                v.env_value = v.env_release_start * (1.0f - t);
            }
        }
        break;
    }
    case EnvPhase::Idle:
    default:
        v.env_value = 0;
        v.active = false;
        break;
    }
    return v.env_value;
}

// -----------------------------------------------------------------------------
// Sweep + vibrato modulators. Returns the effective frequency for this
// sample — the sum of (linear-swept base) + (vibrato wobble). Vibrato
// is added to the swept frequency rather than to the original so the
// two effects compose without eating each other.
// -----------------------------------------------------------------------------

static inline float step_freq(Voice& v) {
    float f = v.freq_hz;

    if (v.sweeping && v.sweep_ms > 0) {
        v.sweep_pos_ms += DT_MS;
        float t = v.sweep_pos_ms / v.sweep_ms;
        if (t >= 1.0f) {
            f = v.sweep_target_hz;
            v.freq_hz = f;
            v.sweeping = false;
        } else {
            f = v.sweep_start_hz + (v.sweep_target_hz - v.sweep_start_hz) * t;
            v.freq_hz = f;
        }
    }

    if (v.vib_depth_hz > 0 && v.vib_rate_hz > 0) {
        v.vib_phase += TWO_PI * v.vib_rate_hz / SAMPLE_RATE;
        if (v.vib_phase >= TWO_PI) v.vib_phase -= TWO_PI;
        f += v.vib_depth_hz * sinf(v.vib_phase);
    }

    if (f < 1.0f) f = 1.0f;
    if (f > 18000.0f) f = 18000.0f;
    return f;
}

// -----------------------------------------------------------------------------
// Per-voice oscillator. Returns a sample in [-1, 1].
// -----------------------------------------------------------------------------

static inline float osc_pulse(Voice& v, float freq_hz) {
    v.phase += freq_hz / SAMPLE_RATE;
    if (v.phase >= 1.0f) v.phase -= 1.0f;
    return (v.phase < v.duty) ? 1.0f : -1.0f;
}

static inline float osc_triangle(Voice& v, float freq_hz) {
    v.phase += freq_hz / SAMPLE_RATE;
    if (v.phase >= 1.0f) v.phase -= 1.0f;
    // 0..0.5 ramps -1..+1; 0.5..1 ramps +1..-1. Standard symmetric
    // triangle shape, no anti-aliasing — the chip aesthetic prefers
    // the harshness.
    if (v.phase < 0.5f) {
        return -1.0f + 4.0f * v.phase;
    } else {
        return 3.0f - 4.0f * v.phase;
    }
}

static inline float osc_noise(Voice& v) {
    if (v.noise_counter <= 0) {
        // Galois LFSR step. Tap selection (bit 0 ^ bit 1) gives the
        // long noise pattern (~32k samples). Keeps the sound crunchy
        // without obvious periodicity in normal SFX durations.
        uint16_t bit = (v.lfsr ^ (v.lfsr >> 1)) & 1;
        v.lfsr = (v.lfsr >> 1) | (bit << 14);
        v.noise_sample = (v.lfsr & 1) ? 1 : -1;
        v.noise_counter = v.noise_period_samples;
    } else {
        v.noise_counter--;
    }
    return (float)v.noise_sample;
}

// -----------------------------------------------------------------------------
// Main render loop. Mix all active voices into `out`, sample by sample.
// -----------------------------------------------------------------------------

void Engine::render(int16_t* out, size_t n_samples) {
    const float master01 = master_ / 255.0f;

    for (size_t i = 0; i < n_samples; i++) {
        float mix = 0.0f;

        // Pulse A
        {
            Voice& v = voices_[VOICE_PULSE_A];
            if (v.active) {
                float env = step_env(v);
                if (v.active) {  // step_env may have flipped to Idle
                    float f = step_freq(v);
                    float s = osc_pulse(v, f);
                    mix += s * env * (v.volume / 255.0f);
                }
            }
        }

        // Pulse B
        {
            Voice& v = voices_[VOICE_PULSE_B];
            if (v.active) {
                float env = step_env(v);
                if (v.active) {
                    float f = step_freq(v);
                    float s = osc_pulse(v, f);
                    mix += s * env * (v.volume / 255.0f);
                }
            }
        }

        // Triangle
        {
            Voice& v = voices_[VOICE_TRIANGLE];
            if (v.active) {
                float env = step_env(v);
                if (v.active) {
                    float f = step_freq(v);
                    float s = osc_triangle(v, f);
                    mix += s * env * (v.volume / 255.0f);
                }
            }
        }

        // Noise. The noise voice's "frequency" controls its tap rate,
        // not an audible pitch — we recompute period_samples whenever
        // the live freq has drifted by more than a hair (sweep moves
        // it). Cheap because we only do it when the voice is active.
        {
            Voice& v = voices_[VOICE_NOISE];
            if (v.active) {
                float env = step_env(v);
                if (v.active) {
                    float f = step_freq(v);
                    int new_period = (int)(SAMPLE_RATE / (f < 30.0f ? 30.0f : f));
                    if (new_period < 1) new_period = 1;
                    v.noise_period_samples = new_period;
                    float s = osc_noise(v);
                    mix += s * env * (v.volume / 255.0f);
                }
            }
        }

        // Final mix scale + clamp to int16. master01 covers the user
        // volume slider; VOICE_AMP is the per-voice peak headroom.
        float sample = mix * VOICE_AMP * master01;
        if (sample >  32767.0f) sample =  32767.0f;
        if (sample < -32768.0f) sample = -32768.0f;
        out[i] = (int16_t)sample;
    }
}

} // namespace synth
