-- Key Repeat Test Screen
-- Test and debug key repeat functionality

local KeyRepeatTest = {
    title = "Key Repeat Test",
    enabled = false,
    delay = 400,
    rate = 50,
    key_log = {},
    max_log = 15,
    last_key_time = 0,
}

function KeyRepeatTest:new()
    local o = {
        title = self.title,
        enabled = tdeck.keyboard.get_repeat_enabled(),
        delay = tdeck.keyboard.get_repeat_delay(),
        rate = tdeck.keyboard.get_repeat_rate(),
        key_log = {},
        last_key_time = 0,
    }
    setmetatable(o, {__index = KeyRepeatTest})
    return o
end

function KeyRepeatTest:on_enter()
    -- Read current settings
    self.enabled = tdeck.keyboard.get_repeat_enabled()
    self.delay = tdeck.keyboard.get_repeat_delay()
    self.rate = tdeck.keyboard.get_repeat_rate()
end

function KeyRepeatTest:on_exit()
    -- Disable key repeat when leaving (safety)
    tdeck.keyboard.set_repeat_enabled(false)
end

function KeyRepeatTest:add_log(text)
    local now = tdeck.system.millis()
    local delta = now - self.last_key_time
    self.last_key_time = now

    local entry = string.format("%dms: %s", delta, text)
    table.insert(self.key_log, 1, entry)

    while #self.key_log > self.max_log do
        table.remove(self.key_log)
    end
end

function KeyRepeatTest:render(display)
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

    -- Current settings
    local x = fw
    local y = 2 * fh
    local status_color = self.enabled and colors.SUCCESS or colors.ERROR
    display.draw_text(x, y, "Repeat: " .. (self.enabled and "ON" or "OFF"), status_color)

    y = y + fh
    display.draw_text(x, y, "Delay: " .. self.delay .. "ms", colors.TEXT)

    y = y + fh
    display.draw_text(x, y, "Rate: " .. self.rate .. "ms", colors.TEXT)

    -- Instructions
    y = y + fh + 4
    display.draw_text(x, y, "E=Toggle  D/R=Delay  F/T=Rate", colors.TEXT_SECONDARY)

    -- Separator
    y = y + fh + 2
    display.fill_rect(4, y, display.width - 8, 1, colors.TEXT_SECONDARY)

    -- Key log
    y = y + 6
    display.draw_text(x, y, "Key Log (delta ms):", colors.TEXT_SECONDARY)
    y = y + fh

    for i, entry in ipairs(self.key_log) do
        if y > display.height - 30 then break end
        display.draw_text(x, y, entry, colors.TEXT)
        y = y + fh
    end
end

function KeyRepeatTest:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end

    local c = key.character and string.upper(key.character) or nil

    -- Toggle enable
    if c == "E" then
        self.enabled = not self.enabled
        tdeck.keyboard.set_repeat_enabled(self.enabled)
        self:add_log("Repeat " .. (self.enabled and "ENABLED" or "DISABLED"))
        ScreenManager.invalidate()
        return "continue"
    end

    -- Decrease delay
    if c == "D" then
        self.delay = math.max(100, self.delay - 50)
        tdeck.keyboard.set_repeat_delay(self.delay)
        self:add_log("Delay: " .. self.delay)
        ScreenManager.invalidate()
        return "continue"
    end

    -- Increase delay
    if c == "R" then
        self.delay = math.min(1000, self.delay + 50)
        tdeck.keyboard.set_repeat_delay(self.delay)
        self:add_log("Delay: " .. self.delay)
        ScreenManager.invalidate()
        return "continue"
    end

    -- Decrease rate
    if c == "F" then
        self.rate = math.max(20, self.rate - 10)
        tdeck.keyboard.set_repeat_rate(self.rate)
        self:add_log("Rate: " .. self.rate)
        ScreenManager.invalidate()
        return "continue"
    end

    -- Increase rate
    if c == "T" then
        self.rate = math.min(200, self.rate + 10)
        tdeck.keyboard.set_repeat_rate(self.rate)
        self:add_log("Rate: " .. self.rate)
        ScreenManager.invalidate()
        return "continue"
    end

    -- Log any other key
    local key_desc = ""
    if key.special and key.special ~= "NONE" then
        key_desc = tostring(key.special)
    elseif key.character then
        key_desc = "'" .. key.character .. "'"
    else
        key_desc = "?"
    end

    self:add_log(key_desc)
    ScreenManager.invalidate()

    return "continue"
end

return KeyRepeatTest
