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

## Firmware

Pull the latest rolling-main build from GitHub and install it over
the air.

The screen shows the SHA of the running build and the SHA of the
build currently published as the rolling-main release. WiFi must
be connected; the device fetches a small manifest plus its
detached Ed25519 signature, verifies the signature against a
public key baked into the firmware, then -- and only then -- uses
the URL and SHA-256 from the manifest to install.

Trust is rooted in the signature, not in TLS. A swapped or
corrupted asset is rejected on two grounds: the manifest signature
fails, or the SHA-256 computed while writing the firmware does
not match the manifest's claim.

- "Install update" downloads the firmware straight into the
  inactive OTA partition and stages it. Progress shows the bytes
  written so far.
- "Reboot now" appears once the install finishes (or if a previous
  install is already staged). The device boots into the new image
  and confirms it's healthy after the UI comes up.

Devices flashed before the project's signing key was configured
display "OTA signing not configured on this device" and refuse to
install. The fix is to flash a firmware whose embedded public key
matches the one CI signs releases with.
