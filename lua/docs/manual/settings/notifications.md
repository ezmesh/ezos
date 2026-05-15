# Settings -- Notifications

Settings -- Notifications gates how the device alerts you when
events arrive (DMs, channel messages, file transfers, low battery,
OTA progress, etc.). The sub-screen lives at Settings --
Notifications and covers Do Not Disturb only; per-source mute
toggles live in the wiring of the services that post the
notifications.

Changes apply immediately. Each toggle and value persists to NVS,
so picks survive reboots.

## Manual DND now

A single toggle for "shut up right now". When on, every incoming
notification still lands in the unread list (counts and badges
still update), but the toast and the panel-wake are suppressed.
Wins over the schedule -- a manual flip silences the device even
if the clock is currently outside the quiet hours window. Leave
it on as long as you want; nothing un-flips it for you.

## Quiet hours schedule

The schedule toggle gates a time-of-day window during which the
same suppression as Manual DND applies automatically. Two
sliders pick the window in 15-minute steps:

- **Start** -- when the quiet window opens, as HH:MM in the
  device's local time.
- **End** -- when the quiet window closes. If End is earlier
  than Start, the window wraps midnight (e.g. 22:00 -- 07:00
  is the default and means "from 10pm tonight until 7am
  tomorrow").

The default window is 22:00 -- 07:00 and the schedule is off by
default; turn it on once you've picked times that match your day.

## Allow channel mentions

Sub-toggle of the schedule. When on, a channel message that
contains your node name as a mention (the same check the per-channel
notify_mode already runs) is **exempt** from the silencing and
fires its toast/wake as normal during quiet hours. Off by default
-- DMs from starred contacts will be similarly exempt once
favourites land on `services.contacts`.

## Trigger words

A comma-separated list of words that, in addition to your node
name, mark a channel message as a "mention" for the per-channel
notify_mode. Useful when you put a channel on "Mentions only" but
still want to ring through on specific topics -- e.g. a "Lost dog"
alert channel can stay on Mentions only but you set a trigger
word "dog" or "missing" so those messages still wake you.

Matching is case-insensitive substring, so "storm" matches "Big
storm coming in", you don't need to think about word boundaries.
An empty list disables the feature; your node name remains a
trigger either way.

The list is shared across every "Mentions only" channel; it is
not per-channel. Edit it from Settings -- Notifications --
Trigger words.

## Clock-unset fallback

If the device clock is unset (year < 2020 -- typical right after a
cold boot, before NTP or GPS sync lands), DND is treated as off
regardless of the schedule. Without a wall clock there's no
meaningful "are we inside the quiet window" answer; the failure
mode is "let notifications through" so a fresh boot doesn't
silently eat alerts. The manual override is unaffected -- a
hand-flipped DND stays on even without a clock.

## What is NOT silenced

DND only suppresses the toast and the panel wake. Things that
keep happening regardless:

- Notifications still appear in the unread list with `unread_count`
  advancing -- you'll see them when you next open the panel.
- Per-source mute prefs (`notify_dm`, `notify_file`, etc.) still
  apply on top: a muted source is dropped entirely, not deferred.
- Sticky notifications and explicit `action` callbacks remain
  wired up; tapping them on the unread list works as ever.
