-- Video Poker: Jacks-or-Better, 5-card draw, single line.
--
-- Standard "9/6 Jacks" paytable for one credit bet -- the recreational
-- machine version, not the bonus-poker variants. Bet 1-5 credits per
-- hand; payouts scale linearly except a Royal Flush at max-bet pays
-- 4000 (the classic 800-per-credit jackpot bump).
--
-- Flow: bet -> deal -> hold any subset of the 5 cards -> draw -> score.
-- Press 1..5 (or A/S/D/F/G to keep both rows reachable) to toggle a
-- hold. Enter advances bet -> deal -> draw -> next hand.

local ui    = require("ezui")
local theme = require("ezui.theme")
local node  = require("ezui.node")

local floor = math.floor
local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

-- Card geometry: 5 cards across at 50 px wide + 4 gaps of 6 px = 274,
-- centred horizontally inside the 320 px content area.
local CARD_W   = 50
local CARD_H   = 70
local CARD_GAP = 6
local HAND_W   = 5 * CARD_W + 4 * CARD_GAP

local CLR_CARD_FACE = rgb(245, 245, 240)
local CLR_CARD_BACK = rgb( 35,  60, 120)
local CLR_RED       = rgb(200,  40,  40)
local CLR_BLACK     = rgb( 20,  20,  20)
local CLR_FELT      = rgb( 20,  50,  90)
local CLR_HOLD      = rgb(255, 200,  60)

local SUIT_RED = { true, true, false, false }
local RANK_CHARS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }

local function is_red(card) return SUIT_RED[card.suit] end

local function draw_suit(d, suit, x, y, s, color)
    local hs = floor(s / 2)
    if suit == 1 then
        local r = floor(s / 4) + 1
        d.fill_circle(x + hs - r + 1, y + r, r, color)
        d.fill_circle(x + hs + r - 1, y + r, r, color)
        d.fill_triangle(x, y + r, x + s, y + r, x + hs, y + s, color)
    elseif suit == 2 then
        local cx, cy = x + hs, y + hs
        d.fill_triangle(cx, y, x + s, cy, cx, y + s, color)
        d.fill_triangle(cx, y, x, cy, cx, y + s, color)
    elseif suit == 3 then
        local r = floor(s / 4) + 1
        d.fill_circle(x + hs, y + r, r, color)
        d.fill_circle(x + hs - r, y + hs + 1, r, color)
        d.fill_circle(x + hs + r, y + hs + 1, r, color)
        d.fill_rect(x + hs - 1, y + hs, 3, hs, color)
    elseif suit == 4 then
        local r = floor(s / 4) + 1
        d.fill_triangle(x, y + hs + 1, x + s, y + hs + 1, x + hs, y, color)
        d.fill_circle(x + hs - r + 1, y + hs + 1, r, color)
        d.fill_circle(x + hs + r - 1, y + hs + 1, r, color)
        d.fill_rect(x + hs - 1, y + hs + 1, 3, hs, color)
    end
end

local function draw_card_face(d, card, x, y, held)
    d.fill_rect(x, y, CARD_W, CARD_H, CLR_CARD_FACE)
    if held then
        -- A 2 px gold frame around held cards. Visible at a glance even
        -- in a busy field, doesn't obscure the card content.
        d.draw_rect(x,     y,     CARD_W,     CARD_H,     CLR_HOLD)
        d.draw_rect(x + 1, y + 1, CARD_W - 2, CARD_H - 2, CLR_HOLD)
    else
        d.draw_rect(x, y, CARD_W, CARD_H, rgb(80, 80, 80))
    end

    local color = is_red(card) and CLR_RED or CLR_BLACK
    local rank_str = RANK_CHARS[card.rank]
    theme.set_font("small_aa", "bold")
    d.draw_text(x + 4, y + 4, rank_str, color)
    draw_suit(d, card.suit, x + 4, y + 22, 9, color)
    -- Big centre suit pip.
    draw_suit(d, card.suit,
        x + floor((CARD_W - 18) / 2),
        y + floor((CARD_H - 18) / 2) + 4,
        18, color)

    if held then
        theme.set_font("tiny_aa", "bold")
        local tag = "HELD"
        local tw = theme.text_width(tag)
        d.draw_text(x + floor((CARD_W - tw) / 2),
                    y + CARD_H - 14, tag, CLR_HOLD)
    end
end

-- ---------------------------------------------------------------------------
-- Hand evaluation
-- ---------------------------------------------------------------------------

