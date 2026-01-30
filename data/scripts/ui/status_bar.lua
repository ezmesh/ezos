-- status_bar.lua - Minimal Lua-based status bar
-- Stripped down version to save memory

local StatusBar = {
    battery = 100,
    radio_ok = false,
    signal_bars = 0,
    node_count = 0,
    has_unread = false,
    free_mem_kb = 0,
    total_mem_kb = 0,
    free_psram_kb = 0,
    total_psram_kb = 0,

    -- Memory history (small ring buffers)
    heap_history = {},
    heap_idx = 1,
    psram_history = {},
    psram_idx = 1,
    mem_last = 0,

    -- Time format: 1 = 24h, 2 = 12h AM/PM
    time_format = 1,

    -- Loading indicator (uses counter so multiple processes can use it correctly)
    loading_count = 0,
    loading_frame = 0,
    loading_last = 0,

    -- Menu hotkey detection
    menu_check_interval = 100,
    menu_last_check = 0,
    menu_triggered = false,
    -- Default hotkey: sym key (column 0, row 2 = 0x04)
    -- Format: matrix bits packed as col0*128^0 + col1*128^1 + ...
    menu_hotkey = 139264,  -- LShift (col1=0x40) + RShift (col2=0x08)
    menu_hotkey_loaded = false,

    -- Screenshot hotkey detection
    screenshot_hotkey = 2097156,  -- Default: Mic (col3=0x01) + Sym (col0=0x04) = 2097156
    screenshot_hotkey_loaded = false,
    screenshot_triggered = false,
}

function StatusBar.set_battery(p) StatusBar.battery = p or 0 end
function StatusBar.set_radio(ok, b) StatusBar.radio_ok = ok; StatusBar.signal_bars = b or 0 end
function StatusBar.set_node_count(c) StatusBar.node_count = c or 0 end
function StatusBar.set_node_id(id) end
function StatusBar.set_unread(u) StatusBar.has_unread = u or false end
function StatusBar.set_free_memory(kb) StatusBar.free_mem_kb = kb or 0 end

function StatusBar.show_loading(flush_now)
    StatusBar.loading_count = StatusBar.loading_count + 1
    if StatusBar.loading_count == 1 then
        StatusBar.loading_frame = 0
        StatusBar.loading_last = 0
    end
    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
        -- If flush_now is true, force immediate render so spinner is visible
        -- before a blocking operation starts
        if flush_now then
            _G.ScreenManager.render()
        end
    end
end

function StatusBar.hide_loading()
    if StatusBar.loading_count > 0 then
        StatusBar.loading_count = StatusBar.loading_count - 1
    end
    if _G.ScreenManager then _G.ScreenManager.invalidate() end
end

function StatusBar.is_loading()
    return StatusBar.loading_count > 0
end

function StatusBar.update_memory()
    if tdeck.system.get_free_heap then
        StatusBar.free_mem_kb = math.floor(tdeck.system.get_free_heap() / 1024)
        if tdeck.system.get_total_heap then
            StatusBar.total_mem_kb = math.floor(tdeck.system.get_total_heap() / 1024)
        end
    end

    if tdeck.system.get_free_psram then
        StatusBar.free_psram_kb = math.floor(tdeck.system.get_free_psram() / 1024)
        if tdeck.system.get_total_psram then
            StatusBar.total_psram_kb = math.floor(tdeck.system.get_total_psram() / 1024)
        end
    end

    -- Sample history every 500ms
    local now = tdeck.system.millis()
    if now - StatusBar.mem_last >= 500 then
        StatusBar.mem_last = now

        -- Heap usage percentage
        local heap_total = StatusBar.total_mem_kb
        if heap_total <= 0 then heap_total = 320 end
        local heap_used = heap_total - StatusBar.free_mem_kb
        local heap_pct = math.floor((heap_used / heap_total) * 100)
        if heap_pct < 0 then heap_pct = 0 end
        if heap_pct > 100 then heap_pct = 100 end
        StatusBar.heap_history[StatusBar.heap_idx] = heap_pct
        StatusBar.heap_idx = StatusBar.heap_idx + 1
        if StatusBar.heap_idx > 30 then StatusBar.heap_idx = 1 end

        -- PSRAM usage percentage
        local psram_total = StatusBar.total_psram_kb
        if psram_total > 0 then
            local psram_used = psram_total - StatusBar.free_psram_kb
            local psram_pct = math.floor((psram_used / psram_total) * 100)
            if psram_pct < 0 then psram_pct = 0 end
            if psram_pct > 100 then psram_pct = 100 end
            StatusBar.psram_history[StatusBar.psram_idx] = psram_pct
            StatusBar.psram_idx = StatusBar.psram_idx + 1
            if StatusBar.psram_idx > 30 then StatusBar.psram_idx = 1 end
        end

        if _G.ScreenManager then
            _G.ScreenManager.invalidate()
        end
    end
