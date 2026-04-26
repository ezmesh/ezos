// Multi-voice software synth for chip-tune sound effects + music.
//
// Mixes four fixed voices into a 16-bit mono buffer at the I2S sample
// rate (currently 44.1 kHz, matched against the existing audio task in
// src/lua/bindings/audio_bindings.cpp):
//
//   Voice 0 — pulse A   (variable duty 5..95%)
//   Voice 1 — pulse B   (variable duty 5..95%)
//   Voice 2 — triangle  (linear ramp; smooth, "bass body" timbre)
//   Voice 3 — noise     (15-bit Galois LFSR; period set by freq_hz)
//
// Each voice has an ADSR envelope, an optional linear pitch sweep
// (start_hz -> target_hz over sweep_ms), and an optional vibrato. All
// are independent, so a layered SFX (e.g. an explosion) is just a few
// note_on() calls in close succession from the Lua thread.
//
// Concurrency: parameters are written from the Lua thread (core 0) and
// read from the audio task (core 1). All exposed setter fields are
// volatile and 32-bit-aligned so reads see either the old or new value
// — no torn updates that matter at sample resolution. Worst case the
// audio task uses a stale parameter for one buffer (~5.8 ms at 256
// samples / 44100 Hz), which is far below human perception.

#pragma once

#include <stdint.h>
#include <stddef.h>

namespace synth {

constexpr int N_VOICES = 4;

// Voice indices used by note_on() / note_off() / set_*. Lua side
// binds to these via 1-based indexing so the public API matches the
// rest of the firmware (Lua arrays are 1-indexed).
constexpr int VOICE_PULSE_A  = 0;
constexpr int VOICE_PULSE_B  = 1;
constexpr int VOICE_TRIANGLE = 2;
constexpr int VOICE_NOISE    = 3;

enum class EnvPhase : uint8_t {
    Idle = 0,
    Attack,
    Decay,
    Sustain,
    Release,
};

struct Voice {
    // ----- Live parameters (set from Lua, read from audio task) -----
    volatile bool active = false;
    volatile float freq_hz = 440.0f;
    volatile float duty = 0.5f;          // pulse only

    // Velocity / volume (0..255). Multiplied with envelope value and
    // master volume in the mixer.
    volatile uint8_t volume = 0;

    // ADSR (ms; sustain_lvl is 0..255 fraction of peak).
    volatile uint16_t attack_ms = 0;
    volatile uint16_t decay_ms = 0;
    volatile uint8_t sustain_lvl = 255;
    volatile uint16_t release_ms = 0;

    // Linear pitch sweep. start_hz captured at note_on; target_hz +
    // sweep_ms set by set_sweep(). When sweeping, freq_hz is the
    // engine's interpolated value — Lua reads/writes are still legal
    // but get overwritten on the next sample.
    volatile float sweep_target_hz = 0;
    volatile uint16_t sweep_ms = 0;

    // Vibrato — sinusoidal pitch wiggle.
    volatile float vib_depth_hz = 0;
    volatile float vib_rate_hz = 0;

    // ----- Audio-task-only state (not touched from Lua) -----
    EnvPhase env_phase = EnvPhase::Idle;
    float    env_pos_ms = 0;
    float    env_value = 0;            // current envelope output 0..1
    float    env_release_start = 0;    // env value at moment of note_off

    float    sweep_pos_ms = 0;
    float    sweep_start_hz = 440.0f;
    bool     sweeping = false;

    float    vib_phase = 0;            // radians

    // Oscillator state.
    float    phase = 0;                // 0..1 for pulse / triangle

    // Noise state. The 15-bit Galois LFSR matches the NES' "long" mode
    // (the "metallic" mode on real hardware uses a shorter feedback
    // tap; we'll leave that for later if an SFX needs it).
    uint16_t lfsr = 0x4000;            // any non-zero seed
    int      noise_counter = 0;        // sample countdown to next tap
    int      noise_period_samples = 8; // re-derived from freq_hz on note_on
    int      noise_sample = 0;         // last LFSR-derived ±1 sample
};

// Singleton engine. Only one I2S output, so one engine instance is
// enough. Audio task takes a const reference; Lua thread mutates
// through the public methods.
class Engine {
public:
    void note_on(int voice_idx, float hz, uint8_t vol);
    void note_off(int voice_idx);

    void set_duty(int voice_idx, float duty);
    void set_envelope(int voice_idx,
                      uint16_t attack_ms,
                      uint16_t decay_ms,
                      uint8_t  sustain_lvl,
                      uint16_t release_ms);
    void set_sweep(int voice_idx, float target_hz, uint16_t ms);
    void set_vibrato(int voice_idx, float depth_hz, float rate_hz);

    // Whole-engine controls.
    void set_master(uint8_t m);
    uint8_t master() const { return master_; }

    // Force every voice into Idle and zero output. Used by the Lua
    // shutdown path or panic-stop.
    void silence_all();

    // True if any voice is in a non-Idle envelope phase. Used by the
    // audio task to know when to drop back to Off mode and stop
    // burning I2S DMA frames on silence.
    bool any_active() const;

    // Render `n_samples` mono int16 samples into `out`. Called from
    // the audio task with the I2S DMA chunk size (typically 256). The
    // returned pointer is the same as `out`. Mixing is signed, clamped
    // to int16 range. Per-sample work is small enough to fit ~6% of
    // one core at 4 voices.
    void render(int16_t* out, size_t n_samples);

private:
    Voice voices_[N_VOICES];
    uint8_t master_ = 200;
};

extern Engine g;

} // namespace synth
