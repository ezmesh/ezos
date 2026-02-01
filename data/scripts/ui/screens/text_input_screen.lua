-- Text Input Screen for T-Deck OS
-- Generic single-line text input dialog

local ListMixin = load_module("/scripts/ui/list_mixin.lua")
local Components = load_module("/scripts/ui/components.lua")

local TextInputScreen = {
    title = "Input",
}

-- Create a new text input screen
-- opts:
--   title: Screen title
--   label: Field label
--   value: Initial value
--   placeholder: Placeholder text when empty
--   password_mode: true to mask input with asterisks
--   max_length: Maximum input length (default 64)
--   on_submit: Callback function(value) called when user confirms
function TextInputScreen:new(opts)
    opts = opts or {}
    local o = {
        title = opts.title or self.title,
        label = opts.label or "Value:",
        on_submit = opts.on_submit,

        -- UI Components
        text_input = Components.TextInput:new({
            value = opts.value or "",
            placeholder = opts.placeholder or "",
            max_length = opts.max_length or 64,
            width = 200,
            password_mode = opts.password_mode or false,
        }),
    }
    setmetatable(o, {__index = TextInputScreen})
    return o
end

function TextInputScreen:on_enter()
    -- Position cursor at end of existing text
    self.text_input.cursor_pos = #self.text_input.value
end

function TextInputScreen:render(display)
    display.set_font_size("medium")

    local colors = ListMixin.get_colors(display)
    local fw = display.get_font_width()
    local fh = display.get_font_height()
    local w = display.width
    local h = display.height

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Draw title bar
    TitleBar.draw(display, self.title)

    -- Center the input vertically
    local input_y = (h - fh) / 2

    -- Label
    local label_x = 16
    display.draw_text(label_x, input_y, self.label, colors.TEXT_SECONDARY)

    -- Input field (below label)
    local input_x = (w - self.text_input.width) / 2
    self.text_input:render(display, input_x, input_y + fh + 8, true)

    -- Help bar at bottom
    local help_y = h - fh - 8
    local help_text = "[Enter] Save  [Esc] Cancel"
    local help_width = display.text_width(help_text)
    display.draw_text((w - help_width) / 2, help_y, help_text, colors.TEXT_MUTED)
end

function TextInputScreen:handle_key(key)
    ScreenManager.invalidate()

    if key.special == "ESCAPE" then
        return "pop"
    end

    local result = self.text_input:handle_key(key)

    if result == "submit" then
        local value = self.text_input:get_value()
        if self.on_submit then
            self.on_submit(value)
        end
        return "pop"
    end

    return "continue"
end

return TextInputScreen
