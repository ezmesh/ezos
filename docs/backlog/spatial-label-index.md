# Spatial Label Index for Map Viewer

## Problem

The map viewer currently stores labels in a flat sequential list. Every frame, all labels (up to 5,000) are scanned against the viewport bounds - an O(n) operation that wastes CPU cycles checking labels nowhere near the visible area.

**Current performance:** ~5-10ms per frame with 5,000 labels at typical zoom levels.

## Solution

Separate label storage into a spatially-indexed file (`.tdlabels`) alongside the tile archive (`.tdmap`). Labels are grouped by geographic grid cell, enabling O(1) lookup of only relevant labels.

## File Format

### TDLABELS v1 Format

```
Header (32 bytes):
  magic[4]        = "TDLB"
  version[1]      = 1
  grid_bits[1]    = 8 (256x256 grid)
  reserved[2]     = 0
  bounds_min_lat[4] = int32 (lat × 1,000,000)
  bounds_min_lon[4] = int32 (lon × 1,000,000)
  bounds_max_lat[4] = int32
  bounds_max_lon[4] = int32
  label_count[4]  = uint32 total labels
  index_offset[4] = uint32 offset to grid index

Grid Index (256 × 256 × 4 = 262,144 bytes):
  For each cell [y][x]:
    offset[4]     = uint32 offset into label data (0 = no labels)

Cell Label Data (variable):
  count[2]        = uint16 labels in this cell
  For each label:
    lat_e6[4]     = int32 (lat × 1,000,000)
    lon_e6[4]     = int32 (lon × 1,000,000)
    zoom_min[1]   = uint8 minimum zoom to display
    zoom_max[1]   = uint8 maximum zoom to display
    label_type[1] = uint8 (0=city, 1=town, 2=village, 3=suburb, 4=road, 5=water)
    text_len[1]   = uint8
    text[n]       = UTF-8 string (no null terminator)
```

### Grid Cell Calculation

```python
def lat_lon_to_cell(lat, lon, bounds, grid_bits=8):
    """Convert geographic coordinates to grid cell."""
    grid_size = 1 << grid_bits  # 256

    lat_range = bounds.max_lat - bounds.min_lat
    lon_range = bounds.max_lon - bounds.min_lon

    cell_y = int((lat - bounds.min_lat) / lat_range * grid_size)
    cell_x = int((lon - bounds.min_lon) / lon_range * grid_size)

    return (max(0, min(grid_size - 1, cell_x)),
            max(0, min(grid_size - 1, cell_y)))
```

## Implementation Plan

### Phase 1: Build Tool Updates (`tools/maps/`)

**1.1 Create `labels.py` module**

```python
# tools/maps/labels.py

class LabelIndex:
    """Spatial index for map labels."""

    def __init__(self, bounds, grid_bits=8):
        self.bounds = bounds
        self.grid_size = 1 << grid_bits
        self.cells = [[[] for _ in range(self.grid_size)]
                      for _ in range(self.grid_size)]

    def add_label(self, label):
        """Add label to appropriate grid cell."""
        cx, cy = self.lat_lon_to_cell(label.lat, label.lon)
        self.cells[cy][cx].append(label)

    def write(self, path):
        """Write spatial index to .tdlabels file."""
        # Implementation
```

**1.2 Update `pmtiles_to_tdmap.py`**

- Extract labels during tile processing (existing code)
- Build spatial index instead of flat list
- Write `.tdlabels` file alongside `.tdmap`
- Remove label data from TDMAP format (bump to v5)

**1.3 Update `archive.py`**

- Add `TDLabelsReader` class for reading spatial index
- Keep `TDMapReader` for tile-only access
- Update format version handling

### Phase 2: Lua Runtime Updates (`data/scripts/`)

**2.1 Create `label_index.lua` module**

