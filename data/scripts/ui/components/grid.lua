-- Grid: CSS Grid-like layout component

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local Grid = {}
Grid.__index = Grid

-- Create a new Grid container
-- @param opts.columns Column definitions: array of {width=number or "auto" or "1fr"}
-- @param opts.row_gap Vertical gap between rows (default: 4)
-- @param opts.col_gap Horizontal gap between columns (default: 8)
-- @param opts.align_items Vertical alignment: "start", "center", "end" (default: "center")
-- @param opts.padding Padding inside container (default: 0)
function Grid:new(opts)
    opts = opts or {}
    local o = {
        columns = opts.columns or {{width = "1fr"}, {width = "1fr"}},
        row_gap = opts.row_gap or 4,
        col_gap = opts.col_gap or 8,
        align_items = opts.align_items or "center",
        padding = opts.padding or 0,
        cells = {},  -- Array of {component, col, row, align}
        -- Computed layout
        _layout = nil,
        _container_width = nil,
    }
    setmetatable(o, Grid)
    return o
end

-- Add a cell to the grid
-- @param component Component to add (or nil for empty cell)
-- @param opts.col Column index (1-based, default: next available)
-- @param opts.row Row index (1-based, default: current row)
-- @param opts.align Horizontal alignment: "left", "center", "right" (default: "left")
function Grid:add(component, opts)
    opts = opts or {}

    -- Auto-calculate position if not specified
    local col = opts.col
    local row = opts.row

    if not col or not row then
        -- Find next available position
        local max_row = 0
        local last_col = 0
        for _, cell in ipairs(self.cells) do
            if cell.row > max_row then
                max_row = cell.row
                last_col = cell.col
            elseif cell.row == max_row and cell.col > last_col then
                last_col = cell.col
            end
        end

        if not row then
            if last_col >= #self.columns then
                row = max_row + 1
                col = col or 1
            else
                row = math.max(1, max_row)
                col = col or (last_col + 1)
            end
        else
            col = col or 1
        end
    end

    table.insert(self.cells, {
        component = component,
        col = col,
        row = row,
        align = opts.align or "left",
    })

    self._layout = nil  -- Invalidate cache
    return self
end

-- Add a complete row of components
-- @param components Array of components (or nil for empty cells)
-- @param opts.aligns Array of alignments per column
function Grid:add_row(components, opts)
    opts = opts or {}
    local aligns = opts.aligns or {}

    -- Find next row
    local max_row = 0
    for _, cell in ipairs(self.cells) do
        max_row = math.max(max_row, cell.row)
    end
    local row = max_row + 1

    for i, comp in ipairs(components) do
        if i <= #self.columns then
            self:add(comp, {col = i, row = row, align = aligns[i] or "left"})
        end
    end

    return self
end

