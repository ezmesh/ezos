// ez.synth — multi-voice software synth bindings.
//
// Thin wrappers around src/audio/synth.h. Voice indices arrive 1-based
// from Lua and convert to 0-based on the way in. Argument errors raise
// Lua errors so a typo at a callsite is loud, not silent.

#include "../lua_bindings.h"
#include "../../audio/synth.h"

// Cross-file handoff into audio_bindings.cpp. Both setters are
// no-arg C-linkage shims: ezAudioEnsureTask boots the audio task and
// I2S driver if not already up, ezAudioSetSynthMode/OffMode flip the
// task's `audioMode` without exposing the file-static variable.
extern "C" void ezAudioEnsureTask();
extern "C" void ezAudioSetSynthMode();
extern "C" void ezAudioSetOffMode();

// @module ez.synth
// @brief Multi-voice software synth (chip-tune SFX + simple music).
// @description
// Drives a 4-voice synthesiser at 44.1 kHz mono into the same I2S
// audio output the rest of ez.audio uses. The shape is NES-derived:
// two pulse voices (variable duty), one triangle voice for sub-bass
// bodies, and one noise voice for percussion / explosions. Each voice
// has independent ADSR, an optional linear pitch sweep, and an
// optional vibrato.
// Voice indices (1-based from Lua):
//   1 = pulse A
//   2 = pulse B
//   3 = triangle
//   4 = noise
// @end

static int lua_voice_idx(lua_State* L, int arg) {
    int idx = (int)luaL_checkinteger(L, arg);
    if (idx < 1 || idx > synth::N_VOICES) {
        return luaL_error(L,
            "ez.synth: voice must be 1..%d, got %d",
            synth::N_VOICES, idx);
    }
    return idx - 1;
}

// Activate the audio task into Synth mode if a voice was just
// triggered. The synth's auto-park (in audio_bindings.cpp) drops the
// mode back to Off when every voice goes Idle, so this is the only
// place that needs to bring the task back up.
static void activate_synth_mode() {
    ezAudioEnsureTask();
    ezAudioSetSynthMode();
}

// @lua ez.synth.note_on(voice, hz, vol [, opts]) -> nil
// @brief Trigger a voice with a fresh envelope.
// @description Starts (or retriggers) the given voice. Resets the
// envelope to Attack, the oscillator phase to zero, and clears any
// pending sweep. `opts` is an optional table of per-trigger overrides:
//   { duty = 0.25,                  // pulse only, 0.05..0.95
//     attack_ms = 0, decay_ms = 80,
//     sustain = 0,                  // 0..255
//     release_ms = 0,
//     sweep_hz = 200, sweep_ms = 80,
//     vib_depth_hz = 8, vib_rate_hz = 5 }
// Anything missing keeps its previous setting; this matches the
// expectation that game patches set most params once via set_envelope
// etc. and just retrigger pitch+volume each shot.
// @param voice integer 1..4
// @param hz number frequency in Hz (or LFSR tap rate for the noise voice)
// @param vol integer 0..255
// @param opts table (optional) — see description
// @example
// ez.synth.note_on(1, 880, 200, { duty = 0.25, attack_ms = 0,
//                                  decay_ms = 80, sustain = 0 })
// @end
LUA_FUNCTION(l_synth_note_on) {
    int idx = lua_voice_idx(L, 1);
    float hz = (float)luaL_checknumber(L, 2);
    int vol = (int)luaL_checkinteger(L, 3);
    if (vol < 0) vol = 0;
    if (vol > 255) vol = 255;

    // Trigger the voice first, then apply opts. Order matters because
    // synth::Engine::note_on() resets `sweeping = false` and rewinds
    // the envelope to Attack — anything we wrote into the voice
    // before that call would be wiped. Doing note_on first means
    // set_sweep's `sweep_start_hz = v.freq_hz` capture sees the new
    // freq we just stored, and the `sweeping = true` flag survives
    // through render() so SFX patches with sweep_hz/sweep_ms actually
    // sweep instead of playing flat.
    synth::g.note_on(idx, hz, (uint8_t)vol);

    // Per-trigger overrides via opts table. Read each field if
    // present; missing fields leave the existing voice config alone.
    if (lua_istable(L, 4)) {
        lua_getfield(L, 4, "duty");
        if (lua_isnumber(L, -1)) {
            synth::g.set_duty(idx, (float)lua_tonumber(L, -1));
        }
        lua_pop(L, 1);

        lua_getfield(L, 4, "attack_ms");
        bool has_attack = lua_isnumber(L, -1);
        int attack = has_attack ? (int)lua_tointeger(L, -1) : 0;
        lua_pop(L, 1);
        lua_getfield(L, 4, "decay_ms");
        bool has_decay = lua_isnumber(L, -1);
        int decay = has_decay ? (int)lua_tointeger(L, -1) : 0;
        lua_pop(L, 1);
        lua_getfield(L, 4, "sustain");
        bool has_sustain = lua_isnumber(L, -1);
        int sustain = has_sustain ? (int)lua_tointeger(L, -1) : 255;
        lua_pop(L, 1);
        lua_getfield(L, 4, "release_ms");
        bool has_release = lua_isnumber(L, -1);
        int release = has_release ? (int)lua_tointeger(L, -1) : 0;
        lua_pop(L, 1);
        if (has_attack || has_decay || has_sustain || has_release) {
            synth::g.set_envelope(idx,
                (uint16_t)(attack < 0 ? 0 : attack),
                (uint16_t)(decay < 0 ? 0 : decay),
                (uint8_t)(sustain < 0 ? 0 : (sustain > 255 ? 255 : sustain)),
                (uint16_t)(release < 0 ? 0 : release));
        }

        lua_getfield(L, 4, "sweep_hz");
        bool has_sweep_hz = lua_isnumber(L, -1);
        float sweep_hz = has_sweep_hz ? (float)lua_tonumber(L, -1) : 0;
        lua_pop(L, 1);
        lua_getfield(L, 4, "sweep_ms");
        bool has_sweep_ms = lua_isnumber(L, -1);
        int sweep_ms = has_sweep_ms ? (int)lua_tointeger(L, -1) : 0;
        lua_pop(L, 1);
        if (has_sweep_hz || has_sweep_ms) {
            synth::g.set_sweep(idx, sweep_hz,
                (uint16_t)(sweep_ms < 0 ? 0 : sweep_ms));
        }

        lua_getfield(L, 4, "vib_depth_hz");
        bool has_vd = lua_isnumber(L, -1);
        float vd = has_vd ? (float)lua_tonumber(L, -1) : 0;
        lua_pop(L, 1);
        lua_getfield(L, 4, "vib_rate_hz");
        bool has_vr = lua_isnumber(L, -1);
        float vr = has_vr ? (float)lua_tonumber(L, -1) : 0;
        lua_pop(L, 1);
        if (has_vd || has_vr) {
            synth::g.set_vibrato(idx, vd, vr);
        }
    }

    activate_synth_mode();
    return 0;
}

