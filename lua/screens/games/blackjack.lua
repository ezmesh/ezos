-- Blackjack: single player vs dealer.
--
-- Standard rules. Dealer hits to 16 and stands on all 17 (including
-- soft). Naturals (Ace + 10/face on the first two cards) pay 3:2,
-- regular wins pay 1:1, push returns the bet, bust loses it. No
-- doubling or splitting -- keeps the input model to two keys (Hit /
-- Stand) so it's painless on the T-Deck keyboard.
--
-- Bankroll persists per session in module-level state; closing the
-- screen and reopening starts a fresh bankroll. A persistent high
-- score wasn't worth the storage indirection for a single-player
-- party game.

local ui    = require("ezui")
local theme = require("ezui.theme")
local node  = require("ezui.node")

local floor = math.floor
local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

-- Card geometry. Slightly larger than the solitaire cards because
-- only 2 hands of <=5 cards are on screen at a time.
local CARD_W = 30
local CARD_H = 42
local CARD_GAP = 4

local CLR_CARD_FACE = rgb(245, 245, 240)
local CLR_CARD_BACK = rgb( 35,  60, 120)
local CLR_CARD_BACK_HATCH = rgb( 80, 100, 160)
local CLR_RED       = rgb(200,  40,  40)
local CLR_BLACK     = rgb( 20,  20,  20)
local CLR_FELT      = rgb( 10,  60,  30)

local SUIT_RED = { true, true, false, false }
local RANK_CHARS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }

local function is_red(card) return SUIT_RED[card.suit] end

-- Suit glyph drawn at (x, y) inside an `s` x `s` box. Same shapes as
-- solitaire.lua so cards across the codebase look consistent.
local function draw_suit(d, suit, x, y, s, color)
    local hs = floor(s / 2)
    if suit == 1 then       -- heart
        local r = floor(s / 4) + 1
        d.fill_circle(x + hs - r + 1, y + r, r, color)
        d.fill_circle(x + hs + r - 1, y + r, r, color)
        d.fill_triangle(x, y + r, x + s, y + r, x + hs, y + s, color)
    elseif suit == 2 then   -- diamond
        local cx, cy = x + hs, y + hs
        d.fill_triangle(cx, y, x + s, cy, cx, y + s, color)
        d.fill_triangle(cx, y, x, cy, cx, y + s, color)
    elseif suit == 3 then   -- club
        local r = floor(s / 4) + 1
        d.fill_circle(x + hs, y + r, r, color)
        d.fill_circle(x + hs - r, y + hs + 1, r, color)
        d.fill_circle(x + hs + r, y + hs + 1, r, color)
        d.fill_rect(x + hs - 1, y + hs, 3, hs, color)
    elseif suit == 4 then   -- spade
        local r = floor(s / 4) + 1
        d.fill_triangle(x, y + hs + 1, x + s, y + hs + 1, x + hs, y, color)
        d.fill_circle(x + hs - r + 1, y + hs + 1, r, color)
        d.fill_circle(x + hs + r - 1, y + hs + 1, r, color)
        d.fill_rect(x + hs - 1, y + hs + 1, 3, hs, color)
    end
end

local function draw_card_face(d, card, x, y)
    d.fill_rect(x, y, CARD_W, CARD_H, CLR_CARD_FACE)
    d.draw_rect(x, y, CARD_W, CARD_H, rgb(80, 80, 80))
    theme.set_font("tiny_aa")
    local text_color = is_red(card) and CLR_RED or CLR_BLACK
    d.draw_text(x + 2, y + 2, RANK_CHARS[card.rank], text_color)
    draw_suit(d, card.suit, x + 2, y + 13, 7, text_color)
    draw_suit(d, card.suit, x + floor((CARD_W - 11) / 2),
                            y + floor((CARD_H - 11) / 2) + 2,
                            11, text_color)
end

local function draw_card_back(d, x, y)
    d.fill_rect(x, y, CARD_W, CARD_H, CLR_CARD_BACK)
    -- Cross-hatch for visual interest. Skip the outermost row/column
    -- so the lighter hatch never bleeds into the border line.
    for py = y + 4, y + CARD_H - 5, 4 do
        d.draw_hline(x + 3, py, CARD_W - 6, CLR_CARD_BACK_HATCH)
    end
    d.draw_rect(x, y, CARD_W, CARD_H, rgb(20, 30, 80))
end

-- ---------------------------------------------------------------------------
-- Game state
-- ---------------------------------------------------------------------------

