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
    if ez.audio and ez.audio.stop then
        ez.audio.stop()
    end
end

function SoundTest:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    local y = 3 * fh
    local x = 4 * fw

    display.draw_text(x, y, "Select a note to play:", colors.TEXT)
    y = y + fh * 2

    -- Draw piano keys representation
    for i, name in ipairs(self.note_names) do
        local is_selected = (i == self.selected)
        local key_x = x + (i - 1) * 4 * fw

        -- Key background
        local key_color = is_selected and colors.ACCENT or colors.WHITE
        display.fill_rect(key_x, y, 3 * fw, 3 * fh, key_color)

        -- Key label
        local text_color = colors.BLACK
        display.draw_text(key_x + fw, y + fh, name, text_color)
    end

    y = y + 5 * fh

    -- Status
    if self.playing then
        display.draw_text(x, y, "Playing: " .. self.note_names[self.selected], colors.SUCCESS)
    else
        display.draw_text(x, y, "Press ENTER to play", colors.TEXT_SECONDARY)
    end

    y = y + fh * 2

    -- Beep button
    display.draw_text(x, y, "[B] Quick beep", colors.TEXT)
end

function SoundTest:handle_key(key)
    if key.special == "LEFT" then
        if self.selected > 1 then
            self.selected = self.selected - 1
        end
        ScreenManager.invalidate()
    elseif key.special == "RIGHT" then
        if self.selected < #self.note_names then
            self.selected = self.selected + 1
        end
        ScreenManager.invalidate()
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
    if ez.audio and ez.audio.play_tone then
        local freq = self.frequencies[self.selected]
        ez.audio.play_tone(freq, 500)
        self.playing = true
        ScreenManager.invalidate()

        -- Auto-stop indicator after duration
        -- (The actual sound stops automatically)
    end
end

function SoundTest:stop()
    if ez.audio and ez.audio.stop then
        ez.audio.stop()
        self.playing = false
        ScreenManager.invalidate()
    end
end

function SoundTest:beep()
    if ez.audio and ez.audio.beep then
        ez.audio.beep()
    elseif ez.audio and ez.audio.play_tone then
        ez.audio.play_tone(1000, 100)
    end
end

return SoundTest
