-- Card Graphics and Deck Management Module
-- Reusable card rendering for poker, blackjack, solitaire, etc.

local Cards = {}

-- Card dimensions
Cards.CARD_WIDTH = 28
Cards.CARD_HEIGHT = 40
Cards.CARD_RADIUS = 3

-- Mini card dimensions (for tight spaces)
Cards.MINI_WIDTH = 20
Cards.MINI_HEIGHT = 28

-- Suits
Cards.SUITS = {
    HEARTS = 1,
    DIAMONDS = 2,
    CLUBS = 3,
    SPADES = 4,
}

-- Suit symbols (text fallback)
Cards.SUIT_SYMBOLS = {
    [1] = "H",  -- Hearts
    [2] = "D",  -- Diamonds
    [3] = "C",  -- Clubs
    [4] = "S",  -- Spades
}

-- Suit colors
Cards.SUIT_COLORS = {
    [1] = 0xF800,  -- Hearts = Red
    [2] = 0xF800,  -- Diamonds = Red
    [3] = 0x0000,  -- Clubs = Black
    [4] = 0x0000,  -- Spades = Black
}

-- Values (1=Ace, 11=Jack, 12=Queen, 13=King)
Cards.VALUES = {
    ACE = 1, TWO = 2, THREE = 3, FOUR = 4, FIVE = 5,
    SIX = 6, SEVEN = 7, EIGHT = 8, NINE = 9, TEN = 10,
    JACK = 11, QUEEN = 12, KING = 13,
}

-- Value display strings
Cards.VALUE_STRINGS = {
    [1] = "A", [2] = "2", [3] = "3", [4] = "4", [5] = "5",
    [6] = "6", [7] = "7", [8] = "8", [9] = "9", [10] = "10",
    [11] = "J", [12] = "Q", [13] = "K",
}

-- Card back color
Cards.BACK_COLOR = 0x001F  -- Dark blue
Cards.BACK_PATTERN_COLOR = 0x07FF  -- Cyan pattern

-- Create a new card
-- @param suit Suit constant (1-4)
-- @param value Value constant (1-13)
-- @return card table
function Cards.new_card(suit, value)
    return {
        suit = suit,
        value = value,
        face_up = false,
    }
end

-- Create a standard 52-card deck
-- @return array of cards
function Cards.new_deck()
    local deck = {}
    for suit = 1, 4 do
        for value = 1, 13 do
            table.insert(deck, Cards.new_card(suit, value))
        end
    end
    return deck
end

-- Shuffle a deck in place (Fisher-Yates algorithm)
-- @param deck Array of cards
function Cards.shuffle(deck)
    for i = #deck, 2, -1 do
        local j = math.random(1, i)
        deck[i], deck[j] = deck[j], deck[i]
    end
end

-- Deal cards from deck
-- @param deck Array of cards
-- @param count Number of cards to deal
-- @return array of dealt cards, or nil if not enough cards
function Cards.deal(deck, count)
    if #deck < count then return nil end

    local hand = {}
    for i = 1, count do
        table.insert(hand, table.remove(deck))
    end
    return hand
end

-- Get card name string
-- @param card Card table
-- @return string like "Ace of Spades"
function Cards.get_name(card)
    local suit_names = {"Hearts", "Diamonds", "Clubs", "Spades"}
    local value_names = {"Ace", "Two", "Three", "Four", "Five", "Six",
                         "Seven", "Eight", "Nine", "Ten", "Jack", "Queen", "King"}
    return value_names[card.value] .. " of " .. suit_names[card.suit]
end

-- Get short card string
-- @param card Card table
-- @return string like "AS" for Ace of Spades
function Cards.get_short(card)
    return Cards.VALUE_STRINGS[card.value] .. Cards.SUIT_SYMBOLS[card.suit]
end

-- Draw a heart shape
local function draw_heart(display, x, y, size, color)
    local s = math.floor(size / 4)
    -- Two circles at top
    display.fill_circle(x + s, y + s, s, color)
    display.fill_circle(x + 3*s, y + s, s, color)
    -- Triangle at bottom
    display.fill_triangle(x, y + s, x + 2*s, y + 4*s, x + 4*s, y + s, color)
end

-- Draw a diamond shape
local function draw_diamond(display, x, y, size, color)
    local cx = math.floor(x + size/2)
    local cy = math.floor(y + size/2)
    display.fill_triangle(cx, y, x, cy, cx, y + size, color)
    display.fill_triangle(cx, y, x + size, cy, cx, y + size, color)
end

