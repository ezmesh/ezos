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
