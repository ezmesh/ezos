# Input lock

The input lock blocks the keyboard and the touchscreen so a T-Deck
stowed in a pocket or bag can't fire random keypresses or stray
touches. Mesh, GPS, and other background services keep running --
this is purely an input gate, not a sleep or standby mode.

## Chord

- **Shift + Alt + L** -- lock.
- **Shift + Alt + U** -- unlock.

Both chords work from any screen. The two physical Shift keys are
equivalent; press whichever is comfortable for the thumb that isn't
holding Alt.

## While locked

- Every keystroke other than the unlock chord is swallowed. No
  screens see them.
- Every touch and trackball motion is swallowed.
- A black banner pinned to the bottom of the screen reads
  `Locked -- Shift+Alt+U to unlock`, so the chord is always visible.
- The screensaver still works. If the device dims out while locked,
  the unlock chord both wakes the screen and clears the lock in a
  single press.

## What does keep running

The lock is an input filter only. Behind the banner:

- The mesh stack still receives, decrypts, and ACKs DMs.
- GPS keeps logging if it was already on.
- Notifications still arrive (you'll see toasts when you unlock).
- File transfers, OTA downloads, and scheduled tasks proceed as
  normal.

## When it resets

The lock state is **in-memory only**. On every boot the device
starts unlocked, by design -- a regression in the chord path would
otherwise have the potential to soft-brick the device permanently.
If you ever find yourself stuck locked, a power cycle is the
unconditional escape hatch.
