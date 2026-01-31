-- Hotkey Configuration Screen for T-Deck OS
-- Generic hotkey recorder for any key combination

local ListMixin = load_module("/scripts/ui/list_mixin.lua")

local HotkeyConfig = {
    title = "Hotkey",
    disable_app_menu = true,  -- Prevent menu interference during recording
    capture_input = false,    -- Set to true only while recording
    recording = false,
    countdown = 0,
    countdown_start = 0,
    RECORD_TIMEOUT = 5000,  -- 5 seconds to record
    recorded_matrix = nil,
    current_matrix = nil,
    hotkey_id = "menu",      -- Identifier for this hotkey
    pref_key = "menuHotkey", -- Preferences key for storage
    default_desc = "LShift+RShift",  -- Default description
}

-- Default hotkey descriptions
local DEFAULT_DESCS = {
    menu = "LShift+RShift",
    screenshot = "Mic+Sym",
}

function HotkeyConfig:new(hotkey_id, title, pref_key)
    local o = {
        title = title or "Hotkey",
        disable_app_menu = true,
        recording = false,
        countdown = 0,
        countdown_start = 0,
        RECORD_TIMEOUT = self.RECORD_TIMEOUT,
        recorded_matrix = nil,
        current_matrix = nil,
        hotkey_id = hotkey_id or "menu",
        pref_key = pref_key or "menuHotkey",
        default_desc = DEFAULT_DESCS[hotkey_id] or "Default",
    }
    setmetatable(o, {__index = HotkeyConfig})
    return o
end

function HotkeyConfig:on_enter()
    -- Stay in normal mode for navigation, switch to raw only when recording
    -- Load current hotkey setting
    self:load_current()
end

function HotkeyConfig:on_exit()
    self.recording = false
    self.capture_input = false
    ez.keyboard.set_mode("normal")
end

function HotkeyConfig:start_recording()
    self.recording = true
    self.capture_input = true  -- Prevent ScreenManager from reading keyboard
    self.countdown_start = ez.system.millis()
    self.current_matrix = nil
    ez.keyboard.set_mode("raw")
    if _G.SoundUtils and _G.SoundUtils.is_enabled() then
        _G.SoundUtils.click()
    end
    ScreenManager.invalidate()
end

function HotkeyConfig:stop_recording()
    self.recording = false
    self.capture_input = false
    ez.keyboard.set_mode("normal")
    ScreenManager.invalidate()
end

function HotkeyConfig:load_current()
    if ez.storage and ez.storage.get_pref then
        local saved = ez.storage.get_pref(self.pref_key, nil)
        if saved then
            self.recorded_matrix = saved
        end
    end
end

function HotkeyConfig:save_hotkey(matrix_bits)
    if ez.storage and ez.storage.set_pref then
        if matrix_bits then
            ez.storage.set_pref(self.pref_key, matrix_bits)
        else
            -- Clear/reset to default
            ez.storage.set_pref(self.pref_key, nil)
        end
    end
    self.recorded_matrix = matrix_bits

    -- Notify appropriate handler based on hotkey type
    if self.hotkey_id == "menu" then
        -- Reload the hotkey in StatusBar so it takes effect immediately
        if _G.StatusBar and _G.StatusBar.reload_hotkey then
            _G.StatusBar.reload_hotkey()
        end
    elseif self.hotkey_id == "screenshot" then
        -- Reload screenshot hotkey
        if _G.StatusBar and _G.StatusBar.reload_screenshot_hotkey then
            _G.StatusBar.reload_screenshot_hotkey()
        end
    end
end

function HotkeyConfig:get_matrix_bits()
    local matrix = ez.keyboard.read_raw_matrix()
    if not matrix then return 0 end

    -- Pack 5 columns x 7 rows into a single number
    -- Each column is 7 bits, total 35 bits fits in a Lua number
    local bits = 0
    for col = 1, 5 do
        local col_byte = matrix[col] or 0
        bits = bits + (col_byte * (128 ^ (col - 1)))
    end
    return bits
end

function HotkeyConfig:count_keys(bits)
    local count = 0
    while bits > 0 do
        if bits % 2 == 1 then
            count = count + 1
        end
        bits = math.floor(bits / 2)
    end
    return count
end

