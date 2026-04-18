-- Image Viewer: pan and zoom a JPEG/PNG from storage.
-- Arrows pan, z/x zoom in/out, r resets, q/ESC quits.

local ui = require("ezui")
local theme = require("ezui.theme")
local node_mod = require("ezui.node")
local screen_mod = require("ezui.screen")

local Viewer = { title = "View" }

-- Screen dimensions
local SW, SH = 320, 240
local VIEW_TOP = 18  -- leave room for title bar

-- Per-instance state lives on the instance; these locals are just used by the
-- custom node for the currently-active viewer.
local active_data, active_state

if not node_mod.handler("image_canvas") then
    node_mod.register("image_canvas", {
        measure = function(n, mw, mh) return mw, mh end,

        draw = function(n, d, x, y, w, h)
            d.fill_rect(x, y, w, h, 0)
            if not active_data then
                theme.set_font("medium")
                local msg = active_state and active_state.error or "Loading..."
                local tw = theme.text_width(msg)
                d.draw_text(x + math.floor((w - tw) / 2),
                            y + math.floor(h / 2) - 6,
                            msg, theme.color("TEXT_MUTED"))
                return
            end

            local s = active_state
            local iw, ih = s.img_w or 0, s.img_h or 0
            local scale = s.scale
            -- Top-left corner of image on screen (after pan)
            local img_sw = math.floor(iw * scale)
            local img_sh = math.floor(ih * scale)
            -- Center when image smaller than viewport; otherwise allow pan
            local draw_x, draw_y
            if img_sw <= w then
                draw_x = x + math.floor((w - img_sw) / 2)
            else
                draw_x = x + s.pan_x
            end
            if img_sh <= h then
                draw_y = y + math.floor((h - img_sh) / 2)
            else
                draw_y = y + s.pan_y
            end

            d.set_clip_rect(x, y, w, h)
            if s.is_png then
                d.draw_png(draw_x, draw_y, active_data, scale, scale)
            else
                d.draw_jpeg(draw_x, draw_y, active_data, scale, scale)
            end
            d.clear_clip_rect()

            -- HUD: zoom % and pan hint
            theme.set_font("small")
            local hud = string.format("%d%%", math.floor(scale * 100))
            local pad = 3
            local tw = theme.text_width(hud)
            d.fill_rect(x + 4, y + h - theme.font_height() - pad * 2 - 4,
                        tw + pad * 2,
                        theme.font_height() + pad * 2,
                        theme.color("SURFACE"))
            d.draw_text(x + 4 + pad,
                        y + h - theme.font_height() - pad - 4,
                        hud, theme.color("TEXT"))
        end,
    })
end

function Viewer.initial_state(path)
    return {
        path     = path,
        data     = nil,
        is_png   = path and path:lower():match("%.png$") ~= nil,
        img_w    = 0,
        img_h    = 0,
        scale    = 1.0,
        pan_x    = 0,
        pan_y    = 0,
        loading  = true,
        error    = nil,
    }
end

function Viewer:build(state)
    active_data = state.data
    active_state = state
    local short = state.path or ""
    if #short > 28 then short = "..." .. short:sub(#short - 25) end
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar(short, { back = true }),
        { type = "image_canvas", grow = 1 },
    })
end

-- Fit the image so it's fully visible on first load. Called once after decode.
local function fit_to_screen(state)
    local vw, vh = SW, SH - VIEW_TOP
    if state.img_w <= 0 or state.img_h <= 0 then return end
    local sx = vw / state.img_w
    local sy = vh / state.img_h
    state.scale = math.min(sx, sy, 1.0)  -- never upscale on initial fit
    state.pan_x = 0
    state.pan_y = 0
end

function Viewer:on_enter()
    local state = self._state
    spawn(function()
        local data = async_read(state.path)
        if data and #data > 0 then
            state.data = data
            -- Parse dimensions from JPEG SOF or PNG IHDR header
            local w, h = ez.display.get_image_size(data)
            if w then state.img_w, state.img_h = w, h end
            fit_to_screen(state)
            state.loading = false
            active_data = data
            active_state = state
            screen_mod.invalidate()
        else
            state.error = "Failed to load"
            state.loading = false
            active_state = state
            screen_mod.invalidate()
        end
    end)
end

function Viewer:on_exit()
    active_data = nil
    active_state = nil
end

local PAN_STEP = 24
local ZOOM_STEP = 1.25

local function clamp_pan(state)
    local vw, vh = SW, SH - VIEW_TOP
    local img_sw = math.floor(state.img_w * state.scale)
    local img_sh = math.floor(state.img_h * state.scale)
    if img_sw > vw then
        local min_x = vw - img_sw
        if state.pan_x > 0 then state.pan_x = 0 end
        if state.pan_x < min_x then state.pan_x = min_x end
    else
        state.pan_x = 0
    end
    if img_sh > vh then
        local min_y = vh - img_sh
        if state.pan_y > 0 then state.pan_y = 0 end
        if state.pan_y < min_y then state.pan_y = min_y end
    else
        state.pan_y = 0
    end
end

function Viewer:handle_key(key)
    if key.character == "q" or key.special == "ESCAPE" then
        return "pop"
    end
    if self._state.loading then return "handled" end

    local state = self._state
    local changed = false

    if key.special == "UP" then
        state.pan_y = state.pan_y + PAN_STEP; changed = true
    elseif key.special == "DOWN" then
        state.pan_y = state.pan_y - PAN_STEP; changed = true
    elseif key.special == "LEFT" then
        state.pan_x = state.pan_x + PAN_STEP; changed = true
    elseif key.special == "RIGHT" then
        state.pan_x = state.pan_x - PAN_STEP; changed = true
    elseif key.character == "z" or key.character == "+" or key.character == "=" then
        state.scale = state.scale * ZOOM_STEP
        if state.scale > 8 then state.scale = 8 end
        changed = true
    elseif key.character == "x" or key.character == "-" or key.character == "_" then
        state.scale = state.scale / ZOOM_STEP
        if state.scale < 0.05 then state.scale = 0.05 end
        changed = true
    elseif key.character == "r" then
        fit_to_screen(state)
        changed = true
    end

    if changed then
        clamp_pan(state)
        active_state = state
        screen_mod.invalidate()
        return "handled"
    end
    return nil
end

return Viewer
