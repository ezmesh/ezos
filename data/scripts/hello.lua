-- Hello World Lua Screen for T-Deck OS
-- Demonstrates the basic Lua scripting API

local HelloScreen = {
    title = "Lua Hello World",
    counter = 0,
    last_key = nil
}

function HelloScreen:on_enter()
    tdeck.system.log("HelloScreen entered")
end

function HelloScreen:on_exit()
    tdeck.system.log("HelloScreen exited")
end

function HelloScreen:render(display)
    local colors = display.colors

    -- Draw the main box
    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    -- Show some system info
    local y = 2 * display.font_height
    display.draw_text(2 * display.font_width, y,
                     "Hello from Lua!", colors.GREEN)

    y = y + display.font_height * 2
    local heap_kb = math.floor(tdeck.system.get_free_heap() / 1024)
    local psram_kb = math.floor(tdeck.system.get_free_psram() / 1024)
    display.draw_text(2 * display.font_width, y,
                     string.format("Heap: %d KB", heap_kb), colors.TEXT)

    y = y + display.font_height
    display.draw_text(2 * display.font_width, y,
                     string.format("PSRAM: %d KB", psram_kb), colors.TEXT)

    y = y + display.font_height
    display.draw_text(2 * display.font_width, y,
                     string.format("Uptime: %d s", tdeck.system.uptime()), colors.TEXT)

    y = y + display.font_height
    display.draw_text(2 * display.font_width, y,
                     string.format("Counter: %d", self.counter), colors.CYAN)

    -- Show last key pressed
    y = y + display.font_height * 2
    if self.last_key then
        local key_str = self.last_key.character or self.last_key.special or "?"
        display.draw_text(2 * display.font_width, y,
                         "Last key: " .. key_str, colors.YELLOW)
    end

    -- Instructions
    y = y + display.font_height * 2
    display.draw_text(2 * display.font_width, y,
                     "UP/DOWN: Change counter", colors.TEXT_DIM)
    y = y + display.font_height
    display.draw_text(2 * display.font_width, y,
                     "ESC or 'q': Go back", colors.TEXT_DIM)
end

function HelloScreen:handle_key(key)
    self.last_key = key

    if key.special == "UP" then
        self.counter = self.counter + 1
        tdeck.screen.invalidate()
    elseif key.special == "DOWN" then
        self.counter = self.counter - 1
        tdeck.screen.invalidate()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character then
        -- Any other key press: refresh
        tdeck.screen.invalidate()
    end

    return "continue"
end

return HelloScreen
