# Voice notes

Voice notes records short audio clips from the onboard microphone and
stores them as WAV files on the SD card under `/sd/recordings/`. The
T-Deck Plus has a MEMS microphone routed through an ES7210 codec --
recording requires an SD card and a populated mic.

## Recording

Open Apps -> Voice notes, or press the dedicated **MIC side key** from
anywhere to open the screen. Once it is on top, the MIC key toggles
recording on/off. The same toggle works with **alt+R** on the keyboard.

While a clip is being captured the screen shows "Recording... N s" in
red. Press MIC again to stop and save. A safety cap stops the
recording at five minutes if you forget.

Each clip is named with the current wall-clock time, so newest
recordings sort to the top. If the clock has not been set (no NTP
sync, no RTC) the name falls back to `note_boot_<millis>.wav`.

## Playing back

Press Enter on a clip in the list to play it through the speaker.
Press M to open the actions menu:

- Play: play the clip.
- Delete: remove it from the SD card.

Recordings are mono 16-bit PCM at 16 kHz. Playback uses the same WAV
decoder as the Audio app, so any 16-bit PCM WAV under
`/sd/recordings/` will work.

## If recording fails

- "No microphone": the codec did not acknowledge on the I2C bus.
  Either the board has no mic populated or the codec is wedged --
  reboot the device.
- "Empty clip": the recording stopped immediately with zero bytes
  written. Usually means the I2S RX path could not bring up the
  codec. Check the System Log under Diagnostics.

## Disk space

A one-minute clip at 16 kHz / 16-bit mono is roughly 1.9 MB. Delete
old recordings from the list (M -> Delete) or via the Files app under
the `/sd/recordings/` folder.
