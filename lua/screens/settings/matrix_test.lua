-- Key Matrix diagnostic screen
-- Live view of the raw 5x7 keyboard matrix. Useful for discovering which
-- (col,row) position a key is at, or verifying raw keyboard mode works.
-- The keyboard is held in raw mode while this screen is active; normal key
-- translation resumes on exit.

local ui = require("ezui")
local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")

local Matrix = { title = "Key Matrix" }

local COLS = 5
local ROWS = 7
local matrix_bytes = { 0, 0, 0, 0, 0 }
local raw_ok = false

if not node_mod.handler("matrix_view") then
    node_mod.register("matrix_view", {
        measure = function(n, mw, mh) return mw, mh end,

        draw = function(n, d, x, y, w, h)
            d.fill_rect(x, y, w, h, theme.color("BG"))

            if not raw_ok then
                theme.set_font("medium")
                local msg = "Raw mode not available"
                local tw = theme.text_width(msg)
                d.draw_text(x + math.floor((w - tw) / 2),
                            y + math.floor(h / 2),
                            msg, theme.color("ERROR"))
                return
            end

            theme.set_font("small")
            local fh = theme.font_height()
            local cell_w = 28
            local cell_h = 22
            local grid_w = (COLS + 1) * cell_w
            local grid_h = (ROWS + 1) * cell_h
            local ox = x + math.floor((w - grid_w) / 2)
            local oy = y + 8

            -- Column headers
            for col = 0, COLS - 1 do
                local cx = ox + (col + 1) * cell_w + math.floor(cell_w / 2)
                local label = tostring(col)
                d.draw_text(cx - math.floor(theme.text_width(label) / 2),
                            oy + math.floor((cell_h - fh) / 2),
                            label, theme.color("ACCENT"))
            end

            for row = 0, ROWS - 1 do
                local ry = oy + (row + 1) * cell_h
                local label = tostring(row)
                d.draw_text(ox + math.floor((cell_w - theme.text_width(label)) / 2),
                            ry + math.floor((cell_h - fh) / 2),
                            label, theme.color("ACCENT"))

                for col = 0, COLS - 1 do
                    local cx = ox + (col + 1) * cell_w
                    local pressed = (matrix_bytes[col + 1] & (1 << row)) ~= 0
                    if pressed then
                        d.fill_round_rect(cx + 2, ry + 2, cell_w - 4, cell_h - 4, 3,
                                          theme.color("SUCCESS"))
                    else
                        d.draw_round_rect(cx + 2, ry + 2, cell_w - 4, cell_h - 4, 3,
                                          theme.color("BORDER"))
                    end
                end
            end

            -- Hint
            theme.set_font("small")
            local hint = "Press any key. q to quit."
            d.draw_text(x + math.floor((w - theme.text_width(hint)) / 2),
                        y + h - fh - 4, hint, theme.color("TEXT_MUTED"))
        end,
    })
end

function Matrix:build(state)
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar("Key Matrix", { back = true }),
        { type = "matrix_view", grow = 1 },
    })
end

function Matrix:on_enter()
    raw_ok = ez.keyboard.set_mode("raw")
end

function Matrix:on_exit()
    ez.keyboard.set_mode("normal")
end

function Matrix:update()
    if raw_ok then
        local m = ez.keyboard.read_raw_matrix()
        if m then
            for i = 1, COLS do matrix_bytes[i] = m[i] or 0 end
        end
    end
    screen_mod.invalidate()
end

function Matrix:handle_key(key)
    -- In raw mode most "keys" are suppressed. We rely on the trackball click
    -- (which still delivers ENTER) or the back button for exit.
    if key.special == "ESCAPE" or key.special == "ENTER"
            or key.special == "BACKSPACE" then
        return "pop"
    end
    return "handled"
end

return Matrix
