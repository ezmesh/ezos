# Settings

Open Settings from the app menu. Each section persists its values
under `ez.storage.set_pref`, so changes survive reboots.

## Display

- Theme: Dark / Light. Affects every screen including the map tiles.
- Backlights: display brightness and keyboard backlight level.
- Accent color: highlight color used for selection, focus, and
  buttons. Independent from the theme.
- Wallpaper: pick from the bundled set, or set any JPEG via the
  Files app's "Set as wallpaper" action. The "Rotate" dropdown
  controls when the wallpaper changes: Off, On boot, or Every time
  the desktop is shown.
- Screensaver: pick a timeout (Off / 1 min / 2 min / 5 min /
  10 min / 30 min). After that long without input the device draws
  an animated pixel-exerciser overlay on top of the current screen,
  dismissed by any keypress. Setting the timeout to Off disables
  the dim and panel-off stages below too.
- Auto-dim: on by default. About 30 s before the screensaver fires
  the LCD steps down to the "Screensaver brightness" level below,
  as a heads-up that the screen is about to blank. Turn off if you
  want the display to stay at full brightness right up to the
  screensaver edge. Skipped automatically when the screensaver
  timeout is shorter than the pre-dim lead so the dim never lands
  on top of the screensaver itself.
- Screensaver brightness: 10-100 %, default 30. The level both the
  auto-dim stage and the screensaver overlay clamp the LCD to.
  Lower values save more power; pick the lowest value that's still
  comfortable to glance at in your usual lighting.
- Turn off screen after: Never / 1 / 2 / 5 / 15 / 30 min, default
  5. How long after the screensaver fires the device takes the
  next step: backlight to 0 and the render loop suspended until
  input arrives or a notification posts. Any key, touch, or
  incoming high-priority notification (DM, file transfer, low
  battery, OTA available) restores the screen. Set to Never to
  keep the screensaver running indefinitely without ever blanking
  the panel.

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
  200 ms is the default and works well in most meshes; 400 or 800 ms
  leave more air-time for neighbours in busy channels. The first-run
  wizard asks you to pick a value; you can change it here later.
- Auto-advert: periodic flood announce so neighbouring nodes can
  discover this one. Disabled by default; pick an interval and
  toggle on. "Send advert now" sends a one-shot announce.

## GPS

Enable / disable the GPS receiver. When off, the location services
do not poll the chip and the chip can sleep.

### Track recording

Controls the sampling rule the track recorder uses. The recorder
itself is started and stopped from the Map screen (Alt+M -> Record
track / Stop track); this panel only decides when a new point is
written to the `.eztrack` file.

- Min interval: minimum seconds between recorded points. Choices:
  1, 2, 5 (default), 10, 30 seconds.
- Min distance: minimum metres from the previous recorded point.
  Choices: Off, 2, 5 (default), 10, 25 metres.

A point is recorded only when BOTH thresholds clear. Tighter rules
grow the file faster; looser rules can lose corners on a winding
track.

## Time

Set the system clock. GPS supplies time when a fix is available.

## System

Device-level operations.

- Repeat onboarding: re-runs the first-run wizard from the welcome
  screen. The flow over-writes prefs idempotently, so it's safe to
  rerun on an already-onboarded device.

## Security

Encrypts the Ed25519 identity private key at rest behind a user
passphrase. By default the key is stored in plaintext NVS and anyone
with USB / serial access can read it. Enabling encryption wraps the
private key with PBKDF2-SHA256 + AES-256-GCM keyed off your
passphrase; the wrapped blob is asked for at every subsequent boot.

There is no recovery if you forget the passphrase. See the dedicated
Security page (Settings -- Security on the device, or
`settings/security.md` in the manual) for the full set / change /
remove ceremonies and the trust model notes.

## Firmware

Pull the latest rolling build from GitHub and install it over the
air.

A channel dropdown at the top picks which release to track:

- `main`: the production rolling release. Cut from `main` after
  every merged PR. This is the default and what most users want.
- `test`: the staging rolling release, cut from the `test` branch.
  May be less stable -- it's where new features land for shake-out
  before they get promoted to `main`. Useful if you want to try
  upcoming changes.

Both channels are signed by the same key, so a swapped manifest is
detected by the signature check below. The device also refuses any
manifest whose embedded `tag` does not match the channel you asked
for, so a channel swap can't slip past even with a valid signature.

The screen shows the SHA of the running build and the SHA of the
build currently published on the chosen channel. WiFi must be
connected; the device fetches a small manifest plus its detached
Ed25519 signature, verifies the signature against a public key
baked into the firmware, then -- and only then -- uses the URL and
SHA-256 from the manifest to install.

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

If the manifest's build timestamp is older than the running
firmware's, the screen shows a yellow downgrade warning and the
button changes to "Install (downgrade)". Tapping it pops a
confirmation dialog before the install actually starts. This is
the rollback-attack guard: a signature-only trust model is
otherwise vulnerable to an attacker replaying any older,
legitimately-signed manifest. Downgrades are still allowed --
useful when a freshly-rolled main breaks something -- but only
through the explicit two-step gate.

Devices flashed before the project's signing key was configured
display "OTA signing not configured on this device" and refuse to
install. The fix is to flash a firmware whose embedded public key
matches the one CI signs releases with.

## What's New

A scrollable changelog of the firmware running on the device, plus
(when an update is staged from the Firmware screen) the new entries
from the rolling release waiting to be installed. The list is fed
from `lua/docs/changelog.json`, which the release pipeline
generates from commit messages. Each entry shows the version,
date, scope, description, and short commit hash.
