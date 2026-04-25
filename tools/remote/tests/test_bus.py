"""
ez.bus — pub/sub message bus. We subscribe a Lua-side counter, post some
messages, and verify the callback observed them. pending_count and
has_subscribers are smoke-checked along the way.
"""

from __future__ import annotations

import time


def test_namespace(device):
    assert device.lua_exec("return type(ez.bus)") == "table"


def test_pending_count_returns_integer(device):
    n = device.lua_exec("return ez.bus.pending_count()")
    assert isinstance(n, int) and n >= 0


def test_has_subscribers_for_unknown_topic(device):
    assert device.lua_exec(
        "return ez.bus.has_subscribers('test/no_such_topic_xxx')"
    ) is False


def test_subscribe_post_unsubscribe_round_trip(device):
    """
    Subscribe a counter, post twice, drain via the message-loop pump, then
    unsubscribe. has_subscribers reflects state at each step.
    """
    setup = """
        _G._test_bus_state = { count = 0, last = nil }
        local id = ez.bus.subscribe('test/echo', function(topic, data)
            _G._test_bus_state.count = _G._test_bus_state.count + 1
            _G._test_bus_state.last  = data
        end)
        return id
    """
    sub_id = device.lua_exec(setup)
    assert isinstance(sub_id, (int, str))

    try:
        assert device.lua_exec(
            "return ez.bus.has_subscribers('test/echo')"
        ) is True

        # Post two messages and let the runtime dispatch them. The bus
        # delivers on the next LuaRuntime::update tick, which only runs
        # between Lua coroutine yields — sleep on the host side so wall
        # clock advances between commands.
        device.lua_exec(
            "ez.bus.post('test/echo', 'a'); ez.bus.post('test/echo', 'b')"
        )
        time.sleep(0.3)
        state = device.lua_exec("return _G._test_bus_state")
        assert isinstance(state, dict)
        assert state["count"] == 2
        assert state["last"] == "b"
    finally:
        device.lua_exec(f"return ez.bus.unsubscribe({sub_id!r})")
        assert device.lua_exec(
            "return ez.bus.has_subscribers('test/echo')"
        ) is False
        device.lua_exec("_G._test_bus_state = nil")


def test_unsubscribe_unknown_id_returns_false(device):
    """Unsubscribing a never-registered id must not crash and should report failure."""
    out = device.lua_exec("return ez.bus.unsubscribe(999999999)")
    assert out is False or out is None
