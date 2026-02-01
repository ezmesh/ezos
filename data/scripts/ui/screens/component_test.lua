-- Component Test Screen for T-Deck OS
-- Interactive showcase of all UI components with dynamic layout

local ListMixin = load_module("/scripts/ui/list_mixin.lua")
local Components = load_module("/scripts/ui/components.lua")

local ComponentTest = {
    title = "Component Test"
}

function ComponentTest:new()
    local o = {
        title = self.title,
        focused_index = 1,
        scroll_y = 0,  -- Pixel scroll offset

        -- Create test components
        components = {},
        labels = {},
        row_heights = {},  -- Computed heights per row
        row_positions = {}, -- Computed y positions
        total_height = 0,
        layout_done = false,
    }
    setmetatable(o, {__index = ComponentTest})
    o:init_components()
    return o
end

function ComponentTest:init_components()
    -- TextInput
    table.insert(self.labels, "TextInput")
    table.insert(self.components, Components.TextInput:new({
        placeholder = "Enter text...",
        width = 150,
    }))

    -- TextInput (password)
    table.insert(self.labels, "Password")
    table.insert(self.components, Components.TextInput:new({
        placeholder = "Password",
        password_mode = true,
        width = 150,
    }))

    -- Button
    table.insert(self.labels, "Button")
    table.insert(self.components, Components.Button:new({
        label = "Click Me",
        on_press = function()
            if _G.Toast then
                _G.Toast.show("Button pressed!")
            end
        end,
    }))

    -- Checkbox
    table.insert(self.labels, "Checkbox")
    table.insert(self.components, Components.Checkbox:new({
        label = "Enable feature",
        checked = false,
    }))

    -- Toggle
    table.insert(self.labels, "Toggle")
    table.insert(self.components, Components.Toggle:new({
        label = "Dark mode",
        value = true,
    }))

    -- NumberInput
    table.insert(self.labels, "Number")
    table.insert(self.components, Components.NumberInput:new({
        value = 50,
        min = 0,
        max = 100,
        step = 5,
        suffix = "%",
        width = 100,
    }))

    -- Dropdown
    table.insert(self.labels, "Dropdown")
    table.insert(self.components, Components.Dropdown:new({
        options = {"Option 1", "Option 2", "Option 3", "Option 4", "Option 5"},
        selected = 1,
        width = 120,
    }))

    -- RadioGroup (vertical to demonstrate dynamic height)
    table.insert(self.labels, "Radio")
    table.insert(self.components, Components.RadioGroup:new({
        options = {"Small", "Medium", "Large"},
        selected = 2,
        horizontal = false,
    }))

    -- Flex row demo
    table.insert(self.labels, "Flex Row")
    local flex_row = Components.Flex:new({
        direction = "row",
        gap = 6,
        align_items = "center",
    })
    flex_row:add(Components.Button:new({label = "A", width = 30}), {width = 30, height = 20})
    flex_row:add(Components.Button:new({label = "B", width = 30}), {width = 30, height = 20})
    flex_row:add(Components.Button:new({label = "C", width = 30}), {width = 30, height = 20})
    table.insert(self.components, flex_row)

    -- Flex wrap demo
    table.insert(self.labels, "Flex Wrap")
    local flex_wrap = Components.Flex:new({
        direction = "row",
        wrap = true,
        gap = 4,
    })
    for i = 1, 8 do
        flex_wrap:add(Components.Button:new({label = tostring(i), width = 28}), {width = 28, height = 18})
    end
    table.insert(self.components, flex_wrap)
end

-- Compute layout based on component sizes
function ComponentTest:compute_layout(display, container_width)
    if self.layout_done then return end

    local row_gap = 6
    local y = 0

    for i, comp in ipairs(self.components) do
        local h = 20  -- Default height

        if comp.get_size then
            local _, ch = comp:get_size(display, container_width)
            h = ch
        elseif comp.direction then
            -- Flex container
            local _, ch = comp:get_size(display, container_width)
            h = ch
        end

        -- Minimum row height
        h = math.max(h, 18)

        self.row_heights[i] = h
        self.row_positions[i] = y
        y = y + h + row_gap
    end

    self.total_height = y - row_gap
    self.layout_done = true
end

function ComponentTest:on_enter()
    -- Reset layout on enter
    self.layout_done = false
end

function ComponentTest:render(display)
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height
    local fh = display.get_font_height()

    -- Background
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content area
    local content_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31
    local content_height = h - content_y - 20
    local label_width = 70
    local component_x = label_width + 4
    local component_width = w - component_x - 10

    -- Compute layout if needed
    self:compute_layout(display, component_width)

    -- Clamp scroll
    local max_scroll = math.max(0, self.total_height - content_height)
    self.scroll_y = Utils.clamp(self.scroll_y, 0, max_scroll)

    -- Ensure focused item is visible
    local focused_top = self.row_positions[self.focused_index] or 0
    local focused_bottom = focused_top + (self.row_heights[self.focused_index] or 20)

    if focused_top < self.scroll_y then
        self.scroll_y = focused_top
    elseif focused_bottom > self.scroll_y + content_height then
        self.scroll_y = focused_bottom - content_height
    end

    -- Set clip region (conceptual - we'll just skip out-of-bounds)
    display.set_font_size("small")

    local expanded_dropdown = nil
    local expanded_info = nil

    -- Draw components
    for i = 1, #self.components do
        local row_y = self.row_positions[i]
        local row_h = self.row_heights[i]
        local screen_y = content_y + row_y - self.scroll_y

        -- Check if visible
        if screen_y + row_h > content_y and screen_y < content_y + content_height then
            local is_focused = (i == self.focused_index)

            -- Label (vertically centered in row)
            local label_color = is_focused and colors.ACCENT or colors.TEXT_SECONDARY
            local label_y = screen_y + math.floor((row_h - fh) / 2)
            display.draw_text(4, label_y, self.labels[i], label_color)

            -- Component
            local comp = self.components[i]
            if comp.render then
                -- Check if this is an expanded dropdown - defer rendering
                if comp.is_expanded and comp:is_expanded() then
                    expanded_dropdown = comp
                    expanded_info = {x = component_x, y = screen_y, focused = is_focused}
                elseif comp.direction then
                    -- Flex container
                    comp:render(display, component_x, screen_y, component_width, nil, nil)
                else
                    comp:render(display, component_x, screen_y, is_focused)
                end
            end
        end
    end

    -- Render expanded dropdown last (on top of other components)
    if expanded_dropdown and expanded_info then
        expanded_dropdown:render(display, expanded_info.x, expanded_info.y, expanded_info.focused)
    end

    display.set_font_size("medium")

    -- Scrollbar
    if self.total_height > content_height then
        local sb_x = w - 6
        local sb_height = content_height
        local thumb_height = math.max(12, math.floor(sb_height * content_height / self.total_height))
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
    local comp = self.components[self.focused_index]

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
        if self.focused_index > 1 then
            self.focused_index = self.focused_index - 1
            ScreenManager.invalidate()
        end
        return "continue"
    elseif key.special == "DOWN" then
        if self.focused_index < #self.components then
            self.focused_index = self.focused_index + 1
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
