-- Settings Screen for T-Deck OS
-- Device configuration

local Settings = {
    title = "Settings",
    selected = 1,
    editing = false,
    settings = {
        {name = "node_name", label = "Name:", value = "MeshNode", type = "text"},
        {name = "region", label = "Region:", value = 1, type = "option", options = {"EU868", "US915", "AU915", "AS923"}},
        {name = "tx_power", label = "TX Power:", value = 22, type = "number", min = 0, max = 22, suffix = " dBm"},
        {name = "ttl", label = "TTL:", value = 3, type = "number", min = 1, max = 10, suffix = " hops"},
        {name = "brightness", label = "Display:", value = 200, type = "number", min = 25, max = 255, step = 25, suffix = "%", scale = 100/255},
        {name = "kb_backlight", label = "KB Light:", value = 0, type = "number", min = 0, max = 255, step = 25, suffix = "%", scale = 100/255},
        {name = "font_size", label = "Font:", value = 2, type = "option", options = {"Small", "Medium", "Large"}},
        {name = "trackball", label = "Trackball:", value = 2, type = "number", min = 1, max = 10, suffix = ""},
        {name = "adaptive", label = "Adaptive:", value = true, type = "toggle"},
        {name = "usb", label = "[USB File Transfer]", type = "button"},
        {name = "save", label = "[Save Settings]", type = "button"}
    }
}

function Settings:new()
    local o = {
        title = self.title,
        selected = 1,
        editing = false,
        settings = {}
    }

    -- Deep copy settings
    for i, s in ipairs(self.settings) do
        o.settings[i] = {
            name = s.name,
            label = s.label,
            value = s.value,
            type = s.type,
            options = s.options,
            min = s.min,
            max = s.max,
            step = s.step,
            suffix = s.suffix,
            scale = s.scale
        }
    end

    setmetatable(o, {__index = Settings})
    return o
end

function Settings:on_enter()
    self:load_settings()
end

function Settings:load_settings()
    -- Load from preferences
    local function get_pref(key, default)
        if tdeck.storage and tdeck.storage.get_pref then
            return tdeck.storage.get_pref(key, default)
        end
        return default
    end

    self.settings[1].value = get_pref("nodeName", "MeshNode")
    self.settings[2].value = get_pref("region", 1)
    self.settings[3].value = get_pref("txPower", 22)
    self.settings[4].value = get_pref("ttl", 3)
    self.settings[5].value = get_pref("brightness", 200)
    self.settings[6].value = get_pref("kbBacklight", 0)
    self.settings[7].value = get_pref("fontSize", 2)
    self.settings[8].value = get_pref("tbSens", 2)
    self.settings[9].value = get_pref("adaptScroll", true)

    -- Apply keyboard backlight immediately
    if tdeck.keyboard and tdeck.keyboard.set_backlight then
        tdeck.keyboard.set_backlight(self.settings[6].value)
    end
end

function Settings:save_settings()
    local function set_pref(key, value)
        if tdeck.storage and tdeck.storage.set_pref then
            tdeck.storage.set_pref(key, value)
        end
    end

    set_pref("nodeName", self.settings[1].value)
    set_pref("region", self.settings[2].value)
    set_pref("txPower", self.settings[3].value)
    set_pref("ttl", self.settings[4].value)
    set_pref("brightness", self.settings[5].value)
    set_pref("kbBacklight", self.settings[6].value)
    set_pref("fontSize", self.settings[7].value)
    set_pref("tbSens", self.settings[8].value)
    set_pref("adaptScroll", self.settings[9].value)

    tdeck.system.log("Settings saved")
end

function Settings:get_display_value(setting)
    if setting.type == "text" then
        return setting.value
    elseif setting.type == "option" then
        return setting.options[setting.value] or "?"
    elseif setting.type == "number" then
        local val = setting.value
        if setting.scale then
            val = math.floor(val * setting.scale)
        end
        return tostring(val) .. (setting.suffix or "")
    elseif setting.type == "toggle" then
        return setting.value and "On" or "Off"
    elseif setting.type == "button" then
        return ""
    end
    return ""
end

