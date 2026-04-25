-- Desktop home screen
-- Wallpaper, icon dock, and carbon taskbar.

local theme   = require("ezui.theme")
local node    = require("ezui.node")
local focus   = require("ezui.focus")
local text    = require("ezui.text")
local icons   = require("ezui.icons")
local shadows = require("ezui.shadows")

-- transparent_status: the desktop draws the wallpaper edge-to-edge, so
-- let the global status bar blend into it via a dithered background
-- instead of the opaque black strip used elsewhere.
local Desktop = { title = "Desktop", transparent_status = true }

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
    "wp31", "wp32", "wp33", "wp34", "wp35", "wp36", "wp37", "wp38",
    "wp39",
}
-- Wallpaper draw path:
--   wallpaper_raw  — 320×240 RGB565 blob in LGFX byte-order, blitted via
--                    d.draw_bitmap (~3 ms per frame). Preferred.
--   wallpaper_data — JPEG bytes, decoded via d.draw_jpeg (~55 ms per
--                    frame). Fallback, only hit on a cache miss.
-- The raw blob is generated on first load by decoding the JPEG into an
-- off-screen sprite and copying its pixel buffer out, then cached under
-- /fs/cache/wallpapers/<name>.rgb565 so subsequent boots skip the
-- decode entirely.
local CACHE_DIR = "/fs/cache/wallpapers"
local wallpaper_raw = nil
local wallpaper_data = nil
local wallpaper_index = 1

-- Runtime pan/tile/rotate state. Read from prefs in on_enter; re-read
-- on every reactivate so the settings screen's changes take effect
-- without having to reboot.
local wp_tile_x    = false
local wp_tile_y    = false
local wp_pan       = "none"
local wp_pan_speed = 3

-- Wander mode: we pick a random target offset every few seconds and
-- ease toward it. These are in wallpaper-pixel space.
local wander_from_x, wander_from_y = 0, 0
local wander_to_x,   wander_to_y   = 0, 0
local wander_t0                    = 0
local wander_dur                   = 6000  -- ms between random hops

-- Bools come back as integer 0/1 from NVS (Preferences stores bool as
-- U8). Lua considers 0 truthy, so `v and true or false` is a bug waiting
-- to happen — always compare to 0 explicitly.
local function pref_bool(key, default)
    local v = ez.storage.get_pref(key, default)
    if type(v) == "number" then return v ~= 0 end
    if type(v) == "boolean" then return v end
    return default and true or false
end

local function refresh_wallpaper_prefs()
    wp_tile_x    = pref_bool("wp_tile_x", false)
    wp_tile_y    = pref_bool("wp_tile_y", false)
    wp_pan       = ez.storage.get_pref("wp_pan", "none")
    wp_pan_speed = tonumber(ez.storage.get_pref("wp_pan_speed", 3)) or 3
end

-- Pan offset (in wallpaper-space) for the current animation mode and
-- time. Returned values are the amount the wallpaper is SHIFTED by;
-- the renderer draws the image at (-ox, -oy) plus wrap copies.
local function compute_pan_offset()
    local t_ms = ez.system.millis()
    -- Speed factor: slow (1) = wide, slow motion; fast (10) = tight,
    -- quick motion. Scale the period inversely to speed.
    local speed = math.max(1, math.min(10, wp_pan_speed))
    local W_, H_ = theme.SCREEN_W, theme.SCREEN_H

    if wp_pan == "bounce_x" then
        -- Ease back and forth across the full wallpaper width. Using a
        -- sine keeps the reversal smooth instead of snapping.
        local period = 12000 / speed
        local t = (t_ms % period) / period
        local ox = math.floor((math.sin(t * 2 * math.pi) * 0.5 + 0.5) * W_)
        return ox, 0
    elseif wp_pan == "bounce_y" then
        local period = 12000 / speed
        local t = (t_ms % period) / period
        local oy = math.floor((math.sin(t * 2 * math.pi) * 0.5 + 0.5) * H_)
        return 0, oy
    elseif wp_pan == "drift_x" then
        -- Constant one-way scroll; wrap via modulo in the draw code.
        local period = 16000 / speed
        local ox = math.floor((t_ms % period) / period * W_)
        return ox, 0
    elseif wp_pan == "drift_y" then
        local period = 16000 / speed
        local oy = math.floor((t_ms % period) / period * H_)
        return 0, oy
    elseif wp_pan == "wander" then
        local dur = math.max(1500, math.floor(wander_dur / speed * 3))
        if wander_t0 == 0 or (t_ms - wander_t0) > dur then
            wander_from_x, wander_from_y = wander_to_x, wander_to_y
            wander_to_x = math.random(0, W_ - 1)
            wander_to_y = math.random(0, H_ - 1)
            wander_t0 = t_ms
        end
        local tt = math.max(0, math.min(1, (t_ms - wander_t0) / dur))
        -- Smooth-step easing so the random jumps don't look jerky.
        local e = tt * tt * (3 - 2 * tt)
        local ox = math.floor(wander_from_x + (wander_to_x - wander_from_x) * e)
        local oy = math.floor(wander_from_y + (wander_to_y - wander_from_y) * e)
        return ox, oy
    end
    return 0, 0