-- Draw a club shape
local function draw_club(display, x, y, size, color)
    local s = math.floor(size / 5)
    local cx = math.floor(x + size/2)
    -- Three circles
    display.fill_circle(cx, y + s, s, color)
    display.fill_circle(x + s, y + 3*s, s, color)
    display.fill_circle(x + 4*s, y + 3*s, s, color)
    -- Stem
    display.fill_rect(math.floor(cx - s/2), y + 2*s, s, 3*s, color)
end

-- Draw a spade shape
local function draw_spade(display, x, y, size, color)
    local s = math.floor(size / 4)
    local cx = math.floor(x + size/2)
    -- Inverted heart (two circles + triangle pointing up)
    display.fill_circle(x + s, y + 2*s, s, color)
    display.fill_circle(x + 3*s, y + 2*s, s, color)
    display.fill_triangle(x, y + 2*s, cx, y, x + 4*s, y + 2*s, color)
    -- Stem
    display.fill_rect(math.floor(cx - s/2), y + 2*s, s, 2*s, color)
end

-- Draw suit symbol
-- @param display Display object
-- @param suit Suit constant
-- @param x, y Position
-- @param size Size of symbol
-- @param color Color to draw
function Cards.draw_suit(display, suit, x, y, size, color)
    if suit == Cards.SUITS.HEARTS then
        draw_heart(display, x, y, size, color)
    elseif suit == Cards.SUITS.DIAMONDS then
        draw_diamond(display, x, y, size, color)
    elseif suit == Cards.SUITS.CLUBS then
        draw_club(display, x, y, size, color)
    elseif suit == Cards.SUITS.SPADES then
        draw_spade(display, x, y, size, color)
    end
end

-- Draw a face-up card
-- @param display Display object
-- @param card Card table
-- @param x, y Position (top-left corner)
-- @param width, height Optional dimensions (default CARD_WIDTH x CARD_HEIGHT)
function Cards.draw_face_up(display, card, x, y, width, height)
    width = width or Cards.CARD_WIDTH
    height = height or Cards.CARD_HEIGHT

    local suit_color = Cards.SUIT_COLORS[card.suit]
    local value_str = Cards.VALUE_STRINGS[card.value]

    -- Card background (white with rounded corners)
    display.fill_round_rect(x, y, width, height, Cards.CARD_RADIUS, 0xFFFF)

    -- Card border
    display.draw_round_rect(x, y, width, height, Cards.CARD_RADIUS, 0x0000)

    -- Value in top-left corner
    display.set_font_size("small")
    display.draw_text(x + 2, y + 2, value_str, suit_color)

    -- Small suit symbol in top-left (below value)
    local small_suit_size = 6
    Cards.draw_suit(display, card.suit, x + 2, y + 12, small_suit_size, suit_color)

    -- Large center suit symbol
    local center_suit_size = math.floor(math.min(width, height) / 3)
    local cx = math.floor(x + (width - center_suit_size) / 2)
    local cy = math.floor(y + (height - center_suit_size) / 2)
    Cards.draw_suit(display, card.suit, cx, cy, center_suit_size, suit_color)

    -- Value in bottom-right (upside down conceptually, but we just mirror position)
    local val_width = display.text_width(value_str)
    display.draw_text(x + width - val_width - 2, y + height - 12, value_str, suit_color)

    -- Small suit in bottom-right
    Cards.draw_suit(display, card.suit, x + width - small_suit_size - 2,
                    y + height - small_suit_size - 14, small_suit_size, suit_color)
end

-- Draw a face-down card (card back)
-- @param display Display object
-- @param x, y Position
-- @param width, height Optional dimensions
function Cards.draw_face_down(display, x, y, width, height)
    width = width or Cards.CARD_WIDTH
    height = height or Cards.CARD_HEIGHT

    -- Card background
    display.fill_round_rect(x, y, width, height, Cards.CARD_RADIUS, Cards.BACK_COLOR)

    -- Border
    display.draw_round_rect(x, y, width, height, Cards.CARD_RADIUS, 0xFFFF)

    -- Diamond pattern on back
    local pattern_margin = 3
    local px = x + pattern_margin
    local py = y + pattern_margin
    local pw = width - pattern_margin * 2
    local ph = height - pattern_margin * 2

    -- Inner rectangle
    display.draw_round_rect(px, py, pw, ph, 2, Cards.BACK_PATTERN_COLOR)

    -- Cross pattern
    local cx = math.floor(x + width / 2)
    local cy = math.floor(y + height / 2)
    display.draw_line(px + 2, cy, px + pw - 2, cy, Cards.BACK_PATTERN_COLOR)
    display.draw_line(cx, py + 2, cx, py + ph - 2, Cards.BACK_PATTERN_COLOR)
end

