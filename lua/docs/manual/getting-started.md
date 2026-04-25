# Getting started

ezOS boots straight to the desktop. Four shortcuts cover the most
common tasks: Messages, Contacts, Map, and More (the full app menu).

## First boot

On first boot the device generates a fresh Ed25519 identity and joins
the public mesh channel automatically.

A short onboarding wizard walks you through the must-set fields:

1. **Welcome** -- a one-screen recap of what the device does.
2. **Node name** -- how this device shows up on the mesh. Letters,
   digits, and basic punctuation; ASCII only (32 characters max).
3. **Region** -- the LoRa band that's legal in your country
   (EU 869 / US 915 / AS 433 / AU 915). All nodes in your mesh must be
   on the same band.
4. **Timezone** -- the wall-clock region the status-bar clock uses.
5. **Theme** -- dark or light, plus an accent colour.

After step 5 the device is "onboarded" and every later boot lands
straight on the desktop. Two optional screens follow before the
desktop appears: an optional callsign for chat headers, and a readout
of your public identity (short ID + hex public key) you can share
with another node. Both can be skipped.

To re-run the wizard later, open `Settings > System > Repeat
onboarding`.

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
