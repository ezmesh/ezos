#!/usr/bin/env bash
# Wrapper: generate PMTiles from OSM data with Planetiler.
#
# Two modes:
#   ./planetiler.sh <area-name> [maxzoom]
#       Downloads the Geofabrik extract for the named area and builds fresh.
#       Example: ./planetiler.sh netherlands 15
#
#   ./planetiler.sh <path/to.osm.pbf> [maxzoom]
#       Converts an existing local PBF. Output lands next to the input with a
#       .pmtiles suffix. Example: ./planetiler.sh netherlands-260126.osm.pbf 15
#
# Requires Docker and ~10 GB free disk for the intermediate sort buffer.

set -euo pipefail

input="${1:?Usage: $0 <area-name|pbf-path> [maxzoom]}"
maxzoom="${2:-14}"

if [[ -f "$input" ]]; then
    # Local PBF path mode.
    abs_input="$(readlink -f "$input")"
    host_dir="$(dirname "$abs_input")"
    file_name="$(basename "$abs_input")"
    output_name="${file_name%.osm.pbf}-z${maxzoom}.pmtiles"
    docker run --rm --pull always \
        -e JAVA_TOOL_OPTIONS='-Xmx4g' \
        -v "$host_dir:/data" \
        ghcr.io/onthegomap/planetiler:latest \
        --osm-path="/data/$file_name" \
        --output="/data/$output_name" \
        --maxzoom="$maxzoom" \
        --force
    echo "Wrote: $host_dir/$output_name"
else
    # Named-area mode: Planetiler resolves the Geofabrik URL itself.
    area="$input"
    output_name="${area}-z${maxzoom}.pmtiles"
    docker run --rm --pull always \
        -e JAVA_TOOL_OPTIONS='-Xmx4g' \
        -v "$(pwd):/data" \
        ghcr.io/onthegomap/planetiler:latest \
        --download \
        --area="$area" \
        --output="/data/$output_name" \
        --maxzoom="$maxzoom" \
        --force
    echo "Wrote: $(pwd)/$output_name"
fi
