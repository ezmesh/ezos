# Offline Maps Guide

ezOS supports offline OpenStreetMap tiles in the custom TDMAP format, optimized for the ESP32's limited memory and the 320x240 display.

## Quick Start

1. Download a PMTiles file for your region from [Protomaps](https://protomaps.com/downloads/protomaps) or generate one with [tilemaker](https://tilemaker.org/)
2. Convert to TDMAP format using the included tool
3. Copy to SD card as `/sd/maps/world.tdmap`
4. Open Map from the main menu

## Converting Maps

### Requirements

```bash
cd tools/maps
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Basic Conversion

```bash
python pmtiles_to_tdmap.py input.pmtiles -o output.tdmap
```

### Regional Extract

```bash
# Convert only a specific area (west,south,east,north bounds)
python pmtiles_to_tdmap.py input.pmtiles \
    --bounds 4.0,51.5,7.5,53.5 \
    --zoom 6,14 \
    -o netherlands.tdmap
```

### Options

| Option | Description |
|--------|-------------|
| `-o, --output FILE` | Output file path (default: input name with .tdmap) |
| `-b, --bounds W,S,E,N` | Geographic bounds to extract |
| `-z, --zoom MIN,MAX` | Zoom range (default: from PMTiles metadata) |
| `-j, --workers N` | Parallel workers (default: CPU count) |
| `-n, --dry-run` | Estimate tile count without processing |
| `--no-resume` | Don't resume from checkpoint, start fresh |

### Resume Support

Conversions automatically checkpoint every 500 tiles. If interrupted, run the same command again to resume:

```bash
# If interrupted with Ctrl+C, just run again:
python pmtiles_to_tdmap.py input.pmtiles -o output.tdmap
# Resumes from last checkpoint
```

## TDMAP Format

The TDMAP format is optimized for ESP32:

- **3-bit indexed pixels** - 8 semantic feature types (land, water, roads, etc.)
- **RLE compression** - Typically 5-20x compression ratio
- **Binary search index** - Fast tile lookup by zoom/x/y
- **Geographic labels** - City/town names with lat/lon coordinates

### Feature Types

| Index | Feature | Light Theme | Dark Theme |
|-------|---------|-------------|------------|
| 0 | Land | White | Dark blue-gray |
| 1 | Water | Light blue | Dark blue |
| 2 | Park/Forest | Light green | Dark green |
| 3 | Building | Light gray | Medium dark |
| 4 | Minor Road | Medium gray | Medium gray |
| 5 | Major Road | Dark gray | Lighter gray |
| 6 | Highway | Darker gray | Light gray |
| 7 | Railway | Near black | Medium |

## Generating PMTiles

### Using Tilemaker

[Tilemaker](https://tilemaker.org/) converts OpenStreetMap PBF files to PMTiles:

```bash
# Download OSM data
wget https://download.geofabrik.de/europe/netherlands-latest.osm.pbf

# Convert to PMTiles (requires tilemaker installed)
tilemaker --input netherlands-latest.osm.pbf \
          --output netherlands.pmtiles \
          --config config.json \
          --process process.lua
```

A sample tilemaker configuration is provided in `tools/maps/tilemaker.sh`.

### Pre-made PMTiles

Download regional extracts from:
- [Protomaps Downloads](https://protomaps.com/downloads/protomaps)
- [OpenMapTiles](https://openmaptiles.org/)

## Storage Requirements

| Region | Zoom Range | Approximate Size |
|--------|------------|------------------|
| City (50km) | 10-14 | 10-50 MB |
| Country (NL) | 6-14 | 200-500 MB |
| Continent | 4-12 | 1-5 GB |

## Viewing Maps

### On Device

1. Copy `.tdmap` file to SD card as `/sd/maps/world.tdmap`
2. Insert SD card into T-Deck
3. Open **Map** from main menu
4. Use trackball to pan, +/- keys to zoom

### Preview Tool

A browser-based viewer is included for testing:

```bash
cd tools/maps
python -m http.server 8000
# Open http://localhost:8000/viewer.html
```

## Troubleshooting

### "Map file not found"

- Ensure file is named `world.tdmap` in `/sd/maps/` directory
- Check SD card is properly inserted and formatted (FAT32)

### Labels not showing

- Labels require zoom level 4+ for cities, 7+ for villages
- Toggle labels with the menu option

### Slow loading

- Use regional extracts instead of world maps
- Limit zoom range to 6-12 for faster loading
- Maps are loaded on-demand; first pan may be slower

### Conversion errors

- Ensure PMTiles file is valid vector tiles (not raster)
- Check available disk space for output file
- Try with `--workers 1` if seeing memory issues