local STATE_BETTING = "bet"
local STATE_PLAYING = "play"
local STATE_DEALER  = "dealer"
local STATE_RESULT  = "result"

local game = nil

local function new_shoe()
    -- Single deck reshuffled each hand. With one player and short
    -- sessions, multi-deck shoes don't add anything users will notice.
    local deck = {}
    for suit = 1, 4 do
        for rank = 1, 13 do
            deck[#deck + 1] = { rank = rank, suit = suit }
        end
    end
    for i = #deck, 2, -1 do
        local j = math.random(1, i)
        deck[i], deck[j] = deck[j], deck[i]
    end
    return deck
end

-- Return (best_total, is_soft). "Soft" means at least one ace counted
-- as 11 without busting; matters because an Ace + 6 = 17 doesn't end
-- the dealer's turn.
local function score_hand(hand)
    local total = 0
    local aces  = 0
    for _, card in ipairs(hand) do
        if card.rank == 1 then
            total = total + 11
            aces  = aces + 1
        elseif card.rank >= 10 then
            total = total + 10
        else
            total = total + card.rank
        end
    end
    while total > 21 and aces > 0 do
        total = total - 10
        aces  = aces - 1
    end
    return total, (aces > 0 and total <= 21)
end

local function is_blackjack(hand)
    return #hand == 2 and score_hand(hand) == 21
end

local function init_game()
    math.randomseed(ez.system.millis())
    game = {
        bankroll = 200,
        bet      = 10,
        deck     = nil,
        player   = {},
        dealer   = {},
        state    = STATE_BETTING,
        result   = nil,            -- "win", "lose", "push", "blackjack"
        message  = "Place your bet",
    }
end

local function deal_card(hand)
    hand[#hand + 1] = table.remove(game.deck)
end

local function start_hand()
    game.deck   = new_shoe()
    game.player = {}
    game.dealer = {}
    deal_card(game.player)
    deal_card(game.dealer)
    deal_card(game.player)
    deal_card(game.dealer)
    -- Charge the bet up front; payouts add back to bankroll on result.
    game.bankroll = game.bankroll - game.bet
    game.result   = nil

    if is_blackjack(game.player) and is_blackjack(game.dealer) then
        game.state   = STATE_RESULT
        game.result  = "push"
        game.message = "Both blackjack -- push"
        game.bankroll = game.bankroll + game.bet
    elseif is_blackjack(game.player) then
        game.state   = STATE_RESULT
        game.result  = "blackjack"
        game.message = "Blackjack! Pays 3:2"
        -- 3:2 on the bet, plus the original stake back.
        game.bankroll = game.bankroll + game.bet + floor(game.bet * 3 / 2)
    elseif is_blackjack(game.dealer) then
        game.state   = STATE_RESULT
        game.result  = "lose"
        game.message = "Dealer blackjack"
    else
        game.state   = STATE_PLAYING
        game.message = "Hit or Stand"
    end
end

local function settle_after_dealer()
    local p = score_hand(game.player)
    local dt = score_hand(game.dealer)
    if dt > 21 or p > dt then
        game.result   = "win"
        game.message  = "You win"
        game.bankroll = game.bankroll + game.bet * 2
    elseif p == dt then
        game.result   = "push"
        game.message  = "Push"
        game.bankroll = game.bankroll + game.bet
    else
        game.result   = "lose"
        game.message  = "Dealer wins"
    end
    game.state = STATE_RESULT
end

local function play_dealer()
    -- Dealer hits to 16 and stands on all 17.
    while true do
        local total = score_hand(game.dealer)
        if total >= 17 then break end
        deal_card(game.dealer)
    end
    settle_after_dealer()
end

local function player_hit()
    if game.state ~= STATE_PLAYING then return end
    deal_card(game.player)
    local total = score_hand(game.player)
    if total > 21 then
        game.state   = STATE_RESULT
        game.result  = "lose"
        game.message = "Bust"
    end
end

local function player_stand()
    if game.state ~= STATE_PLAYING then return end
    game.state = STATE_DEALER
    play_dealer()
end

local function adjust_bet(delta)
    if game.state ~= STATE_BETTING then return end
    local new_bet = game.bet + delta
    if new_bet < 5 then new_bet = 5 end
    if new_bet > game.bankroll then new_bet = game.bankroll end
    game.bet = new_bet
end

-- ---------------------------------------------------------------------------
-- Renderer
-- ---------------------------------------------------------------------------

local function draw_hand(d, hand, x, y, hide_first)
    for i, card in ipairs(hand) do
        local cx = x + (i - 1) * (CARD_W + CARD_GAP)
        if hide_first and i == 1 then
            draw_card_back(d, cx, y)
        else
            draw_card_face(d, card, cx, y)
        end
    end
end

-- Content area is 240 - status bar (20) - title bar (20) = 200 px tall.
local FIELD_H = 200

node.register("blackjack_field", {
    measure = function(n, max_w, max_h)
        return max_w, FIELD_H
    end,
    draw = function(n, d, x, y, w, h)
        if not game then return end
        d.fill_rect(x, y, w, h, CLR_FELT)

        -- HUD strip: bankroll on the left, bet on the right.
        theme.set_font("tiny_aa")
        d.fill_rect(x, y, w, 16, theme.color("SURFACE"))
        d.draw_text(x + 6, y + 3, "Chips: " .. game.bankroll,
            theme.color("TEXT"))
        local bet_str = "Bet: " .. game.bet
        local bw = theme.text_width(bet_str)
        d.draw_text(x + w - bw - 6, y + 3, bet_str, theme.color("TEXT"))

        -- Dealer area at the top.
        theme.set_font("tiny_aa")
        local dealer_total = score_hand(game.dealer)
        local dealer_label
        if game.state == STATE_PLAYING then
            -- Hide the hole card's value while the player decides.
            dealer_label = "Dealer: ?"
        else
            dealer_label = "Dealer: " .. dealer_total
        end
        d.draw_text(x + 6, y + 22, dealer_label, theme.color("TEXT"))
        draw_hand(d, game.dealer, x + 6, y + 36,
                  game.state == STATE_PLAYING)

        -- Player area.
        local p_total = score_hand(game.player)
        local p_label = "You: " .. p_total
        d.draw_text(x + 6, y + 92, p_label, theme.color("TEXT"))
        draw_hand(d, game.player, x + 6, y + 106, false)

        -- Footer message + key hints.
        theme.set_font("small_aa", "bold")
        local mw = theme.text_width(game.message)
        d.draw_text(x + floor((w - mw) / 2), y + 162,
            game.message, theme.color("ACCENT"))

        theme.set_font("tiny_aa")
        local hints
        if game.state == STATE_BETTING then
            hints = "L/R bet | Enter deal"
        elseif game.state == STATE_PLAYING then
            hints = "H hit | S stand"
        elseif game.state == STATE_RESULT then
            if game.bankroll <= 0 then
                hints = "Out of chips -- Enter for new game"
            else
                hints = "Enter for next hand"
            end
        else
            hints = ""
        end
        if hints ~= "" then
            local hw = theme.text_width(hints)
            d.draw_text(x + floor((w - hw) / 2), y + 182,
                hints, theme.color("TEXT_MUTED"))
        end
    end,
})

local Blackjack = { title = "Blackjack" }

function Blackjack.initial_state()
    return { tick = 0 }
end

function Blackjack:on_enter()
    init_game()
    self:set_state({ tick = 0 })
end

function Blackjack:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Blackjack", { back = true }),
        { type = "blackjack_field" },
    })
end

function Blackjack:handle_key(key)
    local function bump() self:set_state({ tick = (self._state.tick or 0) + 1 }) end

    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end

    if game.state == STATE_BETTING then
        if key.special == "LEFT" or key.character == "a" then
            adjust_bet(-5); bump(); return "handled"
        elseif key.special == "RIGHT" or key.character == "d" then
            adjust_bet(5); bump(); return "handled"
        elseif key.special == "ENTER" then
            if game.bankroll >= game.bet and game.bet > 0 then
                start_hand(); bump()
            end
            return "handled"
        end
    elseif game.state == STATE_PLAYING then
        if key.character == "h" or key.special == "UP" then
            player_hit(); bump(); return "handled"
        elseif key.character == "s" or key.special == "DOWN"
                or key.special == "ENTER" then
            player_stand(); bump(); return "handled"
        end
    elseif game.state == STATE_RESULT then
        if key.special == "ENTER" then
            if game.bankroll <= 0 then
                init_game()
            else
                if game.bet > game.bankroll then game.bet = game.bankroll end
                game.state   = STATE_BETTING
                game.message = "Place your bet"
                game.player  = {}
                game.dealer  = {}
            end
            bump()
            return "handled"
        end
    end

    return nil
end

return Blackjack
