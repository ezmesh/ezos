# Settings

Open Settings from the app menu. Each section persists its values
under `ez.storage.set_pref`, so changes survive reboots.

## Identity

How this device shows up on the mesh.

- Short ID and public key (read-only).
- Node name: free text, max 32 ASCII chars. Press ENTER inside the
  field to save.
- Callsign: optional free text, max 16 ASCII chars. Press ENTER to
  save; clear the field and ENTER to remove.
- Regenerate identity: generates a fresh Ed25519 keypair and replaces
  the one in NVS. Two-step confirm, since peers will see a different
  short ID and DMs encrypted to the old key stop decrypting.

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

- Region: pick the legal LoRa band (EU 869 / US 915 / AS 433 /
  AU 915). Re-tunes the radio immediately and persists across
  reboots. All nodes in your mesh must use the same band.
- Auto-advert: periodic flood announce so neighbours discover you
  automatically. Off by default; pick an interval if you want it on.
- Manual: one-shot "Send advert now" for an immediate announce.

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