end

function StatusBar.get_status()
    return {
        battery = StatusBar.battery,
        radio_ok = StatusBar.radio_ok,
        signal_bars = StatusBar.signal_bars,
        node_count = StatusBar.node_count,
        has_unread = StatusBar.has_unread,
        free_mem_kb = StatusBar.free_mem_kb,
    }
end

function StatusBar.render(display)
    display.set_font_size("small")
    StatusBar._render_impl(display)
    display.set_font_size("medium")
end

-- Draw a sparkline for a history buffer
local function draw_sparkline(display, history, idx, x, y, width, height, colors)
    local count = #history
    if count == 0 then return end

    local samples = math.min(count, width)
    local start = idx - samples
    if start < 1 then start = start + 30 end

    for i = 0, samples - 1 do
        local hist_idx = start + i
        if hist_idx > 30 then hist_idx = hist_idx - 30 end
        local val = history[hist_idx]
        if val then
            local h = math.floor(val / (100 / height))
            if h < 1 then h = 1 end
            local c = colors.SUCCESS
            if val > 80 then c = colors.ERROR
            elseif val > 60 then c = colors.WARNING end
            display.fill_rect(x + i, y + height - h, 1, h, c)
        end
    end
end

-- Get color based on battery level (used for both battery and signal)
local function get_level_color(level, colors)
    if level <= 20 then return colors.ERROR
    elseif level <= 40 then return colors.WARNING
    else return colors.SUCCESS end
end

