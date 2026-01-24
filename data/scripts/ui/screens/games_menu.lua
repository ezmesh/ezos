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
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1, self.title, colors.CYAN, colors.WHITE)

    local start_y = 3
    for i, item in ipairs(self.items) do
        local y = (start_y + i - 1) * display.font_height
        local is_selected = (i == self.selected)

        if is_selected then
            display.fill_rect(display.font_width, y,
                            (display.cols - 2) * display.font_width,
                            display.font_height, colors.SELECTION)
            display.draw_text(2 * display.font_width, y, ">", colors.CYAN)
        end

        local text_color = is_selected and colors.CYAN or colors.TEXT
        display.draw_text(4 * display.font_width, y, item.label, text_color)
        display.draw_text(15 * display.font_width, y, item.description, colors.TEXT_DIM)
    end

    local help_y = (display.rows - 2) * display.font_height
    display.draw_text_centered(help_y, "[Enter] Play  [Esc] Back", colors.TEXT_DIM)
end

function GamesMenu:handle_key(key)
    if key.special == "UP" then
        self.selected = self.selected - 1
        if self.selected < 1 then self.selected = #self.items end
        tdeck.screen.invalidate()
    elseif key.special == "DOWN" then
        self.selected = self.selected + 1
        if self.selected > #self.items then self.selected = 1 end
        tdeck.screen.invalidate()
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
        local Game = dofile("/scripts/ui/screens/snake.lua")
        tdeck.screen.push(Game:new())
    elseif item.label == "Tetris" then
        local Game = dofile("/scripts/ui/screens/tetris.lua")
        tdeck.screen.push(Game:new())
    elseif item.label == "Breakout" then
        local Game = dofile("/scripts/ui/screens/breakout.lua")
        tdeck.screen.push(Game:new())
    end
end

return GamesMenu