function HotkeyConfig:format_matrix(bits)
    if not bits or bits == 0 then
        return "None"
    end

    -- Describe which keys are set
    local keys = {}
    local temp = bits
    for col = 0, 4 do
        local col_byte = math.floor(temp % 128)
        temp = math.floor(temp / 128)
        for row = 0, 6 do
            if (col_byte & (1 << row)) ~= 0 then
                table.insert(keys, string.format("C%dR%d", col, row))
            end
        end
    end

    if #keys == 0 then
        return "None"
    elseif #keys <= 3 then
        return table.concat(keys, "+")
    else
        return #keys .. " keys"
    end
end

function HotkeyConfig:render(display)
    local colors = ListMixin.get_colors(display)
    local w = display.width
    local h = display.height

    -- Fill background with theme wallpaper
    ListMixin.draw_background(display)

    -- Title bar
    TitleBar.draw(display, self.title)

    local list_start_y = _G.ThemeManager and _G.ThemeManager.LIST_START_Y or 31
    local y = list_start_y + 10

    display.set_font_size("medium")

    -- Current hotkey display
    display.draw_text(10, y, "Current:", colors.TEXT_SECONDARY)
    local current_str = self:format_matrix(self.recorded_matrix)
    if not self.recorded_matrix then
        current_str = "Default (" .. self.default_desc .. ")"
    end
    display.draw_text(90, y, current_str, colors.ACCENT)
    y = y + 25

    -- Separator
    display.fill_rect(10, y, w - 20, 1, colors.TEXT_SECONDARY)
    y = y + 15

    if self.recording then
        -- Recording mode
        local elapsed = ez.system.millis() - self.countdown_start
        local remaining = math.ceil((self.RECORD_TIMEOUT - elapsed) / 1000)

        if elapsed >= self.RECORD_TIMEOUT then
            -- Time's up - save whatever is pressed and exit raw mode
            if self.current_matrix and self.current_matrix > 0 then
                self:save_hotkey(self.current_matrix)
                if _G.SoundUtils and _G.SoundUtils.is_enabled() then
                    _G.SoundUtils.confirm()
                end
            end
            self:stop_recording()
        else
            -- Show countdown
            display.draw_text_centered(y, "RECORDING...", colors.WARNING)
            y = y + 25

            display.set_font_size("large")
            display.draw_text_centered(y, tostring(remaining), colors.WHITE)
            y = y + 35

            display.set_font_size("medium")
            display.draw_text_centered(y, "Hold desired key(s)", colors.TEXT_SECONDARY)
            y = y + 25

            -- Show currently pressed keys
            self.current_matrix = self:get_matrix_bits()
            local pressed_str = self:format_matrix(self.current_matrix)
            display.draw_text_centered(y, "Pressed: " .. pressed_str, colors.SUCCESS)
        end
    else
        -- Normal mode - show instructions
        display.draw_text_centered(y, "Configure " .. string.lower(self.title), colors.TEXT)
        y = y + 30

        display.set_font_size("small")
        display.draw_text_centered(y, "Press ENTER to record new hotkey", colors.TEXT_SECONDARY)
        y = y + 18
        display.draw_text_centered(y, "You have 5 seconds to press", colors.TEXT_SECONDARY)
        y = y + 18
        display.draw_text_centered(y, "and hold the desired key(s)", colors.TEXT_SECONDARY)
        y = y + 30

        display.set_font_size("medium")
        display.draw_text_centered(y, "Press R to reset to default", colors.TEXT_SECONDARY)
        y = y + 20
        display.draw_text_centered(y, "Press Q to exit", colors.TEXT_SECONDARY)
    end

    -- Reset font
    display.set_font_size("medium")
end

function HotkeyConfig:update()
    if self.recording then
        ScreenManager.invalidate()
    end
end

function HotkeyConfig:handle_key(key)
    -- In recording mode, we ignore key events (using raw matrix instead)
    -- Note: handle_key shouldn't be called during recording because capture_input is true
    if self.recording then
        return "continue"
    end

    if key.special == "ENTER" then
        -- Start recording (switches to raw mode)
        self:start_recording()
    elseif key.character == "r" or key.character == "R" then
        -- Reset to default
        self:save_hotkey(nil)
        if _G.SoundUtils and _G.SoundUtils.is_enabled() then
            _G.SoundUtils.back()
        end
        ScreenManager.invalidate()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    return "continue"
end

return HotkeyConfig