-- Returns (rank_id, label). rank_id keys into PAYOUTS below; label
-- is what we render to the player. Strict 9/6 Jacks-or-Better: lower
-- pairs (2-10) pay nothing.
local function evaluate(hand)
    local rank_counts  = {}
    local suit_counts  = {}
    local ranks        = {}
    for _, card in ipairs(hand) do
        rank_counts[card.rank] = (rank_counts[card.rank] or 0) + 1
        suit_counts[card.suit] = (suit_counts[card.suit] or 0) + 1
        ranks[#ranks + 1] = card.rank
    end
    table.sort(ranks)

    local is_flush = false
    for _, c in pairs(suit_counts) do
        if c == 5 then is_flush = true end
    end

    local is_straight = false
    -- Five distinct ascending ranks with span 4.
    local distinct = {}
    do
        local seen = {}
        for _, r in ipairs(ranks) do
            if not seen[r] then seen[r] = true; distinct[#distinct + 1] = r end
        end
        table.sort(distinct)
    end
    if #distinct == 5 and distinct[5] - distinct[1] == 4 then
        is_straight = true
    end
    -- Wheel: A-2-3-4-5. The Ace counts low here; everywhere else it
    -- counts high (which matters for straight-flush vs royal-flush).
    local wheel = (#distinct == 5
        and distinct[1] == 1 and distinct[2] == 2
        and distinct[3] == 3 and distinct[4] == 4 and distinct[5] == 5)
    if wheel then is_straight = true end

    -- Royal vs straight flush.
    if is_flush and is_straight then
        if (not wheel)
                and distinct[5] == 13 and distinct[1] == 1 then
            -- A,K,Q,J,10 of one suit.
            local has_high = false
            for _, r in ipairs(distinct) do
                if r == 10 then has_high = true end
            end
            if has_high then
                return "royal", "Royal Flush"
            end
        end
        return "sflush", "Straight Flush"
    end

    -- Counts to identify pair patterns. Don't shadow `pairs` -- the
    -- global is the iterator we need on the next line.
    local fours, threes, pair_count, jack_or_better_pair = 0, 0, 0, false
    for r, c in pairs(rank_counts) do
        if c == 4 then fours = fours + 1 end
        if c == 3 then threes = threes + 1 end
        if c == 2 then
            pair_count = pair_count + 1
            if r == 1 or r >= 11 then jack_or_better_pair = true end
        end
    end

    if fours == 1 then return "quads",    "Four of a Kind" end
    if threes == 1 and pair_count == 1 then return "fhouse", "Full House" end
    if is_flush  then return "flush",    "Flush" end
    if is_straight then return "straight", "Straight" end
    if threes == 1 then return "trips",    "Three of a Kind" end
    if pair_count == 2 then return "twopair",  "Two Pair" end
    if jack_or_better_pair then return "jacks", "Pair (Jacks+)" end
    return "nothing", "No win"
end

-- 9/6 Jacks-or-Better, payouts per credit bet at credits 1..4.
-- Royal flush jumps to a flat 800 only at credits == 5 (the bonus).
local PAYOUTS = {
    royal    = 250,
    sflush   = 50,
    quads    = 25,
    fhouse   = 9,
    flush    = 6,
    straight = 4,
    trips    = 3,
    twopair  = 2,
    jacks    = 1,
    nothing  = 0,
}

local function payout_for(rank_id, credits)
    if rank_id == "royal" and credits == 5 then return 4000 end
    return (PAYOUTS[rank_id] or 0) * credits
end

-- ---------------------------------------------------------------------------
-- Game state
-- ---------------------------------------------------------------------------

local STATE_BETTING = "bet"
local STATE_HOLD    = "hold"
local STATE_RESULT  = "result"

local game = nil

local function new_deck()
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

local function init_game()
    math.randomseed(ez.system.millis())
    game = {
        credits   = 200,
        bet       = 1,
        deck      = nil,
        hand      = nil,
        held      = { false, false, false, false, false },
        state     = STATE_BETTING,
        last_rank = nil,
        last_label = nil,
        last_payout = 0,
        message   = "Bet then Enter to deal",
    }
end

local function deal()
    game.deck = new_deck()
    game.hand = {}
    for i = 1, 5 do
        game.hand[i] = table.remove(game.deck)
        game.held[i] = false
    end
    game.credits   = game.credits - game.bet
    game.state     = STATE_HOLD
    game.message   = "Hold cards then Enter to draw"
    game.last_rank = nil
    game.last_payout = 0
end

local function draw_replacements()
    for i = 1, 5 do
        if not game.held[i] then
            game.hand[i] = table.remove(game.deck)
        end
    end
    local rank_id, label = evaluate(game.hand)
    local pay = payout_for(rank_id, game.bet)
    game.credits     = game.credits + pay
    game.last_rank   = rank_id
    game.last_label  = label
    game.last_payout = pay
    game.state       = STATE_RESULT
    if pay > 0 then
        game.message = label .. " -- won " .. pay
    else
        game.message = label
    end
end

-- ---------------------------------------------------------------------------
-- Renderer
-- ---------------------------------------------------------------------------

-- Content area is 240 - status bar (20) - title bar (20) = 200 px tall.
local FIELD_H = 200

node.register("vpoker_field", {
    measure = function(n, max_w, max_h)
        return max_w, FIELD_H
    end,
    draw = function(n, d, x, y, w, h)
        if not game then return end
        d.fill_rect(x, y, w, h, CLR_FELT)

        -- HUD strip.
        theme.set_font("tiny_aa")
        d.fill_rect(x, y, w, 16, theme.color("SURFACE"))
        d.draw_text(x + 6, y + 3, "Credits: " .. game.credits,
            theme.color("TEXT"))
        local bet_str = "Bet: " .. game.bet
        local bw = theme.text_width(bet_str)
        d.draw_text(x + w - bw - 6, y + 3, bet_str, theme.color("TEXT"))

        -- Hand row.
        local hand_x = x + floor((w - HAND_W) / 2)
        local hand_y = y + 36
        if game.hand then
            for i = 1, 5 do
                draw_card_face(d, game.hand[i],
                    hand_x + (i - 1) * (CARD_W + CARD_GAP),
                    hand_y, game.held[i])
                -- Slot index above each card so the player can tell
                -- which key (1-5) toggles which hold.
                theme.set_font("tiny_aa")
                local lbl = tostring(i)
                local lw = theme.text_width(lbl)
                d.draw_text(hand_x + (i - 1) * (CARD_W + CARD_GAP)
                              + floor((CARD_W - lw) / 2),
                            hand_y - 12, lbl, theme.color("TEXT_MUTED"))
            end
        else
            -- Pre-deal placeholder: a hint instead of empty space.
            theme.set_font("small_aa")
            local hint = "Press Enter to deal"
            local hw = theme.text_width(hint)
            d.draw_text(x + floor((w - hw) / 2),
                        hand_y + floor(CARD_H / 2) - 4,
                        hint, theme.color("TEXT_MUTED"))
        end

        -- Footer message + key hints.
        theme.set_font("small_aa", "bold")
        local mw = theme.text_width(game.message)
        d.draw_text(x + floor((w - mw) / 2), y + h - 32,
            game.message, theme.color("ACCENT"))

        theme.set_font("tiny_aa")
        local hints
        if game.state == STATE_BETTING then
            hints = "L/R bet | Enter deal"
        elseif game.state == STATE_HOLD then
            hints = "1-5 hold | Enter draw"
        else
            hints = "Enter for next hand"
        end
        local hw = theme.text_width(hints)
        d.draw_text(x + floor((w - hw) / 2), y + h - 14,
            hints, theme.color("TEXT_MUTED"))
    end,
})

local VideoPoker = { title = "Video Poker" }

function VideoPoker.initial_state()
    return { tick = 0 }
end

function VideoPoker:on_enter()
    init_game()
    self:set_state({ tick = 0 })
end

function VideoPoker:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Video Poker", { back = true }),
        { type = "vpoker_field" },
    })
