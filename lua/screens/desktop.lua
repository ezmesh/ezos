-- Desktop home screen
-- Wallpaper, icon dock, and carbon taskbar.

local theme = require("ezui.theme")
local node  = require("ezui.node")
local focus = require("ezui.focus")
local text  = require("ezui.text")
local icons = require("ezui.icons")

local Desktop = { title = "Desktop" }

-- Screen geometry
local W, H = 320, 240
local TASKBAR_H = 24
local ICON_SIZE = 48       -- Native 48px icons (no scaling)
local COLS = 4
local ICON_GAP_X = 16

-- Available wallpaper files (on LittleFS at /fs/wallpapers/NAME.jpg)
local wallpaper_names = {
    "synthwave", "aurora", "eclipse", "astronaut",
    "lowpoly", "bonsai", "jellyfish", "stormclouds",
    "wp01", "wp02", "wp03", "wp04", "wp05", "wp06", "wp07", "wp08",
    "wp09", "wp10", "wp11", "wp12", "wp13", "wp14", "wp15", "wp16",
    "wp17", "wp18", "wp19", "wp20", "wp21", "wp22", "wp23", "wp24",
    "wp25", "wp26", "wp27", "wp28", "wp29", "wp30",
}
local wallpaper_data = nil
local wallpaper_index = 1

local gradient_bands = nil

local function build_gradient()
    if gradient_bands then return end
    gradient_bands = {}
    local band_h = 4
    local bands = math.ceil(H / band_h)
    for i = 0, bands - 1 do
        local t = i / (bands - 1)
        local v = math.floor(40 * (1 - t) + 8 * t)
        gradient_bands[i + 1] = {
            y = i * band_h,
            h = band_h,
            color = ez.display.rgb(v, v, v + 5),
        }
    end
end

