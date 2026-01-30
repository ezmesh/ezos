-- Blackjack for T-Deck OS
-- Classic 21 card game using shared Cards module

local Cards = load_module("/scripts/ui/cards.lua")

local Blackjack = {
    title = "Blackjack",
    CARD_W = 32,
    CARD_H = 44,
}

function Blackjack:new()
    local o = {
        deck = {},
        player_hand = {},
        dealer_hand = {},
        chips = 1000,
        bet = 0,
        state = "betting",  -- betting, playing, dealer_turn, result
        message = "",
        result = "",
    }
    setmetatable(o, {__index = Blackjack})
    return o
end

function Blackjack:on_enter()
    if _G.MainLoop then _G.MainLoop.enter_game_mode() end

    -- Load chips
    if tdeck.storage and tdeck.storage.get_pref then
        self.chips = tdeck.storage.get_pref("blackjack_chips", 1000)
    end

    self:new_round()
end

function Blackjack:on_exit()
    if _G.MainLoop then _G.MainLoop.exit_game_mode() end
    if tdeck.storage and tdeck.storage.set_pref then
        tdeck.storage.set_pref("blackjack_chips", self.chips)
    end
end

function Blackjack:create_deck()
    self.deck = Cards.new_deck()
    Cards.shuffle(self.deck)
end

function Blackjack:draw_card()
    if #self.deck == 0 then
        self:create_deck()
    end
    return table.remove(self.deck)
end

function Blackjack:hand_value(hand)
    local value = 0
    local aces = 0

    for _, card in ipairs(hand) do
        if card.value == 1 then  -- Ace
            aces = aces + 1
            value = value + 11
        elseif card.value >= 10 then  -- Face cards
            value = value + 10
        else
            value = value + card.value
        end
    end

    -- Adjust for aces
    while value > 21 and aces > 0 do
        value = value - 10
        aces = aces - 1
    end

    return value
end

function Blackjack:new_round()
    self.player_hand = {}
    self.dealer_hand = {}
    self.bet = 0
    self.state = "betting"
    self.message = "Place your bet!"
    self.result = ""

    if self.chips <= 0 then
        self.chips = 1000
        self.message = "Chips reset to 1000"
    end

    self:create_deck()
end

function Blackjack:place_bet(amount)
    if amount > self.chips then amount = self.chips end
    if amount <= 0 then return end

    self.bet = amount

    -- Deal initial cards (face up)
    local c1 = self:draw_card()
    c1.face_up = true
    local c2 = self:draw_card()
    c2.face_up = true
    self.player_hand = {c1, c2}

    local d1 = self:draw_card()
    d1.face_up = true
    local d2 = self:draw_card()
    d2.face_up = false  -- Hole card
    self.dealer_hand = {d1, d2}

    self.state = "playing"
    self.message = ""

    -- Check for blackjack
    if self:hand_value(self.player_hand) == 21 then
        self:stand()
    end
end

function Blackjack:hit()
    if self.state ~= "playing" then return end

    local card = self:draw_card()
    card.face_up = true
    table.insert(self.player_hand, card)

    local value = self:hand_value(self.player_hand)
    if value > 21 then
        self:end_round("bust")
    elseif value == 21 then
        self:stand()
    end
end

function Blackjack:stand()
    if self.state ~= "playing" then return end

    self.state = "dealer_turn"
    self:dealer_play()
end

function Blackjack:dealer_play()
    -- Reveal hole card
    self.dealer_hand[2].face_up = true

    -- Dealer hits on 16 or less, stands on 17+
    while self:hand_value(self.dealer_hand) < 17 do
        local card = self:draw_card()
        card.face_up = true
        table.insert(self.dealer_hand, card)
    end

    local dealer_val = self:hand_value(self.dealer_hand)
    local player_val = self:hand_value(self.player_hand)

    if dealer_val > 21 then
        self:end_round("dealer_bust")
    elseif player_val > dealer_val then
        self:end_round("win")
    elseif player_val < dealer_val then
        self:end_round("lose")
    else
        self:end_round("push")
    end