// @lua ez.synth.note_off(voice) -> nil
// @brief Enter the release phase of the voice's envelope.
// @example ez.synth.note_off(2)
// @end
LUA_FUNCTION(l_synth_note_off) {
    int idx = lua_voice_idx(L, 1);
    synth::g.note_off(idx);
    return 0;
}

// @lua ez.synth.set_envelope(voice, attack_ms, decay_ms, sustain, release_ms)
// @brief Set the ADSR envelope shape for a voice.
// @param sustain 0..255 — fraction of peak; 0 = AD-only one-shot
// @end
LUA_FUNCTION(l_synth_set_envelope) {
    int idx = lua_voice_idx(L, 1);
    int a = (int)luaL_checkinteger(L, 2);
    int d = (int)luaL_checkinteger(L, 3);
    int s = (int)luaL_checkinteger(L, 4);
    int r = (int)luaL_checkinteger(L, 5);
    if (a < 0) a = 0; if (d < 0) d = 0; if (r < 0) r = 0;
    if (s < 0) s = 0; if (s > 255) s = 255;
    synth::g.set_envelope(idx, (uint16_t)a, (uint16_t)d, (uint8_t)s, (uint16_t)r);
    return 0;
}

// @lua ez.synth.set_sweep(voice, target_hz, ms) -> nil
// @brief Linear pitch sweep from current freq to `target_hz` over `ms`.
// @end
LUA_FUNCTION(l_synth_set_sweep) {
    int idx = lua_voice_idx(L, 1);
    float target = (float)luaL_checknumber(L, 2);
    int ms = (int)luaL_checkinteger(L, 3);
    synth::g.set_sweep(idx, target, (uint16_t)(ms < 0 ? 0 : ms));
    return 0;
}

// @lua ez.synth.set_vibrato(voice, depth_hz, rate_hz) -> nil
// @brief Sinusoidal pitch wobble around the current freq.
// @end
LUA_FUNCTION(l_synth_set_vibrato) {
    int idx = lua_voice_idx(L, 1);
    float depth = (float)luaL_checknumber(L, 2);
    float rate = (float)luaL_checknumber(L, 3);
    synth::g.set_vibrato(idx, depth, rate);
    return 0;
}

// @lua ez.synth.set_duty(voice, duty) -> nil
// @brief Set pulse duty (0.05..0.95). Ignored for non-pulse voices.
// @end
LUA_FUNCTION(l_synth_set_duty) {
    int idx = lua_voice_idx(L, 1);
    float duty = (float)luaL_checknumber(L, 2);
    synth::g.set_duty(idx, duty);
    return 0;
}

// @lua ez.synth.set_master(v) -> nil
// @brief Set engine master volume 0..255. Independent of ez.audio's volume.
// @end
LUA_FUNCTION(l_synth_set_master) {
    int v = (int)luaL_checkinteger(L, 1);
    if (v < 0) v = 0; if (v > 255) v = 255;
    synth::g.set_master((uint8_t)v);
    return 0;
}

// @lua ez.synth.silence() -> nil
// @brief Stop every voice immediately. Drops audio mode back to Off.
// @end
LUA_FUNCTION(l_synth_silence) {
    synth::g.silence_all();
    ezAudioSetOffMode();
    return 0;
}

// @lua ez.synth.is_active() -> boolean
// @brief True if at least one voice is currently producing sound.
// @end
LUA_FUNCTION(l_synth_is_active) {
    lua_pushboolean(L, synth::g.any_active() ? 1 : 0);
    return 1;
}

static const luaL_Reg synth_funcs[] = {
    {"note_on",      l_synth_note_on},
    {"note_off",     l_synth_note_off},
    {"set_envelope", l_synth_set_envelope},
    {"set_sweep",    l_synth_set_sweep},
    {"set_vibrato",  l_synth_set_vibrato},
    {"set_duty",     l_synth_set_duty},
    {"set_master",   l_synth_set_master},
    {"silence",      l_synth_silence},
    {"is_active",    l_synth_is_active},
    {nullptr, nullptr}
};

void registerSynthModule(lua_State* L) {
    lua_register_module(L, "synth", synth_funcs);
}