function StatusBar._render_impl(display)
    -- Use themed colors if available
    local colors = _G.ThemeManager and _G.ThemeManager.get_colors() or display.colors
    local fw = display.get_font_width()
    local fh = display.get_font_height()
    local cols = display.get_cols()
    local rows = display.get_rows()

    local y = (rows - 1) * fh
    local sep_y = y - fh / 2

    -- Separator and background
    display.fill_rect(0, sep_y - 1, display.width, 1, colors.TEXT_SECONDARY)
    display.fill_rect(0, sep_y, display.width, display.height - sep_y, colors.BLACK)

    -- Calculate vertical center of status bar area for centering elements
    local bar_area_height = display.height - sep_y
    local center_y = sep_y + math.floor(bar_area_height / 2)

    -- Layout: [2px margin][heap spark][2px][psram spark] ... [time] ... [signal bars][2px][battery][2px margin]
    local spark_width = 30
    local spark_height = 10
    local spark_y = center_y - math.floor(spark_height / 2)

    -- Heap sparkline (left with 2px margin)
    local heap_x = 4
    draw_sparkline(display, StatusBar.heap_history, StatusBar.heap_idx, heap_x, spark_y, spark_width, spark_height, colors)

    -- PSRAM sparkline (2px gap after heap)
    local psram_x = heap_x + spark_width + 2
    draw_sparkline(display, StatusBar.psram_history, StatusBar.psram_idx, psram_x, spark_y, spark_width, spark_height, colors)

    -- Loading spinner (after sparklines, animated)
    if StatusBar.loading_count > 0 then
        local spinner_size = 10
        local spinner_x = psram_x + spark_width + 6
        local spinner_cy = center_y
        local spinner_cx = spinner_x + math.floor(spinner_size / 2)

        -- Animate the spinner (4 frames, rotate every 100ms)
        local now = tdeck.system.millis()
        if now - StatusBar.loading_last >= 100 then
            StatusBar.loading_last = now
            StatusBar.loading_frame = (StatusBar.loading_frame + 1) % 4
            if _G.ScreenManager then _G.ScreenManager.invalidate() end
        end

        -- Draw spinner as rotating line segments (4 positions)
        -- Frame 0: | Frame 1: / Frame 2: - Frame 3: \
        local frame = StatusBar.loading_frame
        local r = 4  -- radius

        if frame == 0 then
            -- Vertical |
            display.fill_rect(spinner_cx, spinner_cy - r, 1, r * 2, colors.ACCENT)
        elseif frame == 1 then
            -- Diagonal /
            for i = 0, r - 1 do
                display.fill_rect(spinner_cx - r + i + 1, spinner_cy + r - i - 1, 1, 1, colors.ACCENT)
                display.fill_rect(spinner_cx + i, spinner_cy - i - 1, 1, 1, colors.ACCENT)
            end
        elseif frame == 2 then
            -- Horizontal -
            display.fill_rect(spinner_cx - r, spinner_cy, r * 2, 1, colors.ACCENT)
        else
            -- Diagonal \
            for i = 0, r - 1 do
                display.fill_rect(spinner_cx - r + i + 1, spinner_cy - r + i + 1, 1, 1, colors.ACCENT)
                display.fill_rect(spinner_cx + i, spinner_cy + i, 1, 1, colors.ACCENT)
            end
        end
    end

    -- Battery (far right with 2px margin) - 18px wide + 2px nub = 20px total, 10px tall
    local batt_width = 20
    local batt_height = 10
    local batt_x = display.width - batt_width - 4
    local by = center_y - math.floor(batt_height / 2)

    -- Battery outline
    display.fill_rect(batt_x, by, 18, 1, colors.TEXT_SECONDARY)
    display.fill_rect(batt_x, by + 9, 18, 1, colors.TEXT_SECONDARY)
    display.fill_rect(batt_x, by, 1, 10, colors.TEXT_SECONDARY)
    display.fill_rect(batt_x + 17, by, 1, 10, colors.TEXT_SECONDARY)
    display.fill_rect(batt_x + 18, by + 3, 2, 4, colors.TEXT_SECONDARY)

    -- Battery fill
    local fill = math.floor((StatusBar.battery * 4) / 100)
    if StatusBar.battery > 0 and fill == 0 then fill = 1 end
    local bc = get_level_color(StatusBar.battery, colors)

    for i = 0, 3 do
        local c = (i < fill) and bc or colors.SURFACE
        display.fill_rect(batt_x + 2 + i * 4, by + 2, 3, 6, c)
    end

    -- Signal bars (2px gap before battery) - 4 bars * 4px = 16px, max 12px tall
    local signal_width = 16
    local signal_height = 12
    local signal_x = batt_x - 2 - signal_width
    local signal_base_y = center_y + math.floor(signal_height / 2)

    if StatusBar.radio_ok then
        -- Use battery-style coloring based on signal strength (bars out of 4)
        local signal_level = (StatusBar.signal_bars / 4) * 100
        local sc = get_level_color(signal_level, colors)

        for i = 0, 3 do
            local bh = math.floor((signal_height * (i + 1)) / 4)
            local bx = signal_x + i * 4
            local bar_y = signal_base_y - bh
            local c = (i < StatusBar.signal_bars) and sc or colors.SURFACE
            display.fill_rect(bx, bar_y, 3, bh, c)
        end
    else
        display.draw_text(signal_x, y, "!RF", colors.ERROR)
    end

    -- Time display (center of screen)
    local time_str = "--:--"
    local t = tdeck.system.get_time and tdeck.system.get_time()

    if t then
        -- Load time format preference (1 = 24h, 2 = 12h AM/PM)
        local format = StatusBar.time_format
        if tdeck.storage and tdeck.storage.get_pref then
            format = tdeck.storage.get_pref("timeFormat", 1)
        end

        if format == 2 then
            -- 12h AM/PM format
            local h = t.hour
            local suffix = "AM"
            if h >= 12 then
                suffix = "PM"
                if h > 12 then h = h - 12 end
            end
            if h == 0 then h = 12 end
            time_str = string.format("%d:%02d%s", h, t.minute, suffix)
        else
            -- 24h format
            time_str = string.format("%02d:%02d", t.hour, t.minute)
        end
    end

    -- Center the time on the display using draw_text_centered
    display.draw_text_centered(y - 3, time_str, colors.TEXT)

    -- Unread indicator next to time
    if StatusBar.has_unread then
        local time_width = display.text_width(time_str)
        local time_x = math.floor((display.width - time_width) / 2)
        display.draw_text(time_x + time_width + 2, y, "*", colors.INFO)
    end
end

function StatusBar.load_hotkey()
    -- Load hotkey from preferences (only once unless forced)
    if StatusBar.menu_hotkey_loaded then
        return
    end
    StatusBar.menu_hotkey_loaded = true

    if tdeck.storage and tdeck.storage.get_pref then
        local saved = tdeck.storage.get_pref("menuHotkey", nil)
        if saved and saved > 0 then
            StatusBar.menu_hotkey = saved
        end
    end
end

function StatusBar.reload_hotkey()
    -- Force reload hotkey from preferences (called after settings change)
    StatusBar.menu_hotkey_loaded = false
    StatusBar.menu_hotkey = 139264  -- Reset to default (LShift + RShift)
    StatusBar.load_hotkey()
end

