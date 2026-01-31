-- List Mixin for T-Deck OS
-- Shared functionality for list-based screens

local ListMixin = {}

-- Apply list mixin to a screen class
-- screen should have: selected, scroll_offset, VISIBLE_ROWS, and a method to get item count
function ListMixin.apply(screen)
    -- Select next item
    function screen:select_next()
        local count = self:get_item_count()
        if count == 0 then return end

        if self.selected < count then
            self.selected = self.selected + 1
            -- Scroll down if needed
            if self.selected > self.scroll_offset + self.VISIBLE_ROWS then
                self.scroll_offset = self.selected - self.VISIBLE_ROWS
            end
        end
    end

    -- Select previous item
    function screen:select_previous()
        local count = self:get_item_count()
        if count == 0 then return end

        if self.selected > 1 then
            self.selected = self.selected - 1
            -- Scroll up if needed
            if self.selected <= self.scroll_offset then
                self.scroll_offset = self.selected - 1
            end
        end
    end

    -- Jump to first item
    function screen:select_first()
        self.selected = 1
        self.scroll_offset = 0
    end

    -- Jump to last item
    function screen:select_last()
        local count = self:get_item_count()
        if count == 0 then return end

        self.selected = count
        self.scroll_offset = math.max(0, count - self.VISIBLE_ROWS)
    end

    -- Page down
    function screen:page_down()
        local count = self:get_item_count()
        if count == 0 then return end

        self.selected = math.min(count, self.selected + self.VISIBLE_ROWS)
        self.scroll_offset = math.min(
            math.max(0, count - self.VISIBLE_ROWS),
            self.scroll_offset + self.VISIBLE_ROWS
        )
    end

    -- Page up
    function screen:page_up()
        self.selected = math.max(1, self.selected - self.VISIBLE_ROWS)
        self.scroll_offset = math.max(0, self.scroll_offset - self.VISIBLE_ROWS)
    end

    -- Clamp selection and scroll to valid range
    function screen:clamp_selection()
        local count = self:get_item_count()
        if count == 0 then
            self.selected = 1
            self.scroll_offset = 0
            return
        end

        self.selected = math.max(1, math.min(count, self.selected))
        self.scroll_offset = math.max(0, math.min(count - self.VISIBLE_ROWS, self.scroll_offset))

        -- Ensure selected is visible
        if self.selected <= self.scroll_offset then
            self.scroll_offset = self.selected - 1
        elseif self.selected > self.scroll_offset + self.VISIBLE_ROWS then
            self.scroll_offset = self.selected - self.VISIBLE_ROWS
        end
    end

    -- Handle common list navigation keys
    -- Returns true if key was handled, false otherwise
    function screen:handle_list_key(key)
        if key.special == "UP" then
            self:select_previous()
            return true
        elseif key.special == "DOWN" then
            self:select_next()
            return true
        elseif key.special == "HOME" or (key.ctrl and key.character == "a") then
            self:select_first()
            return true
        elseif key.special == "END" or (key.ctrl and key.character == "e") then
            self:select_last()
            return true
        elseif key.shift and key.special == "UP" then
            self:page_up()
            return true
        elseif key.shift and key.special == "DOWN" then
            self:page_down()
            return true
        end
        return false
    end
end

-- Draw scrollbar for a list
-- Parameters:
--   display: display object
--   x, y: top-left position of scrollbar
--   height: total height of scrollbar area
--   visible_count: number of visible items
--   total_count: total number of items
--   scroll_offset: current scroll offset
--   colors: color table with BORDER, TEXT_DIM, etc.
function ListMixin.draw_scrollbar(display, x, y, height, visible_count, total_count, scroll_offset, colors)
    if total_count <= visible_count then
        return  -- No scrollbar needed
    end

    local scrollbar_width = 6
    local min_thumb = 12

    -- Draw track
    display.fill_rect(x, y, scrollbar_width, height, colors.BORDER or colors.DARK_GRAY)

    -- Calculate thumb size and position
    local thumb_height = math.max(min_thumb, math.floor(height * visible_count / total_count))
    local scroll_range = total_count - visible_count
    local thumb_range = height - thumb_height

    local thumb_y = y
    if scroll_range > 0 then
        thumb_y = y + math.floor(scroll_offset * thumb_range / scroll_range)
    end

    -- Draw thumb
    display.fill_rect(x, thumb_y, scrollbar_width, thumb_height, colors.TEXT_DIM or colors.GRAY)
end

-- Get theme colors with fallback
function ListMixin.get_colors(display)
    if _G.ThemeManager and _G.ThemeManager.get_colors then
        return _G.ThemeManager.get_colors()
    end
    return display.colors
end

-- Draw background with theme support
function ListMixin.draw_background(display)
    if _G.ThemeManager and _G.ThemeManager.draw_background then
        _G.ThemeManager.draw_background(display)
    else
        display.fill_rect(0, 0, display.width, display.height, display.colors.BLACK)
    end
end

return ListMixin
