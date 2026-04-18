-- Solitaire: Klondike solitaire card game
-- Arrows to move cursor, Enter to select/place/draw, Escape to cancel, R to restart, Q to quit.

local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")

local Solitaire = { title = "Solitaire", fullscreen = true }

local floor = math.floor
local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

-- Card dimensions
local CARD_W = 28
local CARD_H = 36
local FACEDOWN_STEP = 6   -- vertical pixels shown per face-down card in tableau
local FACEUP_STEP = 14    -- vertical pixels shown per face-up card in tableau

-- Layout positions for the top row
local STOCK_X = 4
local STOCK_Y = 2
local WASTE_X = 36
local WASTE_Y = 2
local FOUND_START_X = 132  -- first foundation pile x
local FOUND_Y = 2
local FOUND_GAP = 32       -- spacing between foundation piles

-- Tableau layout
local TAB_Y = 46
local TAB_COUNT = 7
local TAB_COL_W = 40
local TAB_START_X = floor((320 - TAB_COUNT * TAB_COL_W) / 2)

-- Suit definitions: 1=hearts, 2=diamonds, 3=clubs, 4=spades
local SUIT_RED = { true, true, false, false }

-- Draw a suit icon at (x, y) with given size (width/height ~= size)
-- suit: 1=heart, 2=diamond, 3=club, 4=spade
local function draw_suit(d, suit, x, y, sz, color)
    local s = sz or 7
    local hs = floor(s / 2)
    if suit == 1 then
        -- Heart: two circles on top, triangle pointing down
        local r = floor(s / 4) + 1
        d.fill_circle(x + hs - r + 1, y + r, r, color)
        d.fill_circle(x + hs + r - 1, y + r, r, color)
        d.fill_triangle(x, y + r, x + s, y + r, x + hs, y + s, color)
    elseif suit == 2 then
        -- Diamond: rotated square (4 triangles forming a diamond)
        local cx, cy = x + hs, y + hs
        d.fill_triangle(cx, y, x + s, cy, cx, y + s, color)
        d.fill_triangle(cx, y, x, cy, cx, y + s, color)
    elseif suit == 3 then
        -- Club: three circles in a trefoil + stem
        local r = floor(s / 4) + 1
        d.fill_circle(x + hs, y + r, r, color)
        d.fill_circle(x + hs - r, y + hs + 1, r, color)
        d.fill_circle(x + hs + r, y + hs + 1, r, color)
        d.fill_rect(x + hs - 1, y + hs, 3, hs, color)
    elseif suit == 4 then
        -- Spade: inverted heart (triangle up + two circles) + stem
        local r = floor(s / 4) + 1
        d.fill_triangle(x, y + hs + 1, x + s, y + hs + 1, x + hs, y, color)
        d.fill_circle(x + hs - r + 1, y + hs + 1, r, color)
        d.fill_circle(x + hs + r - 1, y + hs + 1, r, color)
        d.fill_rect(x + hs - 1, y + hs + 1, 3, hs, color)
    end
end
local RANK_CHARS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }

-- Game state
local stock = {}
local waste = {}
local foundations = { {}, {}, {}, {} }
local tableau = { {}, {}, {}, {}, {}, {}, {} }
local cursor = "stock"      -- current cursor location
local selection = nil        -- { source=location, cards={card,...}, count=N } or nil
local game_won = false

