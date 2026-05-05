# Settings

Open Settings from the app menu. Each section persists its values
under `ez.storage.set_pref`, so changes survive reboots.

## Display

- Theme: Dark / Light. Affects every screen including the map tiles.
- Backlights: display brightness and keyboard backlight level.
- Accent color: highlight color used for selection, focus, and
  buttons. Independent from the theme.

## Sound

UI sound effects on / off. The audio engine drives both UI sounds
and any in-app audio (games, alerts).

## Keyboard

Trackball sensitivity and key repeat tuning.

## Radio

LoRa channel parameters. The defaults match the public mesh; only
change these if you know what you are doing -- a mismatched config
isolates you from the rest of the network.

- Band: regional preset (EU 869, US 915, AS 433, AU 915). Re-tunes
  the radio immediately. All nodes in your mesh must use the same
  band.
- Protocol: switches the air-protocol profile between MeshCore (the
  default) and Meshtastic. The radio is single-tuner, so this is a
  hard switch -- while Meshtastic is selected the device cannot see
  any MeshCore traffic and auto-advert is paused. Frequency is
  preserved across the switch.
- TX queue spacing: minimum gap between queued transmissions.
  Faster settings (50 ms) are more responsive but heavier on the
  channel; politer settings (200, 400 ms) leave more air-time for
  neighbours. The first-run wizard asks you to pick a value; you
  can change it here later.
- Auto-advert: periodic flood announce so neighbouring nodes can
  discover this one. Disabled by default; pick an interval and
  toggle on. "Send advert now" sends a one-shot announce.

## GPS

Enable / disable the GPS receiver. When off, the location services
do not poll the chip and the chip can sleep.

## Time

Set the system clock. GPS supplies time when a fix is available.

## Wallpaper

Pick a wallpaper from `/fs/wallpapers/`. Use the Files app to set
any JPEG as wallpaper.

## System

Device-level operations.

- Repeat onboarding: re-runs the first-run wizard from the welcome
  screen. The flow over-writes prefs idempotently, so it's safe to
  rerun on an already-onboarded device.