-- Draw a card (auto-detects face up/down)
-- @param display Display object
-- @param card Card table (with face_up field)
-- @param x, y Position
-- @param width, height Optional dimensions
function Cards.draw(display, card, x, y, width, height)
    if card.face_up then
        Cards.draw_face_up(display, card, x, y, width, height)
    else
        Cards.draw_face_down(display, x, y, width, height)
    end
end

-- Draw empty card slot (placeholder)
-- @param display Display object
-- @param x, y Position
-- @param width, height Optional dimensions
function Cards.draw_empty_slot(display, x, y, width, height)
    width = width or Cards.CARD_WIDTH
    height = height or Cards.CARD_HEIGHT

    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or {SURFACE = 0x2104}

    -- Dashed outline
    display.draw_round_rect(x, y, width, height, Cards.CARD_RADIUS, colors.SURFACE)
end

-- Draw a hand of cards with overlap
-- @param display Display object
-- @param hand Array of cards
-- @param x, y Starting position
-- @param overlap Horizontal overlap in pixels (default 20)
-- @param width, height Card dimensions
function Cards.draw_hand(display, hand, x, y, overlap, width, height)
    overlap = overlap or 20
    width = width or Cards.CARD_WIDTH
    height = height or Cards.CARD_HEIGHT

    for i, card in ipairs(hand) do
        local card_x = x + (i - 1) * overlap
        Cards.draw(display, card, card_x, y, width, height)
    end
end

-- Draw cards spread horizontally with spacing
-- @param display Display object
-- @param cards Array of cards
-- @param x, y Starting position
-- @param spacing Horizontal spacing between cards
-- @param width, height Card dimensions
function Cards.draw_spread(display, cards, x, y, spacing, width, height)
    spacing = spacing or 4
    width = width or Cards.CARD_WIDTH
    height = height or Cards.CARD_HEIGHT

    for i, card in ipairs(cards) do
        local card_x = x + (i - 1) * (width + spacing)
        Cards.draw(display, card, card_x, y, width, height)
    end
end

-- Calculate hand width when drawn with overlap
-- @param num_cards Number of cards
-- @param overlap Overlap amount
-- @param card_width Card width
-- @return Total width in pixels
function Cards.hand_width(num_cards, overlap, card_width)
    overlap = overlap or 20
    card_width = card_width or Cards.CARD_WIDTH

    if num_cards <= 0 then return 0 end
    return card_width + (num_cards - 1) * overlap
end

-- Calculate spread width
-- @param num_cards Number of cards
-- @param spacing Spacing between cards
-- @param card_width Card width
-- @return Total width in pixels
function Cards.spread_width(num_cards, spacing, card_width)
    spacing = spacing or 4
    card_width = card_width or Cards.CARD_WIDTH

    if num_cards <= 0 then return 0 end
    return num_cards * card_width + (num_cards - 1) * spacing
end

-- Poker hand evaluation helpers
Cards.HAND_RANKS = {
    HIGH_CARD = 1,
    PAIR = 2,
    TWO_PAIR = 3,
    THREE_OF_KIND = 4,
    STRAIGHT = 5,
    FLUSH = 6,
    FULL_HOUSE = 7,
    FOUR_OF_KIND = 8,
    STRAIGHT_FLUSH = 9,
    ROYAL_FLUSH = 10,
}

Cards.HAND_NAMES = {
    [1] = "High Card",
    [2] = "Pair",
    [3] = "Two Pair",
    [4] = "Three of a Kind",
    [5] = "Straight",
    [6] = "Flush",
    [7] = "Full House",
    [8] = "Four of a Kind",
    [9] = "Straight Flush",
    [10] = "Royal Flush",
}

-- Sort cards by value (descending)
function Cards.sort_by_value(cards)
    table.sort(cards, function(a, b) return a.value > b.value end)
end

-- Count cards by value
-- @return table mapping value -> count
function Cards.count_values(cards)
    local counts = {}
    for _, card in ipairs(cards) do
        counts[card.value] = (counts[card.value] or 0) + 1
    end
    return counts
end

-- Count cards by suit
-- @return table mapping suit -> count
function Cards.count_suits(cards)
    local counts = {}
    for _, card in ipairs(cards) do
        counts[card.suit] = (counts[card.suit] or 0) + 1
    end
    return counts
end

-- Check if cards form a straight (5 consecutive values)
-- @param cards Array of 5+ cards
-- @return highest card value in straight, or nil
function Cards.check_straight(cards)
    -- Get unique values, sorted descending
    local values = {}
    local seen = {}
    for _, card in ipairs(cards) do
        if not seen[card.value] then
            seen[card.value] = true
            table.insert(values, card.value)
        end
    end
    table.sort(values, function(a, b) return a > b end)

    -- Check for 5 consecutive
    for i = 1, #values - 4 do
        local is_straight = true
        for j = 0, 3 do
            if values[i + j] - values[i + j + 1] ~= 1 then
                is_straight = false
                break
            end
        end
        if is_straight then
            return values[i]
        end
    end

    -- Check for wheel (A-2-3-4-5)
    if seen[14] or seen[1] then  -- Ace
        local ace_val = seen[14] and 14 or 1
        if seen[2] and seen[3] and seen[4] and seen[5] then
            return 5  -- 5-high straight
        end
    end

    return nil
