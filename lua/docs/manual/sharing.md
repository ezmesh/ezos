# Sharing

Chat bubbles can carry "share cards" that wrap small pieces of
structured data: a contact's pubkey, a channel invite, a clock reading,
or an event/meetup announcement. They all use a fragment-only
`https://ezme.sh/#...` URL so a peer who doesn't run ezOS sees a normal
clickable link, while ezOS receivers parse the fragment locally.

## Cards you can send

Open Alt+M in a chat (DM or channel) to see the Attach options:

- **Share a contact** -- pick one of your contacts. The receiver gets
  an "Add to contacts" card. Plaintext, since pubkeys are public.
- **Invite to a channel** -- pick one of your password-protected
  channels. The receiver gets a "Join channel" card. The invite is
  encrypted to the recipient's identity, so only they can open it.
- **Share time** -- one tap. Receiver gets a "Sync clock" card with
  the round-trip delay applied for accuracy.
- **Attach event** -- fill in title, date (UTC), time (UTC), duration
  in minutes, and optionally tick "Attach my GPS location". Receiver
  gets an EVENT card with options to add a reminder or jump to the
  spot on the map.

## Receiving an event

When an event card arrives, tap (or focus + Enter) the bubble to open
the actions menu:

- **Add to reminders** -- the device will pop a notification 10
  minutes before the start time and another one when it starts.
  Reminders persist across reboots and survive flashing.
- **Show on map** -- only shown when the sender attached coordinates.
  Opens the default map archive centred on the event location.

Past events are read-only; the card grays out and "Add to reminders"
becomes "Event has started/ended".

## URL formats

Receivers parse any of these out of bubble text:

```
https://ezme.sh/#add/v1?k=<64-hex pubkey>&n=<name>
https://ezme.sh/#join/v1?t=<base64url token>
https://ezme.sh/#time/v1?t=<unix>
https://ezme.sh/#cal/v1?ts=<unix>&dur=<secs>&n=<title>[&lat=<e6>&lon=<e6>]
```

For `cal/v1`, durations are capped at 24 hours and timestamps must be
within a year of "now"; out-of-range values are silently dropped on
parse to keep stale or malformed cards from polluting the reminder
queue. Titles are restricted to printable ASCII (the on-device bitmap
fonts only cover that range).
