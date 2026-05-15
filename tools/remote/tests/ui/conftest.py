"""
Per-widget UI test fixtures.

Each test gets a `mounted` callable that takes a Lua expression returning
a widget tree (or a single widget node) and pushes the ui_fixture screen
on top of the test_mode steady state. After the call:

- `mounted.device` is the EzRemote handle (so the test can call
  wait_frame_text() / wait_frame_primitives()).
- A Lua error inside the builder surfaces as `pytest.fail` with the
  message captured in _G._ui_fixture_build_err.

The screen is popped between tests by the parent autouse
`reset_to_test_mode` fixture in tools/remote/tests/conftest.py.

Pattern:

    def test_button_label_renders(mounted):
        mounted("return ezui.button('Hi')")
        texts = mounted.device.wait_frame_text()
        labels = [t['text'] for t in texts]
        assert 'Hi' in labels
"""

from __future__ import annotations

import pytest

# Lua snippet that installs the builder closure, then pushes the fixture
# screen. The builder is wrapped in a function so the test's expression
# can return either a single widget node or a full vbox tree — both
# shapes are handled in lua/screens/ui_fixture.lua.
_MOUNT_LUA = """
_G._ui_fixture_build = function()
    local ezui = require('ezui')
    {expr}
end
_G._ui_fixture_build_err = nil
local s = require('ezui.screen')
local def = require('screens.ui_fixture')
s.push(s.create(def, def.initial_state and def.initial_state() or {{}}))
return s.depth()
"""


@pytest.fixture()
def mounted(device):
    """Return a callable that mounts a widget tree on the ui_fixture screen."""

    class _Mount:
        def __init__(self, dev):
            self.device = dev

        def __call__(self, expr: str):
            """Evaluate `expr` (a Lua expression returning a widget node or tree)
            and push the fixture screen showing it. Fails the test if the
            builder raises a Lua error.

            Forces one frame render via wait_frame_text() so the builder
            actually runs, then surfaces any Lua error captured in
            _G._ui_fixture_build_err.
            """
            depth = self.device.lua_exec(_MOUNT_LUA.format(expr=expr))
            if depth != 3:
                pytest.fail(
                    f"ui_fixture push left unexpected stack depth {depth} "
                    f"(expected 3: desktop + test_mode + ui_fixture)"
                )
            # Force a render so the builder actually executes; without this
            # the error variable would still be nil from before push().
            self.device.wait_frame_text()
            err = self.device.lua_exec("return _G._ui_fixture_build_err")
            if err:
                pytest.fail(f"ui_fixture builder raised: {err}")

    return _Mount(device)