end

-- Clamp the offset when tiling is disabled so we don't reveal empty
-- strips. Without tiling, pan simply does nothing on the locked axis.
local function effective_offset(ox, oy)
    if not wp_tile_x then ox = 0 end
    if not wp_tile_y then oy = 0 end
    return ox, oy
end

local function cache_path_for(name_or_path)
    -- Strip directory + extension to get a stable cache key.
    local stem = name_or_path:match("([^/]+)%.[^/]+$") or name_or_path
    return CACHE_DIR .. "/" .. stem .. ".rgb565"
end

local function decode_jpeg_to_raw(jpeg_data)
    local sp = ez.display.create_sprite(theme.SCREEN_W, theme.SCREEN_H)
    if not sp then return nil end
    local ok = sp:draw_jpeg(0, 0, jpeg_data)
    if not ok then sp:destroy(); return nil end
    local raw = sp:get_raw()
    sp:destroy()
    return raw
end

local gradient_bands = nil

-- Pulse highlight: a single cached white round-rect sprite that gets
-- pushed on top of the plate with variable alpha. The display supports
-- true per-pixel alpha blending on sprites (see display.create_sprite),
-- so this is real opacity — not a dither approximation.
local pulse_sprite = nil
local pulse_sprite_key = nil  -- "<pw>x<radius>" so we rebuild on geometry change
local TRANSPARENT_MAGENTA = 0xF81F

local function ensure_pulse_sprite(pw, radius)
    local key = pw .. "x" .. radius
    if pulse_sprite and pulse_sprite_key == key then return pulse_sprite end
    if pulse_sprite and pulse_sprite.destroy then
        pulse_sprite:destroy()
    end
    local size = pw + 4  -- +2px halo margin on each side
    local s = ez.display.create_sprite(size, size)
    if not s then return nil end
    s:set_transparent_color(TRANSPARENT_MAGENTA)
    s:clear(TRANSPARENT_MAGENTA)
    s:fill_round_rect(2, 2, pw, pw, radius, ez.display.rgb(255, 255, 255))
    pulse_sprite = s
    pulse_sprite_key = key
    return s
end

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

