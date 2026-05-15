# Settings -- Privacy

Settings -- Privacy gates the signals the device sends to other nodes
about the user's behaviour. v1 covers a single toggle: DM read
receipts.

Changes apply immediately. Each pref persists to NVS, so picks
survive reboots.

## Send DM read receipts

Default off. When on, opening a DM conversation tells the sender that
their message was read -- the receiver emits a short `ack/v1` share
URL through the same DM crypto / flood path the message rode in on.
The sender's chat bubble flips its accent ring to "read" when the
receipt lands.

The ack ride-along has no visible cost on the receiver's side -- no
outgoing chat bubble is created and no extra unread counter advances.
The radio cost is one TXT_MSG per unique inbound message hash that
hasn't been receipted before. The "already receipted" flag is
persisted, so a reboot doesn't re-flood the channel with one ack per
historical message on the next "mark read" tick.

Why default off: read receipts are privacy-sensitive. Some people
don't want their reading habits broadcast, and the airtime cost on
LoRa is non-zero. Per-contact overrides aren't here yet -- they
would naturally live on the contact's detail screen alongside the
notification mute toggle.

## Delivery acks

DMs already use MeshCore's protocol-level ACK to confirm delivery --
that path is always on and isn't user-tunable. The status dot on
your sent bubble flips to green once the ACK lands. Delivery acks
are independent of the read-receipt feature above: a delivered
message that the recipient never opens shows green but never paints
the "read" ring.
