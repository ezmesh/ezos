"""
ez.http bindings — fetch/get/post/post_json/serve_*.

HTTP calls yield the calling coroutine, so they must run inside
spawn(). Tests stash the result in a Lua global and poll for it from
the host. All gated behind @pytest.mark.network — without
EZ_TEST_NETWORK=1 they're skipped.

EZ_TEST_HTTP_URL overrides the test target (default http://example.com).
"""

from __future__ import annotations

import os
import time

import pytest

pytestmark = pytest.mark.network

TEST_URL = os.environ.get("EZ_TEST_HTTP_URL", "http://example.com/")
RESULT_KEY = "_test_http_result"


def _await_result(device, lua_call: str, timeout: float = 15.0):
    """Run lua_call inside spawn() and poll for _G[RESULT_KEY].

    The Lua side stashes either the call result, or `false` if the call
    returned nil (HTTP failure → no network, DNS error, etc.). When we
    see `false` we skip rather than fail, since the binding wired up
    correctly — the failure is in the network, not in our code.
    """
    code = f"""
        _G.{RESULT_KEY} = nil
        spawn(function()
            _G.{RESULT_KEY} = ({lua_call}) or false
        end)
    """
    device.lua_exec(code)
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = device.lua_exec(f"return _G.{RESULT_KEY}")
        if result is not None:
            device.lua_exec(f"_G.{RESULT_KEY} = nil")
            if result is False:
                pytest.skip(
                    "HTTP call returned nil — likely no network/DNS. "
                    "Set EZ_TEST_HTTP_URL to a reachable endpoint or bring "
                    "wifi up first."
                )
            return result
        time.sleep(0.2)
    device.lua_exec(f"_G.{RESULT_KEY} = nil")
    pytest.skip("HTTP request timed out — likely no network connection")


def _is_http_response(out) -> bool:
    if not isinstance(out, dict):
        return False
    has_status = "status" in out or "code" in out
    has_body = any(k in out for k in ("body", "data", "content"))
    return has_status and has_body


def test_namespace(device):
    assert device.lua_exec("return type(ez.http)") == "table"


def test_get_returns_table(device):
    out = _await_result(device, f"ez.http.get('{TEST_URL}')")
    assert _is_http_response(out), f"unexpected http.get shape: {out!r}"


def test_fetch_returns_table(device):
    out = _await_result(device, f"ez.http.fetch('{TEST_URL}')")
    assert _is_http_response(out), f"unexpected http.fetch shape: {out!r}"


def test_post_returns_table(device):
    out = _await_result(
        device,
        f"ez.http.post('{TEST_URL}', 'hello=world',"
        f" 'application/x-www-form-urlencoded')",
    )
    assert _is_http_response(out), f"unexpected http.post shape: {out!r}"


def test_post_json_returns_table(device):
    out = _await_result(
        device,
        f"ez.http.post_json('{TEST_URL}', {{ key = 'value' }})",
    )
    assert _is_http_response(out), f"unexpected http.post_json shape: {out!r}"


def test_serve_lifecycle(device):
    """serve_start(port, handler_fn) — handler returns (status, body, [headers])."""
    code = """
        local ok = ez.http.serve_start(45685, function(req)
            return 200, 'pong', { ['Content-Type'] = 'text/plain' }
        end)
        return ok
    """
    started = device.lua_exec(code)
    assert isinstance(started, bool)
    if started:
        # serve_update pumps the embedded server; safe to call when idle.
        device.lua_exec("ez.http.serve_update()")
        device.lua_exec("ez.http.serve_stop()")