local function finish_load(jpeg_path, cache_path, jpeg_bytes)
    -- Cache miss: decode the JPEG into a sprite, save the raw buffer
    -- for next time, then switch the draw path to the raw blit.
    local raw = decode_jpeg_to_raw(jpeg_bytes)
    if raw then
        wallpaper_raw = raw
        wallpaper_data = nil
        -- write_file requires the parent directory to exist. mkdir is
        -- idempotent so it's safe to call on every miss.
        ez.storage.mkdir("/fs/cache")
        ez.storage.mkdir(CACHE_DIR)
        ez.storage.write_file(cache_path, raw)
        ez.log("[Desktop] Cached " .. cache_path .. " (" .. #raw .. " bytes)")
    else
        -- Sprite alloc or decode failed — fall back to per-frame JPEG decode.
        wallpaper_raw = nil
        wallpaper_data = jpeg_bytes
        ez.log("[Desktop] Raw cache unavailable, using JPEG decode path")
    end
    local screen_mod = require("ezui.screen")
    screen_mod.invalidate()
end

local function load_from(jpeg_path)
    -- Stamp the pending pref *before* the async read starts. If the JPEG
    -- decoder or sprite allocator crashes the device (native code, so
    -- pcall can't catch it), the next boot sees this stamp and reverts
    -- the wallpaper to the first built-in — otherwise we'd crash on the
    -- same file every boot and the desktop would look like a bootloop.
    ez.storage.set_pref("wp_load_pending", jpeg_path)

    local async = require("ezui.async")
    async.task(function()
        local cache_path = cache_path_for(jpeg_path)

        -- Fast path: use the cached raw blob if its size matches the
        -- panel. A short/corrupt file falls through to the decode path.
        local cached = async_read(cache_path)
        if cached and #cached == theme.SCREEN_W * theme.SCREEN_H * 2 then
            wallpaper_raw = cached
            wallpaper_data = nil
            ez.log("[Desktop] Raw wallpaper hit: " .. cache_path .. " (" .. #cached .. " bytes)")
            ez.storage.set_pref("wp_load_pending", "")
            local screen_mod = require("ezui.screen")
            screen_mod.invalidate()
            return
        end

        -- Slow path: decode JPEG once, cache the raw output.
        local data = async_read(jpeg_path)
        if data and #data > 0 then
            finish_load(jpeg_path, cache_path, data)
        else
            ez.log("[Desktop] Wallpaper not found: " .. jpeg_path)
        end
        -- Clear the pending stamp once control returns here — either the
        -- raw cache was written successfully, or the decode silently fell
        -- back to the per-frame JPEG path. In both cases the process
        -- survived, so the stamp no longer means "last load crashed".
        ez.storage.set_pref("wp_load_pending", "")
    end)
end

local function load_wallpaper(name)
    load_from("/fs/wallpapers/" .. name .. ".jpg")
end

-- Load wallpaper from an arbitrary file path (set by file manager)
local function load_wallpaper_path(full_path)
    load_from(full_path)
end

-- Icon definitions: 4 desktop shortcuts
local icon_defs = {
    { label = "Messages", icon = icons.mail,    screen = "$screens/chat/messages.lua" },
    { label = "Contacts", icon = icons.users,   mod = "screens.chat.contacts" },
    { label = "Map",      icon = icons.globe,   mod = "screens.tools.map_loader" },
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
        if wallpaper_raw then
            local W_, H_ = theme.SCREEN_W, theme.SCREEN_H
            local ox, oy = effective_offset(compute_pan_offset())

            if ox == 0 and oy == 0 then
                -- Fast path: no pan, single blit.
                d.draw_bitmap(0, 0, W_, H_, wallpaper_raw)
            else
                -- Draw the wallpaper at (-ox, -oy) and, when tiling on
                -- an axis is active, an extra copy shifted by one full
                -- wallpaper width/height so the wrapped pixels cover
                -- what would otherwise be a blank strip. LGFX clips any
                -- draw that falls off-screen. Up to 4 blits per frame
                -- at ~3 ms each = ~12 ms for full 2D pan + wrap.
                d.draw_bitmap(-ox, -oy, W_, H_, wallpaper_raw)
                if wp_tile_x and ox ~= 0 then
                    d.draw_bitmap(W_ - ox, -oy, W_, H_, wallpaper_raw)
                end
                if wp_tile_y and oy ~= 0 then
                    d.draw_bitmap(-ox, H_ - oy, W_, H_, wallpaper_raw)
                end
                if wp_tile_x and wp_tile_y and ox ~= 0 and oy ~= 0 then
                    d.draw_bitmap(W_ - ox, H_ - oy, W_, H_, wallpaper_raw)
                end
            end

            -- Panning modes animate continuously; request the next frame.
            if wp_pan ~= "none" and (wp_tile_x or wp_tile_y) then
                local screen_mod = require("ezui.screen")
                screen_mod.invalidate()
            end
        elseif wallpaper_data then
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

        -- Matching top shadow that sits under the translucent status bar.
        -- Drawn here (inside the wallpaper node) so it paints before the
        -- global status bar renders over it — darkens the wallpaper
        -- behind the bar so the node ID / clock stay legible without
        -- making the bar itself fully opaque.
        shadows.draw_horizontal(d, shadows.top, 0, 0, theme.SCREEN_W)
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

            local inset  = icons._plate_inset or 4
            local radius = icons._plate_radius or 8
            local pw     = icons._plate_size or (icon_w - 2 * inset)
            local color  = n.icon.color or ez.display.rgb(80, 80, 90)

            -- Compute the pulse phase once so the outer glow, the
            -- plate colour, and the optional halo all breathe in
            -- sync. Period ~1.4 s; phase goes -1..+1.
            local phase = 0
            if focused then
                local t = ez.system.millis() / 1000.0
                phase = math.sin(t * 2 * math.pi / 1.4)
                local screen_mod = require("ezui.screen")
                screen_mod.invalidate()
            end

            -- Pre-blurred static halo — cheap to draw, adds depth.
            if focused and icons._glow then
                local pad = icons._glow_pad or 8
                d.draw_png(ix - pad, iy - pad, icons._glow)
            end

            -- Plate: resting color only; the pulse rides on top as a
            -- true alpha-blended white highlight (see below).
            d.fill_round_rect(ix + inset - 1, iy + inset - 1,
                              pw + 2, pw + 2, radius + 1, color)

            -- Pulse overlay: a cached white round-rect sprite pushed on
            -- top of the plate with variable alpha. Alpha tracks the
            -- sine phase (0..1 on the bright half, clamped on the dim
            -- half) so the icon breathes via real per-pixel opacity.
            if focused then
                local pulse_hi = math.max(phase, 0)
                if pulse_hi > 0.02 then
                    local hi = ensure_pulse_sprite(pw, radius)
                    if hi then
                        local alpha = math.floor(70 * pulse_hi)
                        hi:push(ix + inset - 2, iy + inset - 2, alpha)
                    end
                end
            end

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

-- Flips true after the first rotate-on-boot has fired this session, so
-- subsequent Desktop:on_enter calls within the same boot don't cycle
-- the wallpaper repeatedly when the user is in "boot" rotate mode.
local rotated_this_boot = false

-- Cycle forward through the built-in name list. If the active
-- wallpaper is a custom path (not in the list) we fall back to the
-- first named entry.
local function advance_wallpaper_name()
    local current = ez.storage.get_pref("wallpaper", wallpaper_names[1])
    local idx = 0
    for i, name in ipairs(wallpaper_names) do
        if name == current then idx = i break end
    end
    idx = (idx % #wallpaper_names) + 1
    local next_name = wallpaper_names[idx]
    ez.storage.set_pref("wallpaper", next_name)
    ez.storage.set_pref("wallpaper_path", "")  -- drop custom override
    wallpaper_index = idx
    return next_name
end

function Desktop:on_enter()
    -- Time, battery, and node id are now polled by the global status bar, so
    -- this screen no longer needs its own periodic state update.
    refresh_wallpaper_prefs()

    -- Bootloop guard: if the last wallpaper load didn't clear its pending
    -- stamp (i.e. the device crashed mid-decode and rebooted), force the
    -- configured wallpaper back to the first built-in so we don't crash
    -- on the same file forever.
    local pending = ez.storage.get_pref("wp_load_pending", "")
    if pending and pending ~= "" then
        ez.log("[Desktop] Previous wallpaper load did not complete (" ..
               pending .. ") — reverting to " .. wallpaper_names[1])
        ez.storage.set_pref("wallpaper",      wallpaper_names[1])
        ez.storage.set_pref("wallpaper_path", "")
        ez.storage.set_pref("wp_load_pending", "")
        wallpaper_index = 1
    end

    -- Event-based auto-rotate. No wall-clock dependency, since the
    -- device often boots without one:
    --   "boot"  — advance once on the first desktop show of this boot.
    --   "shown" — advance every time the desktop becomes active
    --             (including returning from a sub-screen).
    --   "off"   — keep the current wallpaper.
    local rotate_mode = ez.storage.get_pref("wp_rotate", "off")
    local should_rotate = false
    if rotate_mode == "shown" then
        should_rotate = true
    elseif rotate_mode == "boot" and not rotated_this_boot then
        should_rotate = true
    end
    if should_rotate then
        rotated_this_boot = true
        local name = advance_wallpaper_name()
        load_wallpaper(name)
        return
    end

    if not wallpaper_raw and not wallpaper_data then
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
