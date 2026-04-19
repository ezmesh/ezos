"""
MVT → list of geographic labels.

Pure-function stage of the TDMAP pipeline: takes raw MVT bytes plus the tile
coords they belong to and returns a list of label dicts suitable for passing
into `archive.TDMAPWriter.add_label`.

Split out from `pmtiles_to_tdmap.py` so the label-extraction rules (which
OSM property names map to which label type, which zoom thresholds apply) can
evolve independently of the raster renderer.
"""

from typing import List

import mapbox_vector_tile as mvt

from config import (
    LABEL_TYPE_CITY, LABEL_TYPE_TOWN, LABEL_TYPE_VILLAGE, LABEL_TYPE_SUBURB,
    LABEL_TYPE_WATER, LABEL_MIN_ZOOM,
)
from render import decompress_tile, get_layer, tile_pixel_to_lat_lon


def extract_labels(tile_data: bytes, zoom: int, tile_x: int, tile_y: int) -> List[dict]:
    """Extract place and water labels from a single MVT tile.

    Returns a list of dicts with keys: ``zoom_min``, ``zoom_max``, ``lat``,
    ``lon``, ``label_type``, ``text``. Coordinates are geographic (not tile
    pixel) so labels survive resampling into different archive extents.
    """
    labels: List[dict] = []

    try:
        data = decompress_tile(tile_data)
        # y_coord_down=True matches tile_pixel_to_lat_lon's y-down frame. With
        # the library's default (y-up GeoJSON) every label's latitude comes out
        # reflected across the tile's mid-parallel.
        decoded = mvt.decode(data, default_options={"y_coord_down": True})
    except Exception:
        return labels

    # MVT extent is per-layer but almost always 4096 in practice.
    extent = 4096
    for _name, layer in decoded.items():
        if "extent" in layer:
            extent = layer["extent"]
            break

    # --- Place labels (cities/towns/villages/suburbs) ----------------------
    for layer_name in ("place", "place_name", "place_label"):
        layer = get_layer(decoded, layer_name)
        if not layer:
            continue
        for feature in layer.get("features", []):
            props = feature.get("properties", {})
            geom  = feature.get("geometry", {})

            name = props.get("name") or props.get("name:en") or props.get("name:latin")
            if not name:
                continue

            place_class = props.get("class") or props.get("place") or props.get("type", "")

            label_type = None
            if place_class in ("city", "metropolis"):
                label_type = LABEL_TYPE_CITY
            elif place_class == "town":
                label_type = LABEL_TYPE_TOWN
            elif place_class in ("village", "hamlet"):
                label_type = LABEL_TYPE_VILLAGE
            elif place_class in ("suburb", "neighbourhood", "neighborhood", "quarter"):
                label_type = LABEL_TYPE_SUBURB
            else:
                continue

            coords = geom.get("coordinates", [])
            if geom.get("type") == "Point" and len(coords) >= 2:
                lat, lon = tile_pixel_to_lat_lon(zoom, tile_x, tile_y, coords[0], coords[1], extent)
                labels.append({
                    "zoom_min":  LABEL_MIN_ZOOM.get(label_type, zoom),
                    "zoom_max":  14,
                    "lat":       lat,
                    "lon":       lon,
                    "label_type": label_type,
                    "text":      name[:50],
                })

    # --- Water labels ------------------------------------------------------
    for layer_name in ("water_name", "waterway_label"):
        layer = get_layer(decoded, layer_name)
        if not layer:
            continue
        for feature in layer.get("features", []):
            props = feature.get("properties", {})
            geom  = feature.get("geometry", {})

            name = props.get("name") or props.get("name:en")
            if not name:
                continue

            coords = geom.get("coordinates", [])
            px, py = None, None
            if geom.get("type") == "Point" and len(coords) >= 2:
                px, py = coords[0], coords[1]
            elif geom.get("type") in ("LineString", "MultiLineString"):
                if coords and isinstance(coords[0][0], (list, tuple)):
                    coords = coords[0]
                if len(coords) >= 2:
                    mid = len(coords) // 2
                    px, py = coords[mid][0], coords[mid][1]

            if px is None:
                continue

            lat, lon = tile_pixel_to_lat_lon(zoom, tile_x, tile_y, px, py, extent)
            labels.append({
                "zoom_min":  LABEL_MIN_ZOOM[LABEL_TYPE_WATER],
                "zoom_max":  14,
                "lat":       lat,
                "lon":       lon,
                "label_type": LABEL_TYPE_WATER,
                "text":      name[:50],
            })

    return labels
