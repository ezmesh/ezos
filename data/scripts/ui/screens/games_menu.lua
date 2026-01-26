-- Games Menu Screen
-- Lists available games

local GamesMenu = {
    title = "Games",
    selected = 1,
    items = {
        {label = "Snake",    description = "Classic snake game"},
        {label = "Tetris",   description = "Falling blocks"},
        {label = "Breakout", description = "Break the bricks"},
    }
}

function GamesMenu:new()
    local o = {
        title = self.title,
        selected = 1,
        items = {}
    }
    for i, item in ipairs(self.items) do
        o.items[i] = {label = item.label, description = item.description}
    end
    setmetatable(o, {__index = GamesMenu})
    return o
end

function GamesMenu:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    local start_y = 3
    for i, item in ipairs(self.items) do
        local y = (start_y + i - 1) * fh
        local is_selected = (i == self.selected)

        if is_selected then
            display.fill_rect(fw, y, (display.cols - 2) * fw, fh, colors.SELECTION)
            display.draw_text(2 * fw, y, ">", colors.CYAN)
        end

        local text_color = is_selected and colors.CYAN or colors.TEXT
        display.draw_text(4 * fw, y, item.label, text_color)
        display.draw_text(15 * fw, y, item.description, colors.TEXT_DIM)
    end
end

function GamesMenu:handle_key(key)
    if key.special == "UP" then
        self.selected = self.selected - 1
        if self.selected < 1 then self.selected = #self.items end
        ScreenManager.invalidate()
    elseif key.special == "DOWN" then
        self.selected = self.selected + 1
        if self.selected > #self.items then self.selected = 1 end
        ScreenManager.invalidate()
    elseif key.special == "ENTER" then
        self:launch_game()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end
    return "continue"
end

function GamesMenu:launch_game()
    local item = self.items[self.selected]
    if item.label == "Snake" then
        local Game = load_module("/scripts/ui/screens/snake.lua")
        ScreenManager.push(Game:new())
    elseif item.label == "Tetris" then
        local Game = load_module("/scripts/ui/screens/tetris.lua")
        ScreenManager.push(Game:new())
    elseif item.label == "Breakout" then
        local Game = load_module("/scripts/ui/screens/breakout.lua")
        ScreenManager.push(Game:new())
    end
end

-- Menu items for app menu integration
function GamesMenu:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = "Play",
        action = function()
            self_ref:launch_game()
        end
    })

    return items
end

return GamesMenu
