"""
Service-level tests: probe local state of channels, contacts, and direct
messages. These never transmit on the mesh — they only exercise in-memory
APIs.
"""

from __future__ import annotations


def test_channels_service_loads(device):
    code = """
        local ch = require('services.channels')
        return type(ch.get_history) == 'function'
            and type(ch.get_list) == 'function'
    """
    assert device.lua_exec(code) is True


def test_public_channel_history_is_list(device):
    code = "local ch = require('services.channels'); return #ch.get_history('#Public')"
    count = device.lua_exec(code)
    assert isinstance(count, int) and count >= 0


def test_contacts_service_returns_table(device):
    code = """
        local c = require('services.contacts')
        local list = c.get_all()
        return type(list) == 'table'
    """
    assert device.lua_exec(code) is True


def test_direct_messages_service_loads(device):
    code = """
        local dm = require('services.direct_messages')
        return type(dm.get_total_unread) == 'function'
    """
    assert device.lua_exec(code) is True


def test_direct_messages_total_unread_is_number(device):
    n = device.lua_exec(
        "local dm = require('services.direct_messages'); return dm.get_total_unread()"
    )
    assert isinstance(n, (int, float)) and n >= 0
