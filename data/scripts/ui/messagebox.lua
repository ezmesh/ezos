-- MessageBox - Modal dialog overlay
-- Shows a title, body text, and 1-2 buttons
-- Also supports text input prompts

local MessageBox = {
    active = false,
    mode = "alert",  -- "alert" or "prompt"
    title = "",
    body = "",
    buttons = {},
    selected = 1,
    callback = nil,
    -- For prompt mode
    input_text = "",
    cursor_pos = 0,
}

-- Show a message box
-- options: {title, body, buttons = {"OK"} or {"Yes", "No"}, callback = function(button_index)}
-- If title is nil/empty and body is provided, only body is shown (no default "Alert" title)
function MessageBox.show(options)
    MessageBox.mode = "alert"
    MessageBox.title = options.title or ""
    MessageBox.body = options.body or ""
    MessageBox.buttons = options.buttons or {"OK"}
    MessageBox.callback = options.callback
    MessageBox.selected = 1
    MessageBox.active = true

    if _G.Overlays then
        _G.Overlays.enable("messagebox")
    end
    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end
end

-- Hide the message box
function MessageBox.hide()
    MessageBox.active = false
    if _G.Overlays then
        _G.Overlays.disable("messagebox")
    end
    -- Restore keyboard mode
    tdeck.keyboard.set_mode("normal")
    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end
end

-- Convenience: show alert with OK button
function MessageBox.alert(title, body, callback)
    MessageBox.show({
        title = title,
        body = body,
        buttons = {"OK"},
        callback = callback
    })
end

-- Convenience: show confirm with Yes/No buttons
function MessageBox.confirm(title, body, callback)
    MessageBox.show({
        title = title,
        body = body,
        buttons = {"Yes", "No"},
        callback = callback
    })
end

-- Show a text input prompt
-- callback receives (text, confirmed) - confirmed is true if OK pressed, false if cancelled
function MessageBox.prompt(title, default_text, callback)
    MessageBox.mode = "prompt"
    MessageBox.title = title or "Input"
    MessageBox.body = ""
    MessageBox.input_text = default_text or ""
    MessageBox.cursor_pos = #MessageBox.input_text
    MessageBox.buttons = {"OK", "Cancel"}
    MessageBox.callback = callback
    MessageBox.selected = 1
    MessageBox.active = true

    if _G.Overlays then
        _G.Overlays.enable("messagebox")
    end
    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end
end

-- Word wrap text to fit within max_width, returns array of lines
local function wrap_text(display, text, max_width)
    local lines = {}
    local words = {}

    -- Split into words
    for word in text:gmatch("%S+") do
        table.insert(words, word)
    end

    local current_line = ""
    for _, word in ipairs(words) do
        local test_line = current_line == "" and word or (current_line .. " " .. word)
        if display.text_width(test_line) <= max_width then
            current_line = test_line
        else
            if current_line ~= "" then
                table.insert(lines, current_line)
            end
            -- If single word is too long, add it anyway (will overflow)
            current_line = word
        end
    end
    if current_line ~= "" then
        table.insert(lines, current_line)
    end

    return lines
end

