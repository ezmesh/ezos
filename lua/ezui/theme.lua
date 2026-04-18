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
theme.STATUS_H = 20    -- Status bar height
theme.TITLE_H  = 22    -- Title bar height

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
    -- Apply saved accent color
    local saved = ez.storage.get_pref("accent_color", 0)
    if saved ~= 0 then
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

-- Set active font size
function theme.set_font(size)
    ez.display.set_font_size(size or "medium")
end

-- Create an RGB565 color from 0-255 components
function theme.rgb(r, g, b)
    return ez.display.rgb(r, g, b)
end

theme.init("dark")

return theme
