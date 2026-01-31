-- Join Channel Screen for T-Deck OS
-- Dialog to join or create a new channel using UI components

local Components = load_module("/scripts/ui/components.lua")

local JoinChannel = {
    title = "Join Channel",
}

function JoinChannel:new()
    local o = {
        title = self.title,
        selected_field = 1,  -- 1=name, 2=password, 3=join button

        -- UI Components
        channel_input = Components.TextInput:new({
            value = "#",
            placeholder = "#channel",
            max_length = 24,
            width = 180,
        }),
        password_input = Components.TextInput:new({
            value = "",
            placeholder = "optional",
            max_length = 24,
            width = 180,
            password_mode = true,
        }),
        join_button = Components.Button:new({
            label = "Join Channel",
            width = 180,
        }),
    }
    setmetatable(o, {__index = JoinChannel})
    return o
end

function JoinChannel:on_enter()
    -- Nothing special needed
end

function JoinChannel:render(display)
    -- Ensure medium font
    display.set_font_size("medium")

    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local fw = display.get_font_width()
    local fh = display.get_font_height()
    local cols = display.get_cols()
    local rows = display.get_rows()

    -- Fill background with theme wallpaper
    if _G.ThemeManager then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, colors.BLACK)
    end

    display.draw_box(0, 0, cols, rows - 1, self.title, colors.ACCENT, colors.WHITE)

    local y = 3
    local label_x = 2
    local input_x = 80

    -- Channel name field
    local py = y * fh
    display.draw_text(label_x * fw, py, "Channel:", colors.TEXT_SECONDARY)
    self.channel_input:render(display, input_x, py - 2, self.selected_field == 1)

    y = y + 2

    -- Password field
    py = y * fh
    display.draw_text(label_x * fw, py, "Password:", colors.TEXT_SECONDARY)
    self.password_input:render(display, input_x, py - 2, self.selected_field == 2)

    y = y + 2

    -- Hint about encryption
    display.draw_text(label_x * fw, y * fh, "(Leave password empty for public)", colors.TEXT_SECONDARY)
    y = y + 2

    -- Join button
    py = y * fh
    self.join_button:render(display, input_x, py, self.selected_field == 3)

    -- Help bar
    display.draw_text(fw, (rows - 3) * fh, "[Tab]Next [Enter]Join [Esc]Cancel", colors.TEXT_SECONDARY)
end

function JoinChannel:handle_key(key)
    ScreenManager.invalidate()

    -- Navigation between fields
    if key.special == "TAB" or (key.special == "DOWN" and self.selected_field < 3) then
        self.selected_field = (self.selected_field % 3) + 1
        return "continue"
    elseif key.special == "UP" and self.selected_field > 1 then
        self.selected_field = self.selected_field - 1
        return "continue"
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    -- Handle input for current field
    if self.selected_field == 1 then
        local result = self.channel_input:handle_key(key)
        -- Keep the # prefix
        if #self.channel_input.value == 0 then
            self.channel_input:set_value("#")
        elseif string.sub(self.channel_input.value, 1, 1) ~= "#" then
            self.channel_input:set_value("#" .. self.channel_input.value)
        end
        if result == "submit" then
            self.selected_field = 2  -- Move to password
        end
    elseif self.selected_field == 2 then
        local result = self.password_input:handle_key(key)
        if result == "submit" then
            self.selected_field = 3  -- Move to button
        end
    elseif self.selected_field == 3 then
        local result = self.join_button:handle_key(key)
        if result == "pressed" then
            self:do_join()
            return "pop"
        end
    end

    return "continue"
end

function JoinChannel:do_join()
    local channel_name = self.channel_input:get_value()
    if #channel_name < 2 then
        ez.system.log("Channel name too short")
        return
    end

    local ChannelsService = _G.Channels
    if not ChannelsService then
        ez.system.log("Channels service not available")
        return
    end

    local password = self.password_input:get_value()
    if #password == 0 then password = nil end

    if ChannelsService.join(channel_name, password) then
        ez.system.log("Joined channel: " .. channel_name)
    else
        ez.system.log("Failed to join channel")
    end
end

return JoinChannel
