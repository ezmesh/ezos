/**
 * Audio mock module
 * Uses Web Audio API for sound generation
 */

export function createAudioModule() {
    let audioCtx = null;
    let volume = 0.5;
    let enabled = true;
    let currentOscillator = null;
    let currentGain = null;
    let currentFrequency = 440;
    let isPlaying = false;
    const preloadedSounds = [];

    // Lazily create audio context (must be after user interaction)
    function getAudioContext() {
        if (!audioCtx) {
            audioCtx = new (window.AudioContext || window.webkitAudioContext)();
        }
        return audioCtx;
    }

    const module = {
        // Play a tone
        play_tone(frequency, durationMs) {
            if (!enabled) return;

            try {
                const ctx = getAudioContext();
                const oscillator = ctx.createOscillator();
                const gainNode = ctx.createGain();

                oscillator.connect(gainNode);
                gainNode.connect(ctx.destination);

                oscillator.type = 'square';
                oscillator.frequency.value = frequency;
                gainNode.gain.value = volume * 0.3; // Square waves are loud

                oscillator.start();

                // Fade out to avoid click
                gainNode.gain.exponentialRampToValueAtTime(
                    0.001,
                    ctx.currentTime + durationMs / 1000
                );

                setTimeout(() => oscillator.stop(), durationMs);
            } catch (e) {
                console.warn('[Audio] Failed to play tone:', e);
            }
        },

        // Play a beep pattern
        beep(count = 1, frequency = 1000, durationMs = 100, pauseMs = 100) {
            if (!enabled) return;

            let delay = 0;
            for (let i = 0; i < count; i++) {
                setTimeout(() => module.play_tone(frequency, durationMs), delay);
                delay += durationMs + pauseMs;
            }
        },

        // Play success sound
        play_success() {
            module.play_tone(880, 100);
            setTimeout(() => module.play_tone(1320, 150), 120);
        },

        // Play error sound
        play_error() {
            module.play_tone(220, 200);
            setTimeout(() => module.play_tone(165, 300), 220);
        },

        // Play click sound
        play_click() {
            module.play_tone(1500, 10);
        },

        // Play notification sound
        play_notification() {
            module.play_tone(660, 100);
            setTimeout(() => module.play_tone(880, 100), 120);
            setTimeout(() => module.play_tone(660, 100), 240);
        },

        // Set volume (0-100 from Lua, convert to 0.0-1.0)
        set_volume(vol) {
            // Lua passes 0-100, convert to 0.0-1.0
            if (vol > 1) {
                vol = vol / 100;
            }
            volume = Math.max(0, Math.min(1, vol));
        },

        // Get volume (return 0-100 for Lua)
        get_volume() {
            return Math.round(volume * 100);
        },

        // Play PCM sample by name (mock - falls back to beep)
        play_sample(name) {
            if (!enabled) return false;
            console.log(`[Audio] Would play sample: ${name}`);
            // In browser, just play a short beep as placeholder
            module.play_tone(800, 50);
            return true;
        },

        // Play any audio file (auto-detect format)
        play(filename) {
            if (!enabled) return false;
            console.log(`[Audio] Would play file: ${filename}`);
            // In browser, just play a short beep as placeholder
            module.play_tone(800, 100);
            return true;
        },

        // Play WAV file (mock - falls back to beep)
        play_wav(filename) {
            if (!enabled) return false;
            console.log(`[Audio] Would play WAV: ${filename}`);
            module.play_tone(600, 100);
            return true;
        },

        // Play MP3 file (mock - falls back to beep)
        play_mp3(filename) {
            if (!enabled) return false;
            console.log(`[Audio] Would play MP3: ${filename}`);
            module.play_tone(500, 150);
            return true;
        },

        // Preload audio file into memory (mock - returns handle)
        preload(filename) {
            const handle = preloadedSounds.length + 1;
            preloadedSounds.push({ filename, handle });
            console.log(`[Audio] Preloaded: ${filename} -> handle ${handle}`);
            return handle;
        },

        // Play preloaded audio (mock - plays beep)
        play_preloaded(handle) {
            if (!enabled) return false;
            const sound = preloadedSounds.find(s => s.handle === handle);
            if (sound) {
                console.log(`[Audio] Playing preloaded: ${sound.filename}`);
                module.play_tone(700, 50);
                return true;
            }
            console.warn(`[Audio] Invalid handle: ${handle}`);
            return false;
        },

        // Unload preloaded audio
        unload(handle) {
            const idx = preloadedSounds.findIndex(s => s.handle === handle);
            if (idx >= 0) {
                console.log(`[Audio] Unloaded handle ${handle}`);
                preloadedSounds.splice(idx, 1);
            }
        },

        // Enable/disable audio
        set_enabled(state) {
            enabled = state;
        },

        // Check if audio is enabled
        is_enabled() {
            return enabled;
        },

        // Play melody (array of {freq, duration} objects)
        play_melody(notes) {
            if (!enabled) return;

            let delay = 0;
            for (const note of notes) {
                if (note.freq > 0) {
                    setTimeout(() => module.play_tone(note.freq, note.duration), delay);
                }
                delay += note.duration + 20; // Small gap between notes
            }
        },

        // Check if audio is currently playing
        is_playing() {
            return isPlaying;
        },

        // Set frequency for continuous tone
        set_frequency(freq) {
            currentFrequency = freq;
            if (currentOscillator) {
                currentOscillator.frequency.value = freq;
            }
            return true;
        },

        // Start continuous tone at current frequency
        start() {
            if (!enabled || isPlaying) return;

            try {
                const ctx = getAudioContext();
                currentOscillator = ctx.createOscillator();
                currentGain = ctx.createGain();

                currentOscillator.connect(currentGain);
                currentGain.connect(ctx.destination);

                currentOscillator.type = 'square';
                currentOscillator.frequency.value = currentFrequency;
                currentGain.gain.value = volume * 0.3;

                currentOscillator.start();
                isPlaying = true;
            } catch (e) {
                console.warn('[Audio] Failed to start continuous tone:', e);
            }
        },

        // Stop continuous tone
        stop() {
            if (currentOscillator) {
                try {
                    currentOscillator.stop();
                } catch (e) {
                    // Ignore if already stopped
                }
                currentOscillator = null;
                currentGain = null;
            }
            isPlaying = false;
        },
    };

    return module;
}
