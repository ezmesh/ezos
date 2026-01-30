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

function MessageBox.render(display)
    if not MessageBox.active then return end

    -- Ensure medium font (status bar may have changed to small)
    display.set_font_size("medium")

    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local w = display.width
    local h = display.height
    local fh = display.get_font_height()
    local fw = display.get_font_width()

    -- Check if we have a title
    local has_title = MessageBox.title and #MessageBox.title > 0

    -- Box dimensions (smaller if no title)
    local box_w = math.min(280, w - 20)
    local box_h
    if MessageBox.mode == "prompt" then
        box_h = 110
    elseif has_title then
        box_h = 90
    else
        box_h = 70  -- Smaller box when no title
    end
    local box_x = math.floor((w - box_w) / 2)
    local box_y = math.floor((h - box_h) / 2)

    -- Box background with border
    display.fill_rect(box_x, box_y, box_w, box_h, colors.BLACK)
    display.draw_rect(box_x, box_y, box_w, box_h, colors.ACCENT)
    display.draw_rect(box_x + 1, box_y + 1, box_w - 2, box_h - 2, colors.TEXT_SECONDARY)

    -- Title centered (only if present)
    local content_y = box_y + 10
    if has_title then
        local title_w = display.text_width(MessageBox.title)
        local title_x = box_x + math.floor((box_w - title_w) / 2)
        display.draw_text(title_x, content_y, MessageBox.title, colors.ACCENT)
        content_y = content_y + 25
    end

    if MessageBox.mode == "prompt" then
        -- Input field
        local input_x = box_x + 10
        local input_y = content_y
        local input_w = box_w - 20
        local input_h = 22

        -- Input background
        display.fill_rect(input_x, input_y, input_w, input_h, 0x1082)
        display.draw_rect(input_x, input_y, input_w, input_h, colors.TEXT_SECONDARY)

        -- Input text
        local max_chars = math.floor((input_w - 8) / fw)
        local display_text = MessageBox.input_text
        if #display_text > max_chars then
            display_text = display_text:sub(-max_chars)
        end
        display.draw_text(input_x + 4, input_y + 5, display_text, colors.TEXT)

        -- Cursor
        local cursor_x = input_x + 4 + #display_text * fw
        display.fill_rect(cursor_x, input_y + 4, 2, fh, colors.ACCENT)
    else
        -- Use small font for body-only messages (no title)
        if not has_title then
            display.set_font_size("small")
            fw = display.get_font_width()
        end

        -- Body text (centered if no title)
        local body_x = box_x + 10
        local max_chars = math.floor((box_w - 20) / fw)
        local body = MessageBox.body
        if #body > max_chars then
            body = body:sub(1, max_chars - 3) .. "..."
        end
        -- Center body text horizontally if no title
        if not has_title then
            local body_w = display.text_width(body)
            body_x = box_x + math.floor((box_w - body_w) / 2)
        end
        display.draw_text(body_x, content_y, body, colors.TEXT)

        -- Restore medium font
        if not has_title then
            display.set_font_size("medium")
        end
    end

    -- Buttons
    local btn_y = box_y + box_h - 30
    local btn_spacing = 16
    local total_btn_width = 0

    for _, btn in ipairs(MessageBox.buttons) do
        total_btn_width = total_btn_width + display.text_width(btn) + 20
    end
    total_btn_width = total_btn_width + btn_spacing * (#MessageBox.buttons - 1)

    local btn_x = box_x + math.floor((box_w - total_btn_width) / 2)

    for i, btn in ipairs(MessageBox.buttons) do
        local btn_w = display.text_width(btn) + 20
        local is_sel = (i == MessageBox.selected)

        if is_sel then
            display.fill_rect(btn_x, btn_y, btn_w, 22, colors.SURFACE_ALT)
            display.draw_rect(btn_x, btn_y, btn_w, 22, colors.ACCENT)
        else
            display.draw_rect(btn_x, btn_y, btn_w, 22, colors.TEXT_SECONDARY)
        end

        local text_x = btn_x + math.floor((btn_w - display.text_width(btn)) / 2)
        local text_color = is_sel and colors.ACCENT or colors.TEXT
        display.draw_text(text_x, btn_y + 5, btn, text_color)

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
