-- icon_test.lua - Test screen for icon display
-- Shows all available icons with names and sizes

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local IconTest = {
    title = "Icons Test",
}

function IconTest:new()
    local o = {
        title = "Icons Test",
        scroll_y = 0,
        max_scroll = 0,
    }
    setmetatable(o, {__index = IconTest})
    return o
end

function IconTest:on_enter()
    self.scroll_y = 0
end

function IconTest:render(display)
    local colors = ListMixin.get_colors(display)

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    local y = 32 - self.scroll_y
    local x_start = 8
    local w = display.width

    -- Get Icons module
    local Icons = _G.Icons
    if not Icons then
        display.set_font_size("medium")
        display.draw_text(x_start, y, "Icons module not loaded", colors.ERROR)
        return
    end

    -- Get sorted list of icon names
    local icon_names = {}
    for name, _ in pairs(Icons.data) do
        table.insert(icon_names, name)
    end
    table.sort(icon_names)

    -- Layout constants
    local ICON_SIZE = 24
    local CELL_WIDTH = 75    -- Width of each cell (icon + label)
    local CELL_HEIGHT = 50   -- Height of each cell
    local COLS = math.floor((w - 16) / CELL_WIDTH)
    if COLS < 1 then COLS = 1 end

    display.set_font_size("small")
    local font_height = display.get_font_height()

    -- Section: Standard Icons (24x24)
    if y > 10 and y < display.height then
        display.set_font_size("medium")
        display.draw_text(x_start, y, "Standard Icons (24x24)", colors.ACCENT)
        display.set_font_size("small")
    end
    y = y + 20

    -- Draw standard icons in a grid
    local col = 0
    for i, name in ipairs(icon_names) do
        local cell_x = x_start + col * CELL_WIDTH
        local cell_y = y

        -- Only draw if visible
        if cell_y + CELL_HEIGHT > 20 and cell_y < display.height then
            -- Draw icon centered in cell (ensure integer coordinates)
            local icon_x = math.floor(cell_x + (CELL_WIDTH - ICON_SIZE) / 2)
            Icons.draw(name, display, icon_x, cell_y, ICON_SIZE, colors.WHITE)

            -- Draw name below icon (truncate if needed)
            local label = name
            if #label > 10 then
                label = string.sub(label, 1, 9) .. "."
            end
            local label_x = math.floor(cell_x + (CELL_WIDTH - #label * 6) / 2)
            display.draw_text(label_x, cell_y + ICON_SIZE + 2, label, colors.TEXT_SECONDARY)
        end

        col = col + 1
        if col >= COLS then
            col = 0
            y = y + CELL_HEIGHT
        end
    end

    -- Move to next row if we have remaining items
    if col > 0 then
        y = y + CELL_HEIGHT
    end
    y = y + 10

    -- Section: Scaled Icons demonstration
    if y > 10 and y < display.height then
        display.set_font_size("medium")
        display.draw_text(x_start, y, "Scaling Demo", colors.ACCENT)
        display.set_font_size("small")
    end
    y = y + 20

    -- Show an icon at different scales
    local demo_icon = "home"
    local scales = {12, 24, 36, 48}
    local demo_x = x_start

    for _, size in ipairs(scales) do
        if y > 10 and y < display.height and demo_x + size < w - 10 then
            Icons.draw(demo_icon, display, demo_x, y, size, colors.WHITE)
            local size_label = tostring(size)
            local label_x = math.floor(demo_x + (size - #size_label * 6) / 2)
            display.draw_text(label_x, y + size + 2, size_label, colors.TEXT_SECONDARY)
            demo_x = demo_x + size + 20
        end
    end
    y = y + 60

    -- Section: Small Icons (12x12)
    if Icons.small then
        local small_names = {}
        for name, _ in pairs(Icons.small) do
            table.insert(small_names, name)
        end
        table.sort(small_names)

        if #small_names > 0 then
            if y > 10 and y < display.height then
                display.set_font_size("medium")
                display.draw_text(x_start, y, "Small Icons (12x12)", colors.ACCENT)
                display.set_font_size("small")
            end
            y = y + 20

            local SMALL_CELL_WIDTH = 70
            local SMALL_CELL_HEIGHT = 30
            col = 0

            for i, name in ipairs(small_names) do
                local cell_x = x_start + col * SMALL_CELL_WIDTH
                local cell_y = y

                if cell_y + SMALL_CELL_HEIGHT > 20 and cell_y < display.height then
                    -- Draw small icon (ensure integer coordinates)
                    local icon_x = math.floor(cell_x + (SMALL_CELL_WIDTH - 12) / 2)
                    Icons.draw_small(name, display, icon_x, cell_y, colors.WHITE)

                    -- Draw name below
                    local label = name
                    if #label > 8 then
                        label = string.sub(label, 1, 7) .. "."
                    end
                    local label_x = math.floor(cell_x + (SMALL_CELL_WIDTH - #label * 6) / 2)
                    display.draw_text(label_x, cell_y + 14, label, colors.TEXT_SECONDARY)
                end

                col = col + 1
                if col >= COLS then
                    col = 0
                    y = y + SMALL_CELL_HEIGHT
                end
            end

            if col > 0 then
                y = y + SMALL_CELL_HEIGHT
            end
        end
    end

    y = y + 10

    -- Section: Stats
    if y > 10 and y < display.height then
        display.set_font_size("medium")
        display.draw_text(x_start, y, "Summary", colors.ACCENT)
        display.set_font_size("small")
    end
    y = y + 18

    local standard_count = #icon_names
    local small_count = 0
    if Icons.small then
        for _ in pairs(Icons.small) do small_count = small_count + 1 end
    end

    if y > 10 and y < display.height then
        local stats = string.format("Total: %d standard, %d small icons", standard_count, small_count)
        display.draw_text(x_start, y, stats, colors.TEXT_SECONDARY)
    end
    y = y + font_height + 2

    if y > 10 and y < display.height then
        local bytes = standard_count * 72 + small_count * 24
        local mem_info = string.format("Memory: ~%d bytes icon data", bytes)
        display.draw_text(x_start, y, mem_info, colors.TEXT_SECONDARY)
    end
    y = y + 20

    -- Calculate max scroll
    self.max_scroll = math.max(0, y + self.scroll_y - display.height + 20)

    -- Reset to medium font
    display.set_font_size("medium")

    -- Show scroll hint at bottom
    display.set_font_size("small")
    local hint = string.format("[Up/Down] Scroll (%d/%d)  [Q] Quit",
        self.scroll_y, self.max_scroll)
    display.draw_text(5, display.height - 12, hint, colors.TEXT_MUTED)
end

function IconTest:handle_key(key)
    if key.character == "q" or key.special == "ESCAPE" then
        return "pop"
    elseif key.special == "UP" then
        self.scroll_y = math.max(0, self.scroll_y - 30)
        ScreenManager.invalidate()
    elseif key.special == "DOWN" then
        self.scroll_y = math.min(self.max_scroll, self.scroll_y + 30)
        ScreenManager.invalidate()
    elseif key.special == "HOME" then
        self.scroll_y = 0
        ScreenManager.invalidate()
    elseif key.special == "END" then
        self.scroll_y = self.max_scroll
        ScreenManager.invalidate()
    end

    return "continue"
end

return IconTest
