# Settings -- Map

Settings -- Map controls which peers the offline map screen draws
on top of the tile data. The sub-screen lives at Settings -- Map.

Changes apply on back-out -- no service restart, no map reload.
Each toggle persists to NVS, so picks survive reboots.

## Show on map

Three independent toggles pick which peer categories appear as pins:

- **Repeaters and room servers** (default on). Infrastructure peers
  with a known location. These are usually the most useful pins to
  keep on -- they show coverage and route hops at a glance.
- **My contacts** (default on). Chat nodes you have added as
  contacts. Off if you would rather not see them on the map even
  though you have their key.
- **All chat nodes** (default off). Every chat node we have ever
  heard from with a location. Off by default to keep the map
  uncluttered -- on a busy mesh this can be dozens of pins, most
  of which you don't have a relationship with. Turn it on when
  you want a full view of who's around.

A node only renders when its ADVERT carried a location. Nodes
without a location are never drawn regardless of the toggles.

## Staleness

- **Show stale peers** (default off). Peers last heard 1 to 7 days
  ago render dimmer than fresh peers. Peers older than 7 days are
  always hidden regardless of this toggle. Fresh peers (under 24
  hours) always render at full color.

The dimmed style uses the muted-text ink from the active theme,
so stale peers stay legible without competing with fresh ones for
attention.

## Why so many toggles

The peer set on a busy mesh can swamp the map. Splitting the
controls lets you keep the high-signal pins (repeaters, your
contacts) on while suppressing the noisy categories (every node
that ever advertised). The defaults match the most common ask:
infrastructure plus people you know, nothing else.
