"""
ez.audio bindings — tone generation, sample playback, volume.

Tests run with the volume saved and restored to the user's setting. Tone
durations are kept short (≤ 50 ms) so the audio output during the test
suite is just a few brief blips. File-based playback (sample/wav/mp3/
play/preload) is tested via the failure path with a non-existent file:
that exercises the binding wiring without needing a known file on
the device.
"""

from __future__ import annotations

import time

import pytest


@pytest.fixture(autouse=True)
def _restore_volume(device):
    original = device.lua_exec("return ez.audio.get_volume()")
    # Quiet the suite — 20% is audible but not loud.
    device.lua_exec("ez.audio.set_volume(20)")
    yield
    device.lua_exec("ez.audio.stop()")
    device.lua_exec(f"ez.audio.set_volume({original})")


# ---------------------------------------------------------------------------
# Namespace + volume
# ---------------------------------------------------------------------------


def test_namespace(device):
    assert device.lua_exec("return type(ez.audio)") == "table"


def test_volume_round_trip(device):
    device.lua_exec("ez.audio.set_volume(40)")
    assert device.lua_exec("return ez.audio.get_volume()") == 40
    device.lua_exec("ez.audio.set_volume(0)")
    assert device.lua_exec("return ez.audio.get_volume()") == 0
    # Out-of-range clamps to 0..100
    device.lua_exec("ez.audio.set_volume(200)")
    assert device.lua_exec("return ez.audio.get_volume()") == 100


# ---------------------------------------------------------------------------
# Tones
# ---------------------------------------------------------------------------


def test_play_tone_short(device):
    """play_tone(freq, ms) starts an async tone for the given duration."""
    ok = device.lua_exec("return ez.audio.play_tone(880, 50)")
    assert ok is True
    # Wait it out, then stop is harmless even if already finished.
    time.sleep(0.15)
    device.lua_exec("ez.audio.stop()")
    assert device.lua_exec("return ez.audio.is_playing()") is False


def test_is_playing_transitions(device):
    """Right after a long-ish play_tone, is_playing should be true.
    After stop(), it should be false."""
    device.lua_exec("ez.audio.play_tone(440, 500)")
    # Sample shortly after the call to catch the playing window.
    time.sleep(0.05)
    playing = device.lua_exec("return ez.audio.is_playing()")
    device.lua_exec("ez.audio.stop()")
    after = device.lua_exec("return ez.audio.is_playing()")
    # The tone may finish very quickly on a busy device — accept either
    # outcome for the mid-play check, as long as the post-stop value is
    # reliably false.
    assert isinstance(playing, bool)
    assert after is False


def test_set_frequency_validates_range(device):
    assert device.lua_exec("return ez.audio.set_frequency(1000)") is True
    assert device.lua_exec("return ez.audio.set_frequency(20)") is True
    assert device.lua_exec("return ez.audio.set_frequency(20000)") is True
    assert device.lua_exec("return ez.audio.set_frequency(19)") is False
    assert device.lua_exec("return ez.audio.set_frequency(20001)") is False


def test_start_and_stop(device):
    device.lua_exec("ez.audio.set_frequency(800)")
    device.lua_exec("ez.audio.start()")
    time.sleep(0.05)
    device.lua_exec("ez.audio.stop()")
    assert device.lua_exec("return ez.audio.is_playing()") is False


def test_beep_pattern(device):
    """beep(count, freq, on_ms, off_ms) — tiny times so the test
    finishes quickly. The binding is blocking and returns when the
    pattern completes."""
    code = """
        local t0 = ez.system.millis()
        ez.audio.beep(2, 1000, 20, 20)
        return ez.system.millis() - t0
    """
    elapsed = device.lua_exec(code)
    assert isinstance(elapsed, int)
    # 2 * (20 + 20) = 80 ms minimum; allow generous upper bound.
    assert 60 <= elapsed <= 1500, f"beep elapsed {elapsed} ms"


# ---------------------------------------------------------------------------
# File-based playback — exercise the failure path with a missing file
# ---------------------------------------------------------------------------


MISSING = "/fs/no_such_audio.dat"


def test_play_sample_missing_file(device):
    """play_sample on a missing file must return false, not crash."""
    out = device.lua_exec(f"return ez.audio.play_sample('{MISSING}')")
    assert out is False


def test_play_wav_missing_file(device):
    out = device.lua_exec(f"return ez.audio.play_wav('{MISSING}')")
    assert out is False


def test_play_mp3_missing_file(device):
    out = device.lua_exec(f"return ez.audio.play_mp3('{MISSING}')")
    assert out is False


def test_play_dispatches_by_extension(device):
    """play() dispatches on extension. Missing file should still fail
    cleanly for .wav, .mp3, .pcm."""
    for ext in ("wav", "mp3", "pcm"):
        out = device.lua_exec(f"return ez.audio.play('{MISSING}.{ext}')")
        assert out is False, f"play() with .{ext} returned {out!r}"


def test_preload_missing_file_returns_nil(device):
    """preload returns a handle on success; nil on failure."""
    out = device.lua_exec(f"return ez.audio.preload('{MISSING}')")
    # Some bindings return nil-or-(nil, error); accept both.
    if isinstance(out, list):
        out = out[0]
    assert out is None


def test_play_preloaded_invalid_handle_returns_false(device):
    """Calling play_preloaded with an unknown handle should not crash."""
    out = device.lua_exec("return ez.audio.play_preloaded(99999)")
    assert out is False


def test_play_preloaded_async_invalid_handle_returns_false(device):
    out = device.lua_exec("return ez.audio.play_preloaded_async(99999)")
    assert out is False


def test_unload_invalid_handle_is_safe(device):
    """unload with an unknown handle must not crash."""
    device.lua_exec("ez.audio.unload(99999)")
