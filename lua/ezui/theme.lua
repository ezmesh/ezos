-- ezui.theme: Color palettes, semantic tokens, font sizes
-- Provides a single source of truth for all visual styling.

local theme = {}

-- Active palette (mutable, swapped by set_theme)
local palette = {}

-- Built-in palettes
local palettes = {
    dark = {
        BG          = 0x0000,   -- Black
        SURFACE     = 0x18E3,   -- Dark gray
        SURFACE_ALT = 0x2945,   -- Slightly lighter
        BORDER      = 0x4208,   -- Mid gray
        TEXT        = 0xFFFF,   -- White
        TEXT_SEC    = 0xB5B6,   -- Light gray
        TEXT_MUTED  = 0x7BCF,   -- Medium gray
        ACCENT      = 0x2C9F,   -- Bright blue
        ACCENT_DIM  = 0x1A4B,   -- Darker blue
        SUCCESS     = 0x07E0,   -- Green
        WARNING     = 0xFE60,   -- Orange
        ERROR       = 0xF800,   -- Red
        INFO        = 0x067F,   -- Cyan
        SELECTION   = 0x1A4B,   -- Selection highlight bg
        SCROLLBAR   = 0x4208,   -- Scrollbar track
        SCROLLBAR_T = 0x7BCF,   -- Scrollbar thumb
        STATUS_BG   = 0x0000,   -- Status bar background
    },
    light = {
        BG          = 0xEF7D,   -- Off-white
        SURFACE     = 0xFFFF,   -- White
        SURFACE_ALT = 0xE73C,   -- Light gray
        BORDER      = 0xC618,   -- Medium gray
        TEXT        = 0x2104,   -- Near-black
        TEXT_SEC    = 0x4A49,   -- Dark gray
        TEXT_MUTED  = 0x8410,   -- Medium gray
        ACCENT      = 0x2C9F,   -- Bright blue
        ACCENT_DIM  = 0xB5DF,   -- Light blue
        SUCCESS     = 0x2E85,   -- Dark green
        WARNING     = 0xE480,   -- Dark orange
        ERROR       = 0xC000,   -- Dark red
        INFO        = 0x04BF,   -- Teal
        SELECTION   = 0xB5DF,   -- Light blue selection
        SCROLLBAR   = 0xC618,   -- Scrollbar track
        SCROLLBAR_T = 0x8410,   -- Scrollbar thumb
        STATUS_BG   = 0xFFFF,   -- Status bar background
    },
}

-- Font size names mapped to display API values
local FONTS = {
    tiny   = "tiny",
    small  = "small",
    medium = "medium",
    large  = "large",
}

-- Standard spacing constants (pixels)
theme.SPACING = {
    xs = 2,
    sm = 4,
    md = 8,
    lg = 12,
    xl = 16,
}

-- Screen geometry
theme.SCREEN_W = 320
theme.SCREEN_H = 240
theme.STATUS_H = 20    -- Global status bar height (always rendered at top)
theme.TITLE_H  = 14    -- In-screen sub-bar height (back hint / right action)

-- Map tile palettes. Tiles store 3-bit semantic indices (0..7 = Land, Water,
-- Park, Building, RoadMinor, RoadMajor, Highway, Railway); the renderer maps
-- them to colors via `tiles` (1-indexed RGB565 array passed to
-- draw_indexed_bitmap). Label inks travel with the palette so the map_view
-- widget doesn't have to second-guess background luminance per theme.
local MAP_PALETTES = {
    light = {
        tiles = {
            0xFFFF,  -- 1: Land    — white
            0xA69E,  -- 2: Water   — light blue
            0xCF39,  -- 3: Park    — light green
            0xD69A,  -- 4: Building— light gray
            0x8C51,  -- 5: RoadMinor — medium gray
            0x630C,  -- 6: RoadMajor — darker gray
            0x4208,  -- 7: Highway — dark gray
            0x3186,  -- 8: Railway — near black
        },
        label_ink   = 0x0000,  -- Black for default place names
        label_halo  = 0xFFFF,  -- White halo
        label_water = 0x18C3,  -- Dark navy on light water
        label_park  = 0x1A40,  -- Dark green on light park
    },
    dark = {
        tiles = {
            0x2104,  -- 1: Land    — slate
            0x19CB,  -- 2: Water   — deep blue
            0x19C3,  -- 3: Park    — deep green
            0x4A49,  -- 4: Building— mid gray
            0x738E,  -- 5: RoadMinor — light-mid gray
            0x9492,  -- 6: RoadMajor — lighter gray
            0xB596,  -- 7: Highway — pale gray
            0xD69A,  -- 8: Railway — near white
        },
        label_ink   = 0xFFFF,  -- White on dark land
        label_halo  = 0x0000,  -- Black halo
        label_water = 0xA65F,  -- Light blue on dark water
        label_park  = 0xA6F4,  -- Light green on dark park
    },
}

