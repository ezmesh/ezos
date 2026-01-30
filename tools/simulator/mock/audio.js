/**
 * Audio mock module
 * Uses Web Audio API for sound generation
 */

export function createAudioModule() {
    let audioCtx = null;
    let volume = 0.5;
    let enabled = true;

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

        // Set volume (0.0 - 1.0)
        set_volume(vol) {
            volume = Math.max(0, Math.min(1, vol));
        },

        // Get volume
        get_volume() {
            return volume;
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
    };

    return module;
}
