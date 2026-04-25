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

`tools/maps/pmtiles_to_tdmap.py` on a host machine converts
OpenStreetMap PMTiles into the on-device `.tdmap` format. See
`tools/maps/` for the conversion pipeline. Each archive is keyed by
filename, so a per-region `last view` pref is saved per archive --
switching does not strand you outside the new bounds.

## Themes and tile colors

Tiles store semantic indices (Land, Water, Park, Building, road
classes, Railway). The renderer maps those to colors via the active
ezui theme (Settings -> Display -> Dark mode). Switching themes
repaints tiles in the same frame -- no archive reload required.

## Layers

A `.tdmap` archive bakes one rasterization. To show a different layer
mix (e.g. without buildings), generate a new archive with a different
config and pick it from the loader.