end

local function toggle_hold(i)
    if game.state ~= STATE_HOLD then return end
    game.held[i] = not game.held[i]
end

function VideoPoker:handle_key(key)
    local function bump() self:set_state({ tick = (self._state.tick or 0) + 1 }) end

    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end

    if game.state == STATE_BETTING then
        if key.special == "LEFT" or key.character == "a" then
            game.bet = math.max(1, game.bet - 1); bump(); return "handled"
        elseif key.special == "RIGHT" or key.character == "d" then
            game.bet = math.min(5, math.min(game.credits, game.bet + 1))
            bump(); return "handled"
        elseif key.special == "ENTER" then
            if game.credits >= game.bet then deal(); bump() end
            return "handled"
        end
    elseif game.state == STATE_HOLD then
        local idx = nil
        if     key.character == "1" then idx = 1
        elseif key.character == "2" then idx = 2
        elseif key.character == "3" then idx = 3
        elseif key.character == "4" then idx = 4
        elseif key.character == "5" then idx = 5
        end
        if idx then toggle_hold(idx); bump(); return "handled" end
        if key.special == "ENTER" then
            draw_replacements(); bump(); return "handled"
        end
    elseif game.state == STATE_RESULT then
        if key.special == "ENTER" then
            if game.credits <= 0 then
                init_game()
            else
                if game.bet > game.credits then game.bet = game.credits end
                game.state   = STATE_BETTING
                game.message = "Bet then Enter to deal"
                game.hand    = nil
            end
            bump()
            return "handled"
        end
    end

    return nil
end

return VideoPoker
