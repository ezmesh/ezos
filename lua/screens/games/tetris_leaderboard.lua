-- Tetris leaderboard.
--
-- Shows the top-5 high scores for both Easy and Hard difficulties on a
-- single screen. The game-over panel inside tetris.lua already prints
-- one of these lists, but only the board for the difficulty that was
-- just played and only while the player is still on the over-screen.
-- This screen makes both boards reachable from the tetris menu at any
-- time.

local ui         = require("ezui")
local highscores = require("engine.highscores")

local Screen = { title = "Tetris scores" }

local HS_KEYS = { easy = "tetris_easy", hard = "tetris_hard" }

local function format_row(i, h)
    local name = (h.name and h.name ~= "") and h.name or "---"
    return string.format("%d. %-12s %6d  %d lines",
        i, name, h.score, h.extra)
end

local function board_section(label, key)
    local rows = highscores.format(key, format_row)
    local children = {
        ui.text_widget(label, {
            font = "small_aa", color = "TEXT_SEC",
        }),
    }
    for _, line in ipairs(rows) do
        children[#children + 1] = ui.text_widget(line, {
            font = "small_aa", color = "TEXT",
        })
    end
    return ui.padding({ 6, 12, 4, 12 },
        ui.vbox({ gap = 2 }, children))
end

function Screen:build(_state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Tetris scores", { back = true }),
        ui.scroll({ grow = 1 },
            ui.vbox({ gap = 4 }, {
                board_section("EASY", HS_KEYS.easy),
                board_section("HARD", HS_KEYS.hard),
            })
        ),
    })
end

function Screen:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    return nil
end

return Screen
