-- Solitaire (Klondike) for T-Deck OS
-- Classic card game using shared Cards module

local ListMixin = load_module("/scripts/ui/list_mixin.lua")
local Cards = load_module("/scripts/ui/cards.lua")

local Solitaire = {
    title = "Solitaire",
    CARD_W = 26,
    CARD_H = 36,
    STACK_OFFSET = 12,
}

function Solitaire:new()
    local o = {
        stock = {},       -- Draw pile
        waste = {},       -- Discard pile
        foundations = {{}, {}, {}, {}},  -- 4 foundation piles (A-K)
        tableau = {{}, {}, {}, {}, {}, {}, {}},  -- 7 tableau columns
        selected = nil,   -- {source, index, cards}
        cursor = {area = "tableau", col = 1, row = 1},
        moves = 0,
        won = false,
    }
    setmetatable(o, {__index = Solitaire})
    return o
end

function Solitaire:on_enter()
    if _G.MainLoop then _G.MainLoop.enter_game_mode() end
    self:new_game()
end

function Solitaire:on_exit()
    if _G.MainLoop then _G.MainLoop.exit_game_mode() end
end

function Solitaire:create_deck()
    local deck = Cards.new_deck()
    Cards.shuffle(deck)
    return deck
end

function Solitaire:new_game()
    local deck = self:create_deck()

    self.stock = {}
    self.waste = {}
    self.foundations = {{}, {}, {}, {}}
    self.tableau = {{}, {}, {}, {}, {}, {}, {}}
    self.selected = nil
    self.cursor = {area = "tableau", col = 1, row = 1}
    self.moves = 0
    self.won = false

    -- Deal to tableau
    for col = 1, 7 do
        for row = 1, col do
            local card = table.remove(deck)
            card.face_up = (row == col)
            table.insert(self.tableau[col], card)
        end
    end

    -- Rest goes to stock
    self.stock = deck
end

function Solitaire:draw_from_stock()
    if #self.stock == 0 then
        -- Flip waste back to stock
        while #self.waste > 0 do
            local card = table.remove(self.waste)
            card.face_up = false
            table.insert(self.stock, card)
        end
    else
        local card = table.remove(self.stock)
        card.face_up = true
        table.insert(self.waste, card)
        self.moves = self.moves + 1
    end
end