-- Build and shuffle a standard 52-card deck
local function make_deck()
    local deck = {}
    for suit = 1, 4 do
        for rank = 1, 13 do
            deck[#deck + 1] = { rank = rank, suit = suit, face_up = false }
        end
    end
    math.randomseed(ez.system.millis())
    for i = #deck, 2, -1 do
        local j = math.random(1, i)
        deck[i], deck[j] = deck[j], deck[i]
    end
    return deck
end

-- Deal a new game from a shuffled deck
local function new_game()
    local deck = make_deck()
    stock = {}
    waste = {}
    foundations = { {}, {}, {}, {} }
    tableau = { {}, {}, {}, {}, {}, {}, {} }
    selection = nil
    game_won = false
    cursor = "stock"

    -- Deal tableau: column i gets i cards, only the last is face-up
    local idx = 1
    for col = 1, TAB_COUNT do
        for row = 1, col do
            local card = deck[idx]
            card.face_up = (row == col)
            tableau[col][row] = card
            idx = idx + 1
        end
    end

    -- Remaining cards go to stock (face-down)
    for i = idx, 52 do
        deck[i].face_up = false
        stock[#stock + 1] = deck[i]
    end
end

-- Check if a card is red
local function is_red(card)
    return SUIT_RED[card.suit]
end

-- Check if moving cards onto a tableau target is valid.
-- bottom_card is the lowest card being moved.
-- target is the tableau column table.
local function can_place_on_tableau(bottom_card, target)
    if #target == 0 then
        -- Only kings can be placed on empty tableau columns
        return bottom_card.rank == 13
    end
    local top = target[#target]
    if not top.face_up then return false end
    -- Must alternate colors and descend in rank
    return is_red(bottom_card) ~= is_red(top) and bottom_card.rank == top.rank - 1
end

-- Check if a card can be placed on a foundation pile
local function can_place_on_foundation(card, fnd_idx)
    local pile = foundations[fnd_idx]
    if #pile == 0 then
        return card.rank == 1  -- only aces on empty foundations
    end
    local top = pile[#pile]
    return card.suit == top.suit and card.rank == top.rank + 1
end

-- Parse a location string into its type and index
-- Returns type ("stock","waste","foundation","tableau") and index (1-based) or nil
local function parse_location(loc)
    if loc == "stock" then return "stock", 0 end
    if loc == "waste" then return "waste", 0 end
    local fi = loc:match("^f(%d)$")
    if fi then return "foundation", tonumber(fi) end
    local ti = loc:match("^t(%d)$")
    if ti then return "tableau", tonumber(ti) end
    return nil, 0
end

-- Get the pile table for a given location
local function get_pile(loc)
    local lt, idx = parse_location(loc)
    if lt == "stock" then return stock end
    if lt == "waste" then return waste end
    if lt == "foundation" then return foundations[idx] end
    if lt == "tableau" then return tableau[idx] end
    return nil
end

-- Flip the top card of a tableau column face-up if it is face-down
local function reveal_top(col)
    local t = tableau[col]
    if #t > 0 and not t[#t].face_up then
        t[#t].face_up = true
    end
end

-- Check if the game has been won (all foundations have 13 cards)
local function check_win()
    for i = 1, 4 do
        if #foundations[i] ~= 13 then return end
    end
    game_won = true
end

-- Try to automatically move a card to a foundation (used by 'a' key)
local function auto_move(loc)
    local lt, idx = parse_location(loc)
    local pile
    if lt == "waste" then
        pile = waste
    elseif lt == "tableau" then
        pile = tableau[idx]
    else
        return false
    end
    if #pile == 0 then return false end
    local card = pile[#pile]
    if not card.face_up then return false end
    for fi = 1, 4 do
        if can_place_on_foundation(card, fi) then
            foundations[fi][#foundations[fi] + 1] = card
            table.remove(pile, #pile)
            if lt == "tableau" then reveal_top(idx) end
            check_win()
            return true
        end
    end
    return false
end

-- Navigation: define the ordered locations in each row
local TOP_ROW = { "stock", "waste", "f1", "f2", "f3", "f4" }
local BOT_ROW = { "t1", "t2", "t3", "t4", "t5", "t6", "t7" }

-- Find which row and position a location is in
local function find_in_rows(loc)
    for i, v in ipairs(TOP_ROW) do
        if v == loc then return "top", i end
    end
    for i, v in ipairs(BOT_ROW) do
        if v == loc then return "bot", i end
    end
    return "top", 1
end

-- Move cursor in a direction
local function move_cursor(dir)
    local row, pos = find_in_rows(cursor)
    if dir == "LEFT" then
        if row == "top" then
            cursor = TOP_ROW[math.max(1, pos - 1)]
        else
            cursor = BOT_ROW[math.max(1, pos - 1)]
        end
    elseif dir == "RIGHT" then
        if row == "top" then
            cursor = TOP_ROW[math.min(#TOP_ROW, pos + 1)]
        else
            cursor = BOT_ROW[math.min(#BOT_ROW, pos + 1)]
        end
    elseif dir == "UP" then
        if row == "bot" then
            -- Move to the nearest top-row position
            if pos <= 2 then
                cursor = TOP_ROW[pos]
            else
                -- Map tableau columns 3-7 to foundations 1-4 and overflow
                cursor = TOP_ROW[math.min(pos, #TOP_ROW)]
            end
        end
    elseif dir == "DOWN" then
        if row == "top" then
            -- Move to the nearest tableau column
            if pos <= 2 then
                cursor = BOT_ROW[pos]
            else
                cursor = BOT_ROW[math.min(pos, #BOT_ROW)]
            end
        end
    end
end

-- Handle enter/select action at current cursor location
local function do_action()
    local lt, idx = parse_location(cursor)

    -- Stock: draw a card or recycle waste
    if lt == "stock" then
        if selection then
            selection = nil  -- cancel selection when clicking stock
        end
        if #stock > 0 then
            local card = table.remove(stock, #stock)
            card.face_up = true
            waste[#waste + 1] = card
        elseif #waste > 0 then
            -- Recycle waste back to stock
            for i = #waste, 1, -1 do
                waste[i].face_up = false
                stock[#stock + 1] = waste[i]
            end
            waste = {}
        end
        return
    end

    -- If we have a selection, try to place it
    if selection then
        local target_type = lt
        local target_idx = idx

        if target_type == "foundation" then
            -- Can only place a single card on foundation
            if selection.count == 1 then
                local card = selection.cards[1]
                if can_place_on_foundation(card, target_idx) then
                    -- Remove from source
                    local src_lt, src_idx = parse_location(selection.source)
                    if src_lt == "waste" then
                        table.remove(waste, #waste)
                    elseif src_lt == "tableau" then
                        for i = 1, selection.count do
                            table.remove(tableau[src_idx])
                        end
                        reveal_top(src_idx)
                    elseif src_lt == "foundation" then
                        table.remove(foundations[src_idx])
                    end
                    foundations[target_idx][#foundations[target_idx] + 1] = card
                    selection = nil
                    check_win()
                    return
                end
            end
        elseif target_type == "tableau" then
            local bottom_card = selection.cards[1]
            if can_place_on_tableau(bottom_card, tableau[target_idx]) then
                -- Remove from source
                local src_lt, src_idx = parse_location(selection.source)
                if src_lt == "waste" then
                    table.remove(waste, #waste)
                elseif src_lt == "tableau" then
                    for i = 1, selection.count do
                        table.remove(tableau[src_idx])
                    end
                    reveal_top(src_idx)
                elseif src_lt == "foundation" then
                    table.remove(foundations[src_idx])
                end
                -- Add cards to target tableau
                local t = tableau[target_idx]
                for i = 1, selection.count do
                    t[#t + 1] = selection.cards[i]
                end
                selection = nil
                check_win()
                return
            end
        end

        -- If we clicked the same location, deselect
        if cursor == selection.source then
            selection = nil
            return
        end

        -- Invalid move: keep selection active so user can try another target
        return
    end

    -- No selection: try to select from current location
    if lt == "waste" then
        if #waste > 0 then
            selection = { source = cursor, cards = { waste[#waste] }, count = 1 }
        end
    elseif lt == "foundation" then
        local pile = foundations[idx]
        if #pile > 0 then
            selection = { source = cursor, cards = { pile[#pile] }, count = 1 }
        end
    elseif lt == "tableau" then
        local col = tableau[idx]
        if #col == 0 then return end
        -- Select all face-up cards from the bottom of the face-up run
        local face_up_start = #col
        for i = #col, 1, -1 do
            if col[i].face_up then
                face_up_start = i
            else
                break
            end
        end
        local cards = {}
        for i = face_up_start, #col do
            cards[#cards + 1] = col[i]
        end
        selection = { source = cursor, cards = cards, count = #cards }
    end
end

-- Get the screen position of a location (for cursor drawing)
local function get_location_rect(loc)
    local lt, idx = parse_location(loc)
    if lt == "stock" then
        return STOCK_X, STOCK_Y, CARD_W, CARD_H
    elseif lt == "waste" then
        return WASTE_X, WASTE_Y, CARD_W, CARD_H
    elseif lt == "foundation" then
        return FOUND_START_X + (idx - 1) * FOUND_GAP, FOUND_Y, CARD_W, CARD_H
    elseif lt == "tableau" then
        local x = TAB_START_X + (idx - 1) * TAB_COL_W
        local col = tableau[idx]
        if #col == 0 then
            return x, TAB_Y, CARD_W, CARD_H
        end
        -- Cursor goes on the topmost card
        local y = TAB_Y
        for i = 1, #col - 1 do
            if col[i].face_up then
                y = y + FACEUP_STEP
            else
                y = y + FACEDOWN_STEP
            end
        end
        return x, y, CARD_W, CARD_H
    end
    return 0, 0, CARD_W, CARD_H
end

-- Colors
local CLR_BG = rgb(20, 80, 40)          -- green felt background
local CLR_CARD_FACE = rgb(255, 255, 255) -- white card face
local CLR_CARD_BACK = rgb(40, 40, 160)   -- blue card back
local CLR_CARD_BACK2 = rgb(60, 60, 200)  -- lighter blue for pattern
local CLR_RED = rgb(220, 30, 30)         -- red suit text
local CLR_BLACK = rgb(20, 20, 20)        -- black suit text
local CLR_EMPTY = rgb(10, 60, 30)        -- empty pile outline
local CLR_CURSOR = rgb(255, 220, 50)     -- yellow cursor
local CLR_SELECT = rgb(255, 180, 0)      -- orange selection highlight
local CLR_TEXT = rgb(200, 200, 200)       -- HUD text
local CLR_TEXT_DIM = rgb(120, 120, 120)   -- dim hint text
local CLR_WIN = rgb(50, 220, 50)         -- win text

-- Draw a single card face-up at (x, y) with optional highlight
local function draw_card_face(d, card, x, y, highlight)
    d.fill_rect(x, y, CARD_W, CARD_H, CLR_CARD_FACE)
    if highlight then
        d.draw_rect(x, y, CARD_W, CARD_H, CLR_SELECT)
        d.draw_rect(x + 1, y + 1, CARD_W - 2, CARD_H - 2, CLR_SELECT)
    else
        d.draw_rect(x, y, CARD_W, CARD_H, rgb(80, 80, 80))
    end
    -- Rank text and suit icon in the top-left corner
    theme.set_font("tiny")
    local rank_str = RANK_CHARS[card.rank]
    local text_color = is_red(card) and CLR_RED or CLR_BLACK
    d.draw_text(x + 2, y + 2, rank_str, text_color)
    draw_suit(d, card.suit, x + 2, y + 12, 7, text_color)

    -- Centered suit icon for visual distinction
    draw_suit(d, card.suit, x + floor((CARD_W - 9) / 2), y + 22, 9, text_color)
end

-- Draw a face-down card at (x, y)
local function draw_card_back(d, x, y)
    d.fill_rect(x, y, CARD_W, CARD_H, CLR_CARD_BACK)
    -- Simple cross-hatch pattern for the card back
    for py = y + 3, y + CARD_H - 4, 4 do
        d.draw_hline(x + 3, py, CARD_W - 6, CLR_CARD_BACK2)
    end
    for px = x + 3, x + CARD_W - 4, 4 do
        d.fill_rect(px, y + 3, 1, CARD_H - 6, CLR_CARD_BACK2)
    end
    d.draw_rect(x, y, CARD_W, CARD_H, rgb(30, 30, 120))
end

-- Draw an empty pile outline at (x, y)
local function draw_empty_pile(d, x, y)
    d.draw_rect(x, y, CARD_W, CARD_H, CLR_EMPTY)
    d.draw_rect(x + 1, y + 1, CARD_W - 2, CARD_H - 2, CLR_EMPTY)
end

-- Check if a card in a tableau column at a given index is part of the current selection
local function is_selected_tableau(col_idx, card_idx)
    if not selection then return false end
    local src_lt, src_idx = parse_location(selection.source)
    if src_lt ~= "tableau" or src_idx ~= col_idx then return false end
    local col = tableau[col_idx]
    local sel_start = #col - selection.count + 1
    return card_idx >= sel_start
end

-- Check if a given location's top card is selected
local function is_selected_top(loc)
    if not selection then return false end
    return selection.source == loc
end

-- Register the custom drawing node for the solitaire board
if not node_mod.handler("solitaire_view") then
    node_mod.register("solitaire_view", {
        measure = function(n, max_w, max_h) return 320, 240 end,
        draw = function(n, d, x, y, w, h)
            -- Fill background with green felt
            d.fill_rect(x, y, 320, 240, CLR_BG)

            -- === Top row: Stock, Waste, Foundations ===

            -- Stock pile
            if #stock > 0 then
                draw_card_back(d, x + STOCK_X, y + STOCK_Y)
                -- Show remaining count
                theme.set_font("tiny")
                local count_str = tostring(#stock)
                d.draw_text(x + STOCK_X + floor((CARD_W - theme.text_width(count_str)) / 2),
                           y + STOCK_Y + CARD_H + 1, count_str, CLR_TEXT_DIM)
            else
                -- Empty stock: draw recycle indicator
                draw_empty_pile(d, x + STOCK_X, y + STOCK_Y)
                theme.set_font("tiny")
                local r_str = "O"
                d.draw_text(x + STOCK_X + floor((CARD_W - theme.text_width(r_str)) / 2),
                           y + STOCK_Y + floor((CARD_H - 8) / 2), r_str, CLR_EMPTY)
            end

            -- Waste pile
            if #waste > 0 then
                local card = waste[#waste]
                draw_card_face(d, card, x + WASTE_X, y + WASTE_Y, is_selected_top("waste"))
            else
                draw_empty_pile(d, x + WASTE_X, y + WASTE_Y)
            end

            -- Foundation piles
            for fi = 1, 4 do
                local fx = x + FOUND_START_X + (fi - 1) * FOUND_GAP
                local pile = foundations[fi]
                if #pile > 0 then
                    draw_card_face(d, pile[#pile], fx, y + FOUND_Y,
                                  is_selected_top("f" .. fi))
                else
                    -- Empty foundation: show suit icon placeholder
                    draw_empty_pile(d, fx, y + FOUND_Y)
                    draw_suit(d, fi, fx + floor((CARD_W - 11) / 2),
                             y + FOUND_Y + floor((CARD_H - 11) / 2), 11, CLR_EMPTY)
                end
            end

            -- === Tableau columns ===
            for col = 1, TAB_COUNT do
                local tx = x + TAB_START_X + (col - 1) * TAB_COL_W
                local t = tableau[col]
                if #t == 0 then
                    -- Empty column: show placeholder
                    draw_empty_pile(d, tx, y + TAB_Y)
                else
                    local cy = y + TAB_Y
                    for ci = 1, #t do
                        local card = t[ci]
                        local is_last = (ci == #t)
                        local sel = is_selected_tableau(col, ci)

                        if card.face_up then
                            if is_last then
                                -- Draw full card for the top card
                                draw_card_face(d, card, tx, cy, sel)
                            else
                                -- Draw partial card (only top portion visible)
                                -- Clip to FACEUP_STEP height by drawing only the top part
                                d.fill_rect(tx, cy, CARD_W, FACEUP_STEP, CLR_CARD_FACE)
                                if sel then
                                    d.draw_rect(tx, cy, CARD_W, FACEUP_STEP, CLR_SELECT)
                                else
                                    d.draw_hline(tx, cy, CARD_W, rgb(80, 80, 80))
                                    d.fill_rect(tx, cy, 1, FACEUP_STEP, rgb(80, 80, 80))
                                    d.fill_rect(tx + CARD_W - 1, cy, 1, FACEUP_STEP, rgb(80, 80, 80))
                                end
                                theme.set_font("tiny")
                                local rank_str = RANK_CHARS[card.rank]
                                local tc = is_red(card) and CLR_RED or CLR_BLACK
                                d.draw_text(tx + 2, cy + 2, rank_str, tc)
                                draw_suit(d, card.suit, tx + 2 + theme.text_width(rank_str) + 1, cy + 2, 7, tc)
                            end
                            cy = cy + (is_last and 0 or FACEUP_STEP)
                        else
                            if is_last then
                                draw_card_back(d, tx, cy)
                            else
                                -- Face-down partial: just show the top edge
                                d.fill_rect(tx, cy, CARD_W, FACEDOWN_STEP, CLR_CARD_BACK)
                                d.draw_hline(tx, cy, CARD_W, rgb(30, 30, 120))
                                d.fill_rect(tx, cy, 1, FACEDOWN_STEP, rgb(30, 30, 120))
                                d.fill_rect(tx + CARD_W - 1, cy, 1, FACEDOWN_STEP, rgb(30, 30, 120))
                            end
                            cy = cy + (is_last and 0 or FACEDOWN_STEP)
                        end
                    end
                end
            end

            -- === Cursor highlight ===
            if not game_won then
                local cx, cy, cw, ch = get_location_rect(cursor)
                cx = x + cx
                cy = y + cy
                d.draw_rect(cx - 1, cy - 1, cw + 2, ch + 2, CLR_CURSOR)
                d.draw_rect(cx - 2, cy - 2, cw + 4, ch + 4, CLR_CURSOR)
            end

            -- === HUD text ===
            theme.set_font("tiny")
            if game_won then
                theme.set_font("small")
                local win_msg = "YOU WIN!"
                local ww = theme.text_width(win_msg)
                d.draw_text(x + floor((320 - ww) / 2), y + 228, win_msg, CLR_WIN)
            else
                local hint
                if selection then
                    hint = "Enter:place  Esc:cancel"
                else
                    hint = "Enter:sel  A:auto  R:new"
                end
                d.draw_text(x + floor((320 - theme.text_width(hint)) / 2), y + 232, hint, CLR_TEXT_DIM)
            end
        end,
    })
end

function Solitaire:build(state)
    return { type = "solitaire_view" }
end

function Solitaire:on_enter()
    new_game()
end

function Solitaire:update()
    screen_mod.invalidate()
end

function Solitaire:handle_key(key)
    -- Quit with 'q' or Escape when nothing is selected
    if key.character == "q" then return "pop" end
    if key.special == "ESCAPE" then
        if selection then
            selection = nil
            return "handled"
        end
        return "pop"
    end

    -- Restart with 'r'
    if key.character == "r" then
        new_game()
        return "handled"
    end

    if game_won then return "handled" end

    -- Navigation
    if key.special == "LEFT" then move_cursor("LEFT")
    elseif key.special == "RIGHT" then move_cursor("RIGHT")
    elseif key.special == "UP" then move_cursor("UP")
    elseif key.special == "DOWN" then move_cursor("DOWN")
    elseif key.special == "ENTER" or key.character == " " then
        do_action()
    elseif key.character == "a" then
        -- Auto-move current location's top card to a foundation
        auto_move(cursor)
    end
    return "handled"
end

return Solitaire
