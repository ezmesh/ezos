"""
ez.keyboard bindings — read-mostly. Setters that change persistent state
(backlight, repeat tuning, trackball, mode) save and restore the original
value so tests don't leave the device with surprise behaviour.
"""

from __future__ import annotations


def test_namespace(device):
    assert device.lua_exec("return type(ez.keyboard)") == "table"


# ---------------------------------------------------------------------------
# Read state probes — always callable, no input required
# ---------------------------------------------------------------------------


def test_available_returns_bool(device):
    assert isinstance(device.lua_exec("return ez.keyboard.available()"), bool)


def test_has_key_activity_returns_bool(device):
    assert isinstance(
        device.lua_exec("return ez.keyboard.has_key_activity()"), bool
    )


def test_has_trackball_returns_bool(device):
    assert isinstance(device.lua_exec("return ez.keyboard.has_trackball()"), bool)


def test_modifier_state_queries(device):
    """No keys held during a normal test run, so all modifiers should be false."""
    for fn in ("is_shift_held", "is_ctrl_held", "is_alt_held", "is_fn_held"):
        v = device.lua_exec(f"return ez.keyboard.{fn}()")
        assert v is False, f"{fn} returned {v!r}"


def test_is_held_for_unpressed_key(device):
    assert device.lua_exec("return ez.keyboard.is_held('a')") is False


def test_read_returns_table_or_nil(device):
    """read() returns a key event table when one is queued, else nil."""
    out = device.lua_exec("return ez.keyboard.read()")
    assert out is None or isinstance(out, dict)


def test_get_raw_matrix_bits(device):
    n = device.lua_exec("return ez.keyboard.get_raw_matrix_bits()")
    assert isinstance(n, int) and n >= 0


def test_get_pin_states(device):
    s = device.lua_exec("return ez.keyboard.get_pin_states()")
    assert isinstance(s, str)


# ---------------------------------------------------------------------------
# Mode + raw matrix
# ---------------------------------------------------------------------------


def test_mode_round_trip(device):
    original = device.lua_exec("return ez.keyboard.get_mode()")
    assert original in ("normal", "raw")
    try:
        ok = device.lua_exec("return ez.keyboard.set_mode('raw')")
        assert ok is True
        assert device.lua_exec("return ez.keyboard.get_mode()") == "raw"

        # In raw mode, read_raw_matrix returns a table; in normal, nil.
        m = device.lua_exec("return ez.keyboard.read_raw_matrix()")
        assert m is None or isinstance(m, (dict, list))

        # is_key_pressed(col, row) is callable in either mode.
        assert isinstance(
            device.lua_exec("return ez.keyboard.is_key_pressed(0, 0)"), bool
        )

        # read_raw_code returns nil when no key is pressed.
        rc = device.lua_exec("return ez.keyboard.read_raw_code()")
        assert rc is None or isinstance(rc, int)
    finally:
        device.lua_exec(f"ez.keyboard.set_mode('{original}')")


def test_set_mode_rejects_unknown(device):
    """Invalid mode string raises a Lua error."""
    import pytest
    with pytest.raises(RuntimeError, match="[Ii]nvalid mode"):
        device.lua_exec("return ez.keyboard.set_mode('quantum')")


# ---------------------------------------------------------------------------
# Backlight
# ---------------------------------------------------------------------------


def test_backlight_round_trip(device):
    original = device.lua_exec("return ez.keyboard.get_backlight()")
    assert isinstance(original, int) and 0 <= original <= 255
    try:
        device.lua_exec("ez.keyboard.set_backlight(0)")
        assert device.lua_exec("return ez.keyboard.get_backlight()") == 0
        device.lua_exec("ez.keyboard.set_backlight(128)")
        assert device.lua_exec("return ez.keyboard.get_backlight()") == 128
    finally:
        device.lua_exec(f"ez.keyboard.set_backlight({original})")


# ---------------------------------------------------------------------------
# Key repeat
# ---------------------------------------------------------------------------


def test_repeat_enabled_round_trip(device):
    original = device.lua_exec("return ez.keyboard.get_repeat_enabled()")
    assert isinstance(original, bool)
    try:
        device.lua_exec("ez.keyboard.set_repeat_enabled(true)")
        assert device.lua_exec("return ez.keyboard.get_repeat_enabled()") is True
        device.lua_exec("ez.keyboard.set_repeat_enabled(false)")
        assert device.lua_exec("return ez.keyboard.get_repeat_enabled()") is False
    finally:
        device.lua_exec(
            f"ez.keyboard.set_repeat_enabled({'true' if original else 'false'})"
        )


def test_repeat_delay_round_trip(device):
    original = device.lua_exec("return ez.keyboard.get_repeat_delay()")
    assert isinstance(original, int) and original > 0
    try:
        device.lua_exec("ez.keyboard.set_repeat_delay(400)")
        assert device.lua_exec("return ez.keyboard.get_repeat_delay()") == 400
    finally:
        device.lua_exec(f"ez.keyboard.set_repeat_delay({original})")


def test_repeat_rate_round_trip(device):
    original = device.lua_exec("return ez.keyboard.get_repeat_rate()")
    assert isinstance(original, int) and original > 0
    try:
        device.lua_exec("ez.keyboard.set_repeat_rate(50)")
        assert device.lua_exec("return ez.keyboard.get_repeat_rate()") == 50
    finally:
        device.lua_exec(f"ez.keyboard.set_repeat_rate({original})")


# ---------------------------------------------------------------------------
# Trackball
# ---------------------------------------------------------------------------


def test_trackball_sensitivity_round_trip(device):
    original = device.lua_exec("return ez.keyboard.get_trackball_sensitivity()")
    assert isinstance(original, int)
    try:
        device.lua_exec("ez.keyboard.set_trackball_sensitivity(2)")
        assert (
            device.lua_exec("return ez.keyboard.get_trackball_sensitivity()") == 2
        )
    finally:
        device.lua_exec(f"ez.keyboard.set_trackball_sensitivity({original})")


def test_trackball_mode_round_trip(device):
    original = device.lua_exec("return ez.keyboard.get_trackball_mode()")
    assert isinstance(original, str)
    # The exact set of modes is implementation-defined; round-trip the
    # current value to verify get/set wire up.
    try:
        device.lua_exec(f"ez.keyboard.set_trackball_mode('{original}')")
        assert (
            device.lua_exec("return ez.keyboard.get_trackball_mode()") == original
        )
    finally:
        device.lua_exec(f"ez.keyboard.set_trackball_mode('{original}')")


# ---------------------------------------------------------------------------
# Blocking read — pass a tiny timeout so we don't actually hold up the suite
# ---------------------------------------------------------------------------


def test_read_blocking_with_short_timeout(device):
    """A 1ms timeout returns nil immediately when no key is pressed."""
    out = device.lua_exec("return ez.keyboard.read_blocking(1)")
    assert out is None or isinstance(out, dict)
