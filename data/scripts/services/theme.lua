-- Theme Manager Service for T-Deck OS
-- Manages wallpaper patterns, icon themes, and color themes

local ThemeManager = {
    -- Current active settings
    current_wallpaper = "solid",
    current_icon_theme = "default",
    current_color_theme = "default",

    -- Layout constants for vertical lists
    LIST_START_Y = 31,  -- Y position where list content starts (after title bar)

    -- Available options
    WALLPAPERS = {"solid", "grid", "dots", "dots_diag", "dense", "dense_diag", "hlines", "vlines", "diag"},
    ICON_THEMES = {"default", "cyan", "orange", "mono"},
    COLOR_THEMES = {
        -- Dark themes
        "default", "amber", "ocean", "sunset", "forest", "midnight",
        "cyberpunk", "cherry", "aurora", "coral", "volcano", "arctic",
        -- Light themes
        "jf", "daylight", "latte", "mint", "lavender", "peach",
        "cream", "sky", "rose", "sage"
    },

    -- Color theme definitions (RGB565 values)
    -- Semantic color names:
    --   ACCENT      = Primary accent color (selections, highlights, links)
    --   SUCCESS     = Success/positive state
    --   WARNING     = Warning/caution state
    --   ERROR       = Error/danger state
    --   INFO        = Informational/secondary accent
    --   TEXT        = Primary text color (must contrast with BACKGROUND)
    --   TEXT_SECONDARY = Secondary/dimmed text
    --   TEXT_MUTED  = Very dim text for hints (must contrast with BACKGROUND)
    --   SURFACE     = Card/input field backgrounds
    --   SURFACE_ALT = Selection highlight background
    --   TINT1/TINT2 = Wallpaper pattern colors
    COLOR_PALETTES = {
        -- Default: Cyan/Green look
        default = {
            TINT1 = 0x1082,       -- Dark cyan tint
            TINT2 = 0x0841,       -- Darker accent
            ACCENT = 0x07FF,      -- Bright cyan
            SUCCESS = 0x07E0,     -- Bright green
            WARNING = 0xFD20,     -- Orange
            ERROR = 0xF800,       -- Red
            INFO = 0xFFE0,        -- Yellow
            TEXT = 0x07E0,        -- Green text
            TEXT_SECONDARY = 0x03E0, -- Dark green
            TEXT_MUTED = 0x4208,  -- Gray for hints
            SURFACE = 0x2104,     -- Dark surface
            SURFACE_ALT = 0x0320, -- Selection background
        },
        -- Amber: Warm amber
        amber = {
            TINT1 = 0x4200,       -- Dark amber tint
            TINT2 = 0x2100,       -- Deeper amber
            ACCENT = 0xFE00,      -- Amber
            SUCCESS = 0x97E0,     -- Yellow-green
            WARNING = 0xFD20,     -- Orange
            ERROR = 0xF800,       -- Red
            INFO = 0xFFE0,        -- Yellow
            TEXT = 0xFE00,        -- Amber text
            TEXT_SECONDARY = 0x8400, -- Dark amber
            TEXT_MUTED = 0x6300,  -- Dim amber
            SURFACE = 0x2104,     -- Dark surface
            SURFACE_ALT = 0x4200, -- Selection background
        },
        -- Ocean: Cool blue depths
        ocean = {
            TINT1 = 0x1926,       -- Deep blue tint
            TINT2 = 0x0C63,       -- Darker ocean
            ACCENT = 0x5DDF,      -- Light blue
            SUCCESS = 0x57EA,     -- Sea green
            WARNING = 0xFD40,     -- Coral
            ERROR = 0xF800,       -- Red
            INFO = 0xFFE0,        -- Yellow
            TEXT = 0xBF3F,        -- Light cyan text
            TEXT_SECONDARY = 0x6D9F, -- Medium blue
            TEXT_MUTED = 0x4C9F,  -- Dim blue
            SURFACE = 0x1084,     -- Dark blue surface
            SURFACE_ALT = 0x2966, -- Selection background
        },
        -- Sunset: Warm evening colors
        sunset = {
            TINT1 = 0x4000,       -- Dark red-brown tint
            TINT2 = 0x6100,       -- Warm orange accent
            ACCENT = 0xFD40,      -- Coral
            SUCCESS = 0xFE60,     -- Warm yellow-green
            WARNING = 0xFD20,     -- Orange
            ERROR = 0xF800,       -- Red
            INFO = 0xFFE0,        -- Yellow
            TEXT = 0xFE60,        -- Warm text
            TEXT_SECONDARY = 0xB400, -- Dim orange
            TEXT_MUTED = 0x7300,  -- Muted orange
            SURFACE = 0x2000,     -- Dark warm surface
            SURFACE_ALT = 0x6000, -- Selection background
        },
        -- Forest: Natural greens
        forest = {
            TINT1 = 0x2945,       -- Very dark green tint
            TINT2 = 0x1903,       -- Deep forest
            ACCENT = 0x8F8B,      -- Sage green
            SUCCESS = 0x5F26,     -- Forest green
            WARNING = 0xC580,     -- Autumn orange
            ERROR = 0xB8A2,       -- Muted red
            INFO = 0xBE66,        -- Olive yellow
            TEXT = 0xAF2D,        -- Pale green text
            TEXT_SECONDARY = 0x6E8A, -- Medium green
            TEXT_MUTED = 0x4B29,  -- Dark forest
            SURFACE = 0x1903,     -- Dark surface
            SURFACE_ALT = 0x3B07, -- Selection background
        },
        -- Midnight: Deep blues and purples
        midnight = {
            TINT1 = 0x2105,       -- Deep midnight tint
            TINT2 = 0x3107,       -- Purple accent
            ACCENT = 0x7C1F,      -- Purple-blue
            SUCCESS = 0x57EA,     -- Neon green
            WARNING = 0xC45F,     -- Pink-purple
            ERROR = 0xF80F,       -- Magenta
            INFO = 0xC65F,        -- Lavender
            TEXT = 0xB59F,        -- Light purple text
            TEXT_SECONDARY = 0x738E, -- Medium purple-gray
            TEXT_MUTED = 0x528A,  -- Dim purple
            SURFACE = 0x1083,     -- Dark surface
            SURFACE_ALT = 0x3107, -- Selection background
        },
        -- Cyberpunk: Neon pink and blue
        cyberpunk = {
            TINT1 = 0x1083,       -- Dark blue-black tint
            TINT2 = 0x380F,       -- Magenta accent
            ACCENT = 0x07FF,      -- Electric cyan
            SUCCESS = 0x47E0,     -- Neon green
            WARNING = 0xFD20,     -- Orange
            ERROR = 0xF81F,       -- Magenta
            INFO = 0xF81F,        -- Magenta
            TEXT = 0xF81F,        -- Bright magenta text
            TEXT_SECONDARY = 0xA80F, -- Medium magenta
            TEXT_MUTED = 0x780F,  -- Dim magenta
            SURFACE = 0x0841,     -- Dark surface
            SURFACE_ALT = 0x380F, -- Selection background
        },
        -- Cherry: Dark with pink/red
        cherry = {
            TINT1 = 0x3082,       -- Dark red tint
            TINT2 = 0x6041,       -- Pink accent
            ACCENT = 0xF8B2,      -- Light pink
            SUCCESS = 0x97E6,     -- Yellow-green
            WARNING = 0xFD20,     -- Orange
            ERROR = 0xF800,       -- Red
            INFO = 0xFEB2,        -- Light coral
            TEXT = 0xFE92,        -- Soft pink text
            TEXT_SECONDARY = 0xC514, -- Medium pink
            TEXT_MUTED = 0x8410,  -- Gray-pink
            SURFACE = 0x2041,     -- Dark surface
            SURFACE_ALT = 0x6041, -- Selection background
        },
        -- Aurora: Northern lights inspired
        aurora = {
            TINT1 = 0x1084,       -- Deep blue-green tint
            TINT2 = 0x2946,       -- Purple-blue accent
            ACCENT = 0x5FFC,      -- Bright teal
            SUCCESS = 0x47E9,     -- Aurora green
            WARNING = 0xFC92,     -- Pink
            ERROR = 0xF98B,       -- Coral
            INFO = 0x9FFC,        -- Light teal
            TEXT = 0xBFFF,        -- Light cyan-white
            TEXT_SECONDARY = 0x7F9E, -- Medium teal
            TEXT_MUTED = 0x4E8D,  -- Dim teal
            SURFACE = 0x1042,     -- Dark surface
            SURFACE_ALT = 0x2946, -- Selection background
        },
        -- Coral: Tropical reef colors
        coral = {
            TINT1 = 0x1926,       -- Deep blue tint
            TINT2 = 0x4082,       -- Coral accent
            ACCENT = 0x4E9F,      -- Turquoise
            SUCCESS = 0x5FCA,     -- Sea green
            WARNING = 0xFCC6,     -- Coral pink
            ERROR = 0xF986,       -- Salmon
            INFO = 0xFE86,        -- Sandy yellow
            TEXT = 0xBF9F,        -- Light blue-white
            TEXT_SECONDARY = 0x7D5E, -- Medium aqua
            TEXT_MUTED = 0x5C8D,  -- Dim aqua
            SURFACE = 0x1084,     -- Dark surface
            SURFACE_ALT = 0x3986, -- Selection background
        },
        -- Volcano: Molten lava colors
        volcano = {
            TINT1 = 0x2000,       -- Dark red-black tint
            TINT2 = 0x5000,       -- Ember accent
            ACCENT = 0xFC00,      -- Lava orange
            SUCCESS = 0xFE40,     -- Yellow-orange
            WARNING = 0xFB00,     -- Bright orange
            ERROR = 0xF800,       -- Bright red
            INFO = 0xFFE0,        -- Bright yellow
            TEXT = 0xFE40,        -- Orange-yellow text
            TEXT_SECONDARY = 0xB400, -- Medium orange
            TEXT_MUTED = 0x7300,  -- Dim orange
            SURFACE = 0x1000,     -- Charcoal surface
            SURFACE_ALT = 0x5000, -- Selection background
        },
        -- Arctic: Ice and snow
        arctic = {
            TINT1 = 0x2966,       -- Ice blue tint
            TINT2 = 0x1084,       -- Deep blue accent
            ACCENT = 0x9E9F,      -- Ice blue
            SUCCESS = 0x8F8D,     -- Frost green
            WARNING = 0xAD0D,     -- Pale orange
            ERROR = 0xB186,       -- Muted red
            INFO = 0xC618,        -- Pale yellow
            TEXT = 0xDEDB,        -- Snow white
            TEXT_SECONDARY = 0x9CD3, -- Light gray
            TEXT_MUTED = 0x738E,  -- Frost gray
            SURFACE = 0x1926,     -- Deep ice surface
            SURFACE_ALT = 0x3A08, -- Selection background
        },

        -- ===== LIGHT THEMES =====

        -- JF: Pink primary with white background, vibrant complementary colors
        -- Brand pink #f28dbe = 0xEC77, Ocean blue #007FFF = 0x055F
        jf = {
            is_light = true,
            BACKGROUND = 0xFFFF,  -- Pure white
            TINT1 = 0xFE18,       -- Very light pink tint
            TINT2 = 0xADDF,       -- Light blue accent
            ACCENT = 0xEC77,      -- JF Pink primary (#f28dbe)
            SUCCESS = 0x2E8B,     -- Sea green (#2E8B57)
            WARNING = 0xFD20,     -- Bright orange
            ERROR = 0xF800,       -- Bright red
            INFO = 0x055F,        -- Ocean blue (#007FFF)
            TEXT = 0x2104,        -- Near black text
            TEXT_SECONDARY = 0x6B4D, -- Medium gray
            TEXT_MUTED = 0x9492,  -- Light gray
            SURFACE = 0xF79E,     -- Very light pink-gray
            SURFACE_ALT = 0xFE18, -- Light pink selection
        },
        -- Daylight: Bright white with blue
        daylight = {
            is_light = true,
            BACKGROUND = 0xFFFF,  -- Pure white
            TINT1 = 0xDEFB,       -- Light gray tint
            TINT2 = 0xB5D6,       -- Light blue accent
            ACCENT = 0x2D7F,      -- Bright blue
            SUCCESS = 0x2E8B,     -- Green
            WARNING = 0xFC60,     -- Orange
            ERROR = 0xF800,       -- Red
            INFO = 0xFE00,        -- Amber
            TEXT = 0x2104,        -- Near black
            TEXT_SECONDARY = 0x6B4D, -- Medium gray
            TEXT_MUTED = 0x9492,  -- Light gray
            SURFACE = 0xE71C,     -- Very light gray
            SURFACE_ALT = 0xB5F6, -- Light blue selection
        },
        -- Latte: Coffee/cream theme
        latte = {
            is_light = true,
            BACKGROUND = 0xEF5D,  -- Warm off-white
            TINT1 = 0xD69A,       -- Light brown tint
            TINT2 = 0xC618,       -- Cream accent
            ACCENT = 0x3C7F,      -- Teal
            SUCCESS = 0x4586,     -- Sage green
            WARNING = 0xC3A0,     -- Coffee brown
            ERROR = 0xC186,       -- Muted red
            INFO = 0xCE00,        -- Caramel
            TEXT = 0x4208,        -- Dark brown
            TEXT_SECONDARY = 0x7BCF, -- Medium brown-gray
            TEXT_MUTED = 0xA514,  -- Light brown
            SURFACE = 0xDEDB,     -- Light cream
            SURFACE_ALT = 0xC618, -- Selection background
        },
        -- Mint: Light green/white
        mint = {
            is_light = true,
            BACKGROUND = 0xE7FC,  -- Mint white
            TINT1 = 0xCF5A,       -- Light mint tint
            TINT2 = 0xAF0C,       -- Green accent
            ACCENT = 0x2D8D,      -- Teal
            SUCCESS = 0x2E69,     -- Forest green
            WARNING = 0xD400,     -- Orange-brown
            ERROR = 0xC186,       -- Muted red
            INFO = 0x95E0,        -- Yellow-green
            TEXT = 0x2945,        -- Dark green-gray
            TEXT_SECONDARY = 0x5ACB, -- Medium gray-green
            TEXT_MUTED = 0x8C71,  -- Light gray-green
            SURFACE = 0xD71C,     -- Very light green-gray
            SURFACE_ALT = 0xB7F5, -- Selection background
        },
        -- Lavender: Light purple
        lavender = {
            is_light = true,
            BACKGROUND = 0xF79E,  -- Lavender white
            TINT1 = 0xD69B,       -- Light purple tint
            TINT2 = 0xC59F,       -- Purple accent
            ACCENT = 0x897F,      -- Purple-blue
            SUCCESS = 0x6E0C,     -- Muted green
            WARNING = 0xD44F,     -- Muted orange
            ERROR = 0xC967,       -- Muted pink-red
            INFO = 0xBE2D,        -- Muted yellow
            TEXT = 0x4A69,        -- Dark purple-gray
            TEXT_SECONDARY = 0x738E, -- Medium gray
            TEXT_MUTED = 0x9CD3,  -- Light gray
            SURFACE = 0xEF5D,     -- Very light purple
            SURFACE_ALT = 0xC59F, -- Selection background
        },
        -- Peach: Light orange/pink
        peach = {
            is_light = true,
            BACKGROUND = 0xFEB7,  -- Peach white
            TINT1 = 0xE634,       -- Light peach tint
            TINT2 = 0xFDF6,       -- Coral accent
            ACCENT = 0xD34B,      -- Coral (darker for contrast)
            SUCCESS = 0x5D88,     -- Sage
            WARNING = 0xFB80,     -- Orange
            ERROR = 0xF8A7,       -- Coral
            INFO = 0xFE40,        -- Peach
            TEXT = 0x4A49,        -- Dark warm gray
            TEXT_SECONDARY = 0x7BCF, -- Medium warm gray
            TEXT_MUTED = 0xA514,  -- Light warm gray
            SURFACE = 0xF71C,     -- Very light peach
            SURFACE_ALT = 0xEDD4, -- Selection background
        },
        -- Cream: Warm neutral
        cream = {
            is_light = true,
            BACKGROUND = 0xFED6,  -- Warm cream
            TINT1 = 0xE6B4,       -- Light tan tint
            TINT2 = 0xD69A,       -- Darker cream accent
            ACCENT = 0x4A69,      -- Blue-gray
            SUCCESS = 0x4C85,     -- Olive green
            WARNING = 0xC3E0,     -- Brown
            ERROR = 0xB8C3,       -- Muted red
            INFO = 0xC580,        -- Tan
            TEXT = 0x39E7,        -- Dark brown-gray
            TEXT_SECONDARY = 0x6B4D, -- Medium gray
            TEXT_MUTED = 0x9CD3,  -- Light gray
            SURFACE = 0xE6F4,     -- Light gray
            SURFACE_ALT = 0xD6B4, -- Selection background
        },
        -- Sky: Light blue
        sky = {
            is_light = true,
            BACKGROUND = 0xE73F,  -- Light sky blue
            TINT1 = 0xCE9F,       -- Soft blue tint
            TINT2 = 0xB5D6,       -- Deeper blue accent
            ACCENT = 0x055F,      -- Bright blue
            SUCCESS = 0x3E8B,     -- Fresh green
            WARNING = 0xFC60,     -- Warm orange
            ERROR = 0xF186,       -- Coral red
            INFO = 0xFE40,        -- Sunny yellow
            TEXT = 0x2124,        -- Dark blue-gray
            TEXT_SECONDARY = 0x52AA, -- Medium gray-blue
            TEXT_MUTED = 0x8410,  -- Light gray-blue
            SURFACE = 0xD6FE,     -- Very light blue
            SURFACE_ALT = 0xADDF, -- Selection background
        },
        -- Rose: Soft pink
        rose = {
            is_light = true,
            BACKGROUND = 0xFE99,  -- Rose white
            TINT1 = 0xFDF6,       -- Light rose tint
            TINT2 = 0xEC77,       -- Pink accent
            ACCENT = 0xD34B,      -- Darker rose (for contrast)
            SUCCESS = 0x5D88,     -- Sage green
            WARNING = 0xFB60,     -- Peach
            ERROR = 0xF8A7,       -- Coral
            INFO = 0xFE40,        -- Cream yellow
            TEXT = 0x4228,        -- Dark warm gray
            TEXT_SECONDARY = 0x738E, -- Medium rose-gray
            TEXT_MUTED = 0xA514,  -- Light gray
            SURFACE = 0xF71C,     -- Very light pink
            SURFACE_ALT = 0xEDD4, -- Selection background
        },
        -- Sage: Soft green
        sage = {
            is_light = true,
            BACKGROUND = 0xEF7C,  -- Sage white
            TINT1 = 0xCF39,       -- Light sage tint
            TINT2 = 0xAED1,       -- Green accent
            ACCENT = 0x3D8D,      -- Teal
            SUCCESS = 0x4E69,     -- Sage green
            WARNING = 0xC400,     -- Warm brown
            ERROR = 0xB186,       -- Muted red
            INFO = 0xA5E0,        -- Olive yellow
            TEXT = 0x3186,        -- Dark green-gray
            TEXT_SECONDARY = 0x5ACB, -- Medium sage
            TEXT_MUTED = 0x8C71,  -- Light sage
            SURFACE = 0xDF3B,     -- Very light sage
            SURFACE_ALT = 0xBF35, -- Selection background
        },
    },

    -- Custom wallpaper tint colors (RGB565, nil = use theme defaults)
    custom_wallpaper_tint1 = nil,
    custom_wallpaper_tint2 = nil,

    -- Active color palette (initialized from default)
    colors = nil,
}

-- Initialize theme manager - load saved preferences
function ThemeManager.init()
    local function get_pref(key, default)
        if tdeck.storage and tdeck.storage.get_pref then
            return tdeck.storage.get_pref(key, default)
        end
        return default
    end

    ThemeManager.current_wallpaper = get_pref("wallpaper", "solid")
    ThemeManager.current_icon_theme = get_pref("icon_theme", "default")
    ThemeManager.current_color_theme = get_pref("color_theme", "default")

    -- Load custom wallpaper tints (-1 means auto/nil)
    local tint1 = get_pref("wallpaper_tint", -1)
    tint1 = tonumber(tint1) or -1
    if tint1 >= 0 then
        ThemeManager.custom_wallpaper_tint1 = tint1
    else
        ThemeManager.custom_wallpaper_tint1 = nil
    end

    local tint2 = get_pref("wallpaper_tint2", -1)
    tint2 = tonumber(tint2) or -1
    if tint2 >= 0 then
        ThemeManager.custom_wallpaper_tint2 = tint2
    else
        ThemeManager.custom_wallpaper_tint2 = nil
    end

    -- Validate wallpaper
    local valid_wp = false
    for _, wp in ipairs(ThemeManager.WALLPAPERS) do
        if wp == ThemeManager.current_wallpaper then
            valid_wp = true
            break
        end
    end
    if not valid_wp then
        ThemeManager.current_wallpaper = "solid"
    end

    -- Validate icon theme
    local valid_icon = false
    for _, th in ipairs(ThemeManager.ICON_THEMES) do
        if th == ThemeManager.current_icon_theme then
            valid_icon = true
            break
        end
    end
    if not valid_icon then
        ThemeManager.current_icon_theme = "default"
    end

    -- Validate color theme
    local valid_color = false
    for _, ct in ipairs(ThemeManager.COLOR_THEMES) do
        if ct == ThemeManager.current_color_theme then
            valid_color = true
            break
        end
    end
    if not valid_color then
        ThemeManager.current_color_theme = "default"
    end

    -- Apply color theme
    ThemeManager.apply_color_theme()

    tdeck.system.log("[Theme] Init - wp:" .. ThemeManager.current_wallpaper .. " colors:" .. ThemeManager.current_color_theme)
end

-- Apply current color theme to the colors table
function ThemeManager.apply_color_theme()
    local palette = ThemeManager.COLOR_PALETTES[ThemeManager.current_color_theme]
    if not palette then
        palette = ThemeManager.COLOR_PALETTES["default"]
    end

    -- Create colors table with base colors from display.colors plus theme overrides
    local base = tdeck.display.colors

    -- Determine background color (light themes have custom backgrounds)
    local bg_color = palette.is_light and palette.BACKGROUND or base.BLACK

    ThemeManager.colors = {
        -- Base colors (always available)
        BLACK = base.BLACK,
        WHITE = base.WHITE,
        BLUE = base.BLUE,
        LIGHT_GRAY = base.LIGHT_GRAY,

        -- Semantic theme colors
        ACCENT = palette.ACCENT,           -- Primary accent (selections, highlights)
        SUCCESS = palette.SUCCESS,         -- Success/positive state
        WARNING = palette.WARNING,         -- Warning/caution state
        ERROR = palette.ERROR,             -- Error/danger state
        INFO = palette.INFO,               -- Informational accent

        -- Text colors
        TEXT = palette.TEXT,               -- Primary text
        TEXT_SECONDARY = palette.TEXT_SECONDARY, -- Secondary/dimmed text
        TEXT_MUTED = palette.TEXT_MUTED,   -- Very dim text for hints

        -- Surface colors
        BACKGROUND = bg_color,             -- Main background
        SURFACE = palette.SURFACE,         -- Card/input backgrounds
        SURFACE_ALT = palette.SURFACE_ALT, -- Selection/highlight background

        -- Wallpaper tints
        TINT1 = palette.TINT1,
        TINT2 = palette.TINT2,

        -- Theme metadata
        is_light = palette.is_light or false,
    }
end

-- Check if current theme is light
function ThemeManager.is_light_theme()
    local palette = ThemeManager.COLOR_PALETTES[ThemeManager.current_color_theme]
    return palette and palette.is_light or false
end

-- Get wallpaper pattern colors (returns tint1, tint2)
function ThemeManager.get_pattern_colors()
    local palette = ThemeManager.COLOR_PALETTES[ThemeManager.current_color_theme]

    -- Get tint1 (primary pattern color)
    local tint1
    if ThemeManager.custom_wallpaper_tint1 then
        tint1 = ThemeManager.custom_wallpaper_tint1
    elseif palette and palette.TINT1 then
        tint1 = palette.TINT1
    elseif palette and palette.is_light then
        tint1 = 0xDEFB  -- Light gray for light themes
    else
        tint1 = 0x1082  -- Dark gray for dark themes
    end

    -- Get tint2 (secondary accent color)
    local tint2
    if ThemeManager.custom_wallpaper_tint2 then
        tint2 = ThemeManager.custom_wallpaper_tint2
    elseif palette and palette.TINT2 then
        tint2 = palette.TINT2
    elseif palette and palette.is_light then
        tint2 = 0xC618  -- Slightly darker for light themes
    else
        tint2 = 0x0841  -- Slightly darker for dark themes
    end

    return tint1, tint2
end

-- Legacy function for compatibility - returns primary tint
function ThemeManager.get_pattern_color()
    local tint1, _ = ThemeManager.get_pattern_colors()
    return tint1
end

-- Set custom wallpaper tint colors (nil to use theme default)
function ThemeManager.set_wallpaper_tint(color, color2)
    ThemeManager.custom_wallpaper_tint1 = color
    ThemeManager.custom_wallpaper_tint2 = color2
    if tdeck.storage and tdeck.storage.set_pref then
        if color then
            tdeck.storage.set_pref("wallpaper_tint", color)
        else
            tdeck.storage.set_pref("wallpaper_tint", -1)
        end
        if color2 then
            tdeck.storage.set_pref("wallpaper_tint2", color2)
        else
            tdeck.storage.set_pref("wallpaper_tint2", -1)
        end
    end
    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end
end

-- Get custom wallpaper tints (nil if using theme default)
function ThemeManager.get_wallpaper_tint()
    return ThemeManager.custom_wallpaper_tint1, ThemeManager.custom_wallpaper_tint2
end

-- Get current colors (for screens to use)
function ThemeManager.get_colors()
    if not ThemeManager.colors then
        ThemeManager.apply_color_theme()
    end
    return ThemeManager.colors
end

-- Set and apply new wallpaper
function ThemeManager.set_wallpaper(name)
    local valid = false
    for _, wp in ipairs(ThemeManager.WALLPAPERS) do
        if wp == name then
            valid = true
            break
        end
    end

    if not valid then return false end

    ThemeManager.current_wallpaper = name
    ThemeManager.save()

    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end

    return true
end

-- Set and apply new icon theme
function ThemeManager.set_icon_theme(name)
    local valid = false
    for _, th in ipairs(ThemeManager.ICON_THEMES) do
        if th == name then
            valid = true
            break
        end
    end

    if not valid then return false end

    ThemeManager.current_icon_theme = name
    ThemeManager.save()

    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end

    return true
end

-- Set and apply new color theme
function ThemeManager.set_color_theme(name)
    local valid = false
    for _, ct in ipairs(ThemeManager.COLOR_THEMES) do
        if ct == name then
            valid = true
            break
        end
    end

    if not valid then return false end

    ThemeManager.current_color_theme = name
    ThemeManager.apply_color_theme()
    ThemeManager.save()

    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end

    return true
end

-- Get index of current color theme in COLOR_THEMES array
function ThemeManager.get_color_theme_index()
    for i, ct in ipairs(ThemeManager.COLOR_THEMES) do
        if ct == ThemeManager.current_color_theme then
            return i
        end
    end
    return 1
end

-- Set color theme by index
function ThemeManager.set_color_theme_by_index(index)
    if index >= 1 and index <= #ThemeManager.COLOR_THEMES then
        ThemeManager.set_color_theme(ThemeManager.COLOR_THEMES[index])
    end
end

-- Save current theme preferences
function ThemeManager.save()
    if tdeck.storage and tdeck.storage.set_pref then
        tdeck.storage.set_pref("wallpaper", ThemeManager.current_wallpaper)
        tdeck.storage.set_pref("icon_theme", ThemeManager.current_icon_theme)
        tdeck.storage.set_pref("color_theme", ThemeManager.current_color_theme)
    end
end

-- Get icon path for current theme
function ThemeManager.get_icon_path(name, size)
    size = size or 32

    if ThemeManager.current_icon_theme == "default" then
        return string.format("/icons/%dx%d/%s.rgb565", size, size, name)
    else
        return string.format("/themes/%s/icons/%dx%d/%s.rgb565",
                            ThemeManager.current_icon_theme, size, size, name)
    end
end

-- Draw wallpaper background using primitives with two tints
function ThemeManager.draw_background(display)
    local w = display.width
    local h = display.height
    local pattern = ThemeManager.current_wallpaper

    -- Get background color from theme (light themes have light backgrounds)
    local theme_colors = ThemeManager.get_colors()
    local bg = theme_colors.BACKGROUND or display.colors.BLACK

    -- Get both pattern colors
    local c1, c2 = ThemeManager.get_pattern_colors()

    -- Fill with background color
    display.fill_rect(0, 0, w, h, bg)

    if pattern == "grid" then
        -- Grid pattern: primary lines with accent at intersections
        local sp = 16
        -- Draw main grid lines with tint1
        for x = 0, w, sp do
            display.fill_rect(x, 0, 1, h, c1)
        end
        for y = 0, h, sp do
            display.fill_rect(0, y, w, 1, c1)
        end
        -- Draw accent dots at intersections with tint2
        for y = 0, h, sp do
            for x = 0, w, sp do
                display.fill_rect(x, y, 2, 2, c2)
            end
        end

    elseif pattern == "dots" then
        -- Sparse dots pattern with alternating colors
        local sp = 12
        local alt = false
        for y = sp, h, sp do
            alt = not alt
            for x = sp, w, sp do
                local color = alt and c1 or c2
                display.fill_rect(x, y, 1, 1, color)
                alt = not alt
            end
        end

    elseif pattern == "dots_diag" then
        -- Sparse dots with diagonal offset (every other row shifted)
        local sp = 12
        local row = 0
        for y = sp, h, sp do
            local offset = (row % 2 == 1) and math.floor(sp / 2) or 0
            for x = sp + offset, w, sp do
                local color = (row % 2 == 0) and c1 or c2
                display.fill_rect(x, y, 1, 1, color)
            end
            row = row + 1
        end

    elseif pattern == "dense" then
        -- Dense dots with two colors creating texture
        local sp = 6
        for y = sp, h, sp do
            for x = sp, w, sp do
                -- Alternating pattern based on position
                local color = ((x + y) % 12 == 0) and c2 or c1
                display.fill_rect(x, y, 1, 1, color)
            end
        end

    elseif pattern == "dense_diag" then
        -- Dense dots with diagonal offset (every other row shifted)
        local sp = 6
        local row = 0
        for y = sp, h, sp do
            local offset = (row % 2 == 1) and math.floor(sp / 2) or 0
            for x = sp + offset, w, sp do
                local color = (row % 2 == 0) and c1 or c2
                display.fill_rect(x, y, 1, 1, color)
            end
            row = row + 1
        end

    elseif pattern == "hlines" then
        -- Horizontal lines with alternating colors
        local sp = 8
        local alt = false
        for y = 0, h, sp do
            display.fill_rect(0, y, w, 1, alt and c2 or c1)
            alt = not alt
        end

    elseif pattern == "vlines" then
        -- Vertical lines with alternating colors
        local sp = 8
        local alt = false
        for x = 0, w, sp do
            display.fill_rect(x, 0, 1, h, alt and c2 or c1)
            alt = not alt
        end

    elseif pattern == "diag" then
        -- Diagonal lines with two colors
        local sp = 10
        local line_num = 0
        for i = -h, w + h, sp do
            local color = (line_num % 2 == 0) and c1 or c2
            for j = 0, math.min(w, h) do
                local x = i + j
                local y = j
                if x >= 0 and x < w and y < h then
                    display.fill_rect(x, y, 1, 1, color)
                end
            end
            line_num = line_num + 1
        end
    end
    -- "solid" just uses the background color already drawn
end

-- Get index of current wallpaper in WALLPAPERS array
function ThemeManager.get_wallpaper_index()
    for i, wp in ipairs(ThemeManager.WALLPAPERS) do
        if wp == ThemeManager.current_wallpaper then
            return i
        end
    end
    return 1
end

-- Get index of current icon theme in ICON_THEMES array
function ThemeManager.get_icon_theme_index()
    for i, th in ipairs(ThemeManager.ICON_THEMES) do
        if th == ThemeManager.current_icon_theme then
            return i
        end
    end
    return 1
end

-- Set wallpaper by index
function ThemeManager.set_wallpaper_by_index(index)
    if index >= 1 and index <= #ThemeManager.WALLPAPERS then
        ThemeManager.set_wallpaper(ThemeManager.WALLPAPERS[index])
    end
end

-- Set icon theme by index
function ThemeManager.set_icon_theme_by_index(index)
    if index >= 1 and index <= #ThemeManager.ICON_THEMES then
        ThemeManager.set_icon_theme(ThemeManager.ICON_THEMES[index])
    end
end

return ThemeManager
