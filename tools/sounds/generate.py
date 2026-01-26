#!/usr/bin/env python3
"""
UI Sound Generator for T-Deck OS
Generates short PCM sound effects with proper envelopes.
Output: 16-bit signed PCM at 22050Hz, mono

Usage: python generate.py [output_dir]
"""

import struct
import math
import os
import sys

SAMPLE_RATE = 22050
OUTPUT_DIR = "../../data/sounds"

def generate_tone(freq, duration_ms, volume=0.5, attack_ms=2, decay_ms=10, release_ms=5):
    """Generate a tone with ADSR-like envelope"""
    samples = int(SAMPLE_RATE * duration_ms / 1000)
    attack_samples = int(SAMPLE_RATE * attack_ms / 1000)
    decay_samples = int(SAMPLE_RATE * decay_ms / 1000)
    release_samples = int(SAMPLE_RATE * release_ms / 1000)
    sustain_samples = samples - attack_samples - decay_samples - release_samples
    if sustain_samples < 0:
        sustain_samples = 0

    data = []
    for i in range(samples):
        # Calculate envelope
        if i < attack_samples:
            env = i / max(1, attack_samples)
        elif i < attack_samples + decay_samples:
            env = 1.0 - 0.3 * ((i - attack_samples) / max(1, decay_samples))
        elif i < attack_samples + decay_samples + sustain_samples:
            env = 0.7
        else:
            remaining = samples - i
            env = 0.7 * (remaining / max(1, release_samples))

        # Generate sample with slight harmonics for richer sound
        t = i / SAMPLE_RATE
        sample = math.sin(2 * math.pi * freq * t)
        sample += 0.3 * math.sin(2 * math.pi * freq * 2 * t)  # 2nd harmonic
        sample += 0.1 * math.sin(2 * math.pi * freq * 3 * t)  # 3rd harmonic
        sample = sample / 1.4  # Normalize

        sample = sample * env * volume
        # Convert to 16-bit signed
        sample_int = int(sample * 32767)
        sample_int = max(-32768, min(32767, sample_int))
        data.append(sample_int)

    return data

def generate_click(volume=0.4):
    """Short click/tick sound - like a mechanical switch"""
    samples = int(SAMPLE_RATE * 0.015)  # 15ms
    data = []
    for i in range(samples):
        t = i / SAMPLE_RATE
        # Quick decay envelope
        env = math.exp(-t * 300)
        # Mix of frequencies for click character
        sample = math.sin(2 * math.pi * 800 * t) * 0.5
        sample += math.sin(2 * math.pi * 400 * t) * 0.3
        # Add some noise for texture
        noise = (hash(i) % 1000 - 500) / 500.0 * 0.2
        sample = (sample + noise) * env * volume
        sample_int = int(sample * 32767)
        sample_int = max(-32768, min(32767, sample_int))
        data.append(sample_int)
    return data

def generate_scroll(volume=0.35):
    """Very short scroll tick - crisp high-frequency tick for small speakers"""
    samples = int(SAMPLE_RATE * 0.006)  # 6ms - very short
    data = []
    for i in range(samples):
        t = i / SAMPLE_RATE
        # Very quick decay
        env = math.exp(-t * 600)
        # Higher frequencies only - works better on small speakers
        # Primary tone around 1kHz with harmonic at 2kHz
        sample = math.sin(2 * math.pi * 1000 * t) * 0.7
        sample += math.sin(2 * math.pi * 2000 * t) * 0.3
        # Slight attack click using higher frequency burst
        if t < 0.001:
            sample += math.sin(2 * math.pi * 3000 * t) * 0.4
        sample = sample * env * volume
        sample_int = int(sample * 32767)
        sample_int = max(-32768, min(32767, sample_int))
        data.append(sample_int)
    return data

def generate_back(volume=0.35):
    """Back/cancel - descending tone"""
    samples = int(SAMPLE_RATE * 0.025)  # 25ms
    data = []
    for i in range(samples):
        t = i / SAMPLE_RATE
        # Descending pitch
        freq = 500 - (t * 8000)  # Sweep down
        if freq < 150:
            freq = 150
        env = math.exp(-t * 80)
        sample = math.sin(2 * math.pi * freq * t)
        sample = sample * env * volume
        sample_int = int(sample * 32767)
        sample_int = max(-32768, min(32767, sample_int))
        data.append(sample_int)
    return data