-- Compute column widths
function Grid:_compute_columns(container_width)
    local available = container_width - self.padding * 2
    local col_widths = {}
    local fr_total = 0
    local fixed_total = 0

    -- First pass: fixed widths and count fr units
    for i, col in ipairs(self.columns) do
        if type(col.width) == "number" then
            col_widths[i] = col.width
            fixed_total = fixed_total + col.width
        elseif col.width == "auto" then
            col_widths[i] = 0  -- Will be computed from content
        else
            -- Parse "Nfr" format
            local fr = tonumber(string.match(col.width, "(%d+)fr")) or 1
            col_widths[i] = fr  -- Store fr value temporarily
            fr_total = fr_total + fr
        end
    end

    -- Account for gaps
    local gaps_width = (#self.columns - 1) * self.col_gap
    local remaining = available - fixed_total - gaps_width

    -- Second pass: distribute remaining space to fr columns
    if fr_total > 0 and remaining > 0 then
        for i, col in ipairs(self.columns) do
            if type(col.width) == "string" and col.width:match("fr") then
                local fr = col_widths[i]
                col_widths[i] = math.floor(remaining * fr / fr_total)
            end
        end
    end

    return col_widths
end

-- Compute full layout
function Grid:_compute_layout(display, container_width)
    if self._layout and self._container_width == container_width then
        return self._layout
    end

    local col_widths = self:_compute_columns(container_width)

    -- Compute column x positions
    local col_x = {}
    local x = self.padding
    for i, w in ipairs(col_widths) do
        col_x[i] = x
        x = x + w + self.col_gap
    end

    -- Find max row
    local max_row = 0
    for _, cell in ipairs(self.cells) do
        max_row = math.max(max_row, cell.row)
    end

    -- Compute row heights
    local row_heights = {}
    for row = 1, max_row do
        local max_h = 18  -- Minimum row height
        for _, cell in ipairs(self.cells) do
            if cell.row == row and cell.component then
                local h = 18
                if cell.component.get_size then
                    local _, ch = cell.component:get_size(display, col_widths[cell.col] or 100)
                    h = ch
                end
                max_h = math.max(max_h, h)
            end
        end
        row_heights[row] = max_h
    end

    -- Compute row y positions
    local row_y = {}
    local y = self.padding
    for row = 1, max_row do
        row_y[row] = y
        y = y + (row_heights[row] or 18) + self.row_gap
    end

    local total_height = y - self.row_gap + self.padding

    self._layout = {
        col_widths = col_widths,
        col_x = col_x,
        row_heights = row_heights,
        row_y = row_y,
        total_height = total_height,
        max_row = max_row,
    }
    self._container_width = container_width

    return self._layout
end

function Grid:get_size(display, container_width)
    container_width = container_width or 320
    local layout = self:_compute_layout(display, container_width)
    return container_width, layout.total_height
end

-- Get row count
function Grid:row_count()
    local max_row = 0
    for _, cell in ipairs(self.cells) do
        max_row = math.max(max_row, cell.row)
    end
    return max_row
end

-- Render the grid
-- @param focused_row Which row is focused (1-based, nil = none)
-- @param focused_col Which column in that row is focused (default: all)
function Grid:render(display, x, y, width, focused_row, focused_col)
    width = width or 320
    local layout = self:_compute_layout(display, width)

    for _, cell in ipairs(self.cells) do
        if cell.component and cell.component.render then
            local col_x = layout.col_x[cell.col] or 0
            local col_w = layout.col_widths[cell.col] or 100
            local row_y = layout.row_y[cell.row] or 0
            local row_h = layout.row_heights[cell.row] or 18

            -- Get component size
            local comp_w, comp_h = col_w, row_h
            if cell.component.get_size then
                comp_w, comp_h = cell.component:get_size(display, col_w)
            end

            -- Horizontal alignment
            local cx = x + col_x
            if cell.align == "right" then
                cx = x + col_x + col_w - comp_w
            elseif cell.align == "center" then
                cx = x + col_x + math.floor((col_w - comp_w) / 2)
            end

            -- Vertical alignment
            local cy = y + row_y
            if self.align_items == "center" then
                cy = y + row_y + math.floor((row_h - comp_h) / 2)
            elseif self.align_items == "end" then
                cy = y + row_y + row_h - comp_h
            end

            -- Check if focused
            local is_focused = (focused_row == cell.row) and
                              (focused_col == nil or focused_col == cell.col)

            cell.component:render(display, cx, cy, is_focused)
        end
    end

    return width, layout.total_height
end

-- Get component at row/col
function Grid:get_cell(row, col)
    for _, cell in ipairs(self.cells) do
        if cell.row == row and cell.col == col then
            return cell.component, cell
        end
    end
    return nil
end

-- Handle key for focused cell
function Grid:handle_key(key, focused_row, focused_col)
    local comp = self:get_cell(focused_row, focused_col or 1)
    if comp and comp.handle_key then
        return comp:handle_key(key)
    end
    return nil
end

return Grid
