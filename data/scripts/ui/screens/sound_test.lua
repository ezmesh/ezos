-- Sound Test Screen for T-Deck OS
-- Test audio output

local SoundTest = {
    title = "Sound Test",
    selected = 1,
    frequencies = {262, 294, 330, 349, 392, 440, 494, 523},  -- C4 to C5
    note_names = {"C4", "D4", "E4", "F4", "G4", "A4", "B4", "C5"},
    playing = false
}

function SoundTest:new()
    local o = {
        title = self.title,
        selected = 1,
        playing = false
    }
    setmetatable(o, {__index = SoundTest})
    return o
end

function SoundTest:on_exit()
    if tdeck.audio and tdeck.audio.stop then
        tdeck.audio.stop()
    end
end

function SoundTest:render(display)
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    local y = 3 * display.font_height
    local x = 4 * display.font_width

    display.draw_text(x, y, "Select a note to play:", colors.TEXT)
    y = y + display.font_height * 2

    -- Draw piano keys representation
    for i, name in ipairs(self.note_names) do
        local is_selected = (i == self.selected)
        local key_x = x + (i - 1) * 4 * display.font_width

        -- Key background
        local key_color = is_selected and colors.CYAN or colors.WHITE
        display.fill_rect(key_x, y, 3 * display.font_width, 3 * display.font_height, key_color)

        -- Key label
        local text_color = is_selected and colors.BLACK or colors.BLACK
        display.draw_text(key_x + display.font_width, y + display.font_height, name, text_color)
    end

    y = y + 5 * display.font_height

    -- Status
    if self.playing then
        display.draw_text(x, y, "Playing: " .. self.note_names[self.selected], colors.GREEN)
    else
        display.draw_text(x, y, "Press ENTER to play", colors.TEXT_DIM)
    end

    y = y + display.font_height * 2

    -- Beep button
    display.draw_text(x, y, "[B] Quick beep", colors.TEXT)

    -- Help text
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[<>]Select [Enter]Play [S]Stop [Q]Back", colors.TEXT_DIM)
end

function SoundTest:handle_key(key)
    if key.special == "LEFT" then
        if self.selected > 1 then
            self.selected = self.selected - 1
        end
        tdeck.screen.invalidate()
    elseif key.special == "RIGHT" then
        if self.selected < #self.note_names then
            self.selected = self.selected + 1
        end
        tdeck.screen.invalidate()
    elseif key.special == "ENTER" then
        self:play_note()
    elseif key.special == "ESCAPE" or key.character == "q" then
        self:on_exit()
        return "pop"
    elseif key.character == "s" then
        self:stop()
    elseif key.character == "b" then
        self:beep()
    end

    return "continue"
end

function SoundTest:play_note()
    if tdeck.audio and tdeck.audio.play_tone then
        local freq = self.frequencies[self.selected]
        tdeck.audio.play_tone(freq, 500)
        self.playing = true
        tdeck.screen.invalidate()

        -- Auto-stop indicator after duration
        -- (The actual sound stops automatically)
    end
end

function SoundTest:stop()
    if tdeck.audio and tdeck.audio.stop then
        tdeck.audio.stop()
        self.playing = false
        tdeck.screen.invalidate()
    end
end

function SoundTest:beep()
    if tdeck.audio and tdeck.audio.beep then
        tdeck.audio.beep()
    elseif tdeck.audio and tdeck.audio.play_tone then
        tdeck.audio.play_tone(1000, 100)
    end
end

return SoundTest
