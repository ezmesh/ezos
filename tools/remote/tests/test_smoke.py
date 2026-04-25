"""
Smoke tests: device responds, Lua VM is alive, basic state probes work.
These don't depend on UI navigation — they only need a working serial link.
"""

from __future__ import annotations


def test_ping(device):
    assert device.ping() is True


def test_lua_exec_arithmetic(device):
    assert device.lua_exec("return 1 + 2") == 3


def test_lua_exec_returns_string(device):
    assert device.lua_exec('return "hello"') == "hello"


def test_lua_runtime_has_ez_namespace(device):
    """Sanity-check that the C++ bindings registered the global ez table."""
    assert device.lua_exec("return type(ez)") == "table"
    assert device.lua_exec("return type(ez.system)") == "table"


def test_screen_stack_has_root(device):
    depth = device.lua_exec("return require('ezui.screen').depth()")
    assert isinstance(depth, int) and depth >= 1


def test_memory_baseline(device):
    """Current Lua heap usage in KiB; just a smoke value, not a regression gate."""
    kib = device.lua_exec("return collectgarbage('count')")
    assert isinstance(kib, (int, float))
    assert kib > 0
