# Mesh basics

ezOS speaks MeshCore over LoRa. This is a long-range, low-bandwidth
radio protocol designed for off-grid messaging without infrastructure.

## Channels vs DMs

Two kinds of message exist:

- Channel messages are broadcast to anyone tuned to a channel. The
  default `#Public` channel is unencrypted and shared with everyone in
  range. Custom channels use a shared password (AES-128) so only
  members can read them.
- Direct Messages (DMs) are encrypted point-to-point with the
  recipient's public key. Add a contact first; you cannot DM a node
  you have not met.

## Adding a contact

When another node sends an ADVERT in range, it shows up under
Contacts -> Known nodes. Open the entry and pick "Add as contact" to
keep it. The first DM you send to a brand-new contact triggers an
auto-ADVERT so they can answer back.

## Range and coverage

Direct line-of-sight LoRa range is highly variable -- a few hundred
meters indoors, several kilometers outdoors with good antennas.
Repeaters relay packets and extend coverage; check Contacts for any
repeaters within range.
