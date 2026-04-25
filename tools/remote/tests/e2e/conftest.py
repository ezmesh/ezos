"""
Pytest fixtures for end-to-end ezOS tests that require two T-Decks.

Both devices are driven over USB via tools.remote.ez_remote. A and B are
distinct EzRemote sessions; the autouse reset puts each into the
test_mode screen between tests so neither accumulates UI state.

Environment:
    EZ_TEST_DEVICE_A    Default /dev/ttyACM0
    EZ_TEST_DEVICE_B    Default /dev/ttyACM1

When either port is missing or unresponsive, every test is skipped
with a clear message — these tests are dual-device and intentionally
opt-in for users with the hardware.

Like the single-device suite, transmit-bearing tests respect the
public-channel rule (CLAUDE.md): A and B exchange only on
addressed/private channels, never on #Public.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO_ROOT / "tools" / "remote"))

from ez_remote import EzRemote  # noqa: E402

PORT_A = os.environ.get("EZ_TEST_DEVICE_A", "/dev/ttyACM0")
PORT_B = os.environ.get("EZ_TEST_DEVICE_B", "/dev/ttyACM1")


_ENTER_TEST_MODE_LUA = (
    "local s = require('ezui.screen'); "
    "for _ = 1, 32 do if s.depth() <= 1 then break end s.pop() end "
    "local ok, t = pcall(require, 'ezui.transient'); "
    "if ok and t.reset then t.reset() end "
    "local def = require('screens.test_mode'); "
    "s.push(s.create(def, def.initial_state and def.initial_state() or {})); "
    "return s.depth()"
)


def _open_remote(port: str, label: str) -> EzRemote:
    if not os.path.exists(port):
        pytest.skip(
            f"No {label} device at {port}. Set EZ_TEST_DEVICE_{label[-1]} "
            f"or plug in a second T-Deck."
        )
    remote = EzRemote(port, timeout=10)
    time.sleep(0.3)
    remote.ser.reset_input_buffer()
    remote.ser.reset_output_buffer()

    last_exc: Exception | None = None
    for i in range(4):
        try:
            if remote.ping():
                break
        except Exception as exc:
            last_exc = exc
            try:
                remote.ser.reset_input_buffer()
            except Exception:
                pass
            time.sleep(0.2 * (i + 1))
    else:
        remote.close()
        pytest.skip(
            f"Device {label} at {port} did not respond to ping: {last_exc}"
        )

    _wrap_lua_exec_with_retry(remote)

    # Enter test_mode
    for _ in range(3):
        try:
            depth = remote.lua_exec(_ENTER_TEST_MODE_LUA)
            if depth == 2:
                break
        except Exception:
            time.sleep(0.3)
    return remote


def _wrap_lua_exec_with_retry(remote: EzRemote) -> None:
    original = remote.lua_exec

    def _retried(code: str):
        try:
            return original(code)
        except TimeoutError:
            try:
                remote.ser.reset_input_buffer()
            except Exception:
                pass
            time.sleep(0.3)
            return original(code)

    remote.lua_exec = _retried  # type: ignore[assignment]


def _exit_test_mode(remote: EzRemote) -> None:
    try:
        remote.lua_exec(
            "local s = require('ezui.screen'); "
            "for _ = 1, 32 do if s.depth() <= 1 then break end s.pop() end "
            "local ok, t = pcall(require, 'ezui.transient'); "
            "if ok and t.reset then t.reset() end"
        )
    except Exception:
        pass


@pytest.fixture(scope="session")
def device_a() -> EzRemote:
    if PORT_A == PORT_B:
        pytest.skip("EZ_TEST_DEVICE_A and EZ_TEST_DEVICE_B must be different ports")
    remote = _open_remote(PORT_A, "A")
    yield remote
    _exit_test_mode(remote)
    remote.close()


@pytest.fixture(scope="session")
def device_b() -> EzRemote:
    if PORT_A == PORT_B:
        pytest.skip("EZ_TEST_DEVICE_A and EZ_TEST_DEVICE_B must be different ports")
    remote = _open_remote(PORT_B, "B")
    yield remote
    _exit_test_mode(remote)
    remote.close()


@pytest.fixture(scope="session")
def both_devices(device_a, device_b):
    """Aggregate fixture for tests that touch both. Asserts they're
    distinct nodes (different MAC / mesh node id) so a misconfigured
    setup doesn't masquerade as success."""
    id_a = device_a.lua_exec("return ez.mesh.get_node_id()")
    id_b = device_b.lua_exec("return ez.mesh.get_node_id()")
    if id_a == id_b:
        pytest.skip(
            f"Both ports report the same node id ({id_a}). "
            "Are you actually pointed at two different devices?"
        )
    return device_a, device_b


@pytest.fixture(autouse=True)
def reset_both(device_a, device_b):
    """Pop anything tests pushed above test_mode on either device."""
    for d in (device_a, device_b):
        depth = d.lua_exec(
            "local s = require('ezui.screen'); "
            "for _ = 1, 32 do if s.depth() <= 2 then break end s.pop() end "
            "local ok, t = pcall(require, 'ezui.transient'); "
            "if ok and t.reset then t.reset() end "
            "return s.depth()"
        )
        if depth != 2:
            d.lua_exec(_ENTER_TEST_MODE_LUA)
    yield
    for d in (device_a, device_b):
        try:
            d.lua_exec(
                "local s = require('ezui.screen'); "
                "for _ = 1, 32 do if s.depth() <= 2 then break end s.pop() end"
            )
        except Exception:
            pass
