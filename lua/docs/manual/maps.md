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

`tools/maps/make_map.py` on a host machine converts a regional
PMTiles into the on-device `.tdmap` format. The pipeline is one
command per region preset:

    cd tools/maps
    pip install -r requirements.txt
    ./planetiler.sh netherlands 14   # one-time, ~10 min, needs Docker
    python make_map.py netherlands   # converts to netherlands.tdmap

For a custom area, pass any PMTiles + bounds:

    python make_map.py custom local.pmtiles \
        --bounds 4.7,52.3,5.05,52.45 --zoom 11,14 -o ams.tdmap

See `tools/maps/regions.py` to add a new region preset. Each archive
is keyed by filename, so a per-region "last view" pref is saved per
archive -- switching does not strand you outside the new bounds.

## Themes and tile colors

Tiles store semantic indices (Land, Water, Park, Building, road
classes, Railway). The renderer maps those to colors via the active
ezui theme (Settings -> Display -> Dark mode). Switching themes
repaints tiles in the same frame -- no archive reload required.

## Layers

A `.tdmap` archive bakes one rasterization. To show a different layer
mix (e.g. without buildings), generate a new archive with a different
config and pick it from the loader.

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

## Recording a route

The Map screen can record your movement to a track file on SD. Open
Map, press Alt+M, and pick "Start recording route" -- the status strip
at the bottom of the map adds a `REC` badge while a session is active,
and the live polyline appears in the accent colour as you move.

A point is captured only when both the time and distance thresholds
pass (defaults: 5 s and 5 m). Tune them in Settings -> GPS -> Track
recording. Losing the GPS fix pauses the session implicitly; the next
valid fix starts a new segment, with no interpolation across the gap.

Stop the session via Alt+M -> "Stop recording route". Tracks land in
`/sd/tracks/<unix>-<label>.eztrack`. Open one again from Alt+M ->
"Open saved track..." -- the viewer lists every track newest-first and
offers Open / Stats / Delete actions behind Alt+M.

Nothing is transmitted automatically. The recorder respects the GPS
power toggle, so disabling GPS mid-session simply stops sampling.

## Sharing a one-off location

Two share paths exist alongside the broadcast home. Both ride inside
chat as a normal-looking link bubble, so a non-ezOS receiver still
sees a clickable URL.

From the Map screen (Alt+M):

- **Share this point -> DM...** pans the map crosshair to wherever you
  want and sends that coordinate to a contact you pick. The URL is
  encrypted to that contact only -- anyone else who picks up the
  message sees opaque ciphertext.
- **Share this point -> Channel...** posts the crosshair to a channel
  you pick. Channel posts are cleartext to every member of that
  channel; choose this path knowing every member can see the point.

From a chat screen (Alt+M):

- **Share my location** uses your current GPS fix when available, or
  your broadcast-home point as a fallback. DM conversations get the
  encrypted variant; channel conversations get the plaintext variant.

On the receiving side, tapping the LOCATION card opens a context menu
with "Show on map" (opens the Map app centered on the point at zoom 14)
and "Copy coordinates" (shows the lat,lon in a confirmation dialog so
you can read them off). Encrypted shares from contacts you don't share
a secret with (e.g. unknown sender, or your identity was rotated)
render as "Location share (cannot open)" rather than failing silently.

The receive notification toast for an inbound location share is on by
default. Silence it by setting the `notify_gps` pref to `0` from the
terminal -- a Settings entry is planned but not built yet.
