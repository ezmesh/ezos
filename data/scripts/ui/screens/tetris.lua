-- Tetris Game for T-Deck OS

local Tetris = {
    title = "Tetris",
    -- Game board: 10 wide, 20 tall
    BOARD_W = 10,
    BOARD_H = 20,
    CELL_SIZE = 10,
}

-- Tetromino shapes (each rotation)
local PIECES = {
    -- I piece
    {color = 0x07FF, shapes = {
        {{0,1},{1,1},{2,1},{3,1}},
        {{2,0},{2,1},{2,2},{2,3}},
    }},
    -- O piece
    {color = 0xFFE0, shapes = {
        {{0,0},{1,0},{0,1},{1,1}},
    }},
    -- T piece
    {color = 0xF81F, shapes = {
        {{1,0},{0,1},{1,1},{2,1}},
        {{1,0},{1,1},{2,1},{1,2}},
        {{0,1},{1,1},{2,1},{1,2}},
        {{1,0},{0,1},{1,1},{1,2}},
    }},
    -- S piece
    {color = 0x07E0, shapes = {
        {{1,0},{2,0},{0,1},{1,1}},
        {{1,0},{1,1},{2,1},{2,2}},
    }},
    -- Z piece
    {color = 0xF800, shapes = {
        {{0,0},{1,0},{1,1},{2,1}},
        {{2,0},{1,1},{2,1},{1,2}},
    }},
    -- J piece
    {color = 0x001F, shapes = {
        {{0,0},{0,1},{1,1},{2,1}},
        {{1,0},{2,0},{1,1},{1,2}},
        {{0,1},{1,1},{2,1},{2,2}},
        {{1,0},{1,1},{0,2},{1,2}},
    }},
    -- L piece
    {color = 0xFD20, shapes = {
        {{2,0},{0,1},{1,1},{2,1}},
        {{1,0},{1,1},{1,2},{2,2}},
        {{0,1},{1,1},{2,1},{0,2}},
        {{0,0},{1,0},{1,1},{1,2}},
    }},
}

function Tetris:new()
    local o = {
        board = {},
        current_piece = nil,
        piece_x = 0,
        piece_y = 0,
        piece_rot = 1,
        next_piece = nil,
        score = 0,
        level = 1,
        lines = 0,
        game_over = false,
        last_drop = 0,
        drop_interval = 500,
        paused = false,
    }
    -- Initialize empty board
    for y = 1, Tetris.BOARD_H do
        o.board[y] = {}
        for x = 1, Tetris.BOARD_W do
            o.board[y][x] = 0
        end
    end
    setmetatable(o, {__index = Tetris})
    return o
end

function Tetris:on_enter()
    -- Enter game mode (disables GC, slows mesh, hides status bar)
    if _G.MainLoop then _G.MainLoop.enter_game_mode() end
    self:spawn_piece()
    self.last_drop = ez.system.millis()
end

function Tetris:on_exit()
    -- Exit game mode
    if _G.MainLoop then _G.MainLoop.exit_game_mode() end
end