end

-- Check if 5+ cards have a flush (5 same suit)
-- @return suit of flush, or nil
function Cards.check_flush(cards)
    local suit_counts = Cards.count_suits(cards)
    for suit, count in pairs(suit_counts) do
        if count >= 5 then
            return suit
        end
    end
    return nil
end

-- Evaluate a poker hand (best 5 from 7 cards)
-- @param cards Array of cards (typically 7 for Texas Hold'em)
-- @return rank (1-10), high_cards (array for tiebreaker)
function Cards.evaluate_hand(cards)
    if #cards < 5 then
        return Cards.HAND_RANKS.HIGH_CARD, {0}
    end

    local value_counts = Cards.count_values(cards)
    local suit_counts = Cards.count_suits(cards)

    -- Count pairs, trips, quads
    local found_pairs = {}
    local trips = {}
    local quads = {}

    for value, count in pairs(value_counts) do
        if count == 4 then
            table.insert(quads, value)
        elseif count == 3 then
            table.insert(trips, value)
        elseif count == 2 then
            table.insert(found_pairs, value)
        end
    end

    table.sort(found_pairs, function(a, b) return a > b end)
    table.sort(trips, function(a, b) return a > b end)
    table.sort(quads, function(a, b) return a > b end)

    -- Check for flush
    local flush_suit = Cards.check_flush(cards)

    -- Check for straight
    local straight_high = Cards.check_straight(cards)

    -- Check straight flush / royal flush
    if flush_suit and straight_high then
        -- Get flush cards and check for straight among them
        local flush_cards = {}
        for _, card in ipairs(cards) do
            if card.suit == flush_suit then
                table.insert(flush_cards, card)
            end
        end
        local sf_high = Cards.check_straight(flush_cards)
        if sf_high then
            if sf_high == 14 then  -- Ace-high straight flush
                return Cards.HAND_RANKS.ROYAL_FLUSH, {14}
            else
                return Cards.HAND_RANKS.STRAIGHT_FLUSH, {sf_high}
            end
        end
    end

    -- Four of a kind
    if #quads > 0 then
        return Cards.HAND_RANKS.FOUR_OF_KIND, {quads[1]}
    end

    -- Full house
    if #trips > 0 and (#found_pairs > 0 or #trips > 1) then
        local pair_val = #found_pairs > 0 and found_pairs[1] or trips[2]
        return Cards.HAND_RANKS.FULL_HOUSE, {trips[1], pair_val}
    end

    -- Flush
    if flush_suit then
        local flush_cards = {}
        for _, card in ipairs(cards) do
            if card.suit == flush_suit then
                table.insert(flush_cards, card.value)
            end
        end
        table.sort(flush_cards, function(a, b) return a > b end)
        return Cards.HAND_RANKS.FLUSH, {flush_cards[1], flush_cards[2], flush_cards[3], flush_cards[4], flush_cards[5]}
    end

    -- Straight
    if straight_high then
        return Cards.HAND_RANKS.STRAIGHT, {straight_high}
    end

    -- Three of a kind
    if #trips > 0 then
        return Cards.HAND_RANKS.THREE_OF_KIND, {trips[1]}
    end

    -- Two pair
    if #found_pairs >= 2 then
        return Cards.HAND_RANKS.TWO_PAIR, {found_pairs[1], found_pairs[2]}
    end

    -- One pair
    if #found_pairs == 1 then
        return Cards.HAND_RANKS.PAIR, {found_pairs[1]}
    end

    -- High card
    local highs = {}
    for _, card in ipairs(cards) do
        table.insert(highs, card.value)
    end
    table.sort(highs, function(a, b) return a > b end)
    return Cards.HAND_RANKS.HIGH_CARD, {highs[1], highs[2], highs[3], highs[4], highs[5]}
end

-- Compare two evaluated hands
-- @return 1 if hand1 wins, -1 if hand2 wins, 0 if tie
function Cards.compare_hands(rank1, highs1, rank2, highs2)
    if rank1 > rank2 then return 1 end
    if rank1 < rank2 then return -1 end

    -- Same rank, compare high cards
    for i = 1, math.min(#highs1, #highs2) do
        if highs1[i] > highs2[i] then return 1 end
        if highs1[i] < highs2[i] then return -1 end
    end

    return 0  -- Tie
end

return Cards
