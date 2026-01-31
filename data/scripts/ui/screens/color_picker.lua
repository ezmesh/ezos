-- Color Picker Screen for T-Deck OS
-- Reusable RGB color picker with hex input and theme color swatches

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local ColorPicker = {
    title = "Color Picker",
    -- RGB values (0-255)
    r = 0,
    g = 0,
    b = 0,
    -- Current selection mode: "slider" or "palette"
    mode = "slider",
    -- Slider field: 1=R, 2=G, 3=B, 4=Hex, 5=Auto
    slider_field = 1,
    -- Palette selection index
    palette_index = 1,
    -- Edit mode for sliders
    editing = false,
    -- Hex input buffer
    hex_buffer = "",
    -- Options
    allow_auto = false,
    is_auto = false,
    -- Callback
    on_select = nil,
}

-- Theme color names for palette
ColorPicker.PALETTE_COLORS = {
    "ACCENT", "SUCCESS", "WARNING", "ERROR", "INFO",
    "TEXT", "TEXT_SECONDARY", "SURFACE", "SURFACE_ALT"
}

-- Convert RGB888 to RGB565
function ColorPicker.rgb_to_565(r, g, b)
    local r5 = math.floor(r / 8)  -- 5 bits
    local g6 = math.floor(g / 4)  -- 6 bits
    local b5 = math.floor(b / 8)  -- 5 bits
    return (r5 * 2048) + (g6 * 32) + b5
end

-- Convert RGB565 to RGB888
function ColorPicker.rgb565_to_888(color)
    local r5 = math.floor(color / 2048) % 32
    local g6 = math.floor(color / 32) % 64
    local b5 = color % 32
    -- Expand to 8 bits
    local r = (r5 * 8) + math.floor(r5 / 4)
    local g = (g6 * 4) + math.floor(g6 / 16)
    local b = (b5 * 8) + math.floor(b5 / 4)
    return r, g, b
end

function ColorPicker:new(opts)
    opts = opts or {}
    local o = {
        title = opts.title or "Color Picker",
        r = 0,
        g = 0,
        b = 0,
        mode = "slider",
        slider_field = 1,
        palette_index = 1,
        editing = false,
        hex_buffer = "",
        allow_auto = opts.allow_auto or false,
        is_auto = opts.is_auto or false,
        on_select = opts.on_select,
    }

    -- Initialize from RGB565 color if provided
    if opts.color then
        o.r, o.g, o.b = ColorPicker.rgb565_to_888(opts.color)
    end

    setmetatable(o, {__index = ColorPicker})
    return o
end

function ColorPicker:get_rgb565()
    return ColorPicker.rgb_to_565(self.r, self.g, self.b)
end

function ColorPicker:get_hex_string()
    return string.format("#%02X%02X%02X", self.r, self.g, self.b)
end

function ColorPicker:parse_hex(hex)
    -- Remove # if present
    hex = hex:gsub("^#", "")
    if #hex ~= 6 then return false end

    local r = tonumber(hex:sub(1, 2), 16)
    local g = tonumber(hex:sub(3, 4), 16)
    local b = tonumber(hex:sub(5, 6), 16)

    if r and g and b then
        self.r = r
        self.g = g
        self.b = b
        return true
    end
    return false
end

function ColorPicker:set_from_rgb565(color)
    self.r, self.g, self.b = ColorPicker.rgb565_to_888(color)
    self.is_auto = false
end

