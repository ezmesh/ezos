# Settings -- Lockscreen

A session lock that sits between the screensaver and the desktop.
While the device is locked, the keyboard, trackball, and touch are
intercepted by an unlock prompt; nothing under the prompt receives
input.

## Modes

- **Off** (default). No lockscreen. The screensaver may still kick
  in but the device wakes straight to the desktop.
- **PIN**. 4-8 digit numeric. Easier to type on the T-Deck QWERTY
  -- digits are entered as `alt + Q W E R T Y U I O P` (= 1 2 3 4
  5 6 7 8 9 0).
- **Passphrase**. Any ASCII string. Use if you want a stronger
  secret than four digits, or to match the at-rest identity wrap
  (Settings -- Security).

## What gets locked

When the lockscreen mode is anything other than Off, the lockscreen
overlay is pushed on top of the screen stack:

- On every boot.
- After the screensaver activates (the unlock prompt sits behind
  the screensaver overlay; a wake-tap dismisses the screensaver but
  lands you in the prompt, not on the desktop).
- Immediately on **Alt + L** from any screen.

There is no other exit path. BACKSPACE / ESCAPE on the unlock
screen are swallowed.

## Failure backoff

Wrong attempts increment a persistent counter (`lock_fail_n`) and
push a cooldown deadline (`lock_until_ms`) according to this
schedule: 1 s, 2 s, 4 s, 8 s, 16 s, 32 s, 60 s. The cooldown
deadline is in millis-since-boot; rebooting resets the timer (you
can retry immediately) but the count is preserved, so a power-
cycle attack just removes the wait, not the throttle.

A successful unlock clears both the count and the deadline.

## What is NOT covered

- "Wipe on too many fails" is not implemented in v1.
- The lockscreen does not encrypt anything at rest; the on-disk
  data is unchanged. Combine with Settings -- Security to wrap the
  identity key for at-rest protection.
- Notifications still post and toast as usual under the lock; only
  the input path is gated.

## Trust model

The lockscreen secret is hashed with PBKDF2-SHA256 (50 000
iterations) and a 16-byte random per-device salt before storage.
The plaintext PIN / passphrase is never persisted.

The hash is stored in NVS, which is readable by anyone with USB or
reflash access. The lock protects against an attacker who picks up
the device and tries it; it does not protect against an attacker
who can extract NVS and grind the salt-and-hash on a faster
machine. For an unattended-device threat model, pair this with the
at-rest identity wrap.
