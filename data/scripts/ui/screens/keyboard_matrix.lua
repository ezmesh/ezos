-- Keyboard Matrix Test Screen for T-Deck OS
-- Shows raw keyboard matrix bits (5 cols × 7 rows)

local KeyboardMatrix = {
    title = "Key Matrix",
    raw_mode_ok = false,
    error_msg = nil,
    disable_app_menu = true  -- Prevent app menu from interfering with raw keyboard input
}

function KeyboardMatrix:new()
    local o = {
        title = self.title,
        raw_mode_ok = false,
        error_msg = nil,
        disable_app_menu = true
    }
    setmetatable(o, {__index = KeyboardMatrix})
    return o
end

function KeyboardMatrix:on_enter()
    -- Try to enable raw mode
    local ok = ez.keyboard.set_mode("raw")
    if ok then
        self.raw_mode_ok = true
    else
        self.raw_mode_ok = false
        self.error_msg = "Raw mode not supported"
    end
end

function KeyboardMatrix:on_exit()
    ez.keyboard.set_mode("normal")
end

function KeyboardMatrix:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Use small font throughout
    display.set_font_size("small")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Show error if raw mode failed
    if self.error_msg then
        display.draw_text_centered(display.height / 2 - fh, self.error_msg, colors.ERROR)
        display.draw_text_centered(display.height / 2 + fh, "Press any key to exit", colors.TEXT_SECONDARY)
        return
    end

    local matrix = ez.keyboard.read_raw_matrix()

    local start_y = fh + 12
    local start_x = 3 * fw
    local cell_w = 3 * fw
    local cell_h = fh + 2

    -- Column headers
    for col = 0, 4 do
        local hx = start_x + col * cell_w
        display.draw_text(hx, start_y, tostring(col), colors.ACCENT)
    end

    -- Draw matrix grid (7 rows × 5 cols)
    for row = 0, 6 do
        local y = start_y + (row + 1) * cell_h

        -- Row label
        display.draw_text(fw, y, tostring(row), colors.ACCENT)

        for col = 0, 4 do
            local x = start_x + col * cell_w

            local pressed = false
            if matrix then
                local col_byte = matrix[col + 1] or 0
                pressed = (col_byte & (1 << row)) ~= 0
            end

            if pressed then
                display.fill_rect(x - 1, y - 1, cell_w - 2, cell_h - 1, colors.SUCCESS)
                display.draw_text(x, y, "1", colors.BLACK)
            else
                display.draw_text(x, y, "0", colors.TEXT_SECONDARY)
            end
        end
    end

    -- Show raw bytes - position above status bar
    local status_bar_height = fh + 8
    local info_y = display.height - status_bar_height - fh * 2 - 4

    if matrix then
        local hex_str = ""
        for col = 1, 5 do
            hex_str = hex_str .. string.format("%02X ", matrix[col] or 0)
        end
        display.draw_text(fw, info_y, "Bytes: " .. hex_str, colors.TEXT_SECONDARY)
    else
        display.draw_text(fw, info_y, "No matrix data", colors.WARNING)
    end

    -- Help text
    display.draw_text(fw, info_y + fh + 2, "ESC to exit", colors.TEXT_SECONDARY)
end

function KeyboardMatrix:update()
    -- Continuously refresh to show live matrix state
    ScreenManager.invalidate()
end

function KeyboardMatrix:handle_key(key)
    if key.special == "ESCAPE" or key.special == "ENTER" or key.character == "q" then
        return "pop"
    end
    return "continue"
end

return KeyboardMatrix
