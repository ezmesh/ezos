-- UI Components for T-Deck OS
-- Reusable drawing functions for common UI elements

local Components = {}

-- Draw a labeled value pair (e.g., "Battery: 85%")
function Components.draw_label_value(display, x, y, label, value, label_color, value_color)
    label_color = label_color or display.colors.TEXT_DIM
    value_color = value_color or display.colors.TEXT

    display.draw_text(x, y, label .. ": ", label_color)
    local label_width = display.text_width(label .. ": ")
    display.draw_text(x + label_width, y, tostring(value), value_color)
end

-- Draw a horizontal separator line
function Components.draw_separator(display, y, color)
    color = color or display.colors.BORDER
    display.draw_hline(1, y, display.cols - 2, true, true, color)
end

-- Draw a progress bar with label
function Components.draw_labeled_progress(display, x, y, w, label, progress, fg, bg)
    fg = fg or display.colors.GREEN
    bg = bg or display.colors.DARK_GRAY

    -- Draw label
    display.draw_text(x, y, label, display.colors.TEXT_DIM)

    -- Draw progress bar below
    local bar_y = y + display.font_height
    display.draw_progress(x, bar_y, w, display.font_height - 2, progress, fg, bg)

    -- Draw percentage
    local pct_text = string.format("%d%%", math.floor(progress * 100))
    local pct_x = x + w + display.font_width
    display.draw_text(pct_x, bar_y, pct_text, display.colors.TEXT)
end

-- Draw a simple list with scrolling support
function Components.draw_scrollable_list(display, x, y, w, h, items, selected, scroll_offset)
    scroll_offset = scroll_offset or 0
    local visible_items = math.floor(h / display.font_height)
    local colors = display.colors

    for i = 1, visible_items do
        local item_idx = scroll_offset + i
        if item_idx > #items then break end

        local item = items[item_idx]
        local item_y = y + (i - 1) * display.font_height
        local is_selected = (item_idx == selected)

        if is_selected then
            display.fill_rect(x, item_y, w, display.font_height, colors.SELECTION)
        end

        local text = type(item) == "table" and item.label or tostring(item)
        local text_color = is_selected and colors.CYAN or colors.TEXT
        display.draw_text(x + display.font_width, item_y, text, text_color)
    end

    -- Draw scroll indicators if needed
    if scroll_offset > 0 then
        display.draw_text(x + w - display.font_width, y, "^", colors.TEXT_DIM)
    end
    if scroll_offset + visible_items < #items then
        local bottom_y = y + (visible_items - 1) * display.font_height
        display.draw_text(x + w - display.font_width, bottom_y, "v", colors.TEXT_DIM)
    end

    return visible_items
end

-- Calculate scroll offset to keep selected item visible
function Components.calculate_scroll(selected, scroll_offset, visible_items, total_items)
    -- Scroll down if selected is below visible area
    if selected > scroll_offset + visible_items then
        scroll_offset = selected - visible_items
    end
    -- Scroll up if selected is above visible area
    if selected <= scroll_offset then
        scroll_offset = selected - 1
    end
    -- Clamp scroll offset
    scroll_offset = math.max(0, math.min(scroll_offset, total_items - visible_items))
    return scroll_offset
end

-- Draw a dialog box centered on screen
function Components.draw_dialog(display, title, message, buttons)
    buttons = buttons or {"OK"}
    local colors = display.colors

    -- Calculate dialog size
    local padding = 2
    local dialog_w = display.cols - 4
    local dialog_h = 6 + #buttons
    local dialog_x = 2
    local dialog_y = math.floor((display.rows - dialog_h) / 2)

    -- Draw dialog background
    display.fill_rect(dialog_x * display.font_width, dialog_y * display.font_height,
                     dialog_w * display.font_width, dialog_h * display.font_height,
                     colors.BLACK)

    -- Draw dialog border
    display.draw_box(dialog_x, dialog_y, dialog_w, dialog_h, title,
                    colors.BORDER, colors.CYAN)

    -- Draw message
    local msg_y = (dialog_y + 2) * display.font_height
    display.draw_text_centered(msg_y, message, colors.TEXT)

    return dialog_x, dialog_y, dialog_w, dialog_h
end

-- Draw a text input field
function Components.draw_input_field(display, x, y, w, text, cursor_pos, cursor_visible)
    local colors = display.colors

    -- Draw field background
    display.fill_rect(x, y, w, display.font_height, colors.DARK_GRAY)

    -- Draw text
    display.draw_text(x + 2, y, text, colors.TEXT)

    -- Draw cursor
    if cursor_visible then
        local cursor_x = x + 2 + cursor_pos * display.font_width
        display.fill_rect(cursor_x, y + 1, 2, display.font_height - 2, colors.CYAN)
    end
end

-- Format bytes to human-readable string
function Components.format_bytes(bytes)
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%.1f KB", bytes / 1024)
    else
        return string.format("%d B", bytes)
    end
end

-- Format time duration
function Components.format_duration(seconds)
    if seconds >= 3600 then
        return string.format("%dh %dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
    elseif seconds >= 60 then
        return string.format("%dm %ds", math.floor(seconds / 60), seconds % 60)
    else
        return string.format("%ds", seconds)
    end
end

return Components
