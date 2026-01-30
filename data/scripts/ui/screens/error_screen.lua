-- Error Screen for T-Deck OS
-- Displays Lua errors with options to retry or restart

local TextUtils = load_module("/scripts/ui/text_utils.lua")

local ErrorScreen = {
    title = "Error",
    error_message = "",
    source = "",
    stack_trace = "",
    scroll_offset = 0
}

function ErrorScreen:new(message, source, stack)
    local o = {
        title = "Error",
        error_message = message or "Unknown error",
        source = source or "",
        stack_trace = stack or "",
        scroll_offset = 0
    }
    setmetatable(o, {__index = ErrorScreen})
    return o
end

function ErrorScreen:render(display)
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    -- Title bar (red for errors)
    TitleBar.draw_error(display, self.title)

    -- Content font
    display.set_font_size("medium")
    local fw = display.get_font_width()
    local fh = display.get_font_height()

    local y = 2 * fh
    local x = 2 * fw
    local max_width_px = display.width - (4 * fw)  -- Pixel-based width

    -- Source
    if #self.source > 0 then
        display.draw_text(x, y, "Source:", colors.TEXT_SECONDARY)
        y = y + fh

        -- Truncate source path if too wide
        local src = TextUtils.truncate(self.source, max_width_px, display)
        display.draw_text(x, y, src, colors.WARNING)
        y = y + fh * 2
    end

    -- Error message
    display.draw_text(x, y, "Error:", colors.TEXT_SECONDARY)
    y = y + fh

    -- Word wrap error message using pixel-based measurement
    local lines = TextUtils.wrap_text(self.error_message, max_width_px, display)

    for _, line in ipairs(lines) do
        if y < (display.rows - 4) * fh then
            display.draw_text(x, y, line, colors.ERROR)
            y = y + fh
        end
    end

    -- Stack trace (if available and space allows)
    if #self.stack_trace > 0 and y < (display.rows - 5) * fh then
        y = y + fh
        display.draw_text(x, y, "Stack:", colors.TEXT_SECONDARY)
        y = y + fh

        local stack_lines = {}
        for line in string.gmatch(self.stack_trace, "[^\n]+") do
            table.insert(stack_lines, line)
        end

        for i, line in ipairs(stack_lines) do
            if y >= (display.rows - 4) * fh then break end
            if i > self.scroll_offset then
                -- Truncate line if too wide
                local display_line = TextUtils.truncate(line, max_width_px, display)
                display.draw_text(x, y, display_line, colors.TEXT_MUTED)
                y = y + fh
            end
        end
    end

    -- Options
    y = (display.rows - 3) * fh
    display.draw_text(x, y, "[R]etry [F]iles [Q]uit [X]Restart", colors.TEXT_SECONDARY)
end

function ErrorScreen:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character == "r" then
        -- Retry by reloading scripts and popping
        if tdeck.system.reload_scripts then
            tdeck.system.reload_scripts()
        end
        return "pop"
    elseif key.character == "f" then
        -- Open file browser for recovery/debugging
        local ok, Files = pcall(dofile, "/scripts/ui/screens/files.lua")
        if ok and Files then
            ScreenManager.push(Files:new("/scripts"))
        end
    elseif key.character == "x" then
        -- Full restart
        if tdeck.system.restart then
            tdeck.system.restart()
        end
    elseif key.special == "UP" then
        if self.scroll_offset > 0 then
            self.scroll_offset = self.scroll_offset - 1
            ScreenManager.invalidate()
        end
    elseif key.special == "DOWN" then
        self.scroll_offset = self.scroll_offset + 1
        ScreenManager.invalidate()
    end

    return "continue"
end

return ErrorScreen
