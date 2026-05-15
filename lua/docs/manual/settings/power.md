# Settings -- Power

A battery-aware policy that backs off non-essential radio, GPS, NTP,
and display activity as the battery drains. Three tiers with
hysteresis so the device doesn't flap at the boundary:

| Battery | Tier      | What changes                                                                          |
|---------|-----------|---------------------------------------------------------------------------------------|
| > 30 %  | Normal    | Default. Everything runs at full cadence.                                             |
| 10 - 30 % | Frugal  | ADVERT period doubled. GPS clock sync paused. NTP cadence stretched.                  |
| < 10 %  | Survival  | ADVERT period quartered. GPS sync and NTP stopped. Non-DM custom packets suppressed. Display brightness clamped to <= 30 %. TX power dropped one notch. |

Hysteresis: Frugal leaves at >= 35 %, Survival leaves at >= 15 %.
Charging is treated as full battery -- the device snaps out of any
backed-off tier as soon as you plug it in.

DM traffic is never gated by Power. Someone in trouble might be on
4 % battery; their DMs go through.

## Manual overrides

Two toggles let the user pin a tier:

- **Always Normal** -- pin the device to Normal regardless of
  battery. Useful when sat on a powered desk and Frugal kicking in
  at 30 % is more annoying than helpful.
- **Force Survival now** -- pin the device to Survival regardless of
  battery. Useful when "I need this to last another four hours."

The two are mutually exclusive: turning one on turns the other off.

## Surfacing

- The status bar gains a small "lp" tag in Frugal and "LP" in
  Survival, just left of the battery glyph.
- The first entry into Frugal or Survival posts a one-shot
  notification so the user isn't surprised by missed traffic.

## What is NOT changed

- DM TXT_MSG traffic flows at full cadence in every tier.
- WiFi state is not touched (use Settings -- WiFi to power-cycle).
- The screensaver / idle ladder is unaffected by the tier; pick a
  short `ss_timeout` in Settings -- Display if you want it tighter.

## Limitations

- Threshold customization (override which percentage enters which
  tier) is not yet exposed in the UI. Defaults are baked in.
- NTP frugal-mode interval is the default lwIP SNTP cadence; the
  service can stop NTP but cannot reach into lwIP to slow it down.
  Survival still stops NTP cleanly.
