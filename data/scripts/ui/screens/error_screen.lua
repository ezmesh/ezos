-- Error Screen for T-Deck OS
-- Displays Lua errors with options to retry or restart

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
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.RED, colors.WHITE)

    local y = 2 * display.font_height
    local x = 2 * display.font_width
    local max_width = display.cols - 4

    -- Source
    if #self.source > 0 then
        display.draw_text(x, y, "Source:", colors.TEXT_DIM)
        y = y + display.font_height

        local src = self.source
        if #src > max_width then
            src = "..." .. string.sub(src, -max_width + 3)
        end
        display.draw_text(x, y, src, colors.ORANGE)
        y = y + display.font_height * 2
    end

    -- Error message
    display.draw_text(x, y, "Error:", colors.TEXT_DIM)
    y = y + display.font_height

    -- Word wrap error message
    local err = self.error_message
    local lines = {}
    while #err > 0 do
        if #err <= max_width then
            table.insert(lines, err)
            break
        else
            -- Find break point
            local break_at = max_width
            for i = max_width, 1, -1 do
                if string.sub(err, i, i) == " " then
                    break_at = i
                    break
                end
            end
            table.insert(lines, string.sub(err, 1, break_at))
            err = string.sub(err, break_at + 1)
        end
    end

    for _, line in ipairs(lines) do
        if y < (display.rows - 4) * display.font_height then
            display.draw_text(x, y, line, colors.RED)
            y = y + display.font_height
        end
    end

    -- Stack trace (if available and space allows)
    if #self.stack_trace > 0 and y < (display.rows - 5) * display.font_height then
        y = y + display.font_height
        display.draw_text(x, y, "Stack:", colors.TEXT_DIM)
        y = y + display.font_height

        local stack_lines = {}
        for line in string.gmatch(self.stack_trace, "[^\n]+") do
            table.insert(stack_lines, line)
        end

        for i, line in ipairs(stack_lines) do
            if y >= (display.rows - 4) * display.font_height then break end
            if i > self.scroll_offset then
                local display_line = line
                if #display_line > max_width then
                    display_line = string.sub(display_line, 1, max_width - 3) .. "..."
                end
                display.draw_text(x, y, display_line, colors.TEXT_DIM)
                y = y + display.font_height
            end
        end
    end

    -- Options
    y = (display.rows - 3) * display.font_height
    display.draw_text(x, y, "[R]etry [F]iles [Q]uit [X]Restart", colors.TEXT_DIM)
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
            tdeck.screen.push(Files:new("/scripts"))
        end
    elseif key.character == "x" then
        -- Full restart
        if tdeck.system.restart then
            tdeck.system.restart()
        end
    elseif key.special == "UP" then
        if self.scroll_offset > 0 then
            self.scroll_offset = self.scroll_offset - 1
            tdeck.screen.invalidate()
        end
    elseif key.special == "DOWN" then
        self.scroll_offset = self.scroll_offset + 1
        tdeck.screen.invalidate()
    end

    return "continue"
end

return ErrorScreen
