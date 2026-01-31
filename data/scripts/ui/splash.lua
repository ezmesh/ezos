-- splash.lua - Stylized splash screen with triangular cat
-- Shows splash while loading essential UI modules (Icons)

local function show()
    local d = ez.display
    local cx, cy = 160, 115
    -- Colors: orange fur, darker shade, cream inner ear, white, black
    local ORANGE = 0xFD20      -- Main fur
    local DARK_ORANGE = 0xC340 -- Shading
    local CREAM = 0xFFB0       -- Inner ear
    local WHITE = 0xFFFF
    local BLACK = 0x0000
    local PINK = 0xF8B0        -- Nose

    d.fill_rect(0, 0, 320, 240, BLACK)

    -- Head (hexagon-like shape using triangles) - wider for chonky look
    -- Main face area - diamond shape
    d.fill_triangle(cx-55, cy-20, cx+55, cy-20, cx, cy+50, ORANGE)
    d.fill_triangle(cx-55, cy-20, cx+55, cy-20, cx, cy-35, ORANGE)
    -- Cheeks - connect to main face corners, fuller cheeks
    d.fill_triangle(cx-68, cy+5, cx-55, cy-20, cx-42, cy+38, ORANGE)
    d.fill_triangle(cx+68, cy+5, cx+55, cy-20, cx+42, cy+38, ORANGE)
    -- Fill gap between cheeks and main face
    d.fill_triangle(cx-55, cy-20, cx-42, cy+38, cx, cy+50, ORANGE)
    d.fill_triangle(cx+55, cy-20, cx+42, cy+38, cx, cy+50, ORANGE)

    -- Left ear (triangle pointing up)
    d.fill_triangle(cx-58, cy-15, cx-30, cy-15, cx-44, cy-58, ORANGE)
    -- Left ear inner (smaller triangle)
    d.fill_triangle(cx-54, cy-18, cx-34, cy-18, cx-44, cy-46, CREAM)

    -- Right ear (triangle pointing up) with notch
    d.fill_triangle(cx+58, cy-15, cx+30, cy-15, cx+44, cy-58, ORANGE)
    -- Right ear inner
    d.fill_triangle(cx+54, cy-18, cx+34, cy-18, cx+44, cy-46, CREAM)
    -- Ear notch (smaller black triangle cut)
    d.fill_triangle(cx+46, cy-52, cx+50, cy-46, cx+42, cy-46, BLACK)

    -- Chin shading
    d.fill_triangle(cx-20, cy+35, cx+20, cy+35, cx, cy+50, DARK_ORANGE)

    -- Eyes (almond shape using triangles)
    d.fill_triangle(cx-35, cy-5, cx-15, cy-5, cx-25, cy+12, WHITE)
    d.fill_triangle(cx-35, cy-5, cx-15, cy-5, cx-25, cy-15, WHITE)
    d.fill_triangle(cx+35, cy-5, cx+15, cy-5, cx+25, cy+12, WHITE)
    d.fill_triangle(cx+35, cy-5, cx+15, cy-5, cx+25, cy-15, WHITE)

    -- Pupils (vertical slits)
    d.fill_rect(cx-27, cy-8, 5, 16, BLACK)
    d.fill_rect(cx+23, cy-8, 5, 16, BLACK)

    -- Nose (small triangle)
    d.fill_triangle(cx-8, cy+18, cx+8, cy+18, cx, cy+28, PINK)

    -- Mouth lines
    d.draw_line(cx, cy+28, cx, cy+35, BLACK)
    d.draw_line(cx, cy+35, cx-10, cy+42, BLACK)
    d.draw_line(cx, cy+35, cx+10, cy+42, BLACK)

    -- Loading text
    d.set_font_size("small")
    d.draw_text_centered(200, "Loading...", 0x8410)

    d.flush()
end

local function wait_for_modules()
    local start_time = ez.system.millis()
    local MIN_DISPLAY_MS = 800  -- Minimum time to show splash
    local MAX_WAIT_MS = 5000    -- Maximum time to wait for modules

    -- Show splash immediately
    show()

    -- Load Icons module (the main thing we're waiting for)
    ez.system.log("[Splash] Loading Icons...")
    local ok, Icons = pcall(load_module, "/scripts/ui/icons.lua")
    if ok and Icons then
        _G.Icons = Icons
        ez.system.log("[Splash] Icons loaded")
    else
        ez.system.log("[Splash] Icons failed to load: " .. tostring(Icons))
    end

    -- Ensure minimum display time
    local elapsed = ez.system.millis() - start_time
    if elapsed < MIN_DISPLAY_MS then
        ez.system.delay(MIN_DISPLAY_MS - elapsed)
    end

    ez.system.log("[Splash] Done, waited " .. (ez.system.millis() - start_time) .. "ms")
end

-- Execute immediately
wait_for_modules()

-- Return nil so nothing gets stored
return nil
