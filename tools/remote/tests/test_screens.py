"""
Screen navigation tests: push known screens and verify they end up on top
of the stack with the expected title. The autouse fixture in conftest pops
back to root between tests, so each test starts from the desktop.
"""

from __future__ import annotations

import pytest

# (require path, expected screen title)
SCREENS = [
    ("screens.about", "About"),
    ("screens.tools.terminal", "Terminal"),
    ("screens.tools.help", "Help"),
]


_PUSH_HELPER = """
local s = require('ezui.screen')
local def = require('{path}')
local init = type(def.initial_state) == 'function' and def.initial_state() or {{}}
s.push(s.create(def, init))
"""


@pytest.mark.parametrize("module_path,expected_title", SCREENS)
def test_push_screen_sets_title(device, module_path, expected_title):
    device.lua_exec(_PUSH_HELPER.format(path=module_path))
    title = device.lua_exec(
        "local s = require('ezui.screen'); local t = s.stack[#s.stack]; "
        "return t and t.title or nil"
    )
    assert title == expected_title, (
        f"Pushed {module_path}, expected title {expected_title!r}, got {title!r}"
    )


def test_pop_restores_root_depth(device):
    initial = device.lua_exec("return require('ezui.screen').depth()")
    device.lua_exec(_PUSH_HELPER.format(path="screens.about"))
    pushed = device.lua_exec("return require('ezui.screen').depth()")
    assert pushed == initial + 1
    device.lua_exec("require('ezui.screen').pop()")
    after_pop = device.lua_exec("return require('ezui.screen').depth()")
    assert after_pop == initial