function StatusBar.load_screenshot_hotkey()
    -- Load screenshot hotkey from preferences (only once unless forced)
    if StatusBar.screenshot_hotkey_loaded then
        return
    end
    StatusBar.screenshot_hotkey_loaded = true

    if tdeck.storage and tdeck.storage.get_pref then
        local saved = tdeck.storage.get_pref("screenshotHotkey", nil)
        if saved and saved > 0 then
            StatusBar.screenshot_hotkey = saved
        end
    end
end

function StatusBar.reload_screenshot_hotkey()
    -- Force reload screenshot hotkey from preferences
    StatusBar.screenshot_hotkey_loaded = false
    StatusBar.screenshot_hotkey = 2097156  -- Reset to default (Mic + Sym)
    StatusBar.load_screenshot_hotkey()
end

function StatusBar.take_screenshot()
    -- Take a screenshot and save to SD card
    if tdeck.display and tdeck.display.save_screenshot then
        local filename = "/screenshots/screen_" .. os.time() .. ".bmp"
        local ok = tdeck.display.save_screenshot(filename)
        if ok then
            tdeck.system.log("[Screenshot] Saved: " .. filename)
            if _G.SoundUtils and _G.SoundUtils.is_enabled() then
                _G.SoundUtils.confirm()
            end
        else
            tdeck.system.log("[Screenshot] Failed to save")
            if _G.SoundUtils and _G.SoundUtils.is_enabled() then
                _G.SoundUtils.error()
            end
        end
        return ok
    else
        tdeck.system.log("[Screenshot] Not available")
        return false
    end
end

function StatusBar.get_matrix_bits(matrix)
    -- Pack 5 columns into a single number matching hotkey format
    -- Use bit shifts instead of exponentiation to keep values as integers
    local bits = 0
    for col = 1, 5 do
        local col_byte = math.floor(matrix[col] or 0)
        bits = bits | (col_byte << ((col - 1) * 7))
    end
    return bits
end

function StatusBar.check_hotkeys()
    -- Skip if current screen has disabled the app menu
    local current = _G.ScreenManager and _G.ScreenManager.peek()
    local menu_disabled = current and current.disable_app_menu

    local now = tdeck.system.millis()
    if now - StatusBar.menu_last_check < StatusBar.menu_check_interval then
        return
    end
    StatusBar.menu_last_check = now

    -- Load hotkey configurations
    StatusBar.load_hotkey()
    StatusBar.load_screenshot_hotkey()

    local prev_mode = tdeck.keyboard.get_mode()
    if not tdeck.keyboard.set_mode("raw") then
        return
    end

    local matrix = tdeck.keyboard.read_raw_matrix()
    if not matrix then
        tdeck.keyboard.set_mode(prev_mode)
        return
    end

    -- Get current matrix bits
    local current_bits = StatusBar.get_matrix_bits(matrix)

    tdeck.keyboard.set_mode(prev_mode)

    -- Check menu hotkey (unless disabled by current screen)
    if not menu_disabled then
        local menu_pressed = (current_bits & StatusBar.menu_hotkey) == StatusBar.menu_hotkey
        if menu_pressed and StatusBar.menu_hotkey > 0 then
            if not StatusBar.menu_triggered then
                StatusBar.menu_triggered = true
                if _G.AppMenu then
                    _G.AppMenu.show()
                end
            end
        else
            StatusBar.menu_triggered = false
        end
    end

    -- Check screenshot hotkey
    local screenshot_pressed = (current_bits & StatusBar.screenshot_hotkey) == StatusBar.screenshot_hotkey
    if screenshot_pressed and StatusBar.screenshot_hotkey > 0 then
        if not StatusBar.screenshot_triggered then
            StatusBar.screenshot_triggered = true
            StatusBar.take_screenshot()
        end
    else
        StatusBar.screenshot_triggered = false
    end
end

-- Alias for backward compatibility
function StatusBar.check_menu_trigger()
    StatusBar.check_hotkeys()
end

function StatusBar.update()
    StatusBar.update_memory()
    StatusBar.check_menu_trigger()
end

function StatusBar.register()
    if Overlays then
        Overlays.register("status_bar", StatusBar.render, 100)
    end
    if _G.MainLoop then
        _G.MainLoop.on_update("status_bar", StatusBar.update)
    end
    StatusBar.update_memory()
end

function StatusBar.unregister()
    if Overlays then Overlays.unregister("status_bar") end
    if _G.MainLoop then _G.MainLoop.off_update("status_bar") end
end

function StatusBar.enable()
    if Overlays then Overlays.enable("status_bar") end
end

function StatusBar.disable()
    if Overlays then Overlays.disable("status_bar") end
end

function StatusBar.is_menu_active() return false end
function StatusBar.handle_menu_key(key) return false end

return StatusBar