function Tetris:spawn_piece()
    if self.next_piece then
        self.current_piece = self.next_piece
    else
        self.current_piece = PIECES[math.random(#PIECES)]
    end
    self.next_piece = PIECES[math.random(#PIECES)]
    self.piece_x = 4
    self.piece_y = 1
    self.piece_rot = 1

    if not self:can_move(0, 0) then
        self.game_over = true
    end
end

function Tetris:get_shape()
    local shapes = self.current_piece.shapes
    local rot = ((self.piece_rot - 1) % #shapes) + 1
    return shapes[rot]
end

function Tetris:can_move(dx, dy, new_rot)
    local shapes = self.current_piece.shapes
    local rot = new_rot or self.piece_rot
    rot = ((rot - 1) % #shapes) + 1
    local shape = shapes[rot]

    for _, cell in ipairs(shape) do
        local nx = self.piece_x + cell[1] + dx
        local ny = self.piece_y + cell[2] + dy

        if nx < 1 or nx > self.BOARD_W or ny < 1 or ny > self.BOARD_H then
            return false
        end
        if self.board[ny][nx] ~= 0 then
            return false
        end
    end
    return true
end

function Tetris:lock_piece()
    local shape = self:get_shape()
    local color = self.current_piece.color

    for _, cell in ipairs(shape) do
        local x = self.piece_x + cell[1]
        local y = self.piece_y + cell[2]
        if y >= 1 and y <= self.BOARD_H and x >= 1 and x <= self.BOARD_W then
            self.board[y][x] = color
        end
    end

    self:clear_lines()
    self:spawn_piece()
end

function Tetris:clear_lines()
    local cleared = 0
    local y = self.BOARD_H

    while y >= 1 do
        local full = true
        for x = 1, self.BOARD_W do
            if self.board[y][x] == 0 then
                full = false
                break
            end
        end

        if full then
            -- Remove line and shift down
            for yy = y, 2, -1 do
                for x = 1, self.BOARD_W do
                    self.board[yy][x] = self.board[yy-1][x]
                end
            end
            for x = 1, self.BOARD_W do
                self.board[1][x] = 0
            end
            cleared = cleared + 1
        else
            y = y - 1
        end
    end

    if cleared > 0 then
        local points = {40, 100, 300, 1200}
        self.score = self.score + (points[cleared] or 1200) * self.level
        self.lines = self.lines + cleared
        self.level = math.floor(self.lines / 10) + 1
        self.drop_interval = math.max(100, 500 - (self.level - 1) * 40)
    end
end

function Tetris:drop()
    if self:can_move(0, 1) then
        self.piece_y = self.piece_y + 1
    else
        self:lock_piece()
    end
end

function Tetris:hard_drop()
    while self:can_move(0, 1) do
        self.piece_y = self.piece_y + 1
        self.score = self.score + 2
    end
    self:lock_piece()
end

function Tetris:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, w, h, colors.BLACK)
    end

    -- Board position
    local board_x = (w - self.BOARD_W * self.CELL_SIZE) / 2
    local board_y = 10

    -- Draw border
    display.fill_rect(board_x - 2, board_y - 2,
                     self.BOARD_W * self.CELL_SIZE + 4,
                     self.BOARD_H * self.CELL_SIZE + 4, colors.SURFACE)
    display.fill_rect(board_x, board_y,
                     self.BOARD_W * self.CELL_SIZE,
                     self.BOARD_H * self.CELL_SIZE, colors.BLACK)

    -- Draw board
    for y = 1, self.BOARD_H do
        for x = 1, self.BOARD_W do
            if self.board[y][x] ~= 0 then
                local px = board_x + (x - 1) * self.CELL_SIZE
                local py = board_y + (y - 1) * self.CELL_SIZE
                display.fill_rect(px, py, self.CELL_SIZE - 1, self.CELL_SIZE - 1, self.board[y][x])
            end
        end
    end

    -- Draw current piece
    if self.current_piece and not self.game_over then
        local shape = self:get_shape()
        local color = self.current_piece.color
        for _, cell in ipairs(shape) do
            local px = board_x + (self.piece_x + cell[1] - 1) * self.CELL_SIZE
            local py = board_y + (self.piece_y + cell[2] - 1) * self.CELL_SIZE
            display.fill_rect(px, py, self.CELL_SIZE - 1, self.CELL_SIZE - 1, color)
        end
    end

    -- Score and level
    local info_x = board_x + self.BOARD_W * self.CELL_SIZE + 15
    display.draw_text(info_x, 20, "Score", colors.TEXT_SECONDARY)
    display.draw_text(info_x, 35, tostring(self.score), colors.WHITE)
    display.draw_text(info_x, 55, "Level", colors.TEXT_SECONDARY)
    display.draw_text(info_x, 70, tostring(self.level), colors.WHITE)
    display.draw_text(info_x, 90, "Lines", colors.TEXT_SECONDARY)
    display.draw_text(info_x, 105, tostring(self.lines), colors.WHITE)

    -- Next piece preview
    display.draw_text(info_x, 130, "Next", colors.TEXT_SECONDARY)
    if self.next_piece then
        local preview_y = 145
        local shape = self.next_piece.shapes[1]
        for _, cell in ipairs(shape) do
            local px = info_x + cell[1] * 8
            local py = preview_y + cell[2] * 8
            display.fill_rect(px, py, 7, 7, self.next_piece.color)
        end
    end

    if self.game_over then
        display.draw_text_centered(h / 2 - 10, "GAME OVER", colors.ERROR)
        display.draw_text_centered(h / 2 + 10, "[Enter] Restart", colors.TEXT_SECONDARY)
    elseif self.paused then
        display.draw_text_centered(h / 2, "PAUSED", colors.WARNING)
    end

    local help_y = h - 15
    display.draw_text(5, help_y, "[Arrows] Move  [Space] Drop  [Q] Quit", colors.TEXT_SECONDARY)
end

function Tetris:handle_key(key)
    if self.game_over then
        if key.special == "ENTER" then
            -- Clean up before restart
            run_gc("collect", "tetris-restart")
            -- Restart
            for y = 1, self.BOARD_H do
                for x = 1, self.BOARD_W do
                    self.board[y][x] = 0
                end
            end
            self.score = 0
            self.level = 1
            self.lines = 0
            self.game_over = false
            self.drop_interval = 500
            self:spawn_piece()
        elseif key.special == "ESCAPE" or key.character == "q" then
            self:on_exit()
            return "pop"
        end
        ScreenManager.invalidate()
        return "continue"
    end

    if key.character == "p" then
        self.paused = not self.paused
        ScreenManager.invalidate()
        return "continue"
    end

    if self.paused then
        ScreenManager.invalidate()
        return "continue"
    end

    if key.special == "LEFT" then
        if self:can_move(-1, 0) then
            self.piece_x = self.piece_x - 1
        end
    elseif key.special == "RIGHT" then
        if self:can_move(1, 0) then
            self.piece_x = self.piece_x + 1
        end
    elseif key.special == "DOWN" then
        self:drop()
        self.score = self.score + 1
    elseif key.special == "UP" then
        -- Rotate
        if self:can_move(0, 0, self.piece_rot + 1) then
            self.piece_rot = self.piece_rot + 1
        end
    elseif key.character == " " then
        self:hard_drop()
    elseif key.special == "ESCAPE" or key.character == "q" then
        self:on_exit()
        return "pop"
    end

    ScreenManager.invalidate()
    return "continue"
end

function Tetris:update()
    if self.game_over or self.paused then return end

    local now = ez.system.millis()
    if now - self.last_drop >= self.drop_interval then
        self:drop()
        self.last_drop = now
        ScreenManager.invalidate()
    end
end

return Tetris
