-- Sprite Alpha Test Screen for T-Deck OS
-- Demonstrates sprite rendering with alpha blending

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local SpriteTest = {
    title = "Sprite Alpha"
}

function SpriteTest:new()
    local o = {
        title = self.title,
        alpha = 192,
        sprite = nil,
        popup_sprite = nil,
        time = 0,
    }
    setmetatable(o, {__index = SpriteTest})
    return o
end

function SpriteTest:on_enter()
end

function SpriteTest:on_exit()
    if self.sprite then
        self.sprite:destroy()
        self.sprite = nil
    end
    if self.popup_sprite then
        self.popup_sprite:destroy()
        self.popup_sprite = nil
    end
end

function SpriteTest:render(display)
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height

    ListMixin.draw_background(display)
    TitleBar.draw(display, self.title)

    local content_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31

    display.set_font_size("small")

    -- Draw grid pattern as background
    local grid_color = colors.SURFACE or display.rgb(30, 30, 30)
    for y = content_y, h - 20, 16 do
        for x = 0, w, 16 do
            display.draw_rect(x, y, 15, 15, grid_color)
        end
    end

    -- Draw colorful shapes as background
    display.fill_circle(60, content_y + 40, 25, colors.RED or display.rgb(255, 0, 0))
    display.fill_circle(160, content_y + 60, 30, colors.GREEN or display.rgb(0, 255, 0))
    display.fill_circle(260, content_y + 45, 20, colors.BLUE or display.rgb(0, 0, 255))

    -- Draw text that will show through
    display.set_font_size("medium")
    display.draw_text(20, content_y + 90, "Background text", colors.WHITE)
    display.draw_text(20, content_y + 110, "visible through", colors.CYAN or display.rgb(0, 255, 255))
    display.draw_text(20, content_y + 130, "semi-transparent", colors.YELLOW or display.rgb(255, 255, 0))
    display.draw_text(20, content_y + 150, "sprite overlay!", colors.ACCENT)

    -- Create main overlay sprite if needed
    if not self.sprite then
        self.sprite = display.create_sprite(180, 100)
    end

    -- Render the overlay sprite content
    if self.sprite then
        local sprite = self.sprite
        local sprite_bg = display.rgb(40, 40, 80)

        sprite:clear(sprite_bg)
        sprite:draw_round_rect(0, 0, 180, 100, 8, colors.ACCENT)
        sprite:draw_text(10, 10, "Sprite Overlay", colors.WHITE)
        sprite:draw_text(10, 30, string.format("Alpha: %d", self.alpha), colors.CYAN or display.rgb(0, 255, 255))
        sprite:fill_circle(140, 60, 20, colors.ACCENT)
        sprite:fill_rect(10, 55, 60, 30, colors.SUCCESS or colors.GREEN)

        local bar_w = math.floor(160 * self.alpha / 255)
        sprite:fill_rect(10, 88, bar_w, 8, colors.ACCENT)
        sprite:draw_rect(10, 88, 160, 8, colors.WHITE)

        sprite:push(70, content_y + 20, self.alpha)
    end

    -- Create popup sprite for animation demo
    if not self.popup_sprite then
        self.popup_sprite = display.create_sprite(100, 50)
    end

    -- Animate a floating popup
    if self.popup_sprite then
        local popup = self.popup_sprite
        popup:clear(0x0000)
        popup:set_transparent_color(0x0000)

        local popup_bg = display.rgb(80, 40, 40)
        popup:fill_round_rect(0, 0, 100, 50, 6, popup_bg)
        popup:draw_round_rect(0, 0, 100, 50, 6, colors.RED or display.rgb(255, 80, 80))
        popup:draw_text(8, 8, "Floating", colors.WHITE)
        popup:draw_text(8, 28, "Popup", colors.WHITE)

        self.time = self.time + 0.05
        local float_y = content_y + 100 + math.floor(math.sin(self.time) * 15)
        local float_alpha = 180 + math.floor(math.sin(self.time * 2) * 40)

        popup:push(200, float_y, float_alpha)
    end

    -- Draw alpha comparison strips at bottom
    display.set_font_size("tiny")
    local strip_y = h - 55
    local strip_h = 20
    local strip_w = 50

    display.draw_text(10, strip_y - 12, "Alpha comparison:", colors.TEXT_MUTED or colors.TEXT)

    local alphas = {64, 128, 192, 255}
    local labels = {"25%", "50%", "75%", "100%"}

    for i, a in ipairs(alphas) do
        local x = 10 + (i - 1) * (strip_w + 10)

        -- Checkerboard background
        display.fill_rect(x, strip_y, strip_w, strip_h, colors.WHITE)
        display.fill_rect(x, strip_y, strip_w / 2, strip_h / 2, colors.BLACK)
        display.fill_rect(x + strip_w / 2, strip_y + strip_h / 2, strip_w / 2, strip_h / 2, colors.BLACK)

        -- Overlay with alpha
        local temp_sprite = display.create_sprite(strip_w, strip_h)
        if temp_sprite then
            temp_sprite:clear(colors.ACCENT)
            temp_sprite:push(x, strip_y, a)
            temp_sprite:destroy()
        end

        display.draw_text(x + 15, strip_y + strip_h + 2, labels[i], colors.TEXT_MUTED or colors.TEXT)
    end

    display.set_font_size("small")
    local hint = "UP/DOWN:Alpha  LEFT/RIGHT:+/-10  ESC:Back"
    display.draw_text(4, h - 14, hint, colors.TEXT_MUTED or colors.TEXT)

    display.set_font_size("medium")

    -- Request continuous redraw for animation
    ScreenManager.post_invalidate()
end

function SpriteTest:handle_key(key)
    if key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    if key.special == "UP" then
        self.alpha = math.min(255, self.alpha + 5)
        ScreenManager.invalidate()
    elseif key.special == "DOWN" then
        self.alpha = math.max(0, self.alpha - 5)
        ScreenManager.invalidate()
    elseif key.special == "RIGHT" then
        self.alpha = math.min(255, self.alpha + 10)
        ScreenManager.invalidate()
    elseif key.special == "LEFT" then
        self.alpha = math.max(0, self.alpha - 10)
        ScreenManager.invalidate()
    end

    return "continue"
end

return SpriteTest
