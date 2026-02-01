-- Button: Clickable button component

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local Button = {}
Button.__index = Button

function Button:new(opts)
    opts = opts or {}
    local o = {
        label = opts.label or "Button",
        width = opts.width,
        disabled = opts.disabled or false,
        on_press = opts.on_press,
    }
    setmetatable(o, Button)
    return o
end

function Button:render(display, x, y, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local fw = display.get_font_width()

    local width = self.width or (#self.label * fw + 12)
    local height = fh + 6

    -- Background
    local bg_color
    if self.disabled then
        bg_color = colors.SURFACE
    elseif focused then
        bg_color = colors.SURFACE_ALT
    else
        bg_color = colors.SURFACE
    end
    display.fill_rect(x, y, width, height, bg_color)

    -- Border
    local border_color = focused and colors.ACCENT or colors.TEXT_SECONDARY
    if self.disabled then
        border_color = colors.SURFACE
    end
    display.draw_rect(x, y, width, height, border_color)

    -- Label centered
    local text_color = self.disabled and colors.TEXT_SECONDARY or (focused and colors.ACCENT or colors.TEXT)
    local text_x = x + math.floor((width - #self.label * fw) / 2)
    local text_y = y + 3
    display.draw_text(text_x, text_y, self.label, text_color)

    return width, height
end

function Button:handle_key(key)
    if self.disabled then return nil end

    if key.special == "ENTER" then
        if self.on_press then
            self.on_press()
        end
        return "pressed"
    end
    return nil
end

return Button
