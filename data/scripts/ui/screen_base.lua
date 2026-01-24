-- Screen Base Class for T-Deck OS
-- Provides default implementations and helper methods for Lua screens

local ScreenBase = {}
ScreenBase.__index = ScreenBase

-- Constructor: create a new screen instance
function ScreenBase:new(config)
    config = config or {}
    local instance = setmetatable({
        title = config.title or "Screen",
        _needsRedraw = true
    }, self)
    return instance
end

-- Lifecycle methods (override in subclass)
function ScreenBase:on_enter()
    self:invalidate()
end

function ScreenBase:on_exit()
end

function ScreenBase:on_refresh()
end

-- Rendering (override in subclass)
function ScreenBase:render(display)
    -- Default: draw title box
    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, display.colors.BORDER, display.colors.CYAN)
end

-- Input handling (override in subclass)
-- Return "continue", "pop", "push", "replace", or "exit"
function ScreenBase:handle_key(key)
    if key.special == "ESCAPE" then
        return "pop"
    end
    return "continue"
end

-- Get screen title
function ScreenBase:get_title()
    return self.title
end

-- Mark screen for redraw
function ScreenBase:invalidate()
    self._needsRedraw = true
    tdeck.screen.invalidate()
end

-- Helper: draw centered text
function ScreenBase:draw_centered(display, y, text, color)
    color = color or display.colors.TEXT
    display.draw_text_centered(y, text, color)
end

-- Helper: draw a menu list with selection
function ScreenBase:draw_menu(display, items, selected, start_row)
    start_row = start_row or 2
    local colors = display.colors

    for i, item in ipairs(items) do
        local y = (start_row + i - 1) * display.font_height
        local is_selected = (i == selected)

        if is_selected then
            -- Draw selection highlight
            display.fill_rect(display.font_width, y,
                            (display.cols - 2) * display.font_width,
                            display.font_height,
                            colors.SELECTION)
            display.draw_text(display.font_width, y, ">", colors.CYAN)
        end

        local text_color = is_selected and colors.CYAN or colors.TEXT
        local label = type(item) == "table" and item.label or item
        display.draw_text(3 * display.font_width, y, label, text_color)
    end
end

-- Helper: handle menu navigation
-- Returns new selected index, or nil if key wasn't navigation
function ScreenBase:handle_menu_nav(key, selected, item_count)
    if key.special == "UP" then
        local new_sel = selected - 1
        if new_sel < 1 then new_sel = item_count end
        return new_sel
    elseif key.special == "DOWN" then
        local new_sel = selected + 1
        if new_sel > item_count then new_sel = 1 end
        return new_sel
    end
    return nil
end

-- Helper: push a new screen
function ScreenBase:push_screen(screen)
    tdeck.screen.push(screen)
end

-- Helper: replace current screen
function ScreenBase:replace_screen(screen)
    tdeck.screen.replace(screen)
end

-- Create a subclass of ScreenBase
function ScreenBase:extend()
    local cls = {}
    cls.__index = cls
    setmetatable(cls, {__index = self})

    function cls:new(config)
        local instance = ScreenBase.new(self, config)
        setmetatable(instance, cls)
        return instance
    end

    return cls
end

return ScreenBase
