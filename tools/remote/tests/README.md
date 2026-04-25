# On-device ezOS tests

Pytest harness that drives a real T-Deck over USB via `tools/remote/ez_remote.py`.

## Requirements

- T-Deck Plus running ezOS firmware, plugged in via USB
- Default port: `/dev/ttyACM0` (override with `EZ_REMOTE_PORT`)
- Python deps from `tools/remote/requirements.txt`, plus `pytest`

When no device is present, every test is skipped — so the suite is safe to
run unconditionally.

## Running

```bash
cd tools/remote/tests
pip install pytest
pytest                       # all tests, default port
EZ_REMOTE_PORT=/dev/ttyACM1 pytest
pytest test_smoke.py -v      # one file, verbose
```

## Layout

| File | Coverage |
|------|----------|
| `conftest.py` | Session-scoped device fixture; pops back to root between tests |
| `test_smoke.py` | Ping, Lua exec, ez namespace, memory baseline |
| `test_screens.py` | Push/pop known screens, verify titles and stack depth |
| `test_services.py` | Local probes for channels, contacts, direct messages |

## Adding tests

- New tests should reuse the `device` fixture and avoid public mesh sends.
- Long-running probes belong behind their own pytest mark so the smoke suite
  stays fast.
- The `reset_to_home` autouse fixture guarantees each test starts at the
  desktop. If a test pushes nested screens, no manual cleanup is needed.
