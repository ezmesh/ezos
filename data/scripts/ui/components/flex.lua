-- Flex: Flexbox-like layout container with wrapping support

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local Flex = {}
Flex.__index = Flex

-- Create a new Flex container
-- @param opts.direction "row" (default) or "column"
-- @param opts.wrap true to enable wrapping (default: false)
-- @param opts.gap spacing between items in pixels (default: 4)
-- @param opts.align_items "start", "center", "end" (cross-axis alignment, default: "start")
-- @param opts.justify_content "start", "center", "end", "space-between", "space-around" (default: "start")
-- @param opts.padding padding inside container (default: 0)
function Flex:new(opts)
    opts = opts or {}
    local o = {
        children = {},
        direction = opts.direction or "row",
        wrap = opts.wrap or false,
        gap = opts.gap or 4,
        align_items = opts.align_items or "start",
        justify_content = opts.justify_content or "start",
        padding = opts.padding or 0,
        width = opts.width,   -- nil = auto
        height = opts.height, -- nil = auto
        -- Computed layout cache
        _layout = nil,
        _layout_width = nil,
    }
    setmetatable(o, Flex)
    return o
end

-- Add a child with optional size hints
-- @param child Component with :render(display, x, y, focused) method
-- @param opts.width fixed width (nil = measure from child)
-- @param opts.height fixed height (nil = measure from child)
-- @param opts.flex flex grow factor (default: 0, no growing)
function Flex:add(child, opts)
    opts = opts or {}
    table.insert(self.children, {
        component = child,
        width = opts.width,
        height = opts.height,
        flex = opts.flex or 0,
        -- Computed values
        _x = 0,
        _y = 0,
        _w = 0,
        _h = 0,
    })
    self._layout = nil  -- Invalidate cache
    return self
end

-- Remove all children
function Flex:clear()
    self.children = {}
    self._layout = nil
    return self
end

-- Compute layout for given container width
function Flex:_compute_layout(display, container_width, container_height)
    if self._layout and self._layout_width == container_width then
        return self._layout
    end

    local pad = self.padding
    local available_width = container_width - pad * 2
    local available_height = container_height and (container_height - pad * 2) or 9999

    local is_row = self.direction == "row"
    local lines = {{items = {}, main_size = 0, cross_size = 0}}
    local current_line = lines[1]

    -- First pass: measure children and assign to lines
    for _, child in ipairs(self.children) do
        -- Measure child
        local w = child.width
        local h = child.height

        if not w or not h then
            -- Try to get size from component
            if child.component.get_size then
                local cw, ch = child.component:get_size(display)
                w = w or cw
                h = h or ch
            else
                -- Default size for unmeasurable components
                w = w or 60
                h = h or 20
            end
        end

        child._w = w
        child._h = h

        local main_size = is_row and w or h
        local cross_size = is_row and h or w

        -- Check if we need to wrap
        if self.wrap and #current_line.items > 0 then
            local would_be = current_line.main_size + self.gap + main_size
            local limit = is_row and available_width or available_height
            if would_be > limit then
                -- Start new line
                current_line = {items = {}, main_size = 0, cross_size = 0}
                table.insert(lines, current_line)
            end
        end

        -- Add to current line
        table.insert(current_line.items, child)
        if #current_line.items > 1 then
            current_line.main_size = current_line.main_size + self.gap
        end
        current_line.main_size = current_line.main_size + main_size
        current_line.cross_size = math.max(current_line.cross_size, cross_size)
    end

    -- Second pass: position items within lines
    local cross_offset = pad
    local total_width = 0
    local total_height = 0

    for _, line in ipairs(lines) do
        local main_offset = pad
        local available_main = is_row and available_width or available_height

        -- Calculate extra space for justify-content
        local extra_space = available_main - line.main_size
        local space_before = 0
        local space_between = self.gap

        if extra_space > 0 and #line.items > 0 then
            if self.justify_content == "center" then
                space_before = extra_space / 2
            elseif self.justify_content == "end" then
                space_before = extra_space
            elseif self.justify_content == "space-between" and #line.items > 1 then
                space_between = self.gap + extra_space / (#line.items - 1)
            elseif self.justify_content == "space-around" then
                local per_item = extra_space / #line.items
                space_before = per_item / 2
                space_between = self.gap + per_item
            end
        end

        main_offset = main_offset + space_before

        for i, child in ipairs(line.items) do
            local main_size = is_row and child._w or child._h
            local cross_size = is_row and child._h or child._w

            -- Calculate cross-axis position based on align_items
            local cross_pos = cross_offset
            if self.align_items == "center" then
                cross_pos = cross_offset + (line.cross_size - cross_size) / 2
            elseif self.align_items == "end" then
                cross_pos = cross_offset + line.cross_size - cross_size
            end

            if is_row then
                child._x = main_offset
                child._y = cross_pos
            else
                child._x = cross_pos
                child._y = main_offset
            end

            main_offset = main_offset + main_size
            if i < #line.items then
                main_offset = main_offset + space_between
            end
        end

        -- Track total size
        if is_row then
            total_width = math.max(total_width, main_offset + pad)
            total_height = cross_offset + line.cross_size + pad
        else
            total_width = cross_offset + line.cross_size + pad
            total_height = math.max(total_height, main_offset + pad)
        end

        cross_offset = cross_offset + line.cross_size + self.gap
    end

    self._layout = {
        width = total_width,
        height = total_height,
        lines = lines,
    }
    self._layout_width = container_width

    return self._layout
end

-- Get computed size after layout
function Flex:get_size(display, container_width)
    container_width = container_width or 320
    local layout = self:_compute_layout(display, container_width, nil)
    return layout.width, layout.height
end

-- Render the flex container and all children
-- @param display Display object
-- @param x, y Top-left position
-- @param width Container width (required for wrapping)
-- @param height Container height (optional)
-- @param focused_index Which child is focused (1-based, nil = none)
function Flex:render(display, x, y, width, height, focused_index)
    width = width or self.width or 320
    height = height or self.height

    local layout = self:_compute_layout(display, width, height)

    -- Render each child
    for i, child in ipairs(self.children) do
        local focused = (focused_index == i)
        local cx = x + child._x
        local cy = y + child._y

        if child.component.render then
            child.component:render(display, cx, cy, focused)
        end
    end

    return layout.width, layout.height
end

-- Handle key for a specific focused child
function Flex:handle_key(key, focused_index)
    if focused_index and focused_index >= 1 and focused_index <= #self.children then
        local child = self.children[focused_index]
        if child.component.handle_key then
            return child.component:handle_key(key)
        end
    end
    return nil
end

-- Get number of children
function Flex:count()
    return #self.children
end

-- Get child at index
function Flex:get(index)
    return self.children[index] and self.children[index].component
end

return Flex