-- Returns the map palette/ink struct for the active theme. Falls back to dark
-- when a custom theme has been registered without a matching map palette.
function theme.map_palette()
    return MAP_PALETTES[theme.name] or MAP_PALETTES.dark
end

-- Predefined accent color presets
theme.ACCENT_PRESETS = {
    { name = "Blue",    color = 0x2C9F },
    { name = "Teal",    color = 0x07F0 },
    { name = "Green",   color = 0x07E0 },
    { name = "Purple",  color = 0x881F },
    { name = "Red",     color = 0xF800 },
    { name = "Orange",  color = 0xFBE0 },
    { name = "Pink",    color = 0xF81F },
    { name = "Yellow",  color = 0xFFE0 },
}

-- Darken an RGB565 color by a factor (0-1)
function theme.darken_rgb565(color, factor)
    factor = factor or 0.5
    local r = math.floor(math.floor(color / 2048) % 32 * factor)
    local g = math.floor(math.floor(color / 32) % 64 * factor)
    local b = math.floor(color % 32 * factor)
    return r * 2048 + g * 32 + b
end

-- Brighten an RGB565 color by a factor (>1). Channels clamp at their max
-- (31 for R/B, 63 for G) so strong factors won't wrap around into dim
-- colours.
function theme.brighten_rgb565(color, factor)
    factor = factor or 1.2
    local r = math.floor(math.floor(color / 2048) % 32 * factor)
    local g = math.floor(math.floor(color / 32) % 64 * factor)
    local b = math.floor(color % 32 * factor)
    if r > 31 then r = 31 end
    if g > 63 then g = 63 end
    if b > 31 then b = 31 end
    return r * 2048 + g * 32 + b
end

-- Set accent color and derive related colors
function theme.set_accent(color)
    palette.ACCENT = color
    palette.ACCENT_DIM = theme.darken_rgb565(color)
    palette.SELECTION = palette.ACCENT_DIM
end

-- Save accent color preference and apply it
function theme.save_accent(color)
    ez.storage.set_pref("accent_color", color)
    theme.set_accent(color)
end

-- Initialize with a palette name
function theme.init(name)
    name = name or "dark"
    local p = palettes[name]
    if not p then p = palettes.dark end
    for k, v in pairs(p) do palette[k] = v end
    theme.name = name
    -- Apply saved accent color. Coerce via tonumber so a garbage
    -- string pref (e.g. left over from the dev prefs editor) can't
    -- crash boot in darken_rgb565's bit math.
    local saved = tonumber(ez.storage.get_pref("accent_color", 0))
    if saved and saved ~= 0 then
        theme.set_accent(saved)
    end
end

-- Get a color by semantic name
function theme.color(name)
    return palette[name] or 0xF81F -- Magenta = missing color
end

-- Get the full palette table (for direct access)
function theme.colors()
    return palette
end

-- Register a custom palette
function theme.register(name, colors)
    palettes[name] = colors
end

-- Switch to a different palette at runtime
function theme.set(name)
    theme.init(name)
end

-- Font helpers
theme.FONT = FONTS

-- Measure text width in current font
function theme.text_width(text)
    return ez.display.text_width(text)
end

-- Get current font metrics
function theme.font_height()
    return ez.display.get_font_height()
end

function theme.font_width()
    return ez.display.get_font_width()
end

-- Set the active font size, resetting the style axis to regular unless
-- a specific style is requested.
function theme.set_font(size, style)
    ez.display.set_font_size(size or "medium")
    ez.display.set_font_style(style or "regular")
end

-- Set the style axis without touching size. Useful for rich-text runs that
-- share a size but flip between regular/bold/italic.
function theme.set_font_style(style)
    ez.display.set_font_style(style or "regular")
end

-- Create an RGB565 color from 0-255 components
function theme.rgb(r, g, b)
    return ez.display.rgb(r, g, b)
end

theme.init("dark")

return theme
