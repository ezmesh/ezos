-- Component Test Screen for T-Deck OS
-- Interactive showcase of all UI components using Grid layout

local ListMixin = load_module("/scripts/ui/list_mixin.lua")
local Components = load_module("/scripts/ui/components.lua")

local ComponentTest = {
    title = "Component Test"
}

function ComponentTest:new()
    local o = {
        title = self.title,
        focused_row = 1,
        scroll_y = 0,  -- Pixel scroll offset
        grid = nil,
        interactive_col = 2,  -- Column with interactive components
    }
    setmetatable(o, {__index = ComponentTest})
    o:init_grid()
    return o
end

function ComponentTest:init_grid()
    -- Create grid with label column and right-aligned input column
    self.grid = Components.Grid:new({
        columns = {
            {width = 80},     -- Labels
            {width = "1fr"},  -- Components (fills remaining space)
        },
        row_gap = 6,
        col_gap = 12,
        align_items = "center",
    })

    -- Row 1: TextInput
    self.grid:add_row({
        Components.Label:new({text = "TextInput"}),
        Components.TextInput:new({placeholder = "Enter text...", width = 150}),
    }, {aligns = {"left", "right"}})

    -- Row 2: Password
    self.grid:add_row({
        Components.Label:new({text = "Password"}),
        Components.TextInput:new({placeholder = "Password", password_mode = true, width = 150}),
    }, {aligns = {"left", "right"}})

    -- Row 3: Button
    self.grid:add_row({
        Components.Label:new({text = "Button"}),
        Components.Button:new({
            label = "Click Me",
            on_press = function()
                if _G.Toast then _G.Toast.show("Button pressed!") end
            end,
        }),
    }, {aligns = {"left", "right"}})

    -- Row 4: Checkbox
    self.grid:add_row({
        Components.Label:new({text = "Checkbox"}),
        Components.Checkbox:new({label = "Enable", checked = false}),
    }, {aligns = {"left", "right"}})

    -- Row 5: Toggle
    self.grid:add_row({
        Components.Label:new({text = "Toggle"}),
        Components.Toggle:new({label = "Dark", value = true}),
    }, {aligns = {"left", "right"}})

    -- Row 6: NumberInput
    self.grid:add_row({
        Components.Label:new({text = "Number"}),
        Components.NumberInput:new({value = 50, min = 0, max = 100, step = 5, suffix = "%", width = 100}),
    }, {aligns = {"left", "right"}})

    -- Row 7: Dropdown
    self.grid:add_row({
        Components.Label:new({text = "Dropdown"}),
        Components.Dropdown:new({
            options = {"Option 1", "Option 2", "Option 3", "Option 4", "Option 5"},
            selected = 1,
            width = 120,
        }),
    }, {aligns = {"left", "right"}})

    -- Row 8: RadioGroup
    self.grid:add_row({
        Components.Label:new({text = "Radio"}),
        Components.RadioGroup:new({options = {"Small", "Medium", "Large"}, selected = 2}),
    }, {aligns = {"left", "right"}})

    -- Row 9: Flex row
    local flex_row = Components.Flex:new({direction = "row", gap = 6, align_items = "center"})
    flex_row:add(Components.Button:new({label = "A", width = 30}), {width = 30, height = 20})
    flex_row:add(Components.Button:new({label = "B", width = 30}), {width = 30, height = 20})
    flex_row:add(Components.Button:new({label = "C", width = 30}), {width = 30, height = 20})
    self.grid:add_row({
        Components.Label:new({text = "Flex Row"}),
        flex_row,
    }, {aligns = {"left", "right"}})

    -- Row 10: Flex wrap
    local flex_wrap = Components.Flex:new({direction = "row", wrap = true, gap = 4})
    for i = 1, 8 do
        flex_wrap:add(Components.Button:new({label = tostring(i), width = 28}), {width = 28, height = 18})
    end
    self.grid:add_row({
        Components.Label:new({text = "Flex Wrap"}),
        flex_wrap,
    }, {aligns = {"left", "right"}})
end

function ComponentTest:on_enter()
    -- Nothing special needed
end

