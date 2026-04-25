# Dual-device end-to-end tests

These tests drive **two** T-Decks at once over USB. They cover the
behaviours that single-device unit tests can't: a packet leaves device A
and arrives at device B, A's announce shows up in B's node list, an
encrypted DM round-trips, and so on.

## Requirements

- Two T-Deck Plus devices running the same ezOS firmware, both plugged
  in via USB.
- Both devices on the same LoRa frequency, bandwidth, spreading factor,
  and sync word (default mesh config).
- Default ports: `/dev/ttyACM0` and `/dev/ttyACM1`. Override with the
  `EZ_TEST_DEVICE_A` / `EZ_TEST_DEVICE_B` env vars.

When either port is missing or unresponsive, every test is skipped — so
running `pytest` on a one-device setup won't fail.

## Running

```bash
cd tools/remote/tests/e2e
pytest                        # all tests with default ports
pytest -k mesh                # subset
EZ_TEST_DEVICE_B=/dev/ttyACM2 pytest
```

## What's tested

| File | Coverage |
|------|----------|
| `test_radio.py`   | Raw LoRa send from A, verify B's RX counter advances |
| `test_mesh.py`    | Announce visibility, packet capture, send/receive round trips |

## Conventions

- Tests must use addressed channels or DM, not the public `#Public`
  channel — the antenna is on a real airwave shared with other users.
- Each test starts with both devices in `test_mode` (the same screen
  the single-device suite uses); the autouse fixture pops back to it
  between tests so a leaked screen on either side doesn't bleed.
- Tests that wait on radio propagation should be marked `@pytest.mark.slow`
  and use generous timeouts — LoRa airtime + mesh routing can take
  seconds even between adjacent devices.
