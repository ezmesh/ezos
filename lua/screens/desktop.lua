-- Desktop home screen
-- Wallpaper, icon dock, and carbon taskbar.

local theme   = require("ezui.theme")
local node    = require("ezui.node")
local focus   = require("ezui.focus")
local text    = require("ezui.text")
local icons   = require("ezui.icons")
local shadows = require("ezui.shadows")

local Desktop = { title = "Desktop" }

-- Screen geometry
local W, H = 320, 240
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
    { label = "Messages", icon = icons.mail,    screen = "$screens/chat/messages.lua" },
    { label = "Contacts", icon = icons.users,   mod = "screens.chat.contacts" },
    { label = "Map",      icon = icons.globe,   mod = "screens.tools.map" },
    { label = "More",     icon = icons.more_horiz, screen = "$screens/menu.lua" },
}

-- Register desktop-specific node types

node.register("wallpaper", {
    measure = function(n, max_w, max_h)
        return max_w, max_h
    end,
    draw = function(n, d, x, y, w, h)
        -- Wallpapers are authored at the full 320x240 panel size. The
        -- desktop sits under the global status bar, so the zstack would
        -- otherwise allocate the reduced content area and clip the image.
        -- Draw edge-to-edge; the opaque status bar covers the top strip.
        if wallpaper_data then
            d.draw_jpeg(0, 0, wallpaper_data)
        else
            build_gradient()
            for _, band in ipairs(gradient_bands) do
                d.fill_rect(0, band.y, theme.SCREEN_W, band.h, band.color)
            end
        end

        -- Soft fade over the bottom strip where the icon labels sit so
        -- bright wallpapers don't wash out the text.
        local fade_h = shadows.STRIP_SHORT
        shadows.draw_horizontal(d, shadows.bottom,
            0, theme.SCREEN_H - fade_h, theme.SCREEN_W)
    end,
})

node.register("desktop_icon", {
    focusable = true,

    measure = function(n, max_w, max_h)
        local slot_w = math.floor((W - ICON_GAP_X * (COLS + 1)) / COLS)
        theme.set_font("medium_aa")
        local label_h = theme.font_height()
        return slot_w, ICON_SIZE + label_h + 4
    end,

    draw = function(n, d, x, y, w, h)
        local focused = n._focused
        local cx = x + math.floor(w / 2)

        theme.set_font("medium_aa")
        local label = n.label or ""
        local lw = theme.text_width(label)

        -- Render the icon as layers (bottom to top):
        --   0. Pre-blurred white halo, drawn only when focused so the
        --      plate appears to glow off the wallpaper.
        --   1. Rounded-rect plate in the icon's accent colour, brightened
        --      slightly on focus for a "lit up" effect.
        --   2. White glyph PNG centred on the plate.
        --   3. Shared glass shim (gradient + highlight + border).
        local png = n.icon and n.icon.lg
        if png then
            local icon_w = 48
            local ix = cx - math.floor(icon_w / 2)
            local iy = y + 2

            if focused and icons._glow then
                local pad = icons._glow_pad or 8
                d.draw_png(ix - pad, iy - pad, icons._glow)
            end

            local inset  = icons._plate_inset or 4
            local radius = icons._plate_radius or 8
            local pw     = icons._plate_size or (icon_w - 2 * inset)
            local color  = n.icon.color or ez.display.rgb(80, 80, 90)
            if focused then
                -- Medium-paced pulse (~1.4 s period) by brightening the
                -- plate with a sine-wave factor between roughly 1.15 and
                -- 1.5. screen.invalidate() below keeps the next frame
                -- scheduled so the pulse actually advances.
                local t = ez.system.millis() / 1000.0
                local pulse = 1.32 + 0.18 * math.sin(t * 2 * math.pi / 1.4)
                if theme.brighten_rgb565 then
                    color = theme.brighten_rgb565(color, pulse)
                end
                local screen_mod = require("ezui.screen")
                screen_mod.invalidate()
            end
            d.fill_round_rect(ix + inset, iy + inset, pw, pw, radius, color)

            d.draw_png(ix, iy, png)

            if icons._shim then
                d.draw_png(ix, iy, icons._shim)
            end
        end

        -- Label: static colour with a 1px black shadow for legibility over
        -- bright wallpapers. Selection is communicated by the glow + plate
        -- brightening above, so the text stays the same in both states.
        local lx = cx - math.floor(lw / 2)
        local ly = y + ICON_SIZE + 3
        d.draw_text(lx + 1, ly + 1, label, ez.display.rgb(0, 0, 0))
        d.draw_text(lx, ly, label, ez.display.rgb(230, 230, 235))
    end,

    on_activate = function(n, key)
        local ok, ui_sounds = pcall(require, "services.ui_sounds")
        if ok then ui_sounds.play("button") end
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

            -- Icons anchored near the bottom of the wallpaper, with the
            -- global status bar taking the top strip.
            {
                type = "vbox", gap = 0, children = {
                    { type = "spacer", grow = 1 },
                    {
                        type = "hbox",
                        gap = ICON_GAP_X,
                        padding = { 0, ICON_GAP_X, 0, ICON_GAP_X },
                        children = row_icons,
                    },
                    { type = "spacer", h = 12, grow = 0 },
                },
            },
        },
    }
end

function Desktop:on_enter()
    -- Time, battery, and node id are now polled by the global status bar, so
    -- this screen no longer needs its own periodic state update.
    if not wallpaper_data then
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
end

-- Debounce character hotkeys. The T-Deck keyboard re-emits held keycodes
-- every ~60ms (no release events for character keys), so a single tap fires
-- multiple events. Swallow any repeat within the cooldown window.
local CHAR_KEY_COOLDOWN_MS = 400
local last_char_key = nil
local last_char_time = 0

local function char_key_debounced(ch)
    local now = ez.system.millis()
    if ch == last_char_key and now - last_char_time < CHAR_KEY_COOLDOWN_MS then
        return true
    end
    last_char_key = ch
    last_char_time = now
    return false
end

function Desktop:handle_key(key)
    if key.special == "TAB" or key.character == "m" then
        local ui = require("ezui")
        ui.push_screen("$screens/menu.lua")
        return "handled"
    end
    if key.character == "w" then
        if char_key_debounced("w") then return "handled" end
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
