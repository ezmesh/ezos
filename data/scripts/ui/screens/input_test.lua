-- Input Test Screen for T-Deck OS
-- Test keyboard and trackball input

local InputTest = {
    title = "Input Test",
    last_key = nil,
    key_history = {},
    max_history = 10
}

function InputTest:new()
    local o = {
        title = self.title,
        last_key = nil,
        key_history = {}
    }
    setmetatable(o, {__index = InputTest})
    return o
end

function InputTest:render(display)
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    local y = 2 * display.font_height
    local x = 2 * display.font_width

    display.draw_text(x, y, "Press any key to test:", colors.TEXT)
    y = y + display.font_height * 2

    if self.last_key then
        -- Show last key details
        display.draw_text(x, y, "Last Key:", colors.TEXT_DIM)
        y = y + display.font_height

        if self.last_key.special then
            display.draw_text(x + 2 * display.font_width, y,
                            "Special: " .. self.last_key.special, colors.CYAN)
        elseif self.last_key.character then
            display.draw_text(x + 2 * display.font_width, y,
                            "Char: '" .. self.last_key.character .. "'", colors.CYAN)
        end
        y = y + display.font_height

        -- Modifiers
        local mods = {}
        if self.last_key.shift then table.insert(mods, "SHIFT") end
        if self.last_key.ctrl then table.insert(mods, "CTRL") end
        if self.last_key.alt then table.insert(mods, "ALT") end
        if self.last_key.fn then table.insert(mods, "FN") end

        if #mods > 0 then
            display.draw_text(x + 2 * display.font_width, y,
                            "Mods: " .. table.concat(mods, " + "), colors.TEXT)
        else
            display.draw_text(x + 2 * display.font_width, y, "Mods: none", colors.TEXT_DIM)
        end
        y = y + display.font_height * 2
    else
        display.draw_text(x, y, "(waiting for input...)", colors.TEXT_DIM)
        y = y + display.font_height * 4
    end

    -- Key history
    display.draw_text(x, y, "History:", colors.TEXT_DIM)
    y = y + display.font_height

    for i, key_str in ipairs(self.key_history) do
        if i > 5 then break end  -- Only show last 5
        display.draw_text(x + 2 * display.font_width, y, key_str, colors.TEXT)
        y = y + display.font_height
    end

    -- Help text
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "ESC or Q: Back", colors.TEXT_DIM)
end

function InputTest:handle_key(key)
    -- Record this key
    self.last_key = key

    -- Build key string for history
    local key_str = ""
    if key.special then
        key_str = "[" .. key.special .. "]"
    elseif key.character then
        key_str = "'" .. key.character .. "'"
    end

    -- Add modifiers
    local mods = {}
    if key.shift then table.insert(mods, "S") end
    if key.ctrl then table.insert(mods, "C") end
    if key.alt then table.insert(mods, "A") end
    if key.fn then table.insert(mods, "F") end

    if #mods > 0 then
        key_str = key_str .. " (" .. table.concat(mods, "+") .. ")"
    end

    -- Add to history (at beginning)
    table.insert(self.key_history, 1, key_str)
    while #self.key_history > self.max_history do
        table.remove(self.key_history)
    end

    tdeck.screen.invalidate()

    -- Check for exit
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    return "continue"
end

return InputTest
