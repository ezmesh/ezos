-- Component Test Screen for T-Deck OS
-- Interactive showcase of all UI components

local ListMixin = load_module("/scripts/ui/list_mixin.lua")
local Components = load_module("/scripts/ui/components.lua")

local ComponentTest = {
    title = "Component Test"
}

function ComponentTest:new()
    local o = {
        title = self.title,
        focused_index = 1,
        scroll_y = 0,

        -- Create test components
        components = {},
        labels = {},
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

    -- RadioGroup
    table.insert(self.labels, "Radio")
    table.insert(self.components, Components.RadioGroup:new({
        options = {"Small", "Medium", "Large"},
        selected = 2,
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

function ComponentTest:on_enter()
    -- Nothing special needed
end

function ComponentTest:render(display)
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height
    local fh = display.get_font_height()
    local fw = display.get_font_width()

    -- Background
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content area
    local content_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31
    local content_height = h - content_y - 20
    local label_width = 80
    local component_x = label_width + 8
    local row_height = 28

    -- Calculate visible range
    local visible_rows = math.floor(content_height / row_height)
    local max_scroll = math.max(0, #self.components - visible_rows)
    self.scroll_y = Utils.clamp(self.scroll_y, 0, max_scroll)

    -- Draw components (two passes: regular components first, then expanded dropdowns on top)
    display.set_font_size("small")

    local expanded_dropdown = nil
    local expanded_info = nil

    for i = 1, #self.components do
        local visible_idx = i - self.scroll_y
        if visible_idx >= 1 and visible_idx <= visible_rows then
            local y = content_y + (visible_idx - 1) * row_height
            local is_focused = (i == self.focused_index)

            -- Label
            local label_color = is_focused and colors.ACCENT or colors.TEXT_SECONDARY
            display.draw_text(4, y + 4, self.labels[i], label_color)

            -- Component
            local comp = self.components[i]
            if comp.render then
                -- Check if this is an expanded dropdown - defer rendering
                if comp.is_expanded and comp:is_expanded() then
                    expanded_dropdown = comp
                    expanded_info = {x = component_x, y = y, focused = is_focused}
                elseif comp.direction then
                    -- Flex container
                    comp:render(display, component_x, y, w - component_x - 8, nil, nil)
                else
                    comp:render(display, component_x, y, is_focused)
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
    if #self.components > visible_rows then
        local sb_x = w - 6
        local sb_height = content_height
        local thumb_height = math.max(12, math.floor(sb_height * visible_rows / #self.components))
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
            -- Scroll to keep focused item visible
            local visible_rows = 6
            if self.focused_index <= self.scroll_y then
                self.scroll_y = self.focused_index - 1
            end
            ScreenManager.invalidate()
        end
        return "continue"
    elseif key.special == "DOWN" then
        if self.focused_index < #self.components then
            self.focused_index = self.focused_index + 1
            -- Scroll to keep focused item visible
            local visible_rows = 6
            if self.focused_index > self.scroll_y + visible_rows then
                self.scroll_y = self.focused_index - visible_rows
            end
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
