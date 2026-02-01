-- VerticalList: Scrollable list of items

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
    }
    setmetatable(o, VerticalList)
    return o
end

function VerticalList:render(display, x, y, width, focused)
    local colors = get_colors(display)
    local fh = display.get_font_height()
    local fw = display.get_font_width()

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
            if self.selected <= self.scroll_offset then
                self.scroll_offset = self.selected - 1
            end
            play_sound("navigate")
            if self.on_change then
                self.on_change(self.selected, self.items[self.selected])
            end
            return "changed"
        end
    elseif key.special == "DOWN" then
        if self.selected < #self.items then
            self.selected = self.selected + 1
            if self.selected > self.scroll_offset + self.visible_rows then
                self.scroll_offset = self.selected - self.visible_rows
            end
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
    end

    return nil
end

function VerticalList:set_items(items)
    self.items = items or {}
    self.selected = math.min(self.selected, math.max(1, #self.items))
    self.scroll_offset = 0
end

function VerticalList:get_selected()
    if #self.items == 0 then return nil, nil end
    return self.selected, self.items[self.selected]
end

function VerticalList:set_selected(index)
    self.selected = math.max(1, math.min(index, #self.items))
    if self.selected <= self.scroll_offset then
        self.scroll_offset = self.selected - 1
    elseif self.selected > self.scroll_offset + self.visible_rows then
        self.scroll_offset = self.selected - self.visible_rows
    end
end

return VerticalList