function MessageBox.render(display)
    if not MessageBox.active then return end

    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height

    -- Check if we have a title
    local has_title = MessageBox.title and #MessageBox.title > 0

    -- Use small font for body text to fit more content
    display.set_font_size("small")
    local small_fh = display.get_font_height()

    -- Calculate wrapped lines for body
    local box_w = math.min(300, w - 16)
    local max_text_width = box_w - 16
    local body_lines = {}
    local max_lines = 6

    if MessageBox.mode ~= "prompt" and MessageBox.body and #MessageBox.body > 0 then
        body_lines = wrap_text(display, MessageBox.body, max_text_width)
        -- Limit to max lines
        if #body_lines > max_lines then
            body_lines[max_lines] = body_lines[max_lines]:sub(1, -4) .. "..."
            for i = max_lines + 1, #body_lines do
                body_lines[i] = nil
            end
        end
    end

    -- Calculate box height based on content
    local title_height = has_title and (small_fh + 6) or 0
    local body_height = #body_lines * (small_fh + 2)
    local button_height = 28
    local padding = 16

    local box_h
    if MessageBox.mode == "prompt" then
        box_h = title_height + 30 + button_height + padding
    else
        box_h = title_height + body_height + button_height + padding
        box_h = math.max(box_h, 60)  -- Minimum height
    end

    local box_x = math.floor((w - box_w) / 2)
    local box_y = math.floor((h - box_h) / 2)

    -- Dim layer behind the dialog (vertical scanlines, 50%)
    display.fill_rect_vlines(0, 0, w, h, colors.BLACK, 2)

    -- Box background with border
    display.fill_rect(box_x, box_y, box_w, box_h, colors.BLACK)
    display.draw_rect(box_x, box_y, box_w, box_h, colors.ACCENT)
    display.draw_rect(box_x + 1, box_y + 1, box_w - 2, box_h - 2, colors.TEXT_SECONDARY)

    local content_y = box_y + 8

    -- Title centered (only if present) - use small font
    if has_title then
        local title_w = display.text_width(MessageBox.title)
        local title_x = box_x + math.floor((box_w - title_w) / 2)
        display.draw_text(title_x, content_y, MessageBox.title, colors.ACCENT)
        content_y = content_y + small_fh + 4
    end

    if MessageBox.mode == "prompt" then
        -- Input field
        display.set_font_size("medium")
        local fh = display.get_font_height()
        local input_x = box_x + 8
        local input_y = content_y
        local input_w = box_w - 16
        local input_h = 22

        -- Input background
        display.fill_rect(input_x, input_y, input_w, input_h, 0x1082)
        display.draw_rect(input_x, input_y, input_w, input_h, colors.TEXT_SECONDARY)

        -- Input text - truncate based on pixel width
        local display_text = MessageBox.input_text
        local max_input_width = input_w - 8
        while display.text_width(display_text) > max_input_width and #display_text > 0 do
            display_text = display_text:sub(2)
        end
        display.draw_text(input_x + 4, input_y + 5, display_text, colors.TEXT)

        -- Cursor
        local cursor_x = input_x + 4 + display.text_width(display_text)
        display.fill_rect(cursor_x, input_y + 4, 2, fh, colors.ACCENT)
    else
        -- Draw wrapped body text lines
        for _, line in ipairs(body_lines) do
            local line_x = box_x + 8
            display.draw_text(line_x, content_y, line, colors.TEXT)
            content_y = content_y + small_fh + 2
        end
    end

    -- Buttons - use medium font
    display.set_font_size("medium")
    local btn_y = box_y + box_h - 26
    local btn_spacing = 12
    local total_btn_width = 0

    for _, btn in ipairs(MessageBox.buttons) do
        total_btn_width = total_btn_width + display.text_width(btn) + 16
    end
    total_btn_width = total_btn_width + btn_spacing * (#MessageBox.buttons - 1)

    local btn_x = box_x + math.floor((box_w - total_btn_width) / 2)

    for i, btn in ipairs(MessageBox.buttons) do
        local btn_w = display.text_width(btn) + 16
        local is_sel = (i == MessageBox.selected)

        if is_sel then
            display.fill_rect(btn_x, btn_y, btn_w, 20, colors.SURFACE_ALT)
            display.draw_rect(btn_x, btn_y, btn_w, 20, colors.ACCENT)
        else
            display.draw_rect(btn_x, btn_y, btn_w, 20, colors.TEXT_SECONDARY)
        end

        local text_x = btn_x + math.floor((btn_w - display.text_width(btn)) / 2)
        local text_color = is_sel and colors.ACCENT or colors.TEXT
        display.draw_text(text_x, btn_y + 4, btn, text_color)

        btn_x = btn_x + btn_w + btn_spacing
    end
end

function MessageBox.handle_key(key)
    if not MessageBox.active then return false end

    -- Handle prompt text input
    if MessageBox.mode == "prompt" then
        if key.character and #key.character == 1 then
            MessageBox.input_text = MessageBox.input_text .. key.character
            MessageBox.cursor_pos = #MessageBox.input_text
            if _G.ScreenManager then _G.ScreenManager.invalidate() end
            return true
        end

        if key.special == "BACKSPACE" then
            if #MessageBox.input_text > 0 then
                MessageBox.input_text = MessageBox.input_text:sub(1, -2)
                MessageBox.cursor_pos = #MessageBox.input_text
                if _G.ScreenManager then _G.ScreenManager.invalidate() end
            end
            return true
        end
    end

    if key.special == "LEFT" then
        MessageBox.selected = MessageBox.selected - 1
        if MessageBox.selected < 1 then MessageBox.selected = #MessageBox.buttons end
        if _G.ScreenManager then _G.ScreenManager.invalidate() end
        return true
    end

    if key.special == "RIGHT" then
        MessageBox.selected = MessageBox.selected + 1
        if MessageBox.selected > #MessageBox.buttons then MessageBox.selected = 1 end
        if _G.ScreenManager then _G.ScreenManager.invalidate() end
        return true
    end

    if key.special == "ENTER" then
        local selected = MessageBox.selected
        local callback = MessageBox.callback
        local input = MessageBox.input_text

        MessageBox.hide()

        if callback then
            if MessageBox.mode == "prompt" then
                -- For prompt: callback(text, confirmed)
                callback(input, selected == 1)
            else
                callback(selected)
            end
        end
        return true
    end

    if key.special == "ESCAPE" then
        local callback = MessageBox.callback
        MessageBox.hide()
        if callback then
            if MessageBox.mode == "prompt" then
                callback("", false)
            else
                callback(0)
            end
        end
        return true
    end

    -- Consume all keys while active
    return true
end

function MessageBox.init()
    if _G.Overlays then
        _G.Overlays.register("messagebox", MessageBox.render, 300, MessageBox.handle_key)
        _G.Overlays.disable("messagebox")
    end
end

return MessageBox