function ComponentTest:render(display)
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height

    -- Background
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content area
    local content_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31
    local content_height = h - content_y - 20
    local padding_left = 4
    local padding_right = 12  -- Extra space for scrollbar

    -- Get grid size
    local grid_width = w - padding_left - padding_right
    local _, grid_height = self.grid:get_size(display, grid_width)

    -- Clamp scroll
    local max_scroll = math.max(0, grid_height - content_height)
    self.scroll_y = Utils.clamp(self.scroll_y, 0, max_scroll)

    -- Ensure focused row is visible
    local layout = self.grid:_compute_layout(display, grid_width)
    local focused_top = layout.row_y[self.focused_row] or 0
    local focused_height = layout.row_heights[self.focused_row] or 20
    local focused_bottom = focused_top + focused_height

    if focused_top < self.scroll_y then
        self.scroll_y = focused_top
    elseif focused_bottom > self.scroll_y + content_height then
        self.scroll_y = focused_bottom - content_height
    end

    display.set_font_size("small")

    -- Render grid (handling dropdown z-index)
    local dropdown_row = nil
    local dropdown_comp = nil

    -- Check for expanded dropdown
    for row = 1, self.grid:row_count() do
        local comp = self.grid:get_cell(row, self.interactive_col)
        if comp and comp.is_expanded and comp:is_expanded() then
            dropdown_row = row
            dropdown_comp = comp
            break
        end
    end

    -- First pass: render all rows except expanded dropdown row
    for row = 1, self.grid:row_count() do
        local row_y = layout.row_y[row] or 0
        local row_h = layout.row_heights[row] or 20
        local screen_y = content_y + row_y - self.scroll_y

        -- Check if visible
        if screen_y + row_h > content_y and screen_y < content_y + content_height then
            local is_focused = (row == self.focused_row)

            -- Render each cell in row
            for col = 1, #self.grid.columns do
                local comp, cell = self.grid:get_cell(row, col)
                if comp and comp.render then
                    -- Skip expanded dropdown (render later)
                    if row == dropdown_row and col == self.interactive_col then
                        -- Will render in second pass
                    else
                        local col_x = layout.col_x[col] or 0
                        local col_w = layout.col_widths[col] or 100

                        -- Get component size
                        local comp_w, comp_h = col_w, row_h
                        if comp.get_size then
                            comp_w, comp_h = comp:get_size(display, col_w)
                        end

                        -- Horizontal alignment
                        local cx = padding_left + col_x
                        if cell.align == "right" then
                            cx = padding_left + col_x + col_w - comp_w
                        elseif cell.align == "center" then
                            cx = padding_left + col_x + math.floor((col_w - comp_w) / 2)
                        end

                        -- Vertical alignment (center)
                        local cy = screen_y + math.floor((row_h - comp_h) / 2)

                        local cell_focused = is_focused and (col == self.interactive_col)
                        comp:render(display, cx, cy, cell_focused)
                    end
                end
            end
        end
    end

    -- Second pass: render expanded dropdown on top
    if dropdown_row and dropdown_comp then
        local row_y = layout.row_y[dropdown_row] or 0
        local row_h = layout.row_heights[dropdown_row] or 20
        local screen_y = content_y + row_y - self.scroll_y

        local col_x = layout.col_x[self.interactive_col] or 0
        local col_w = layout.col_widths[self.interactive_col] or 100

        local comp_w, comp_h = dropdown_comp:get_size(display, col_w)
        local cx = padding_left + col_x + col_w - comp_w
        local cy = screen_y + math.floor((row_h - comp_h) / 2)

        dropdown_comp:render(display, cx, cy, true)
    end

    display.set_font_size("medium")

    -- Scrollbar
    if grid_height > content_height then
        local sb_x = w - 6
        local sb_height = content_height
        local thumb_height = math.max(12, math.floor(sb_height * content_height / grid_height))
        local thumb_y = content_y + math.floor(self.scroll_y * (sb_height - thumb_height) / max_scroll)

        display.fill_rect(sb_x, content_y, 4, sb_height, colors.SURFACE)
        display.fill_rect(sb_x, thumb_y, 4, thumb_height, colors.ACCENT)
    end

    -- Footer hint
    display.set_font_size("small")
    local hint = "UP/DOWN:Navigate  ENTER:Interact  ESC:Back"
    display.draw_text(4, h - 14, hint, colors.TEXT_MUTED)
    display.set_font_size("medium")
end

function ComponentTest:handle_key(key)
    local comp = self.grid:get_cell(self.focused_row, self.interactive_col)

    -- Check if dropdown is expanded - it captures all keys
    if comp and comp.is_expanded and comp:is_expanded() then
        local result = comp:handle_key(key)
        if result then
            ScreenManager.invalidate()
            return "continue"
        end
    end

    -- Navigation
    if key.special == "UP" then
        if self.focused_row > 1 then
            self.focused_row = self.focused_row - 1
            ScreenManager.invalidate()
        end
        return "continue"
    elseif key.special == "DOWN" then
        if self.focused_row < self.grid:row_count() then
            self.focused_row = self.focused_row + 1
            ScreenManager.invalidate()
        end
        return "continue"
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    -- Pass key to focused component
    if comp and comp.handle_key then
        local result = comp:handle_key(key)
        if result then
            ScreenManager.invalidate()
        end
    end

    return "continue"
end

return ComponentTest