function ColorPicker:render(display)
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    local start_y = 28
    local row_height = 22
    local label_x = 8
    local slider_x = 38
    local slider_w = 120
    local value_x = slider_x + slider_w + 6

    -- Color preview (top right)
    local preview_x = w - 55
    local preview_y = start_y
    local preview_w = 48
    local preview_h = 48
    local preview_color = self:get_rgb565()
    display.fill_rect(preview_x, preview_y, preview_w, preview_h, preview_color)
    display.draw_rect(preview_x - 1, preview_y - 1, preview_w + 2, preview_h + 2, colors.TEXT_SECONDARY)

    -- RGB sliders
    local sliders = {
        {label = "R", value = self.r, color = 0xF800},
        {label = "G", value = self.g, color = 0x07E0},
        {label = "B", value = self.b, color = 0x001F},
    }

    local in_slider_mode = (self.mode == "slider")

    for i, slider in ipairs(sliders) do
        local y = start_y + (i - 1) * row_height
        local is_selected = in_slider_mode and (self.slider_field == i)

        -- Selection highlight
        if is_selected then
            local outline_color = self.editing and colors.WARNING or colors.ACCENT
            display.draw_rect(label_x - 2, y - 2, slider_x + slider_w + 40, row_height - 2, outline_color)
        end

        -- Label
        local label_color = is_selected and colors.ACCENT or colors.TEXT
        display.draw_text(label_x, y, slider.label, label_color)

        -- Slider track
        display.fill_rect(slider_x, y + 3, slider_w, 8, colors.SURFACE)

        -- Slider fill
        local fill_w = math.floor(slider.value * slider_w / 255)
        display.fill_rect(slider_x, y + 3, fill_w, 8, slider.color)

        -- Value
        local value_str = tostring(slider.value)
        display.draw_text(value_x, y, value_str, colors.TEXT)
    end

    -- Hex row
    local hex_y = start_y + 3 * row_height
    local is_hex_selected = in_slider_mode and (self.slider_field == 4)

    if is_hex_selected then
        local outline_color = self.editing and colors.WARNING or colors.ACCENT
        display.draw_rect(label_x - 2, hex_y - 2, 160, row_height - 2, outline_color)
    end

    display.draw_text(label_x, hex_y, "Hex", is_hex_selected and colors.ACCENT or colors.TEXT)
    local hex_str = self.editing and is_hex_selected and ("#" .. self.hex_buffer .. "_") or self:get_hex_string()
    display.draw_text(slider_x, hex_y, hex_str, colors.TEXT)

    -- Auto option (if enabled)
    local auto_y = hex_y
    if self.allow_auto then
        auto_y = start_y + 4 * row_height
        local is_auto_selected = in_slider_mode and (self.slider_field == 5)

        if is_auto_selected then
            display.draw_rect(label_x - 2, auto_y - 2, 100, row_height - 2, colors.ACCENT)
        end

        local auto_value = self.is_auto and "[X] Auto" or "[ ] Auto"
        display.draw_text(label_x, auto_y, auto_value, is_auto_selected and colors.ACCENT or colors.TEXT)
    end

    -- Theme color palette section
    local palette_y = auto_y + row_height + 6
    local swatch_size = 20
    local swatch_spacing = 4
    local swatches_per_row = 5

    display.set_font_size("small")
    display.draw_text(label_x, palette_y, "Theme Colors:", colors.TEXT_SECONDARY)
    palette_y = palette_y + 14

    for i, color_name in ipairs(self.PALETTE_COLORS) do
        local row = math.floor((i - 1) / swatches_per_row)
        local col = (i - 1) % swatches_per_row
        local sx = label_x + col * (swatch_size + swatch_spacing)
        local sy = palette_y + row * (swatch_size + swatch_spacing)

        local swatch_color = colors[color_name] or 0x0000
        local is_selected = (self.mode == "palette") and (self.palette_index == i)

        -- Draw swatch
        display.fill_rect(sx, sy, swatch_size, swatch_size, swatch_color)

        -- Selection border
        if is_selected then
            display.draw_rect(sx - 2, sy - 2, swatch_size + 4, swatch_size + 4, colors.ACCENT)
        else
            display.draw_rect(sx, sy, swatch_size, swatch_size, colors.TEXT_SECONDARY)
        end
    end

    -- Mode indicator
    display.set_font_size("small")
    local mode_y = h - 20
    local mode_text = self.mode == "slider" and "TAB: Palette" or "TAB: Sliders"
    display.draw_text(label_x, mode_y, mode_text, colors.TEXT_SECONDARY)
    display.draw_text(w - 80, mode_y, "S: Apply", colors.ACCENT)
end

