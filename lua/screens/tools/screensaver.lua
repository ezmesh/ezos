-- Screensaver: animated overlay drawn on top of the current screen via
-- sprite alpha blending. Mixed floating geometric shapes drift across
-- every pixel position to prevent LCD image persistence.
-- Any keypress dismisses.

local floor = math.floor
local sin = math.sin
local cos = math.cos
local abs = math.abs
local random = math.random

local screensaver = {}

local SW, SH = 320, 240
local TRANSPARENT = 0xF81F      -- magenta key color

local frame = 0
local active = false
local shapes = nil
local sprite = nil

local function rgb(r, g, b) return ez.display.rgb(r, g, b) end

-- Smooth HSV to RGB (h in [0,6))
local function hsv(h, s, v)
    h = h % 6
    local c = v * s
    local x = c * (1 - abs(h % 2 - 1))
    local m = v - c
    local r, g, b
    if     h < 1 then r, g, b = c, x, 0
    elseif h < 2 then r, g, b = x, c, 0
    elseif h < 3 then r, g, b = 0, c, x
    elseif h < 4 then r, g, b = 0, x, c
    elseif h < 5 then r, g, b = x, 0, c
    else               r, g, b = c, 0, x
    end
    return floor((r + m) * 255), floor((g + m) * 255), floor((b + m) * 255)
end

local function make_shape(kind)
    return {
        kind = kind,
        x = random(0, SW),
        y = random(0, SH),
        vx = (random() - 0.5) * 2.0,
        vy = (random() - 0.5) * 2.0,
        size = random(16, 50),
        hue = random() * 6,
        rot = random() * 6.28,
        vrot = (random() - 0.5) * 0.04,
    }
end

local function init_shapes()
    local kinds = { "square", "circle", "diamond", "triangle" }
    shapes = {}
    for i = 1, 16 do
        shapes[i] = make_shape(kinds[(i - 1) % #kinds + 1])
    end
end

local function bounce(s)
    s.x = s.x + s.vx
    s.y = s.y + s.vy
    s.rot = s.rot + s.vrot
    if s.x < -s.size then s.x = -s.size; s.vx = abs(s.vx) end
    if s.x > SW then s.x = SW; s.vx = -abs(s.vx) end
    if s.y < -s.size then s.y = -s.size; s.vy = abs(s.vy) end
    if s.y > SH then s.y = SH; s.vy = -abs(s.vy) end
    s.hue = (s.hue + 0.005) % 6
end

local function draw_shape(sp, s)
    bounce(s)
    local r, g, b = hsv(s.hue, 0.8, 0.9)
    local c = rgb(r, g, b)
    local cx = floor(s.x + s.size / 2)
    local cy = floor(s.y + s.size / 2)
    local half = floor(s.size / 2)

    if s.kind == "square" then
        local x, y = floor(s.x), floor(s.y)
        sp:fill_rect(x, y, s.size, s.size, c)
        sp:draw_rect(x, y, s.size, s.size, rgb(floor(r * 0.6), floor(g * 0.6), floor(b * 0.6)))

    elseif s.kind == "circle" then
        sp:fill_circle(cx, cy, half, c)
        sp:draw_circle(cx, cy, half, rgb(floor(r * 0.6), floor(g * 0.6), floor(b * 0.6)))

    elseif s.kind == "diamond" then
        for dy = -half + 1, half - 1 do
            local w = half - abs(dy)
            if w > 0 then
                sp:draw_line(cx - w, cy + dy, cx + w, cy + dy, c)
            end
        end
        sp:draw_line(cx, cy - half, cx + half, cy, rgb(floor(r * 0.6), floor(g * 0.6), floor(b * 0.6)))
        sp:draw_line(cx + half, cy, cx, cy + half, rgb(floor(r * 0.6), floor(g * 0.6), floor(b * 0.6)))
        sp:draw_line(cx, cy + half, cx - half, cy, rgb(floor(r * 0.6), floor(g * 0.6), floor(b * 0.6)))
        sp:draw_line(cx - half, cy, cx, cy - half, rgb(floor(r * 0.6), floor(g * 0.6), floor(b * 0.6)))

    elseif s.kind == "triangle" then
        local x1 = cx + floor(cos(s.rot) * half)
        local y1 = cy + floor(sin(s.rot) * half)
        local x2 = cx + floor(cos(s.rot + 2.094) * half)
        local y2 = cy + floor(sin(s.rot + 2.094) * half)
        local x3 = cx + floor(cos(s.rot + 4.189) * half)
        local y3 = cy + floor(sin(s.rot + 4.189) * half)
        sp:draw_line(x1, y1, x2, y2, c)
        sp:draw_line(x2, y2, x3, y3, c)
        sp:draw_line(x3, y3, x1, y1, c)
    end
end

-- Public API

function screensaver.start()
    if active then return end
    active = true
    frame = 0
    shapes = nil
    math.randomseed(ez.system.millis())
    if not sprite then
        sprite = ez.display.create_sprite(SW, SH)
        if sprite then
            sprite:set_transparent_color(TRANSPARENT)
        end
    end
    screensaver._saved_kb_bl = tonumber(ez.storage.get_pref("kb_backlight", 0)) or 0
    ez.keyboard.set_backlight(0)
end

function screensaver.stop()
    if not active then return end
    active = false
    if sprite then
        sprite:destroy()
        sprite = nil
    end
    if screensaver._saved_kb_bl then
        ez.keyboard.set_backlight(screensaver._saved_kb_bl)
    end
end

function screensaver.is_active()
    return active
end

function screensaver.draw(d)
    if not active or not sprite then return end
    frame = frame + 1
    if not shapes then init_shapes() end
    sprite:clear(TRANSPARENT)
    for _, s in ipairs(shapes) do
        draw_shape(sprite, s)
    end
    sprite:push(0, 0, 160)
end

return screensaver