local function load_wallpaper(name)
    local path = "/fs/wallpapers/" .. name .. ".jpg"
    spawn(function()
        local data = async_read(path)
        if data and #data > 0 then
            wallpaper_data = data
            ez.log("[Desktop] Wallpaper loaded: " .. name .. " (" .. #data .. " bytes)")
            local screen_mod = require("ezui.screen")
            screen_mod.invalidate()
        else
            ez.log("[Desktop] Wallpaper not found: " .. path)
        end
    end)
end

-- Load wallpaper from an arbitrary file path (set by file manager)
local function load_wallpaper_path(full_path)
    spawn(function()
        local data = async_read(full_path)
        if data and #data > 0 then
            wallpaper_data = data
            ez.log("[Desktop] Custom wallpaper: " .. full_path .. " (" .. #data .. " bytes)")
            local screen_mod = require("ezui.screen")
            screen_mod.invalidate()
        else
            ez.log("[Desktop] Custom wallpaper not found: " .. full_path)
        end
    end)
end

-- Icon definitions: 4 desktop shortcuts
local icon_defs = {
    { label = "Messages", icon = icons.mail,    screen = "$screens/messages.lua" },
    { label = "Contacts", icon = icons.users,   mod = "screens.contacts" },
    { label = "Map",      icon = icons.globe,   mod = "screens.map" },
    { label = "More",     icon = icons.more_horiz, screen = "$screens/menu.lua" },
}

-- Track the currently focused icon label for the taskbar
local focused_label = icon_defs[1].label

-- Register desktop-specific node types

node.register("wallpaper", {
    measure = function(n, max_w, max_h)
        return max_w, max_h
    end,
    draw = function(n, d, x, y, w, h)
        if wallpaper_data then
            d.draw_jpeg(x, y, wallpaper_data)
        else
            build_gradient()
            for _, band in ipairs(gradient_bands) do
                d.fill_rect(x, y + band.y, w, band.h, band.color)
            end
        end
    end,
})

node.register("desktop_icon", {
    focusable = true,

    measure = function(n, max_w, max_h)
        local slot_w = math.floor((W - ICON_GAP_X * (COLS + 1)) / COLS)
        theme.set_font("tiny")
        local label_h = theme.font_height()
        return slot_w, ICON_SIZE + label_h + 4
    end,

    draw = function(n, d, x, y, w, h)
        local focused = n._focused
        local cx = x + math.floor(w / 2)

        -- Update tracked label when this icon is focused
        if focused then
            focused_label = n.label or ""
        end

        -- Measure label to size the highlight
        theme.set_font("tiny")
        local label = n.label or ""
        local lw = theme.text_width(label)
        local label_h = theme.font_height()

        -- Highlight width: at least as wide as label + padding
        local highlight_w = math.max(w - 4, lw + 8)
        local highlight_x = cx - math.floor(highlight_w / 2)

        -- Focus: frosted highlight behind icon and label
        if focused then
            d.fill_round_rect(highlight_x, y, highlight_w, h, 6, ez.display.rgb(60, 60, 70))
            d.draw_round_rect(highlight_x, y, highlight_w, h, 6, ez.display.rgb(120, 120, 135))
        end

        -- Draw 48px PNG icon centered in slot
        local png = n.icon and n.icon.lg
        if png then
            local icon_w, icon_h = 48, 48
            local ix = cx - math.floor(icon_w / 2)
            local iy = y + 2
            d.draw_png(ix, iy, png)
        end

        -- Label below icon
        local lx = cx - math.floor(lw / 2)
        local ly = y + ICON_SIZE + 3
        local label_color = ez.display.rgb(220, 220, 230)
        if not focused then
            d.draw_text(lx + 1, ly + 1, label, ez.display.rgb(0, 0, 0))
        end
        d.draw_text(lx, ly, label, label_color)
    end,

    on_activate = function(n, key)
        if n.on_press then n.on_press() end
        return "handled"
    end,

    on_key = function(n, key)
        if key.special == "LEFT" then
            focus.prev()
            return "handled"
        elseif key.special == "RIGHT" then
            focus.next()
            return "handled"
        end
        if key.special == "UP" or key.special == "DOWN" then
            return "handled"
        end
        return nil
    end,
})

node.register("taskbar", {
    measure = function(n, max_w, max_h)
        return max_w, TASKBAR_H
    end,

    draw = function(n, d, x, y, w, h)
        local bands = 4
        local bh = math.ceil(h / bands)
        for i = 0, bands - 1 do
            local t = i / (bands - 1)
            local v = math.floor(20 + 25 * (1 - t))
            d.fill_rect(x, y + i * bh, w, bh, ez.display.rgb(v, v, v + 2))
        end
        d.draw_hline(x, y, w, ez.display.rgb(80, 80, 85))

        theme.set_font("small")
        local fh = theme.font_height()
        local ty = y + math.floor((h - fh) / 2)
        local text_color = ez.display.rgb(200, 200, 205)

        local shadow = ez.display.rgb(0, 0, 0)

        -- Left: focused icon label
        if focused_label and focused_label ~= "" then
            d.draw_text(x + 7, ty + 1, focused_label, shadow)
            d.draw_text(x + 6, ty, focused_label, ez.display.rgb(255, 255, 255))
        end

        -- Right side: time, date, battery
        local rx = x + w - 4
        if n.battery then
            local bat_str = n.battery .. "%"
            rx = rx - theme.text_width(bat_str)
            d.draw_text(rx + 1, ty + 1, bat_str, shadow)
            d.draw_text(rx, ty, bat_str, text_color)
            rx = rx - 8
        end
        if n.date and n.date ~= "" then
            local dw = theme.text_width(n.date)
            rx = rx - dw
            d.draw_text(rx + 1, ty + 1, n.date, shadow)
            d.draw_text(rx, ty, n.date, text_color)
            rx = rx - 10
        end
        if n.time and n.time ~= "" then
            theme.set_font("medium")
            local tw = theme.text_width(n.time)
            rx = rx - tw
            local time_y = y + math.floor((h - theme.font_height()) / 2)
            d.draw_text(rx + 1, time_y + 1, n.time, shadow)
            d.draw_text(rx, time_y, n.time, ez.display.rgb(255, 255, 255))
        end
    end,
})

-- ---------------------------------------------------------------------------
-- Desktop screen definition
-- ---------------------------------------------------------------------------

function Desktop:build(state)
    local row_icons = {}
    for _, def in ipairs(icon_defs) do
        row_icons[#row_icons + 1] = {
            type = "desktop_icon",
            label = def.label,
            icon = def.icon,
            on_press = function()
                ez.log("[Desktop] " .. def.label)
                if def.mod then
                    local screen_mod = require("ezui.screen")
                    local ScreenDef = require(def.mod)
                    local inst = screen_mod.create(ScreenDef, {})
                    screen_mod.push(inst)
                elseif def.screen then
                    local ui = require("ezui")
                    ui.push_screen(def.screen)
                end
            end,
        }
    end

    return {
        type = "zstack",
        children = {
            { type = "wallpaper" },

            -- Icons bottom-aligned above taskbar
            {
                type = "vbox", gap = 0, children = {
                    { type = "spacer", grow = 1 },
                    {
                        type = "hbox",
                        gap = ICON_GAP_X,
                        padding = { 0, ICON_GAP_X, 0, ICON_GAP_X },
                        children = row_icons,
                    },
                    { type = "spacer", h = TASKBAR_H + 6, grow = 0 },
                },
            },

            -- Taskbar at bottom
            {
                type = "vbox", gap = 0, children = {
                    { type = "spacer", grow = 1 },
                    {
                        type = "taskbar",
                        time = state.time or "",
                        date = state.date or "",
                        battery = state.battery,
                        node_id = state.node_id,
                    },
                },
            },
        },
    }
end

function Desktop:on_enter()
    local time_str = ""
    local date_str = ""
    if ez.system.get_time then
        local t = ez.system.get_time()
        if t and t.hour then
            time_str = string.format("%02d:%02d", t.hour, t.min)
        end
        if t and t.year and t.year > 2024 then
            date_str = string.format("%02d/%02d/%d", t.mday or 0, t.mon or 0, t.year)
        end
    end

    self:set_state({
        node_id = ez.mesh.is_initialized() and ez.mesh.get_short_id() or nil,
        battery = ez.system.get_battery_percent(),
        time = time_str,
        date = date_str,
    })

    if not wallpaper_data then
        -- Check for custom wallpaper path set by file manager
        local custom = ez.storage.get_pref("wallpaper_path", "")
        if custom and #custom > 0 then
            load_wallpaper_path(custom)
        else
            local saved = ez.storage.get_pref("wallpaper", wallpaper_names[1])
            for i, name in ipairs(wallpaper_names) do
                if name == saved then wallpaper_index = i break end
            end
            load_wallpaper(wallpaper_names[wallpaper_index])
        end
    end

    if not self._timer then
        self._timer = ez.system.set_interval(30000, function()
            if ez.system.get_time then
                local t = ez.system.get_time()
                if t and t.hour then
                    local ts = string.format("%02d:%02d", t.hour, t.min)
                    local ds = ""
                    if t.year and t.year > 2024 then
                        ds = string.format("%02d/%02d/%d", t.mday or 0, t.mon or 0, t.year)
                    end
                    self:set_state({
                        time = ts,
                        date = ds,
                        battery = ez.system.get_battery_percent(),
                    })
                end
            end
        end)
    end
end

function Desktop:on_leave()
    if self._timer then
        ez.system.cancel_timer(self._timer)
        self._timer = nil
    end
end

function Desktop:on_exit()
    if self._timer then
        ez.system.cancel_timer(self._timer)
        self._timer = nil
    end
end

function Desktop:handle_key(key)
    if key.special == "TAB" or key.character == "m" then
        local ui = require("ezui")
        ui.push_screen("$screens/menu.lua")
        return "handled"
    end
    if key.character == "w" then
        wallpaper_index = wallpaper_index % #wallpaper_names + 1
        local name = wallpaper_names[wallpaper_index]
        ez.storage.set_pref("wallpaper", name)
        ez.storage.set_pref("wallpaper_path", "")  -- clear custom path
        load_wallpaper(name)
        return "handled"
    end
    return nil
end

return Desktop
