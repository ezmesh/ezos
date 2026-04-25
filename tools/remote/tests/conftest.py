"""
Pytest fixtures for on-device ezOS tests.

Tests in this directory drive a real T-Deck over USB via tools.remote.ez_remote.
A device must be plugged in at the path given by the EZ_REMOTE_PORT environment
variable (default: /dev/ttyACM0). When the port is missing, every test in this
tree is skipped — so the suite is safe to run unconditionally in CI.

Session lifecycle:
    1. Open serial, ping.
    2. Push the `test_mode` screen so tests own the display canvas with no
       interfering UI polling. The desktop screen stays at depth 1; depth 2
       is the test_mode screen we pushed.
    3. Each test runs from this "test-mode steady state". The autouse
       `reset_to_test_mode` fixture pops anything tests pushed above
       test_mode and clears the transient store between tests.
    4. At session teardown, pop test_mode and close serial.

Tests should not transmit on the public mesh channel; mesh and radio
binding tests cover only state-getters and local state mutators by
default. Network-egress tests (wifi connect, http, net) are gated by the
`network` marker and skipped unless explicitly opted in.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "tools" / "remote"))

from ez_remote import EzRemote  # noqa: E402

DEFAULT_PORT = os.environ.get("EZ_REMOTE_PORT", "/dev/ttyACM0")


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line(
        "markers",
        "network: test performs network egress (wifi/http/net). Opt-in only.",
    )
    config.addinivalue_line(
        "markers",
        "mesh_tx: test transmits on the mesh radio. Opt-in only — never on "
        "the public channel.",
    )


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    """Skip opt-in markers unless their env switch is set."""
    skip_network = pytest.mark.skip(reason="network egress disabled (set EZ_TEST_NETWORK=1)")
    skip_mesh_tx = pytest.mark.skip(reason="mesh tx disabled (set EZ_TEST_MESH_TX=1)")
    for item in items:
        if "network" in item.keywords and not os.environ.get("EZ_TEST_NETWORK"):
            item.add_marker(skip_network)
        if "mesh_tx" in item.keywords and not os.environ.get("EZ_TEST_MESH_TX"):
            item.add_marker(skip_mesh_tx)


def _port_available(port: str) -> bool:
    return os.path.exists(port)


@pytest.fixture(scope="session")
def device() -> EzRemote:
    if not _port_available(DEFAULT_PORT):
        pytest.skip(
            f"No device at {DEFAULT_PORT}. Set EZ_REMOTE_PORT or plug in a T-Deck."
        )
    # Use a generous serial timeout: the default 5 s is fine for individual
    # commands but the rapid-fire test cadence sometimes pushes a busy
    # device (LittleFS GC, mesh RX, etc.) past the cliff. Each command
    # still returns in well under a second when the device is healthy.
    remote = EzRemote(DEFAULT_PORT, timeout=10)
    _wrap_lua_exec_with_retry(remote)

    # Give the ESP32-S3 USB-CDC stack time to settle after port open. Without
    # this, the first command's bytes are sometimes lost and read_response
    # blocks until its 5s timeout — even though pyserial reports the port is
    # open, the device-side endpoint may not yet be polling its OUT buffer.
    time.sleep(0.3)
    remote.ser.reset_input_buffer()
    remote.ser.reset_output_buffer()

    try:
        _ping_with_retry(remote, attempts=4)
    except Exception as exc:
        remote.close()
        pytest.skip(f"Device at {DEFAULT_PORT} did not respond to ping: {exc}")

    _enter_test_mode_with_retry(remote, attempts=3)
    try:
        yield remote
    finally:
        try:
            _exit_test_mode(remote)
        except Exception:
            pass
        remote.close()


def _wrap_lua_exec_with_retry(remote: EzRemote) -> None:
    """Wrap remote.lua_exec so a single transient TimeoutError is retried.

    Mid-suite serial timeouts surface occasionally when the device is
    under heavy load (rapid LittleFS ops, mesh RX, etc.). Real failures
    repro on the retry; flakes don't, so one retry is enough to make
    the suite deterministic without masking actual breakage.
    """
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


def _ping_with_retry(device: EzRemote, attempts: int = 3) -> None:
    """Ping with retry. Each attempt resets the I/O buffers first so a
    stale half-message from the previous attempt can't poison the next."""
    last_exc: Exception | None = None
    for i in range(attempts):
        try:
            if device.ping():
                return
        except Exception as exc:
            last_exc = exc
            # Drain whatever's in the buffer before retrying — a partial
            # response from the timed-out attempt would otherwise look
            # like a fresh framing-byte.
            try:
                device.ser.reset_input_buffer()
            except Exception:
                pass
            time.sleep(0.2 * (i + 1))
    if last_exc:
        raise last_exc
    raise RuntimeError("ping returned False after retries")


# Pop to desktop, clear transient state, push test_mode. Idempotent: callable
# from any stack state. Used both at session start and as a fallback in the
# autouse fixture if a test accidentally popped test_mode.
_ENTER_TEST_MODE_LUA = (
    "local s = require('ezui.screen'); "
    "for _ = 1, 32 do if s.depth() <= 1 then break end s.pop() end "
    "local ok, t = pcall(require, 'ezui.transient'); "
    "if ok and t.reset then t.reset() end "
    "local def = require('screens.test_mode'); "
    "s.push(s.create(def, def.initial_state and def.initial_state() or {})); "
    "return s.depth()"
)


def _enter_test_mode_with_retry(device: EzRemote, attempts: int = 3) -> None:
    last_exc: Exception | None = None
    for _ in range(attempts):
        try:
            depth = device.lua_exec(_ENTER_TEST_MODE_LUA)
            if depth == 2:
                return
            last_exc = RuntimeError(f"unexpected stack depth after enter: {depth}")
        except Exception as exc:
            last_exc = exc
    raise last_exc or RuntimeError("could not enter test mode")


def _exit_test_mode(device: EzRemote) -> None:
    device.lua_exec(
        "local s = require('ezui.screen'); "
        "for _ = 1, 32 do if s.depth() <= 1 then break end s.pop() end "
        "local ok, t = pcall(require, 'ezui.transient'); "
        "if ok and t.reset then t.reset() end"
    )


@pytest.fixture(autouse=True)
def reset_to_test_mode(device: EzRemote):
    """
    Each test starts with the test_mode screen on top (depth 2). Pop
    anything tests pushed above it; if the previous test left depth < 2
    (e.g. it accidentally popped test_mode), re-push it. The transient
    store is cleared too so per-screen state never bleeds between tests.
    """
    _reset(device)
    yield
    _reset(device)


def _reset(device: EzRemote) -> None:
    depth = device.lua_exec(
        "local s = require('ezui.screen'); "
        "for _ = 1, 32 do if s.depth() <= 2 then break end s.pop() end "
        "local ok, t = pcall(require, 'ezui.transient'); "
        "if ok and t.reset then t.reset() end "
        "return s.depth()"
    )
    if depth != 2:
        # test_mode got popped — re-push it.
        device.lua_exec(_ENTER_TEST_MODE_LUA)
