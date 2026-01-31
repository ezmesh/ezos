-- Texas Hold'em Poker for T-Deck OS
-- Single player vs 3 computer opponents

local Cards = load_module("/scripts/ui/cards.lua")

local Poker = {
    title = "Texas Hold'em",
}

-- Game constants
local STARTING_CHIPS = 1000
local SMALL_BLIND = 10
local BIG_BLIND = 20
local NUM_AI_PLAYERS = 3

-- Game states
local STATE = {
    WAITING = 1,      -- Waiting to start hand
    PREFLOP = 2,      -- Hole cards dealt, first betting round
    FLOP = 3,         -- 3 community cards, second betting
    TURN = 4,         -- 4th community card, third betting
    RIVER = 5,        -- 5th community card, final betting
    SHOWDOWN = 6,     -- Reveal cards, determine winner
    GAME_OVER = 7,    -- Player out of chips
}

-- Player actions
local ACTION = {
    FOLD = 1,
    CHECK = 2,
    CALL = 3,
    BET = 4,
    RAISE = 5,
    ALL_IN = 6,
}

function Poker:new()
    local o = {
        state = STATE.WAITING,
        deck = {},
        community = {},  -- Community cards (up to 5)
        pot = 0,
        current_bet = 0,
        min_raise = BIG_BLIND,

        -- Players: index 1 is human, 2-4 are AI
        players = {},
        dealer_idx = 1,  -- Dealer button position
        current_player = 1,
        last_raiser = 0,

        -- UI state
        selected_action = 1,
        bet_amount = 0,
        message = "",
        message_timer = 0,

        -- Animation
        last_update = 0,
    }

    setmetatable(o, {__index = Poker})
    o:init_players()
    return o
end

function Poker:init_players()
    self.players = {
        {name = "You", chips = STARTING_CHIPS, hand = {}, bet = 0, folded = false, is_ai = false, all_in = false},
        {name = "Alice", chips = STARTING_CHIPS, hand = {}, bet = 0, folded = false, is_ai = true, all_in = false},
        {name = "Bob", chips = STARTING_CHIPS, hand = {}, bet = 0, folded = false, is_ai = true, all_in = false},
        {name = "Carol", chips = STARTING_CHIPS, hand = {}, bet = 0, folded = false, is_ai = true, all_in = false},
    }
end

function Poker:on_enter()
    if _G.MainLoop then _G.MainLoop.enter_game_mode() end
    math.randomseed(ez.system.millis())
    self:show_message("Press ENTER to deal")
end

function Poker:on_exit()
    if _G.MainLoop then _G.MainLoop.exit_game_mode() end
end

function Poker:show_message(msg, duration)
    self.message = msg
    self.message_timer = ez.system.millis() + (duration or 2000)
end

