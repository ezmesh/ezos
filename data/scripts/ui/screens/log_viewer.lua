-- Log Viewer Screen
-- View system log entries

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local LogViewer = {
    title = "System Log",
    scroll_offset = 0,
    visible_lines = 10,
    auto_scroll = true,
}

function LogViewer:new()
    local o = {
        title = self.title,
        scroll_offset = 0,
        visible_lines = 10,
        auto_scroll = true,
    }
    setmetatable(o, {__index = LogViewer})
    return o
end

function LogViewer:on_enter()
    -- Scroll to bottom (latest entries)
    if _G.Logger then
        local entries = _G.Logger.get_entries()
        self.scroll_offset = math.max(0, #entries - self.visible_lines)
    end
end

function LogViewer:render(display)
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    -- Get log entries
    local entries = {}
    if _G.Logger then
        entries = _G.Logger.get_entries()
    end

    local total = #entries
    local info = total .. " entries"
    if self.auto_scroll then
        info = info .. " [AUTO]"
    end
    -- Draw info in top right corner, aligned with title
    display.draw_text(w - display.text_width(info) - 4, 4, info, colors.TEXT_SECONDARY)

    -- Log area starts below title bar
    local log_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31
    local line_h = 12
    self.visible_lines = math.floor((h - log_y - 20) / line_h)

    -- Draw entries
    for i = 0, self.visible_lines - 1 do
        local idx = self.scroll_offset + i + 1
        if idx > total then break end

        local entry = entries[idx]
        local y = log_y + i * line_h

        -- Color based on level
        local color = colors.TEXT
        if entry:find(" ERR ") then
            color = colors.ERROR
        elseif entry:find(" WRN ") then
            color = colors.WARNING
        elseif entry:find(" DBG ") then
            color = colors.TEXT_MUTED
        end

        -- Truncate for display
        local max_chars = math.floor(w / display.font_width) - 1
        if #entry > max_chars then
            entry = entry:sub(1, max_chars)
        end

        display.draw_text(4, y, entry, color)
    end

    -- Scroll indicator
    if total > self.visible_lines then
        local bar_h = math.max(10, (self.visible_lines / total) * (h - log_y - 30))
        local bar_y = log_y + (self.scroll_offset / (total - self.visible_lines)) * (h - log_y - 30 - bar_h)
        display.fill_rect(w - 4, bar_y, 2, bar_h, colors.SURFACE)
    end

    -- Help
    local help_y = h - 14
    display.fill_rect(0, help_y - 2, w, 16, colors.BLACK)
    display.draw_text(4, help_y, "Up/Dn=Scroll  A=Auto  C=Clear  Bksp=Back", colors.TEXT_SECONDARY)

    -- Reset font size
    display.set_font_size("medium")
end

function LogViewer:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end

    local entries = _G.Logger and _G.Logger.get_entries() or {}
    local total = #entries
    local max_offset = math.max(0, total - self.visible_lines)

    if key.special == "UP" then
        self.scroll_offset = math.max(0, self.scroll_offset - 1)
        self.auto_scroll = false
        ScreenManager.invalidate()

    elseif key.special == "DOWN" then
        self.scroll_offset = math.min(max_offset, self.scroll_offset + 1)
        if self.scroll_offset >= max_offset then
            self.auto_scroll = true
        end
        ScreenManager.invalidate()

    elseif key.special == "LEFT" then
        -- Page up
        self.scroll_offset = math.max(0, self.scroll_offset - self.visible_lines)
        self.auto_scroll = false
        ScreenManager.invalidate()

    elseif key.special == "RIGHT" then
        -- Page down
        self.scroll_offset = math.min(max_offset, self.scroll_offset + self.visible_lines)
        if self.scroll_offset >= max_offset then
            self.auto_scroll = true
        end
        ScreenManager.invalidate()

    elseif key.character == "a" or key.character == "A" then
        -- Toggle auto-scroll
        self.auto_scroll = not self.auto_scroll
        if self.auto_scroll then
            self.scroll_offset = max_offset
        end
        ScreenManager.invalidate()

    elseif key.character == "c" or key.character == "C" then
        -- Clear log
        if _G.Logger then
            _G.Logger.clear()
            self.scroll_offset = 0
        end
        ScreenManager.invalidate()
    end

    return "continue"
end

-- Menu items for app menu integration
function LogViewer:get_menu_items()
    local self_ref = self
    local items = {}

    table.insert(items, {
        label = "Clear",
        action = function()
            if _G.Logger then
                _G.Logger.clear()
                self_ref.scroll_offset = 0
            end
            ScreenManager.invalidate()
        end
    })

    table.insert(items, {
        label = "Auto-scroll",
        action = function()
            self_ref.auto_scroll = not self_ref.auto_scroll
            if self_ref.auto_scroll and _G.Logger then
                local entries = _G.Logger.get_entries()
                self_ref.scroll_offset = math.max(0, #entries - self_ref.visible_lines)
            end
            ScreenManager.invalidate()
        end
    })

    return items
end

function LogViewer:update()
    -- Auto-scroll to latest
    if self.auto_scroll and _G.Logger then
        local entries = _G.Logger.get_entries()
        local max_offset = math.max(0, #entries - self.visible_lines)
        if self.scroll_offset ~= max_offset then
            self.scroll_offset = max_offset
            ScreenManager.invalidate()
        end
    end
end

return LogViewer
