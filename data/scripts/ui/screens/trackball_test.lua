-- Trackball Test Screen for T-Deck OS
-- Visualizes trackball movement as a colored trail

local TrackballTest = {
    title = "Trackball Test",

    -- Screen dimensions
    SCREEN_W = 320,
    SCREEN_H = 240,

    -- Drawing area (leave space for title bar)
    DRAW_Y = 20,

    -- Trail settings
    MAX_POINTS = 500,

    -- Color gradient (rainbow spectrum in RGB565)
    COLORS = {
        0xF800,  -- Red
        0xFC00,  -- Orange
        0xFFE0,  -- Yellow
        0x07E0,  -- Green
        0x07FF,  -- Cyan
        0x001F,  -- Blue
        0x781F,  -- Purple
        0xF81F,  -- Magenta
    }
}

function TrackballTest:new()
    local o = {
        title = self.title,
        -- Current position (start at center)
        x = self.SCREEN_W / 2,
        y = (self.SCREEN_H + self.DRAW_Y) / 2,
        -- Trail of points: array of {x, y}
        points = {},
        -- Movement speed (pixels per trackball tick)
        speed = 2,
    }
    setmetatable(o, {__index = TrackballTest})
    return o
end

function TrackballTest:reset()
    self.x = self.SCREEN_W / 2
    self.y = (self.SCREEN_H + self.DRAW_Y) / 2
    self.points = {}
    ScreenManager.invalidate()
end

function TrackballTest:get_color(index)
    -- Cycle through colors based on point index
    local color_idx = (index % #self.COLORS) + 1
    return self.COLORS[color_idx]
end

function TrackballTest:add_point(x, y)
    table.insert(self.points, {x = x, y = y})

    -- Cap the array size
    while #self.points > self.MAX_POINTS do
        table.remove(self.points, 1)
    end
end

function TrackballTest:move(dx, dy)
    -- Calculate new position with wrapping
    local new_x = self.x + dx * self.speed
    local new_y = self.y + dy * self.speed

    -- Wrap around edges
    if new_x < 0 then new_x = self.SCREEN_W + new_x end
    if new_x >= self.SCREEN_W then new_x = new_x - self.SCREEN_W end
    if new_y < self.DRAW_Y then new_y = self.SCREEN_H + (new_y - self.DRAW_Y) end
    if new_y >= self.SCREEN_H then new_y = self.DRAW_Y + (new_y - self.SCREEN_H) end

    -- Add current position to trail before moving
    self:add_point(self.x, self.y)

    self.x = new_x
    self.y = new_y

    ScreenManager.invalidate()
end

function TrackballTest:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Clear background
    display.fill_rect(0, 0, self.SCREEN_W, self.SCREEN_H, colors.BLACK)

    -- Draw title bar area
    display.fill_rect(0, 0, self.SCREEN_W, self.DRAW_Y, colors.BLACK)
    display.set_font_size("small")
    display.draw_text(4, 2, self.title, colors.ACCENT)

    -- Draw point count and position info
    local info = string.format("Pts:%d  X:%.0f Y:%.0f  [R]eset [Q]uit", #self.points, self.x, self.y)
    local info_width = display.text_width(info)
    display.draw_text(self.SCREEN_W - info_width - 4, 2, info, colors.TEXT_SECONDARY)

    -- Draw separator line
    display.draw_line(0, self.DRAW_Y - 1, self.SCREEN_W, self.DRAW_Y - 1, colors.SURFACE)

    -- Draw trail as connected lines with gradient colors
    if #self.points > 1 then
        for i = 2, #self.points do
            local p1 = self.points[i - 1]
            local p2 = self.points[i]
            local color = self:get_color(i)

            -- Check for wrap-around (don't draw line across screen)
            local dx = math.abs(p2.x - p1.x)
            local dy = math.abs(p2.y - p1.y)

            if dx < self.SCREEN_W / 2 and dy < self.SCREEN_H / 2 then
                display.draw_line(p1.x, p1.y, p2.x, p2.y, color)
            end
        end

        -- Draw line from last point to current position
        local last = self.points[#self.points]
        local color = self:get_color(#self.points + 1)
        local dx = math.abs(self.x - last.x)
        local dy = math.abs(self.y - last.y)

        if dx < self.SCREEN_W / 2 and dy < self.SCREEN_H / 2 then
            display.draw_line(last.x, last.y, self.x, self.y, color)
        end
    end

    -- Draw current position as a crosshair
    local cx, cy = math.floor(self.x), math.floor(self.y)
    local cross_size = 4
    display.draw_line(cx - cross_size, cy, cx + cross_size, cy, colors.WHITE)
    display.draw_line(cx, cy - cross_size, cx, cy + cross_size, colors.WHITE)

    -- Draw center pixel brighter
    display.fill_rect(cx - 1, cy - 1, 3, 3, colors.ACCENT)
end

function TrackballTest:handle_key(key)
    -- Handle trackball directions
    if key.special == "UP" then
        self:move(0, -1)
    elseif key.special == "DOWN" then
        self:move(0, 1)
    elseif key.special == "LEFT" then
        self:move(-1, 0)
    elseif key.special == "RIGHT" then
        self:move(1, 0)
    elseif key.special == "ENTER" then
        -- Reset on enter/click
        self:reset()
    elseif key.character == "r" or key.character == "R" then
        self:reset()
    elseif key.special == "ESCAPE" or key.character == "q" or key.character == "Q" then
        return "pop"
    end

    return "continue"
end

-- Menu items for app menu integration
function TrackballTest:get_menu_items()
    local self_ref = self
    return {
        {
            label = "Reset",
            action = function()
                self_ref:reset()
            end
        }
    }
end

return TrackballTest
