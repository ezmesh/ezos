-- test_icon.lua - Test screen for bitmap display
-- Loads and displays a bitmap image centered on screen

local Bitmap = dofile("/scripts/ui/bitmap.lua")

local TestIcon = {
    title = "Bitmap Test",
    bitmap = nil,
    error_msg = nil,
    test_path = "/icons/32x32/nuvola/email.rgb565",
    test_size = 32
}

function TestIcon:new()
    local o = {
        title = "Bitmap Test",
        bitmap = nil,
        error_msg = nil,
        test_path = "/icons/32x32/nuvola/email.rgb565",
        test_size = 32
    }
    setmetatable(o, {__index = TestIcon})
    return o
end

function TestIcon:on_enter()
    -- Try to load test bitmap
    self.bitmap = Bitmap.load(self.test_path, self.test_size)
    if not self.bitmap then
        self.error_msg = "Failed to load: " .. self.test_path
    end
end

function TestIcon:render(display)
    local colors = display.colors

    -- Header
    display.draw_box(0, 0, display.cols, display.rows - 1, self.title, colors.CYAN, colors.WHITE)

    local center_y = display.height / 2

    if self.bitmap then
        -- Draw bitmap centered
        Bitmap.draw_centered_transparent(self.bitmap)

        -- Show info below
        local info = string.format("%dx%d  %d bytes",
            self.bitmap.width, self.bitmap.height, #self.bitmap.data)
        display.draw_text_centered(center_y + self.bitmap.height / 2 + 20, info, colors.TEXT_DIM)
        display.draw_text_centered(center_y + self.bitmap.height / 2 + 40, self.test_path, colors.TEXT_DIM)
    elseif self.error_msg then
        display.draw_text_centered(center_y - 10, self.error_msg, colors.RED)
        display.draw_text_centered(center_y + 10, "Place RGB565 bitmap at:", colors.TEXT_DIM)
        display.draw_text_centered(center_y + 30, self.test_path, colors.TEXT)
    else
        display.draw_text_centered(center_y, "Loading...", colors.TEXT)
    end

    -- Footer
    local footer_y = (display.rows - 2) * display.font_height
    display.draw_text_centered(footer_y, "[Q] Quit  [R] Reload", colors.TEXT_DIM)
end

function TestIcon:handle_key(key)
    tdeck.screen.invalidate()

    if key.character == "q" or key.special == "ESCAPE" then
        return "pop"
    elseif key.character == "r" then
        self:on_enter()  -- Reload bitmap
    end

    return "continue"
end

return TestIcon
