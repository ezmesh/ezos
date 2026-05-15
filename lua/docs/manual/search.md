# Search

Cross-cutting Search hunts contacts, channels, DM history, channel
history, and settings panels for a substring of the query. Open it
from More -> Tools -> Search.

## Using it

The screen lands you in the input field, so you can start typing
immediately. Results begin to appear once you've entered two or more
characters; the screen waits ~150 ms after your last keystroke before
running so each character doesn't kick off a fresh scan.

Matches group by source:

- Contacts -- name or first 12 hex chars of the pubkey.
- Channels -- channel name.
- Messages (DM) -- any DM text from any conversation.
- Messages (channel) -- any channel-history text from any joined
  channel.
- Settings -- panel title plus a short keyword list (so "brightness"
  still finds Display).

Each group caps at 10 rows; a "More..." row indicates a busy query
that should be narrowed.

## Navigating results

Tap a row (or move focus + Enter) to jump to the matching screen:

- A Contact opens the DM conversation.
- A Channel opens its chat history.
- A DM-message row opens the DM conversation with the right contact.
- A Channel-message row opens the channel chat.
- A Settings row opens the panel directly.

## Going back

Press Backspace once with the query empty (or tap the back-arrow in
the title bar) to leave the screen. While the query is non-empty,
Backspace deletes one character at a time -- the standard text-input
behaviour.

## Limits

The match is case-insensitive substring, byte-for-byte. There is no
fuzzy matching, no regex, and no persistent index -- every search
runs against live in-memory data, so the result reflects what the
device has *right now*. Strings rendered in results are ASCII-only;
non-ASCII bytes from peer mesh data are substituted with `?` to stay
within the on-device font.