end

function Blackjack:end_round(result)
    self.state = "result"
    self.result = result

    if result == "bust" then
        self.message = "Bust! You lose."
        self.chips = self.chips - self.bet
    elseif result == "dealer_bust" then
        self.message = "Dealer busts! You win!"
        self.chips = self.chips + self.bet
    elseif result == "win" then
        local player_val = self:hand_value(self.player_hand)
        if player_val == 21 and #self.player_hand == 2 then
            self.message = "Blackjack! You win 1.5x!"
            self.chips = self.chips + math.floor(self.bet * 1.5)
        else
            self.message = "You win!"
            self.chips = self.chips + self.bet
        end
    elseif result == "lose" then
        self.message = "Dealer wins."
        self.chips = self.chips - self.bet
    elseif result == "push" then
        self.message = "Push - bet returned."
    end
end

function Blackjack:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    display.fill_rect(0, 0, 320, 240, 0x0320)  -- Green felt

    -- Header
    display.set_font_size("small")
    display.draw_text(10, 5, string.format("Chips: $%d", self.chips), colors.WHITE)
    if self.bet > 0 then
        display.draw_text(150, 5, string.format("Bet: $%d", self.bet), colors.ACCENT)
    end

    -- Dealer hand
    display.draw_text(10, 22, "Dealer", colors.WHITE)
    local show_dealer = (self.state == "dealer_turn" or self.state == "result")
    for i, card in ipairs(self.dealer_hand) do
        local x = 10 + (i - 1) * (self.CARD_W + 4)
        if i == 2 and not show_dealer then
            Cards.draw_face_down(display, x, 35, self.CARD_W, self.CARD_H)
        else
            Cards.draw_face_up(display, card, x, 35, self.CARD_W, self.CARD_H)
        end
    end

    if show_dealer then
        display.draw_text(200, 50, tostring(self:hand_value(self.dealer_hand)), colors.WHITE)
    end

    -- Player hand
    display.draw_text(10, 95, "You", colors.WHITE)
    for i, card in ipairs(self.player_hand) do
        local x = 10 + (i - 1) * (self.CARD_W + 4)
        Cards.draw_face_up(display, card, x, 108, self.CARD_W, self.CARD_H)
    end

    if #self.player_hand > 0 then
        display.draw_text(200, 125, tostring(self:hand_value(self.player_hand)), colors.WHITE)
    end

    -- Message
    display.set_font_size("medium")
    display.draw_text_centered(170, self.message, colors.WHITE)

    -- Controls
    display.set_font_size("small")
    if self.state == "betting" then
        display.draw_text(10, 195, "[1]$10 [2]$25 [3]$50 [4]$100 [5]All-in", colors.TEXT_SECONDARY)
        display.draw_text(10, 210, "[Q]uit", colors.TEXT_SECONDARY)
    elseif self.state == "playing" then
        display.draw_text(10, 210, "[H]it [S]tand [Q]uit", colors.TEXT_SECONDARY)
    elseif self.state == "result" then
        display.draw_text(10, 210, "[Enter] New Round [Q]uit", colors.TEXT_SECONDARY)
    end
end

function Blackjack:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        self:on_exit()
        return "pop"
    end

    if self.state == "betting" then
        if key.character == "1" then
            self:place_bet(10)
        elseif key.character == "2" then
            self:place_bet(25)
        elseif key.character == "3" then
            self:place_bet(50)
        elseif key.character == "4" then
            self:place_bet(100)
        elseif key.character == "5" then
            self:place_bet(self.chips)
        end
    elseif self.state == "playing" then
        if key.character == "h" then
            self:hit()
        elseif key.character == "s" then
            self:stand()
        end
    elseif self.state == "result" then
        if key.special == "ENTER" or key.character == " " then
            self:new_round()
        end
    end

    ScreenManager.invalidate()
    return "continue"
end

return Blackjack