function Settings:render(display)
    local colors = display.colors

    display.draw_box(0, 0, display.cols, display.rows - 1,
                    self.title, colors.CYAN, colors.WHITE)

    local label_x = 2
    local value_x = 20

    for i, setting in ipairs(self.settings) do
        local row = i + 1
        local is_selected = (i == self.selected)
        local py = row * display.font_height

        if is_selected then
            display.fill_rect(display.font_width, py,
                            (display.cols - 2) * display.font_width,
                            display.font_height, colors.SELECTION)
            display.draw_text(display.font_width, py, ">", colors.CYAN)
        end

        -- Label
        local label_color = is_selected and colors.CYAN or colors.TEXT_DIM
        display.draw_text(label_x * display.font_width, py, setting.label, label_color)

        -- Value
        if setting.type ~= "button" then
            local value_str = self:get_display_value(setting)

            -- Show arrows when editing
            if self.editing and is_selected and setting.type ~= "text" then
                value_str = "< " .. value_str .. " >"
            end

            local value_color = is_selected and colors.CYAN or colors.TEXT
            display.draw_text(value_x * display.font_width, py, value_str, value_color)
        end
    end

    -- Help bar
    local help_text
    if self.editing then
        help_text = "[<>]Adjust [Enter]Done"
    else
        help_text = "[Enter]Edit [Q]Back"
    end
    display.draw_text(display.font_width, (display.rows - 3) * display.font_height,
                    help_text, colors.TEXT_DIM)
end

function Settings:handle_key(key)
    tdeck.screen.invalidate()

    if self.editing then
        if key.special == "LEFT" then
            self:adjust_value(-1)
        elseif key.special == "RIGHT" then
            self:adjust_value(1)
        elseif key.special == "ENTER" or key.special == "ESCAPE" then
            self.editing = false
        end
        return "continue"
    end

    if key.special == "UP" then
        self:select_previous()
    elseif key.special == "DOWN" then
        self:select_next()
    elseif key.special == "ENTER" then
        self:start_editing()
    elseif key.special == "ESCAPE" or key.character == "q" then
        return "pop"
    end

    return "continue"
end

function Settings:select_next()
    if self.selected < #self.settings then
        self.selected = self.selected + 1
    end
end

function Settings:select_previous()
    if self.selected > 1 then
        self.selected = self.selected - 1
    end
end

function Settings:start_editing()
    local setting = self.settings[self.selected]

    if setting.type == "text" then
        -- TODO: Open text input dialog
        tdeck.system.log("TODO: Text input for " .. setting.name)
    elseif setting.type == "button" then
        -- Execute button action
        if setting.name == "save" then
            self:save_settings()
        elseif setting.name == "usb" then
            local USBTransfer = dofile("/scripts/ui/screens/usb_transfer.lua")
            tdeck.screen.push(USBTransfer:new())
        end
    else
        self.editing = true
    end
end

function Settings:adjust_value(delta)
    local setting = self.settings[self.selected]

    if setting.type == "option" then
        local count = #setting.options
        setting.value = ((setting.value - 1 + delta) % count) + 1
    elseif setting.type == "number" then
        local step = setting.step or 1
        setting.value = setting.value + delta * step
        if setting.min then
            setting.value = math.max(setting.min, setting.value)
        end
        if setting.max then
            setting.value = math.min(setting.max, setting.value)
        end
    elseif setting.type == "toggle" then
        setting.value = not setting.value
    end

    -- Apply changes immediately for certain settings
    if setting.name == "brightness" then
        if tdeck.display and tdeck.display.set_brightness then
            tdeck.display.set_brightness(setting.value)
        end
    elseif setting.name == "kb_backlight" then
        if tdeck.keyboard and tdeck.keyboard.set_backlight then
            tdeck.keyboard.set_backlight(setting.value)
        end
    elseif setting.name == "trackball" then
        if tdeck.keyboard and tdeck.keyboard.set_trackball_sensitivity then
            tdeck.keyboard.set_trackball_sensitivity(setting.value)
        end
    elseif setting.name == "adaptive" then
        if tdeck.keyboard and tdeck.keyboard.set_adaptive_scrolling then
            tdeck.keyboard.set_adaptive_scrolling(setting.value)
        end
    end
end

return Settings