function Solitaire:can_place_on_tableau(card, target_col)
    local target = self.tableau[target_col]
    if #target == 0 then
        return card.value == 13  -- Only Kings on empty
    end
    local top = target[#target]
    -- Different color and one less value
    local card_is_red = (card.suit == 1 or card.suit == 2)
    local top_is_red = (top.suit == 1 or top.suit == 2)
    return top.face_up and
           card_is_red ~= top_is_red and
           card.value == top.value - 1
end

function Solitaire:can_place_on_foundation(card, foundation_idx)
    local foundation = self.foundations[foundation_idx]
    if #foundation == 0 then
        return card.value == 1  -- Only Aces
    end
    local top = foundation[#foundation]
    return card.suit == top.suit and
           card.value == top.value + 1
end

function Solitaire:try_auto_foundation(card, source, source_idx)
    for f = 1, 4 do
        if self:can_place_on_foundation(card, f) then
            -- Move card
            if source == "waste" then
                table.remove(self.waste)
            elseif source == "tableau" then
                table.remove(self.tableau[source_idx])
                -- Flip new top card
                local col = self.tableau[source_idx]
                if #col > 0 and not col[#col].face_up then
                    col[#col].face_up = true
                end
            end
            table.insert(self.foundations[f], card)
            self.moves = self.moves + 1
            self:check_win()
            return true
        end
    end
    return false
end

function Solitaire:check_win()
    local total = 0
    for _, f in ipairs(self.foundations) do
        total = total + #f
    end
    self.won = (total == 52)
end

function Solitaire:get_card_at_cursor()
    if self.cursor.area == "stock" then
        return nil, "stock", 0
    elseif self.cursor.area == "waste" and #self.waste > 0 then
        return self.waste[#self.waste], "waste", 0
    elseif self.cursor.area == "foundation" then
        local f = self.foundations[self.cursor.col]
        if #f > 0 then
            return f[#f], "foundation", self.cursor.col
        end
    elseif self.cursor.area == "tableau" then
        local col = self.tableau[self.cursor.col]
        if self.cursor.row <= #col and col[self.cursor.row].face_up then
            return col[self.cursor.row], "tableau", self.cursor.col
        end
    end
    return nil, nil, 0
end

function Solitaire:do_select()
    if self.cursor.area == "stock" then
        self:draw_from_stock()
        return
    end

    local card, source, idx = self:get_card_at_cursor()

    if self.selected then
        -- Try to place selected cards
        local can_place = false

        if self.cursor.area == "tableau" then
            can_place = self:can_place_on_tableau(self.selected.cards[1], self.cursor.col)
            if can_place then
                for _, c in ipairs(self.selected.cards) do
                    table.insert(self.tableau[self.cursor.col], c)
                end
            end
        elseif self.cursor.area == "foundation" and #self.selected.cards == 1 then
            can_place = self:can_place_on_foundation(self.selected.cards[1], self.cursor.col)
            if can_place then
                table.insert(self.foundations[self.cursor.col], self.selected.cards[1])
            end
        end

        if can_place then
            -- Remove from source
            if self.selected.source == "waste" then
                table.remove(self.waste)
            elseif self.selected.source == "tableau" then
                for _ = 1, #self.selected.cards do
                    table.remove(self.tableau[self.selected.idx])
                end
                -- Flip new top
                local col = self.tableau[self.selected.idx]
                if #col > 0 and not col[#col].face_up then
                    col[#col].face_up = true
                end
            end
            self.moves = self.moves + 1
            self:check_win()
        end

        self.selected = nil
    else
        -- Select cards (only if there's a card to select)
        if not card then return end

        -- Try auto-move to foundation first (single cards only)
        if source == "waste" or (source == "tableau" and self.cursor.row == #self.tableau[idx]) then
            if self:try_auto_foundation(card, source, idx) then
                return  -- Card was moved to foundation
            end
        end

        -- Try auto-move Kings to empty tableau columns
        if card.value == 13 then
            for col = 1, 7 do
                if #self.tableau[col] == 0 then
                    -- Move King (and any cards below it) to empty column
                    if source == "waste" then
                        table.remove(self.waste)
                        table.insert(self.tableau[col], card)
                    elseif source == "tableau" then
                        -- Move King and all cards on top of it
                        local cards_to_move = {}
                        for i = self.cursor.row, #self.tableau[idx] do
                            table.insert(cards_to_move, self.tableau[idx][i])
                        end
                        for _ = 1, #cards_to_move do
                            table.remove(self.tableau[idx])
                        end
                        for _, c in ipairs(cards_to_move) do
                            table.insert(self.tableau[col], c)
                        end
                        -- Flip new top card in source column
                        if #self.tableau[idx] > 0 and not self.tableau[idx][#self.tableau[idx]].face_up then
                            self.tableau[idx][#self.tableau[idx]].face_up = true
                        end
                    end
                    self.moves = self.moves + 1
                    return  -- Card was moved
                end
            end
        end

        -- No auto-move possible, select the card(s)
        if source == "waste" then
            self.selected = {source = "waste", idx = 0, cards = {card}}
        elseif source == "tableau" then
            local cards = {}
            for i = self.cursor.row, #self.tableau[idx] do
                table.insert(cards, self.tableau[idx][i])
            end
            self.selected = {source = "tableau", idx = idx, cards = cards}
        end
    end
end

function Solitaire:do_auto_move()
    local card, source, idx = self:get_card_at_cursor()
    if card then
        self:try_auto_foundation(card, source, idx)
    end
end

function Solitaire:render(display)
    local colors = ListMixin.get_colors(display)

    display.fill_rect(0, 0, 320, 240, 0x0320)

    display.set_font_size("small")
    display.draw_text(5, 2, string.format("Moves: %d", self.moves), colors.WHITE)

    local stock_x, stock_y = 5, 18
    local waste_x = stock_x + self.CARD_W + 5
    local found_x = 145

    -- Stock
    if #self.stock > 0 then
        Cards.draw_face_down(display, stock_x, stock_y, self.CARD_W, self.CARD_H)
    else
        Cards.draw_empty_slot(display, stock_x, stock_y, self.CARD_W, self.CARD_H)
    end
    if self.cursor.area == "stock" then
        display.draw_rect(stock_x - 1, stock_y - 1, self.CARD_W + 2, self.CARD_H + 2, colors.ACCENT)
    end

    -- Waste
    if #self.waste > 0 then
        Cards.draw_face_up(display, self.waste[#self.waste], waste_x, stock_y, self.CARD_W, self.CARD_H)
        -- Show green selection indicator when waste card is selected
        if self.selected and self.selected.source == "waste" then
            display.draw_rect(waste_x, stock_y, self.CARD_W, self.CARD_H, colors.SUCCESS)
        end
    else
        Cards.draw_empty_slot(display, waste_x, stock_y, self.CARD_W, self.CARD_H)
    end
    if self.cursor.area == "waste" then
        display.draw_rect(waste_x - 1, stock_y - 1, self.CARD_W + 2, self.CARD_H + 2, colors.ACCENT)
    end

    -- Foundations
    for f = 1, 4 do
        local fx = found_x + (f - 1) * (self.CARD_W + 5)
        if #self.foundations[f] > 0 then
            Cards.draw_face_up(display, self.foundations[f][#self.foundations[f]], fx, stock_y, self.CARD_W, self.CARD_H)
        else
            Cards.draw_empty_slot(display, fx, stock_y, self.CARD_W, self.CARD_H)
            -- Draw suit hint
            Cards.draw_suit(display, f, fx + 8, stock_y + 12, 10, 0x4208)
        end
        if self.cursor.area == "foundation" and self.cursor.col == f then
            display.draw_rect(fx - 1, stock_y - 1, self.CARD_W + 2, self.CARD_H + 2, colors.ACCENT)
        end
    end

    -- Tableau
    local tab_y = 62
    local tab_spacing = 44
    for col = 1, 7 do
        local tx = 5 + (col - 1) * tab_spacing
        if #self.tableau[col] == 0 then
            Cards.draw_empty_slot(display, tx, tab_y, self.CARD_W, self.CARD_H)
            if self.cursor.area == "tableau" and self.cursor.col == col then
                display.draw_rect(tx - 1, tab_y - 1, self.CARD_W + 2, self.CARD_H + 2, colors.ACCENT)
            end
        else
            for row, card in ipairs(self.tableau[col]) do
                local cy = tab_y + (row - 1) * self.STACK_OFFSET
                local is_cursor = (self.cursor.area == "tableau" and
                                   self.cursor.col == col and
                                   self.cursor.row == row)
                local is_selected = (self.selected and
                                     self.selected.source == "tableau" and
                                     self.selected.idx == col and
                                     row >= #self.tableau[col] - #self.selected.cards + 1)

                Cards.draw(display, card, tx, cy, self.CARD_W, self.CARD_H)

                if is_selected then
                    display.draw_rect(tx, cy, self.CARD_W, self.CARD_H, colors.SUCCESS)
                elseif is_cursor then
                    display.draw_rect(tx - 1, cy - 1, self.CARD_W + 2, self.CARD_H + 2, colors.ACCENT)
                end
            end
        end
    end

    -- Win message
    if self.won then
        display.fill_rect(60, 90, 200, 50, 0x0000)
        display.draw_text_centered(100, "You Win!", colors.SUCCESS)
        display.draw_text_centered(120, "[R] New Game [Q] Quit", colors.TEXT_SECONDARY)
    else
        display.draw_text(5, 227, "[Arrows]Move [Enter]Select [F]oundation [R]eset", colors.TEXT_SECONDARY)
    end
end

function Solitaire:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        self:on_exit()
        return "pop"
    elseif key.character == "r" then
        self:new_game()
        ScreenManager.invalidate()
        return "continue"
    end

    if self.won then return "continue" end

    if key.special == "LEFT" then
        if self.cursor.area == "tableau" then
            if self.cursor.col > 1 then
                self.cursor.col = self.cursor.col - 1
                self.cursor.row = math.max(1, #self.tableau[self.cursor.col])
            end
        elseif self.cursor.area == "foundation" then
            if self.cursor.col > 1 then
                self.cursor.col = self.cursor.col - 1
            else
                self.cursor.area = "waste"
            end
        elseif self.cursor.area == "waste" then
            self.cursor.area = "stock"
        end
    elseif key.special == "RIGHT" then
        if self.cursor.area == "stock" then
            self.cursor.area = "waste"
        elseif self.cursor.area == "waste" then
            self.cursor.area = "foundation"
            self.cursor.col = 1
        elseif self.cursor.area == "foundation" then
            if self.cursor.col < 4 then
                self.cursor.col = self.cursor.col + 1
            end
        elseif self.cursor.area == "tableau" then
            if self.cursor.col < 7 then
                self.cursor.col = self.cursor.col + 1
                self.cursor.row = math.max(1, #self.tableau[self.cursor.col])
            end
        end
    elseif key.special == "UP" then
        if self.cursor.area == "tableau" then
            if self.cursor.row > 1 then
                self.cursor.row = self.cursor.row - 1
                -- Skip face-down cards
                while self.cursor.row > 0 and
                      self.cursor.row <= #self.tableau[self.cursor.col] and
                      not self.tableau[self.cursor.col][self.cursor.row].face_up do
                    self.cursor.row = self.cursor.row - 1
                end
                if self.cursor.row < 1 then self.cursor.row = 1 end
            else
                self.cursor.area = "foundation"
                self.cursor.col = math.min(self.cursor.col, 4)
            end
        end
    elseif key.special == "DOWN" then
        if self.cursor.area == "stock" or self.cursor.area == "waste" or self.cursor.area == "foundation" then
            self.cursor.area = "tableau"
            if self.cursor.area == "foundation" then
                self.cursor.col = math.min(self.cursor.col + 3, 7)
            else
                self.cursor.col = 1
            end
            self.cursor.row = math.max(1, #self.tableau[self.cursor.col])
        elseif self.cursor.area == "tableau" then
            if self.cursor.row < #self.tableau[self.cursor.col] then
                self.cursor.row = self.cursor.row + 1
            end
        end
    elseif key.special == "ENTER" or key.character == " " then
        self:do_select()
    elseif key.character == "f" then
        self:do_auto_move()
    end

    ScreenManager.invalidate()
    return "continue"
end

return Solitaire
