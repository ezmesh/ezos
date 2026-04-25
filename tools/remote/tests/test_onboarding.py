"""
Onboarding wizard smoke test.

Acceptance criteria for issue #22 calls for "at least one test that
pushes the onboarding root screen and asserts the title is right (the
rest is interactive)". Stepping through the wizard exercises text-edit
mode, dropdowns, and accent picking — all of which are awkward to drive
end-to-end over the remote protocol — so that part is left to manual
verification.
"""

from __future__ import annotations


_PUSH_HELPER = """
local s = require('ezui.screen')
local def = require('{path}')
def._onboarding = true
local init = type(def.initial_state) == 'function' and def.initial_state() or {{}}
s.push(s.create(def, init))
"""


def test_welcome_screen_has_expected_title(device):
    device.lua_exec(_PUSH_HELPER.format(path="screens.onboarding.welcome"))
    title = device.lua_exec(
        "local s = require('ezui.screen'); local t = s.stack[#s.stack]; "
        "return t and t.title or nil"
    )
    assert title == "Welcome", (
        f"Pushed onboarding welcome, expected title 'Welcome', got {title!r}"
    )


def test_module_exposes_required_step_count(device):
    """The progress label is computed against this list, so a regression
    that drops a step would show up here before users notice it."""
    count = device.lua_exec(
        "local m = require('screens.onboarding'); return #m.REQUIRED"
    )
    assert count == 5, f"expected 5 required steps, got {count}"


def test_is_onboarded_helper_handles_missing_pref(device):
    """The boot-time gate relies on is_onboarded() returning false when
    no pref has been written; nil/'' must not be treated as truthy.
    Saves and restores the pref so the next reboot doesn't re-trigger
    the wizard on a device that was previously onboarded."""
    result = device.lua_exec(
        "local m = require('screens.onboarding'); "
        "local prev = ez.storage.get_pref('onboarded', nil); "
        "ez.storage.remove_pref('onboarded'); "
        "local got = m.is_onboarded(); "
        "if prev ~= nil then ez.storage.set_pref('onboarded', prev) end; "
        "return got"
    )
    assert result is False, f"expected false for missing pref, got {result!r}"