```lua
-- data/scripts/ui/services/label_index.lua

local LabelIndex = {}

function LabelIndex:new(path)
    local o = {
        path = path,
        bounds = nil,
        grid_size = 256,
        cell_cache = {},  -- LRU cache of loaded cells
        max_cached_cells = 64,
    }
    setmetatable(o, {__index = LabelIndex})
    return o
end

function LabelIndex:load_header()
    -- Read 32-byte header, store bounds
end

function LabelIndex:get_visible_cells(viewport, zoom)
    -- Calculate which grid cells overlap viewport
    -- Returns list of {x, y} cell coordinates
end

function LabelIndex:load_cell(cx, cy)
    -- Load labels for specific cell from file
    -- Cache in cell_cache with LRU eviction
end

function LabelIndex:get_labels(viewport, zoom)
    -- Main query function
    local cells = self:get_visible_cells(viewport, zoom)
    local labels = {}
    for _, cell in ipairs(cells) do
        local cell_labels = self:load_cell(cell.x, cell.y)
        for _, label in ipairs(cell_labels) do
            if label.zoom_min <= zoom and label.zoom_max >= zoom then
                table.insert(labels, label)
            end
        end
    end
    return labels
end

return LabelIndex
```

**2.2 Update `map_viewer.lua`**

```lua
-- Replace flat label loading with spatial index

function MapViewer:load_labels()
    local labels_path = self.map_path:gsub("%.tdmap$", ".tdlabels")
    if ez.storage.exists(labels_path) then
        self.label_index = LabelIndex:new(labels_path)
        self.label_index:load_header()
    end
end

function MapViewer:render_labels(display)
    if not self.label_index then return end

    -- Query only visible labels (O(1) grid lookup)
    local visible = self.label_index:get_labels(self.viewport, self.zoom)

    -- Sort by priority and render (existing occlusion logic)
    self:render_label_list(display, visible)
end
```

### Phase 3: C++ Bindings (Optional Optimization)

If Lua performance is insufficient, add native label index:

**3.1 `src/lua/bindings/map_bindings.cpp`**

```cpp
// @lua ez.map.load_label_index(path) -> LabelIndex
// @lua label_index:query(min_lat, min_lon, max_lat, max_lon, zoom) -> table
```

This moves grid lookup and cell loading to C++ for better performance.

### Phase 4: Migration & Compatibility

**4.1 Version handling**

- TDMAP v5: Tiles only (no embedded labels)
- TDMAP v4: Legacy format with embedded labels (still supported)
- Separate `.tdlabels` file for v5 maps

**4.2 Backward compatibility**

```lua
function MapViewer:load_labels()
    local labels_path = self.map_path:gsub("%.tdmap$", ".tdlabels")

    if ez.storage.exists(labels_path) then
        -- New spatial index
        self.label_index = LabelIndex:new(labels_path)
    elseif self.archive.has_labels then
        -- Legacy flat list (v4 format)
        self.labels = self.archive:load_labels()
    end
end
```

## Performance Expectations

| Metric | Before | After |
|--------|--------|-------|
| Labels scanned per frame | 5,000 | ~50-100 |
| Label filtering time | 5-10ms | <0.5ms |
| Memory (all labels) | ~500KB | ~50KB (cached cells) |
| Initial load time | ~200ms | ~10ms (header only) |

## File Size Impact

For a typical regional map with 5,000 labels:

- **Grid index:** 256KB (fixed overhead)
- **Label data:** ~60KB (same as before, just reorganized)
- **Total `.tdlabels`:** ~320KB

## Testing Plan

1. **Unit tests** for grid cell calculation
2. **Round-trip test**: Generate index, query all cells, verify label count matches
3. **Visual test**: Compare rendered labels before/after
4. **Performance benchmark**: Measure frame time with 5,000 labels
5. **Edge cases**: Labels at grid cell boundaries, empty cells, max zoom

## Future Enhancements

1. **Multi-resolution grid**: Coarse grid for low zoom, fine grid for high zoom
2. **Label streaming**: Load cells asynchronously during pan
3. **Label priority in index**: Pre-sort by priority within each cell
4. **Compressed cell data**: RLE or LZ4 for label text
5. **Shared label pool**: Deduplicate common text strings (e.g., "Street", "Road")