-- Start a new hand
function Poker:start_hand()
    -- Check for game over
    if self.players[1].chips <= 0 then
        self.state = STATE.GAME_OVER
        self:show_message("Game Over! You're broke!", 10000)
        return
    end

    -- Remove busted AI players or give them chips back
    for i = 2, #self.players do
        if self.players[i].chips <= 0 then
            self.players[i].chips = STARTING_CHIPS / 2  -- Rebuy
        end
    end

    -- Reset for new hand
    self.deck = Cards.new_deck()
    Cards.shuffle(self.deck)
    self.community = {}
    self.pot = 0
    self.current_bet = 0
    self.min_raise = BIG_BLIND
    self.last_raiser = 0

    for _, p in ipairs(self.players) do
        p.hand = {}
        p.bet = 0
        p.folded = false
        p.all_in = false
    end

    -- Move dealer button
    self.dealer_idx = (self.dealer_idx % #self.players) + 1

    -- Post blinds
    local sb_idx = (self.dealer_idx % #self.players) + 1
    local bb_idx = (sb_idx % #self.players) + 1

    self:post_blind(sb_idx, SMALL_BLIND)
    self:post_blind(bb_idx, BIG_BLIND)
    self.current_bet = BIG_BLIND

    -- Deal hole cards
    for _, p in ipairs(self.players) do
        p.hand = Cards.deal(self.deck, 2)
        -- Human cards face up, AI face down
        if not p.is_ai then
            for _, card in ipairs(p.hand) do
                card.face_up = true
            end
        end
    end

    -- First to act is after big blind
    self.current_player = (bb_idx % #self.players) + 1
    self.state = STATE.PREFLOP
    self.selected_action = 1
    self.bet_amount = BIG_BLIND

    self:show_message("Your turn")

    -- If human isn't first, run AI
    if self.players[self.current_player].is_ai then
        self:schedule_ai_action()
    end
end

function Poker:post_blind(player_idx, amount)
    local p = self.players[player_idx]
    local actual = math.min(amount, p.chips)
    p.chips = p.chips - actual
    p.bet = actual
    self.pot = self.pot + actual
    if p.chips == 0 then
        p.all_in = true
    end
end

-- Get number of active (non-folded) players
function Poker:count_active()
    local count = 0
    for _, p in ipairs(self.players) do
        if not p.folded then count = count + 1 end
    end
    return count
end

-- Get next active player
function Poker:next_active_player(from_idx)
    local idx = from_idx
    for _ = 1, #self.players do
        idx = (idx % #self.players) + 1
        local p = self.players[idx]
        if not p.folded and not p.all_in then
            return idx
        end
    end
    return nil  -- Everyone folded or all-in
end

-- Check if betting round is complete
function Poker:is_betting_complete()
    -- Only one player left
    if self:count_active() <= 1 then
        return true
    end

    -- Check if everyone has acted and bets are equal
    for i, p in ipairs(self.players) do
        if not p.folded and not p.all_in then
            -- If player hasn't matched current bet, not complete
            if p.bet < self.current_bet then
                return false
            end
        end
    end

    -- Check if we've gone around since last raise
    if self.last_raiser > 0 then
        return self.current_player == self.last_raiser
    end

    return true
end

-- Advance to next stage
function Poker:advance_stage()
    -- Reset bets for new round
    for _, p in ipairs(self.players) do
        p.bet = 0
    end
    self.current_bet = 0
    self.min_raise = BIG_BLIND
    self.last_raiser = 0

    if self.state == STATE.PREFLOP then
        -- Deal flop (3 cards)
        local flop = Cards.deal(self.deck, 3)
        for _, card in ipairs(flop) do
            card.face_up = true
            table.insert(self.community, card)
        end
        self.state = STATE.FLOP
        self:show_message("The Flop")

    elseif self.state == STATE.FLOP then
        -- Deal turn (1 card)
        local turn = Cards.deal(self.deck, 1)
        turn[1].face_up = true
        table.insert(self.community, turn[1])
        self.state = STATE.TURN
        self:show_message("The Turn")

    elseif self.state == STATE.TURN then
        -- Deal river (1 card)
        local river = Cards.deal(self.deck, 1)
        river[1].face_up = true
        table.insert(self.community, river[1])
        self.state = STATE.RIVER
        self:show_message("The River")

    elseif self.state == STATE.RIVER then
        self:showdown()
        return
    end

    -- First to act after flop is first active player after dealer
    self.current_player = self:next_active_player(self.dealer_idx)

    if self.current_player and self.players[self.current_player].is_ai then
        self:schedule_ai_action()
    end
end

-- Determine winner(s) and award pot
function Poker:showdown()
    self.state = STATE.SHOWDOWN

    -- Reveal all hands
    for _, p in ipairs(self.players) do
        if not p.folded then
            for _, card in ipairs(p.hand) do
                card.face_up = true
            end
        end
    end

    -- Evaluate hands
    local best_rank = 0
    local best_highs = {}
    local winners = {}

    for i, p in ipairs(self.players) do
        if not p.folded then
            -- Combine hole cards with community
            local all_cards = {}
            for _, c in ipairs(p.hand) do table.insert(all_cards, c) end
            for _, c in ipairs(self.community) do table.insert(all_cards, c) end

            local rank, highs = Cards.evaluate_hand(all_cards)
            p.hand_rank = rank
            p.hand_name = Cards.HAND_NAMES[rank]

            local cmp = Cards.compare_hands(rank, highs, best_rank, best_highs)
            if cmp > 0 then
                best_rank = rank
                best_highs = highs
                winners = {i}
            elseif cmp == 0 then
                table.insert(winners, i)
            end
        end
    end

    -- Award pot
    local share = math.floor(self.pot / #winners)
    for _, idx in ipairs(winners) do
        self.players[idx].chips = self.players[idx].chips + share
    end

    -- Show winner message
    if #winners == 1 then
        local winner = self.players[winners[1]]
        local verb = winner.is_ai and " wins with " or " win with "
        self:show_message(winner.name .. verb .. winner.hand_name, 4000)
    else
        self:show_message("Split pot!", 4000)
    end

    self.pot = 0
end

-- Player action handling
function Poker:do_action(action, amount)
    local p = self.players[self.current_player]
    amount = amount or 0

    if action == ACTION.FOLD then
        p.folded = true
        if not p.is_ai then
            self:show_message("You fold")
        end

    elseif action == ACTION.CHECK then
        -- Can only check if no bet to call
        if self.current_bet > p.bet then
            return false  -- Must call or fold
        end
        if not p.is_ai then
            self:show_message("Check")
        end

    elseif action == ACTION.CALL then
        local to_call = self.current_bet - p.bet
        local actual = math.min(to_call, p.chips)
        p.chips = p.chips - actual
        p.bet = p.bet + actual
        self.pot = self.pot + actual
        if p.chips == 0 then
            p.all_in = true
        end
        if not p.is_ai then
            self:show_message("Call " .. actual)
        end

    elseif action == ACTION.BET or action == ACTION.RAISE then
        local raise_amount = amount
        if raise_amount < self.min_raise then
            raise_amount = self.min_raise
        end
        local total_bet = self.current_bet + raise_amount
        local to_put = total_bet - p.bet

        if to_put > p.chips then
            -- All-in
            to_put = p.chips
            total_bet = p.bet + to_put
        end

        p.chips = p.chips - to_put
        self.pot = self.pot + to_put
        self.min_raise = total_bet - self.current_bet
        self.current_bet = total_bet
        p.bet = total_bet
        self.last_raiser = self.current_player

        if p.chips == 0 then
            p.all_in = true
        end

        if not p.is_ai then
            self:show_message("Raise to " .. total_bet)
        end

    elseif action == ACTION.ALL_IN then
        local to_put = p.chips
        p.bet = p.bet + to_put
        self.pot = self.pot + to_put
        if p.bet > self.current_bet then
            self.min_raise = p.bet - self.current_bet
            self.current_bet = p.bet
            self.last_raiser = self.current_player
        end
        p.chips = 0
        p.all_in = true
        if not p.is_ai then
            self:show_message("All in!")
        end
    end

    -- Check for instant win (everyone else folded)
    if self:count_active() == 1 then
        for i, player in ipairs(self.players) do
            if not player.folded then
                player.chips = player.chips + self.pot
                local msg = player.is_ai and (player.name .. " takes the pot") or "You take the pot"
                self:show_message(msg, 3000)
                self.pot = 0
                self.state = STATE.SHOWDOWN
                return true
            end
        end
    end

    -- Move to next player or next stage
    local next_player = self:next_active_player(self.current_player)

    if not next_player or self:is_betting_complete() then
        self:advance_stage()
    else
        self.current_player = next_player
        if self.players[self.current_player].is_ai then
            self:schedule_ai_action()
        end
    end

    return true
end

-- AI decision making
function Poker:schedule_ai_action()
    -- Delay AI action for readability
    self.ai_action_time = ez.system.millis() + 800
end

function Poker:ai_take_action()
    local p = self.players[self.current_player]
    if not p.is_ai or p.folded or p.all_in then
        return
    end

    -- Simple AI based on hand strength
    local hand_strength = self:evaluate_ai_hand(self.current_player)
    local to_call = self.current_bet - p.bet
    local pot_odds = to_call > 0 and (to_call / (self.pot + to_call)) or 0

    -- Random factor
    local r = math.random()

    local action, amount

    if to_call == 0 then
        -- No bet to call
        if hand_strength > 0.7 and r < 0.6 then
            -- Strong hand, bet
            action = ACTION.BET
            amount = math.floor(self.pot * 0.5)
        elseif hand_strength > 0.4 and r < 0.3 then
            -- Medium hand, sometimes bet
            action = ACTION.BET
            amount = BIG_BLIND * 2
        else
            action = ACTION.CHECK
        end
    else
        -- Must call, raise, or fold
        if hand_strength > 0.8 and r < 0.5 then
            -- Very strong, raise
            action = ACTION.RAISE
            amount = to_call + math.floor(self.pot * 0.5)
        elseif hand_strength > pot_odds + 0.1 then
            -- Good enough to call
            action = ACTION.CALL
        elseif hand_strength > pot_odds and r < 0.5 then
            -- Borderline, sometimes call
            action = ACTION.CALL
        else
            action = ACTION.FOLD
        end
    end

    -- Cap bet amount
    if amount and amount > p.chips then
        action = ACTION.ALL_IN
    end

    self:do_action(action, amount)
    ScreenManager.invalidate()
end

-- Evaluate AI hand strength (0-1)
function Poker:evaluate_ai_hand(player_idx)
    local p = self.players[player_idx]

    -- Combine cards
    local all_cards = {}
    for _, c in ipairs(p.hand) do table.insert(all_cards, c) end
    for _, c in ipairs(self.community) do table.insert(all_cards, c) end

    if #all_cards < 2 then return 0.5 end

    -- Pre-flop: evaluate hole cards
    if #self.community == 0 then
        local c1, c2 = p.hand[1], p.hand[2]
        local high = math.max(c1.value, c2.value)
        local low = math.min(c1.value, c2.value)
        local paired = c1.value == c2.value
        local suited = c1.suit == c2.suit
        local connected = math.abs(c1.value - c2.value) == 1

        local strength = high / 14 * 0.3

        if paired then
            strength = strength + 0.4 + (c1.value / 14) * 0.2
        end
        if suited then
            strength = strength + 0.1
        end
        if connected then
            strength = strength + 0.05
        end
        if high >= 10 then
            strength = strength + 0.1
        end

        return math.min(1, strength)
    end

    -- Post-flop: use hand evaluation
    local rank, _ = Cards.evaluate_hand(all_cards)
    return rank / 10
end

-- Get available actions for current player
function Poker:get_available_actions()
    local p = self.players[self.current_player]
    local to_call = self.current_bet - p.bet
    local actions = {}

    if to_call == 0 then
        table.insert(actions, {action = ACTION.CHECK, label = "Check"})
        table.insert(actions, {action = ACTION.BET, label = "Bet"})
    else
        table.insert(actions, {action = ACTION.FOLD, label = "Fold"})
        table.insert(actions, {action = ACTION.CALL, label = "Call " .. to_call})
        table.insert(actions, {action = ACTION.RAISE, label = "Raise"})
    end

    table.insert(actions, {action = ACTION.ALL_IN, label = "All In"})

    return actions
end

function Poker:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    -- Background
    display.fill_rect(0, 0, w, h, 0x0320)  -- Dark green felt

    -- Draw table (ellipse approximation)
    local table_cx, table_cy = math.floor(w / 2), math.floor(h / 2) - 10
    local table_rx, table_ry = 140, 70
    display.fill_round_rect(table_cx - table_rx, table_cy - table_ry,
                            table_rx * 2, table_ry * 2, 40, 0x0540)  -- Lighter green
    display.draw_round_rect(table_cx - table_rx, table_cy - table_ry,
                            table_rx * 2, table_ry * 2, 40, 0x8410)  -- Brown edge

    -- Draw pot in center
    display.set_font_size("medium")
    local pot_str = "Pot: $" .. self.pot
    local pot_w = display.text_width(pot_str)
    display.draw_text(math.floor(table_cx - pot_w / 2), table_cy - 8, pot_str, 0xFFFF)

    -- Draw community cards
    if #self.community > 0 then
        local card_spacing = 4
        local total_w = Cards.spread_width(#self.community, card_spacing)
        local start_x = math.floor(table_cx - total_w / 2)
        Cards.draw_spread(display, self.community, start_x, table_cy - 35, card_spacing)
    end

    -- AI players at top (positions around table)
    local half_w = math.floor(w / 2)
    local ai_positions = {
        {x = half_w - 80, y = 8},   -- Left-top
        {x = half_w, y = 2},        -- Center-top
        {x = half_w + 80, y = 8},   -- Right-top
    }

    for i = 2, #self.players do
        local p = self.players[i]
        local pos = ai_positions[i - 1]
        if pos then
            self:draw_player(display, p, i, pos.x, pos.y, true)
        end
    end

    -- Human player at bottom
    self:draw_player(display, self.players[1], 1, half_w, h - 65, false)

    -- Draw dealer button
    local dealer_pos
    if self.dealer_idx == 1 then
        dealer_pos = {x = half_w + 60, y = h - 70}
    else
        local ai_pos = ai_positions[self.dealer_idx - 1]
        if ai_pos then
            dealer_pos = {x = ai_pos.x + 40, y = ai_pos.y + 10}
        end
    end
    if dealer_pos then
        display.fill_circle(dealer_pos.x, dealer_pos.y, 8, 0xFFE0)  -- Yellow
        display.set_font_size("small")
        display.draw_text(dealer_pos.x - 3, dealer_pos.y - 4, "D", 0x0000)
    end

    -- Action buttons (only when it's player's turn)
    if self.state >= STATE.PREFLOP and self.state <= STATE.RIVER and
       self.current_player == 1 and not self.players[1].folded then
        self:draw_actions(display)
    end

    -- Message
    if self.message ~= "" and ez.system.millis() < self.message_timer then
        display.set_font_size("medium")
        local msg_w = display.text_width(self.message)
        local msg_x = (w - msg_w) / 2
        local msg_y = h / 2
        display.fill_round_rect(msg_x - 8, msg_y - 4, msg_w + 16, 20, 4, 0x0000)
        display.draw_text(msg_x, msg_y, self.message, 0xFFFF)
    end

    -- Game state messages
    local half_h = math.floor(h / 2)
    if self.state == STATE.WAITING then
        display.set_font_size("medium")
        display.draw_text_centered(half_h, "Press ENTER to deal", colors.WHITE)
    elseif self.state == STATE.SHOWDOWN then
        display.set_font_size("small")
        display.draw_text_centered(h - 20, "ENTER: New hand  Q: Quit", colors.TEXT_MUTED)
    elseif self.state == STATE.GAME_OVER then
        display.set_font_size("medium")
        display.draw_text_centered(half_h - 10, "GAME OVER", 0xF800)
        display.draw_text_centered(half_h + 10, "ENTER: Restart  Q: Quit", colors.TEXT_MUTED)
    end
end

function Poker:draw_player(display, player, idx, cx, cy, is_ai)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Highlight current player
    local is_current = (idx == self.current_player) and
                       (self.state >= STATE.PREFLOP and self.state <= STATE.RIVER)

    -- Name and chips
    display.set_font_size("small")
    local name_color = player.folded and 0x8410 or (is_current and 0xFFE0 or 0xFFFF)
    local chip_str = "$" .. player.chips

    local name_w = display.text_width(player.name)
    local chip_w = display.text_width(chip_str)

    if is_ai then
        -- AI at top
        display.draw_text(math.floor(cx - name_w / 2), cy, player.name, name_color)
        display.draw_text(math.floor(cx - chip_w / 2), cy + 10, chip_str, 0x07E0)  -- Green

        -- Cards (face down for AI, unless showdown)
        if #player.hand > 0 and not player.folded then
            local card_w = 22
            local card_h = 32
            local overlap = 14
            local total_w = Cards.hand_width(2, overlap, card_w)
            local card_x = math.floor(cx - total_w / 2)
            local card_y = cy + 22

            if self.state == STATE.SHOWDOWN then
                Cards.draw_hand(display, player.hand, card_x, card_y, overlap, card_w, card_h)
            else
                Cards.draw_face_down(display, card_x, card_y, card_w, card_h)
                Cards.draw_face_down(display, card_x + overlap, card_y, card_w, card_h)
            end
        end

        -- Current bet indicator
        if player.bet > 0 then
            local bet_str = "$" .. player.bet
            local bet_w = display.text_width(bet_str)
            display.draw_text(math.floor(cx - bet_w / 2), cy + 56, bet_str, 0xFD20)  -- Orange
        end
    else
        -- Human at bottom
        -- Cards first (larger)
        if #player.hand > 0 and not player.folded then
            local card_w = Cards.CARD_WIDTH
            local card_h = Cards.CARD_HEIGHT
            local overlap = 20
            local total_w = Cards.hand_width(2, overlap, card_w)
            local card_x = math.floor(cx - total_w / 2)
            local card_y = cy

            Cards.draw_hand(display, player.hand, card_x, card_y, overlap, card_w, card_h)
        end

        -- Name below cards
        display.draw_text(math.floor(cx - name_w / 2), cy + 44, player.name, name_color)
        display.draw_text(math.floor(cx - chip_w / 2), cy + 54, chip_str, 0x07E0)

        -- Current bet
        if player.bet > 0 then
            local bet_str = "$" .. player.bet
            local bet_w = display.text_width(bet_str)
            display.draw_text(cx + 50, cy + 20, bet_str, 0xFD20)
        end

        -- Hand rank at showdown
        if self.state == STATE.SHOWDOWN and player.hand_name then
            display.set_font_size("small")
            local rank_w = display.text_width(player.hand_name)
            display.draw_text(math.floor(cx - rank_w / 2), cy - 12, player.hand_name, 0xFFE0)
        end
    end
end

function Poker:draw_actions(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    local actions = self:get_available_actions()
    local btn_w = 50
    local btn_h = 16
    local spacing = 4
    local total_w = #actions * btn_w + (#actions - 1) * spacing
    local start_x = (w - total_w) / 2
    local y = h - 18

    display.set_font_size("small")

    for i, act in ipairs(actions) do
        local x = start_x + (i - 1) * (btn_w + spacing)
        local is_selected = (i == self.selected_action)

        if is_selected then
            display.fill_round_rect(x, y, btn_w, btn_h, 3, colors.ACCENT)
            display.draw_text(x + 4, y + 3, act.label, 0x0000)
        else
            display.draw_round_rect(x, y, btn_w, btn_h, 3, colors.SURFACE)
            display.draw_text(x + 4, y + 3, act.label, colors.TEXT_SECONDARY)
        end
    end
end

function Poker:handle_key(key)
    ScreenManager.invalidate()

    if self.state == STATE.WAITING then
        if key.special == "ENTER" then
            self:start_hand()
        elseif key.special == "ESCAPE" or key.character == "q" then
            self:on_exit()
            return "pop"
        end
        return "continue"
    end

    if self.state == STATE.GAME_OVER then
        if key.special == "ENTER" then
            self:init_players()
            self.state = STATE.WAITING
            self:show_message("Press ENTER to deal")
        elseif key.special == "ESCAPE" or key.character == "q" then
            self:on_exit()
            return "pop"
        end
        return "continue"
    end

    if self.state == STATE.SHOWDOWN then
        if key.special == "ENTER" then
            self.state = STATE.WAITING
            self:start_hand()
        elseif key.special == "ESCAPE" or key.character == "q" then
            self:on_exit()
            return "pop"
        end
        return "continue"
    end

    -- Player's turn during betting
    if self.current_player == 1 and not self.players[1].folded then
        local actions = self:get_available_actions()

        if key.special == "LEFT" then
            self.selected_action = math.max(1, self.selected_action - 1)
        elseif key.special == "RIGHT" then
            self.selected_action = math.min(#actions, self.selected_action + 1)
        elseif key.special == "ENTER" or key.character == " " then
            local act = actions[self.selected_action]
            if act then
                local amount = nil
                if act.action == ACTION.BET or act.action == ACTION.RAISE then
                    amount = self.min_raise + self.current_bet
                end
                self:do_action(act.action, amount)
                self.selected_action = 1
            end
        elseif key.special == "ESCAPE" or key.character == "q" then
            self:on_exit()
            return "pop"
        end
    end

    return "continue"
end

function Poker:update()
    -- Process AI actions
    if self.ai_action_time and ez.system.millis() >= self.ai_action_time then
        self.ai_action_time = nil
        if self.state >= STATE.PREFLOP and self.state <= STATE.RIVER then
            self:ai_take_action()
        end
    end
end

return Poker
