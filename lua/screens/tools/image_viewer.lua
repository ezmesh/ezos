-- Image Viewer: pan and zoom a JPEG/PNG from storage.
-- Arrows pan when the image extends beyond the viewport; otherwise
-- LEFT / RIGHT step to the previous / next image in the same folder.
-- z/x zoom in/out, r resets, q/ESC quits.

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

local function is_image_name(name)
    local l = name:lower()
    return l:match("%.jpe?g$") ~= nil or l:match("%.png$") ~= nil
end

-- Split "/dir/file.jpg" into ("/dir/", "file.jpg"). Roots ("/fs/", "/sd/")
-- keep their trailing slash so callers can append a filename without a
-- separate check. Returns nil for malformed input so the caller can fall
-- back gracefully.
local function split_path(p)
    if not p or p == "" then return nil, nil end
    local dir, name = p:match("^(.*/)([^/]+)$")
    if not dir then return nil, p end
    return dir, name
end

-- List sibling images in `dir`, sorted alphabetically. Excludes
-- subdirectories so the prev/next navigation stays a horizontal stroll
-- through the visible JPEGs/PNGs the user just saw in the file manager.
local function list_siblings(dir)
    if not dir or dir == "" then return {} end
    local entries = ez.storage.list_dir(dir)
    if not entries then return {} end
    local out = {}
    for _, f in ipairs(entries) do
        if not f.is_dir and is_image_name(f.name) then
            out[#out + 1] = f.name
        end
    end
    table.sort(out)
    return out
end

if not node_mod.handler("image_canvas") then
    node_mod.register("image_canvas", {
        measure = function(n, mw, mh) return mw, mh end,

        draw = function(n, d, x, y, w, h)
            d.fill_rect(x, y, w, h, 0)
            if not active_data then
                theme.set_font("medium_aa")
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
            theme.set_font("small_aa")
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
    -- siblings + index are populated in on_enter so set_state doesn't
    -- have to re-scan the directory on every prev/next.
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
        dir      = nil,
        siblings = nil,
        index    = nil,
    }
end

function Viewer:build(state)
    active_data = state.data
    active_state = state
    -- The in-screen title_bar only renders the "Back" affordance plus
    -- an optional `right` label, so the folder-position indicator goes
    -- in `right`. The siblings field is populated asynchronously in
    -- on_enter, so the indicator only lights up once the dir scan
    -- finishes (single-image folders never show it).
    local right
    if state.siblings and state.index and #state.siblings > 1 then
        right = string.format("%d / %d", state.index, #state.siblings)
    end
    return ui.vbox({ gap = 0, bg = "BG" }, {
        ui.title_bar(state.path or "", { back = true, right = right }),
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

-- Load the file at `state.path` into `state.data` + dimensions, then
-- fit to screen. Used by on_enter for the first image and by navigate()
-- for every subsequent prev/next step. The path-stale check after the
-- async read means rapid LEFT/RIGHT presses don't paint the wrong image
-- when reads complete out of order.
local function load_image(state)
    state.loading = true
    state.error   = nil
    state.data    = nil
    state.img_w   = 0
    state.img_h   = 0
    state.is_png  = state.path and state.path:lower():match("%.png$") ~= nil
    -- Show a "Loading..." placeholder immediately on the current canvas.
    active_data  = nil
    active_state = state
    screen_mod.invalidate()

    local async = require("ezui.async")
    local target_path = state.path
    async.task(function()
        local data = async_read(target_path)
        -- The user may have stepped to another image while this read
        -- was in flight; drop the result so we don't clobber the new
        -- state with stale bytes.
        if state.path ~= target_path then return end
        if data and #data > 0 then
            state.data = data
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

function Viewer:on_enter()
    local state = self._state
    -- Resolve siblings + the entry's index once, in a background task,
    -- so the directory listing doesn't block the first paint. The
    -- viewer is usable for the single current image immediately; the
    -- prev/next affordance lights up once the scan completes.
    if not state.siblings then
        local async = require("ezui.async")
        async.task(function()
            local dir, name = split_path(state.path)
            if not dir then return end
            local sibs = list_siblings(dir)
            local idx = 1
            for i, s in ipairs(sibs) do
                if s == name then idx = i; break end
            end
            -- Drop results if the path moved on under us.
            if state.path ~= (dir .. (name or "")) then return end
            state.dir      = dir
            state.siblings = sibs
            state.index    = idx
            screen_mod.invalidate()
        end)
    end

    load_image(state)
end

function Viewer:on_exit()
    active_data = nil
    active_state = nil
end

-- Step to the previous or next image in the same folder. dir = -1
-- (prev) or +1 (next). Clamps at the ends so the very first / last
-- image is a no-op (no wraparound -- it should feel like a tape, not
-- a carousel). Routed through set_state so the title bar's "N/M"
-- indicator rebuilds along with the canvas.
function Viewer:navigate(dir)
    local state = self._state
    if not state.siblings or #state.siblings <= 1 then return false end
    if not state.index then return false end
    local target = state.index + dir
    if target < 1 or target > #state.siblings then return false end
    state.index = target
    state.path  = (state.dir or "") .. state.siblings[target]
    self:set_state({ path = state.path, index = target })
    load_image(state)
    return true
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

-- True when the rendered image is wider/taller than the viewport in
-- the given axis, so panning is possible. Used to decide whether
-- LEFT/RIGHT should pan or page to the next image.
local function can_pan_x(state)
    local vw = SW
    return math.floor((state.img_w or 0) * state.scale) > vw
end
local function can_pan_y(state)
    local vh = SH - VIEW_TOP
    return math.floor((state.img_h or 0) * state.scale) > vh
end

function Viewer:handle_key(key)
    if key.special == "BACKSPACE" or key.special == "ESCAPE" then
        return "pop"
    end
    if self._state.loading then return "handled" end

    local state = self._state
    local changed = false

    -- LEFT/RIGHT: pan when the image is wider than the viewport (the
    -- user is actively framing a region); otherwise page to the
    -- previous / next sibling image in the folder.
    if key.special == "LEFT" then
        if can_pan_x(state) then
            state.pan_x = state.pan_x + PAN_STEP; changed = true
        else
            if self:navigate(-1) then return "handled" end
        end
    elseif key.special == "RIGHT" then
        if can_pan_x(state) then
            state.pan_x = state.pan_x - PAN_STEP; changed = true
        else
            if self:navigate(1) then return "handled" end
        end
    elseif key.special == "UP" then
        if can_pan_y(state) then
            state.pan_y = state.pan_y + PAN_STEP; changed = true
        end
    elseif key.special == "DOWN" then
        if can_pan_y(state) then
            state.pan_y = state.pan_y - PAN_STEP; changed = true
        end
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