def generate_confirm(volume=0.4):
    """Confirmation - pleasant chirp"""
    samples = int(SAMPLE_RATE * 0.035)  # 35ms
    data = []
    for i in range(samples):
        t = i / SAMPLE_RATE
        # Ascending pitch
        freq = 600 + (t * 3000)
        if freq > 1200:
            freq = 1200
        env = 1.0 if t < 0.01 else math.exp(-(t - 0.01) * 60)
        sample = math.sin(2 * math.pi * freq * t)
        sample += 0.2 * math.sin(2 * math.pi * freq * 2 * t)
        sample = sample / 1.2 * env * volume
        sample_int = int(sample * 32767)
        sample_int = max(-32768, min(32767, sample_int))
        data.append(sample_int)
    return data

def generate_error(volume=0.5):
    """Error sound - low buzz"""
    samples = int(SAMPLE_RATE * 0.080)  # 80ms
    data = []
    for i in range(samples):
        t = i / SAMPLE_RATE
        env = 1.0 if t < 0.06 else math.exp(-(t - 0.06) * 50)
        # Harsh low tone
        sample = math.sin(2 * math.pi * 150 * t)
        sample += 0.5 * math.sin(2 * math.pi * 300 * t)
        sample += 0.3 * math.sin(2 * math.pi * 450 * t)
        sample = sample / 1.8 * env * volume
        sample_int = int(sample * 32767)
        sample_int = max(-32768, min(32767, sample_int))
        data.append(sample_int)
    return data

def generate_notify(volume=0.45):
    """Notification - attention-getting"""
    samples = int(SAMPLE_RATE * 0.050)  # 50ms
    data = []
    for i in range(samples):
        t = i / SAMPLE_RATE
        env = math.exp(-t * 40)
        freq = 880
        sample = math.sin(2 * math.pi * freq * t)
        sample += 0.3 * math.sin(2 * math.pi * freq * 1.5 * t)
        sample = sample / 1.3 * env * volume
        sample_int = int(sample * 32767)
        sample_int = max(-32768, min(32767, sample_int))
        data.append(sample_int)
    return data

def generate_message(volume=0.45):
    """Message received - distinctive two-tone"""
    duration_ms = 60
    samples = int(SAMPLE_RATE * duration_ms / 1000)
    data = []
    for i in range(samples):
        t = i / SAMPLE_RATE
        # Two-tone chirp
        if t < 0.025:
            freq = 800
            env = 1.0 if t < 0.02 else math.exp(-(t - 0.02) * 200)
        else:
            freq = 1000
            t2 = t - 0.025
            env = 1.0 if t2 < 0.025 else math.exp(-(t2 - 0.025) * 100)
        sample = math.sin(2 * math.pi * freq * t)
        sample = sample * env * volume
        sample_int = int(sample * 32767)
        sample_int = max(-32768, min(32767, sample_int))
        data.append(sample_int)
    return data

def save_pcm(filename, data):
    """Save as raw 16-bit signed PCM"""
    with open(filename, 'wb') as f:
        for sample in data:
            f.write(struct.pack('<h', sample))
    print(f"  {filename}: {len(data)} samples, {len(data)*2} bytes")

def main():
    output_dir = sys.argv[1] if len(sys.argv) > 1 else OUTPUT_DIR

    # Resolve relative path
    script_dir = os.path.dirname(os.path.abspath(__file__))
    if not os.path.isabs(output_dir):
        output_dir = os.path.join(script_dir, output_dir)

    os.makedirs(output_dir, exist_ok=True)

    print(f"Generating UI sounds to {output_dir}")
    print(f"Format: 16-bit signed PCM, {SAMPLE_RATE}Hz, mono")
    print()

    sounds = {
        'click': generate_click(),
        'scroll': generate_scroll(),
        'back': generate_back(),
        'confirm': generate_confirm(),
        'error': generate_error(),
        'notify': generate_notify(),
        'message': generate_message(),
    }

    for name, data in sounds.items():
        save_pcm(os.path.join(output_dir, f"{name}.pcm"), data)

    print()
    print("Done!")

if __name__ == '__main__':
    main()
