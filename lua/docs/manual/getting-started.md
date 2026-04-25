# Getting started

ezOS boots straight to the desktop. Four shortcuts cover the most
common tasks: Messages, Contacts, Map, and More (the full app menu).

## First boot

On first boot the device generates a fresh Ed25519 identity and joins
the public mesh channel automatically. No setup is required to send
or receive messages on the public channel.

If `!RF` shows in the status bar, the LoRa radio failed to initialize.
Check the wiring and reboot. Until that clears, mesh features are
unavailable.

## Status bar

The status bar at the top shows, left to right:

- The first three hex digits of your node ID
- The active screen title
- Mesh signal strength
- Battery level
- The current time (set in Settings if it looks wrong)

## Powering off

Hold the power button for one second. The device resumes where you
left off when you turn it back on.