function ColorPicker:handle_key(key)
    ScreenManager.invalidate()

    -- Exit keys (always work)
    if key.special == "ESCAPE" or key.special == "BACKSPACE" then
        if self.editing then
            self.editing = false
            self.hex_buffer = ""
        else
            return "pop"
        end
        return "continue"
    end

    -- Hex editing mode
    if self.editing and self.slider_field == 4 then
        if key.special == "ENTER" then
            if #self.hex_buffer == 6 then
                if self:parse_hex(self.hex_buffer) then
                    self.is_auto = false
                end
            end
            self.editing = false
            self.hex_buffer = ""
        elseif key.character then
            local c = key.character:upper()
            if c:match("[0-9A-F]") and #self.hex_buffer < 6 then
                self.hex_buffer = self.hex_buffer .. c
            end
        end
        return "continue"
    end

    -- RGB slider editing mode
    if self.editing and self.slider_field >= 1 and self.slider_field <= 3 then
        local step = key.shift and 16 or 1
        if key.special == "LEFT" then
            self:adjust_rgb(-step)
        elseif key.special == "RIGHT" then
            self:adjust_rgb(step)
        elseif key.special == "ENTER" then
            self.editing = false
        end
        return "continue"
    end

    -- Tab to switch modes
    if key.special == "TAB" or key.character == "\t" then
        if self.mode == "slider" then
            self.mode = "palette"
        else
            self.mode = "slider"
        end
        return "continue"
    end

    -- Save and exit
    if key.character == "s" or key.character == "S" then
        if self.on_select then
            self.on_select(self:get_rgb565(), self.is_auto)
        end
        return "pop"
    end

    -- Mode-specific navigation
    if self.mode == "slider" then
        return self:handle_slider_key(key)
    else
        return self:handle_palette_key(key)
    end
end

function ColorPicker:handle_slider_key(key)
    local max_field = self.allow_auto and 5 or 4

    if key.special == "UP" then
        self.slider_field = self.slider_field - 1
        if self.slider_field < 1 then
            self.mode = "palette"
            self.palette_index = 1
        end
    elseif key.special == "DOWN" then
        self.slider_field = self.slider_field + 1
        if self.slider_field > max_field then
            self.mode = "palette"
            self.palette_index = 1
        end
    elseif key.special == "LEFT" then
        if self.slider_field >= 1 and self.slider_field <= 3 then
            self:adjust_rgb(-1)
            self.is_auto = false
        end
    elseif key.special == "RIGHT" then
        if self.slider_field >= 1 and self.slider_field <= 3 then
            self:adjust_rgb(1)
            self.is_auto = false
        end
    elseif key.special == "ENTER" then
        if self.slider_field == 5 then
            self.is_auto = not self.is_auto
        elseif self.slider_field == 4 then
            self.editing = true
            self.hex_buffer = ""
        else
            self.editing = true
        end
    end

    return "continue"
end

function ColorPicker:handle_palette_key(key)
    local count = #self.PALETTE_COLORS
    local cols = 5

    if key.special == "UP" then
        if self.palette_index <= cols then
            -- Go back to slider mode
            self.mode = "slider"
            self.slider_field = self.allow_auto and 5 or 4
        else
            self.palette_index = self.palette_index - cols
        end
    elseif key.special == "DOWN" then
        if self.palette_index + cols <= count then
            self.palette_index = self.palette_index + cols
        end
    elseif key.special == "LEFT" then
        if self.palette_index > 1 then
            self.palette_index = self.palette_index - 1
        end
    elseif key.special == "RIGHT" then
        if self.palette_index < count then
            self.palette_index = self.palette_index + 1
        end
    elseif key.special == "ENTER" then
        -- Select this theme color
        local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or {}
        local color_name = self.PALETTE_COLORS[self.palette_index]
        local color = colors[color_name]
        if color then
            self:set_from_rgb565(color)
        end
    end

    return "continue"
end

function ColorPicker:adjust_rgb(delta)
    if self.slider_field == 1 then
        self.r = math.max(0, math.min(255, self.r + delta))
    elseif self.slider_field == 2 then
        self.g = math.max(0, math.min(255, self.g + delta))
    elseif self.slider_field == 3 then
        self.b = math.max(0, math.min(255, self.b + delta))
    end
end

-- Menu items for app menu integration
function ColorPicker:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = "Apply",
        action = function()
            if self_ref.on_select then
                self_ref.on_select(self_ref:get_rgb565(), self_ref.is_auto)
            end
            ScreenManager.pop()
        end
    })

    table.insert(items, {
        label = "Cancel",
        action = function()
            ScreenManager.pop()
        end
    })

    if self.allow_auto then
        table.insert(items, {
            label = self.is_auto and "Manual" or "Auto",
            action = function()
                self_ref.is_auto = not self_ref.is_auto
                ScreenManager.invalidate()
            end
        })
    end

    return items
end

return ColorPicker
