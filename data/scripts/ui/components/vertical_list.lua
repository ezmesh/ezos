-- VerticalList: Scrollable list with quick navigation and custom rendering

local function get_colors(display)
    return _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
end

local VerticalList = {}
VerticalList.__index = VerticalList

function VerticalList:new(opts)
    opts = opts or {}
    local o = {
        items = opts.items or {},
        selected = opts.selected or 1,
        scroll_offset = 0,
        visible_rows = opts.visible_rows or 5,
        row_height = opts.row_height or 24,
        show_icons = opts.show_icons or false,
        play_sounds = opts.play_sounds ~= false,
        on_select = opts.on_select,
        on_change = opts.on_change,
        -- Custom item renderer: function(display, item, x, y, width, height, is_selected, colors)
        render_item = opts.render_item,
        -- Track last letter press for cycling through matches
        last_letter = nil,
        last_letter_time = 0,
    }
    setmetatable(o, VerticalList)
    return o
end

function VerticalList:render(display, x, y, width, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()

    local height = self.visible_rows * self.row_height

    -- Background
    display.fill_rect(x, y, width, height, colors.BLACK)

    if #self.items == 0 then
        display.draw_text(x + 4, y + height / 2 - fh / 2, "No items", colors.TEXT_SECONDARY)
        return width, height
    end

    -- Items
    local icon_offset = self.show_icons and 28 or 0

    for i = 1, self.visible_rows do
        local item_idx = self.scroll_offset + i
        if item_idx > #self.items then break end

        local item = self.items[item_idx]
        local item_y = y + (i - 1) * self.row_height
        local is_selected = focused and (item_idx == self.selected)

        -- Use custom renderer if provided
        if self.render_item then
            self.render_item(display, item, x, item_y, width - 8, self.row_height, is_selected, colors)
        else
            -- Default rendering
            -- Selection background
            if is_selected then
                display.fill_rect(x, item_y, width - 8, self.row_height, colors.SURFACE_ALT)

                -- Chevron indicator
                if _G.Icons and _G.Icons.draw_chevron_right then
                    local chevron_y = item_y + math.floor((self.row_height - 9) / 2)
                    _G.Icons.draw_chevron_right(display, x + 2, chevron_y, colors.ACCENT, colors.SURFACE_ALT)
                end
            end

            -- Icon
            if self.show_icons and item.icon and _G.Icons then
                local icon_y = item_y + math.floor((self.row_height - 20) / 2)
                local icon_color = is_selected and colors.ACCENT or colors.WHITE
                _G.Icons.draw(item.icon, display, x + 12, icon_y, 20, icon_color)
            end

            -- Label
            local label_x = x + 12 + icon_offset
            local label_color = is_selected and colors.ACCENT or colors.TEXT
            display.draw_text(label_x, item_y + 2, item.label or "", label_color)

            -- Sublabel
            if item.sublabel then
                display.set_font_size("small")
                local sublabel_color = is_selected and colors.TEXT_SECONDARY or colors.TEXT_MUTED
                display.draw_text(label_x, item_y + 2 + fh - 2, item.sublabel, sublabel_color)
                display.set_font_size("medium")
            end

            -- Hotkey hint (right-aligned, dimmed)
            if item.hotkey then
                local hint = "[" .. item.hotkey .. "]"
                local hint_width = display.text_width(hint)
                display.set_font_size("small")
                display.draw_text(x + width - hint_width - 16, item_y + 4, hint, colors.TEXT_MUTED)
                display.set_font_size("medium")
            end
        end
    end

    -- Scrollbar
    if #self.items > self.visible_rows then
        local sb_x = x + width - 6
        local sb_height = height - 4
        local thumb_height = math.max(8, math.floor(sb_height * self.visible_rows / #self.items))
        local scroll_range = #self.items - self.visible_rows
        local thumb_range = sb_height - thumb_height
        local thumb_y = y + 2 + math.floor(self.scroll_offset * thumb_range / scroll_range)

        display.fill_rect(sb_x, y + 2, 4, sb_height, colors.SURFACE)
        display.fill_rect(sb_x, thumb_y, 4, thumb_height, focused and colors.ACCENT or colors.TEXT_SECONDARY)
    end

    return width, height
end

function VerticalList:handle_key(key)
    if #self.items == 0 then return nil end

    local function play_sound(name)
        if self.play_sounds and _G.SoundUtils and _G.SoundUtils[name] then
            pcall(_G.SoundUtils[name])
        end
    end

    if key.special == "UP" then
        if self.selected > 1 then
            self.selected = self.selected - 1
            self:adjust_scroll()
            play_sound("navigate")
            if self.on_change then
                self.on_change(self.selected, self.items[self.selected])
            end
            return "changed"
        end
    elseif key.special == "DOWN" then
        if self.selected < #self.items then
            self.selected = self.selected + 1
            self:adjust_scroll()
            play_sound("navigate")
            if self.on_change then
                self.on_change(self.selected, self.items[self.selected])
            end
            return "changed"
        end
    elseif key.special == "ENTER" then
        play_sound("click")
        if self.on_select then
            self.on_select(self.selected, self.items[self.selected])
        end
        return "selected"
    elseif key.character then
        -- Letter key navigation
        local result = self:handle_letter_key(key.character)
        if result then
            play_sound(result == "activated" and "click" or "navigate")
            return result
        end
    end

    return nil
end

-- Handle letter key for quick navigation
-- Returns: "activated" if hotkey triggered, "changed" if selection moved, nil otherwise
function VerticalList:handle_letter_key(char)
    local upper = string.upper(char)
    local now = _G.ez and ez.system.millis() or 0

    -- First check for explicit hotkeys (activates immediately)
    for i, item in ipairs(self.items) do
        if item.hotkey and string.upper(item.hotkey) == upper then
            if item.enabled ~= false then
                self.selected = i
                self:adjust_scroll()
                if self.on_change then
                    self.on_change(self.selected, self.items[self.selected])
                end
                if self.on_select then
                    self.on_select(self.selected, self.items[self.selected])
                end
                return "activated"
            end
        end
    end

    -- Find all items starting with this letter
    local matches = {}
    for i, item in ipairs(self.items) do
        local label = item.label or ""
        if string.upper(string.sub(label, 1, 1)) == upper then
            table.insert(matches, i)
        end
    end

    if #matches == 0 then
        return nil
    end

    -- Determine which match to select
    local target_idx
    if self.last_letter == upper and (now - self.last_letter_time) < 1000 then
        -- Same letter pressed within 1 second - cycle to next match
        local current_match_pos = 0
        for pos, idx in ipairs(matches) do
            if idx == self.selected then
                current_match_pos = pos
                break
            end
        end
        -- Move to next match, wrap around
        local next_pos = (current_match_pos % #matches) + 1
        target_idx = matches[next_pos]
    else
        -- Different letter or timeout - go to first match
        target_idx = matches[1]
    end

    self.last_letter = upper
    self.last_letter_time = now

    if target_idx ~= self.selected then
        self.selected = target_idx
        self:adjust_scroll()
        if self.on_change then
            self.on_change(self.selected, self.items[self.selected])
        end
        return "changed"
    end

    return nil
end

function VerticalList:adjust_scroll()
    if self.selected <= self.scroll_offset then
        self.scroll_offset = self.selected - 1
    elseif self.selected > self.scroll_offset + self.visible_rows then
        self.scroll_offset = self.selected - self.visible_rows
    end
    self.scroll_offset = math.max(0, self.scroll_offset)
end

function VerticalList:set_items(items)
    self.items = items or {}
    self.selected = math.min(self.selected, math.max(1, #self.items))
    self.scroll_offset = 0
    self.last_letter = nil
end

function VerticalList:get_selected()
    if #self.items == 0 then return nil, nil end
    return self.selected, self.items[self.selected]
end

function VerticalList:set_selected(index)
    self.selected = math.max(1, math.min(index, #self.items))
    self:adjust_scroll()
end

-- Find and select item by label
function VerticalList:select_by_label(label)
    for i, item in ipairs(self.items) do
        if item.label == label then
            self:set_selected(i)
            return true
        end
    end
    return false
end

return VerticalList
