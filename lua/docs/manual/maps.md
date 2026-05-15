# Maps

The Map app shows offline tiles from `.tdmap` archives stored on the
SD card. There is no online tile fetch -- all data is on disk.

## Loading an archive

Open Map. The loader screen lists every `.tdmap` file under
`/sd/maps/`. Press Enter on a file to open it; press M for actions:

- Open: load the archive immediately.
- Set as default: skip the picker on subsequent opens.
- Clear default: show the picker again next time.

If the loader shows "No .tdmap archives found", insert an SD card or
copy archives in via the Files app.

## Generating archives

`tools/maps/make_map.py` on a host machine converts an OpenStreetMap
PBF into the on-device `.tdmap` format. The pipeline is one command,
and the source PBF is auto-downloaded from Geofabrik on first run:

    python make_map.py monaco                  # tiny -- ~1s end-to-end
    python make_map.py netherlands             # auto-fetches PBF (~500 MB)
    python make_map.py custom local.osm.pbf --bounds 4.7,52.3,5.0,52.5 --zoom 12,14

See `tools/maps/regions.py` to add a new region preset. Each archive
is keyed by filename, so a per-region "last view" pref is saved per
archive -- switching does not strand you outside the new bounds.

## Themes and feature colors

Archives store vector geometry tagged by semantic feature (Land,
Water, Park, Building, road classes, Railway). The renderer maps
those tags to colors via the active ezui theme (Settings -> Display
-> Dark mode). Switching themes repaints in the same frame -- no
archive reload required.

Because rendering is vector-based (no raster tiles), the same archive
covers every zoom level at full fidelity. There is no per-zoom
duplication of data, and the renderer interpolates smoothly between
zoom levels.

## Layers

A `.tdmap` archive includes every feature the generator extracted
from the source. Buildings only render at zoom 13 and above; minor
roads only at zoom 12 and above. To produce an archive with a
different layer mix, edit the extraction predicates in
`tools/maps/make_map.py` and re-run.

## Broadcast home location

Other nodes can see a coarse location for your device on their own
maps and in the Network screen, but only if you tell ezOS what point
to publish. There is no live GPS broadcast and no automatic update --
the value is a deliberate "approximately me" coordinate that you
author once.

To set it: open Map, pan with the trackball / arrow keys so the
centre of the screen sits on the point you want to publish, then
press Alt+M and pick "Set as broadcast home". Alt+M -> "Clear
broadcast home" removes it.

What gets broadcast:

- The exact coordinate you chose, every time your device sends an
  ADVERT. No randomization, no fuzz radius, no live updates from GPS.
- The location bit is added to the ADVERT app_data (MeshCore
  protocol). Anyone receiving your ADVERT sees this coordinate in
  cleartext.

Privacy guidance:

- Pick a point that is **deliberately approximate**. Your town
  centre, a nearby park, or any landmark a few hundred metres from
  where you actually are. Not your home, not your office.
- The broadcast home only controls what you **announce**. A
  determined adversary with multiple LoRa receivers can still
  triangulate your real transmitter position from signal strength
  regardless of what this field says.
- For sharing your precise current location with a specific contact,
  use a share-location card from the chat compose menu instead --
  that goes encrypted, point-to-point, and is opt-in per recipient.

The setting persists across reboots. There is no on-map indicator of
the current broadcast home (yet); re-set it the same way to change
it.
