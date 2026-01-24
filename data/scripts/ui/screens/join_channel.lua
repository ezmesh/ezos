-- Join Channel Screen for T-Deck OS
-- Dialog to join or create a new channel

local JoinChannel = {
    title = "Join Channel",
    channel_name = "#",
    password = "",
    selected_field = 1,  -- 1=name, 2=password, 3=join button
    cursor_visible = true,
    last_blink = 0,
    blink_interval = 500
}

function JoinChannel:new()
    local o = {
        title = self.title,
        channel_name = "#",
        password = "",
        selected_field = 1,
        cursor_visible = true,
        last_blink = 0
    }
    setmetatable(o, {__index = JoinChannel})
    return o
end

function JoinChannel:on_enter()
    self.last_blink = tdeck.system.millis()
end

function JoinChannel:update_cursor()
    local now = tdeck.system.millis()
    if now - self.last_blink > self.blink_interval then
        self.cursor_visible = not self.cursor_visible
        self.last_blink = now
        tdeck.screen.invalidate()
    end
end

function JoinChannel:render(display)
    local colors = display.colors

    self:update_cursor()

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    local y = 3
    local label_x = 2
    local input_x = 12
    local input_width = display.cols - input_x - 2

    -- Channel name field
    local is_name_selected = (self.selected_field == 1)
    local py = y * display.font_height

    display.draw_text(label_x * display.font_width, py, "Channel:", colors.TEXT_DIM)

    -- Input background
    local bg_color = is_name_selected and colors.SELECTION or colors.DARK_GRAY
    display.fill_rect(input_x * display.font_width, py,
                     input_width * display.font_width, display.font_height, bg_color)

    -- Channel name text
    display.draw_text(input_x * display.font_width, py, self.channel_name, colors.TEXT)

    -- Cursor
    if is_name_selected and self.cursor_visible then
        local cursor_x = input_x + #self.channel_name
        display.draw_text(cursor_x * display.font_width, py, "_", colors.CYAN)
    end

    y = y + 2

    -- Password field
    local is_pass_selected = (self.selected_field == 2)
    py = y * display.font_height

    display.draw_text(label_x * display.font_width, py, "Password:", colors.TEXT_DIM)

    -- Input background
    bg_color = is_pass_selected and colors.SELECTION or colors.DARK_GRAY
    display.fill_rect(input_x * display.font_width, py,
                     input_width * display.font_width, display.font_height, bg_color)

    -- Password text (masked)
    local masked = string.rep("*", #self.password)
    display.draw_text(input_x * display.font_width, py, masked, colors.TEXT)

    -- Cursor
    if is_pass_selected and self.cursor_visible then
        local cursor_x = input_x + #self.password
        display.draw_text(cursor_x * display.font_width, py, "_", colors.CYAN)
    end

    y = y + 2

    -- Hint about encryption
    display.draw_text(label_x * display.font_width, y * display.font_height,
                     "(Leave password empty for public)", colors.TEXT_DIM)
    y = y + 2

    -- Join button
    local is_button_selected = (self.selected_field == 3)
    py = y * display.font_height

    if is_button_selected then
        display.fill_rect(display.font_width, py,
                        (display.cols - 2) * display.font_width,
                        display.font_height, colors.SELECTION)
        display.draw_text(display.font_width, py, ">", colors.CYAN)
    end

    local button_color = is_button_selected and colors.CYAN or colors.GREEN
    display.draw_text(label_x * display.font_width, py, "[Join Channel]", button_color)

    -- Help bar
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    "[Tab]Next [Enter]Join [Esc]Cancel", colors.TEXT_DIM)
end

function JoinChannel:handle_key(key)
    tdeck.screen.invalidate()

    if key.special == "UP" then
        self:select_previous()
    elseif key.special == "DOWN" or key.special == "TAB" then
        self:select_next()
    elseif key.special == "ENTER" then
        if self.selected_field == 3 then
            self:do_join()
            return "pop"
        else
            self:select_next()
        end
    elseif key.special == "BACKSPACE" then
        self:handle_backspace()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    elseif key.character then
        self:handle_char(key.character)
    end

    return "continue"
end

function JoinChannel:select_next()
    self.selected_field = (self.selected_field % 3) + 1
end

function JoinChannel:select_previous()
    self.selected_field = ((self.selected_field - 2) % 3) + 1
end

function JoinChannel:handle_char(c)
    if self.selected_field == 1 then
        -- Channel name
        if #self.channel_name < 24 then
            self.channel_name = self.channel_name .. c
        end
    elseif self.selected_field == 2 then
        -- Password
        if #self.password < 24 then
            self.password = self.password .. c
        end
    end
end

function JoinChannel:handle_backspace()
    if self.selected_field == 1 then
        -- Keep the # prefix
        if #self.channel_name > 1 then
            self.channel_name = string.sub(self.channel_name, 1, -2)
        end
    elseif self.selected_field == 2 then
        if #self.password > 0 then
            self.password = string.sub(self.password, 1, -2)
        end
    end
end

function JoinChannel:do_join()
    if #self.channel_name < 2 then
        tdeck.system.log("Channel name too short")
        return
    end

    local password = #self.password > 0 and self.password or nil
    if tdeck.mesh.join_channel(self.channel_name, password) then
        tdeck.system.log("Joined channel: " .. self.channel_name)
    else
        tdeck.system.log("Failed to join channel")
    end
end

return JoinChannel
