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
    WALLPAPERS = {"solid", "grid", "dots", "dense", "hlines", "vlines", "diag"},
    ICON_THEMES = {"default", "cyan", "orange", "mono"},
    COLOR_THEMES = {
        -- Dark themes (1-12)
        "default", "matrix", "amber", "nord", "dracula", "solarized",
        "monokai", "gruvbox", "ocean", "sunset", "forest", "midnight",
        -- More dark themes (13-18)
        "cyberpunk", "hacker", "cherry", "slate", "tokyo", "emerald",
        -- Light themes (19-24)
        "paper", "daylight", "latte", "mint", "lavender", "peach"
    },

    -- Color theme definitions (RGB565 values)
    -- Each theme defines: CYAN, GREEN, ORANGE, RED, YELLOW, TEXT, TEXT_DIM, DARK_GRAY, SELECTION
    COLOR_PALETTES = {
        -- Default: Cyan/Green terminal look
        default = {
            CYAN = 0x07FF,       -- Bright cyan (highlight, accent)
            GREEN = 0x07E0,      -- Bright green (success)
            ORANGE = 0xFD20,     -- Orange (warning accent)
            RED = 0xF800,        -- Red (error)
            YELLOW = 0xFFE0,     -- Yellow (warning)
            TEXT = 0x07E0,       -- Green text
            TEXT_DIM = 0x03E0,   -- Dark green dim text
            DARK_GRAY = 0x4208,  -- Dark gray
            SELECTION = 0x0320,  -- Dark cyan selection
        },
        -- Matrix: Classic green terminal
        matrix = {
            CYAN = 0x07E0,       -- Green for highlight
            GREEN = 0x07E0,      -- Bright green
            ORANGE = 0x05E0,     -- Yellow-green
            RED = 0xF800,        -- Red
            YELLOW = 0x07E0,     -- Green
            TEXT = 0x07E0,       -- Green text
            TEXT_DIM = 0x0320,   -- Dark green
            DARK_GRAY = 0x2104,  -- Very dark
            SELECTION = 0x0320,  -- Dark green
        },
        -- Amber: Warm amber terminal
        amber = {
            CYAN = 0xFE00,       -- Amber highlight
            GREEN = 0xFE00,      -- Amber
            ORANGE = 0xFD20,     -- Orange
            RED = 0xF800,        -- Red
            YELLOW = 0xFFE0,     -- Yellow
            TEXT = 0xFE00,       -- Amber text
            TEXT_DIM = 0x8400,   -- Dark amber
            DARK_GRAY = 0x4208,  -- Dark gray
            SELECTION = 0x4200,  -- Dark amber
        },
        -- Nord: Cool blue-gray palette
        nord = {
            CYAN = 0x869F,       -- Nord cyan (#88C0D0)
            GREEN = 0x9F8B,      -- Nord green (#A3BE8C)
            ORANGE = 0xD461,     -- Nord orange (#D08770)
            RED = 0xB945,        -- Nord red (#BF616A)
            YELLOW = 0xEEC6,     -- Nord yellow (#EBCB8B)
            TEXT = 0xE71C,       -- Nord snow (#ECEFF4)
            TEXT_DIM = 0x8410,   -- Nord gray
            DARK_GRAY = 0x3186,  -- Nord polar night
            SELECTION = 0x4228,  -- Nord selection
        },
        -- Dracula: Dark purple theme
        dracula = {
            CYAN = 0x8FDF,       -- Dracula cyan (#8BE9FD)
            GREEN = 0x57EA,      -- Dracula green (#50FA7B)
            ORANGE = 0xFC68,     -- Dracula orange (#FFB86C)
            RED = 0xF98B,        -- Dracula red/pink (#FF5555)
            YELLOW = 0xF7E6,     -- Dracula yellow (#F1FA8C)
            TEXT = 0xF7BE,       -- Dracula foreground (#F8F8F2)
            TEXT_DIM = 0x630C,   -- Dracula comment (#6272A4)
            DARK_GRAY = 0x4228,  -- Dracula selection
            SELECTION = 0x4228,  -- Dark purple
        },
        -- Solarized: Teal and orange
        solarized = {
            CYAN = 0x2D7F,       -- Solarized cyan (#2AA198)
            GREEN = 0x8DE0,      -- Solarized green (#859900)
            ORANGE = 0xCB20,     -- Solarized orange (#CB4B16)
            RED = 0xD906,        -- Solarized red (#DC322F)
            YELLOW = 0xB580,     -- Solarized yellow (#B58900)
            TEXT = 0x8410,       -- Solarized base0 (#839496)
            TEXT_DIM = 0x5AEB,   -- Solarized base01
            DARK_GRAY = 0x0228,  -- Solarized base03
            SELECTION = 0x0A49,  -- Dark teal
        },
        -- Monokai: Vibrant classic
        monokai = {
            CYAN = 0x667F,       -- Monokai blue (#66D9EF)
            GREEN = 0xA6E5,      -- Monokai green (#A6E22E)
            ORANGE = 0xFD20,     -- Monokai orange (#FD971F)
            RED = 0xF92C,        -- Monokai red (#F92672)
            YELLOW = 0xE7E4,     -- Monokai yellow (#E6DB74)
            TEXT = 0xF7BE,       -- Monokai white (#F8F8F2)
            TEXT_DIM = 0x7BEF,   -- Monokai gray (#75715E)
            DARK_GRAY = 0x39E7,  -- Monokai bg
            SELECTION = 0x4A49,  -- Dark selection
        },
        -- Gruvbox: Warm retro
        gruvbox = {
            CYAN = 0x8E3F,       -- Gruvbox aqua (#8EC07C)
            GREEN = 0xBE66,      -- Gruvbox green (#B8BB26)
            ORANGE = 0xFE00,     -- Gruvbox orange (#FE8019)
            RED = 0xFB48,        -- Gruvbox red (#FB4934)
            YELLOW = 0xFEA0,     -- Gruvbox yellow (#FABD2F)
            TEXT = 0xEF5D,       -- Gruvbox fg (#EBDBB2)
            TEXT_DIM = 0xA514,   -- Gruvbox gray
            DARK_GRAY = 0x3A08,  -- Gruvbox bg
            SELECTION = 0x5ACB,  -- Gruvbox selection
        },
        -- Ocean: Cool blue depths
        ocean = {
            CYAN = 0x5DDF,       -- Light blue
            GREEN = 0x57EA,      -- Sea green
            ORANGE = 0xFD40,     -- Coral
            RED = 0xF800,        -- Red
            YELLOW = 0xFFE0,     -- Yellow
            TEXT = 0xBF3F,       -- Light cyan text
            TEXT_DIM = 0x4C9F,   -- Dim blue
            DARK_GRAY = 0x1926,  -- Deep ocean
            SELECTION = 0x2966,  -- Ocean blue selection
        },
        -- Sunset: Warm evening colors
        sunset = {
            CYAN = 0xFD40,       -- Coral as accent
            GREEN = 0xFE60,      -- Warm yellow-green
            ORANGE = 0xFD20,     -- Orange
            RED = 0xF800,        -- Red
            YELLOW = 0xFFE0,     -- Yellow
            TEXT = 0xFE60,       -- Warm text
            TEXT_DIM = 0xB400,   -- Dim orange
            DARK_GRAY = 0x4000,  -- Dark red-brown
            SELECTION = 0x6000,  -- Dark warm
        },
        -- Forest: Natural greens
        forest = {
            CYAN = 0x8F8B,       -- Sage green
            GREEN = 0x5F26,      -- Forest green
            ORANGE = 0xC580,     -- Autumn orange
            RED = 0xB8A2,        -- Muted red
            YELLOW = 0xBE66,     -- Olive yellow
            TEXT = 0xAF2D,       -- Pale green text
            TEXT_DIM = 0x4B29,   -- Dark forest
            DARK_GRAY = 0x2945,  -- Very dark green
            SELECTION = 0x3B07,  -- Forest selection
        },
        -- Midnight: Deep blues and purples
        midnight = {
            CYAN = 0x7C1F,       -- Purple-blue
            GREEN = 0x57EA,      -- Neon green accent
            ORANGE = 0xC45F,     -- Pink-purple
            RED = 0xF80F,        -- Magenta
            YELLOW = 0xC65F,     -- Lavender
            TEXT = 0xB59F,       -- Light purple text
            TEXT_DIM = 0x528A,   -- Dim purple
            DARK_GRAY = 0x2105,  -- Deep midnight
            SELECTION = 0x3107,  -- Purple selection
        },
        -- Cyberpunk: Neon pink and blue
        cyberpunk = {
            CYAN = 0x07FF,       -- Electric cyan
            GREEN = 0xF81F,      -- Magenta/pink
            ORANGE = 0xFD20,     -- Orange
            RED = 0xF81F,        -- Magenta
            YELLOW = 0x07FF,     -- Cyan accent
            TEXT = 0xF81F,       -- Bright magenta text
            TEXT_DIM = 0x780F,   -- Dim magenta
            DARK_GRAY = 0x1083,  -- Dark blue-black
            SELECTION = 0x380F,  -- Deep magenta
        },
        -- Hacker: Dark with red accents
        hacker = {
            CYAN = 0xF800,       -- Red as highlight
            GREEN = 0x07E0,      -- Green for success
            ORANGE = 0xFD20,     -- Orange warning
            RED = 0xF800,        -- Bright red
            YELLOW = 0xF800,     -- Red accent
            TEXT = 0xF800,       -- Red text
            TEXT_DIM = 0x7800,   -- Dark red
            DARK_GRAY = 0x18C3,  -- Dark gray
            SELECTION = 0x4000,  -- Dark red selection
        },
        -- Cherry: Dark with pink/red
        cherry = {
            CYAN = 0xF8B2,       -- Light pink
            GREEN = 0xFE66,      -- Warm pink-yellow
            ORANGE = 0xFD20,     -- Orange
            RED = 0xF800,        -- Red
            YELLOW = 0xFEB2,     -- Light coral
            TEXT = 0xFE92,       -- Soft pink text
            TEXT_DIM = 0xB945,   -- Muted pink
            DARK_GRAY = 0x3082,  -- Dark with red tint
            SELECTION = 0x6041,  -- Dark pink selection
        },
        -- Slate: Gray-blue professional
        slate = {
            CYAN = 0x6D9F,       -- Steel blue
            GREEN = 0x5E8A,      -- Sage
            ORANGE = 0xDC60,     -- Muted orange
            RED = 0xC186,        -- Muted red
            YELLOW = 0xE6C6,     -- Muted yellow
            TEXT = 0xBDD7,       -- Light gray-blue
            TEXT_DIM = 0x738E,   -- Medium gray
            DARK_GRAY = 0x31A6,  -- Dark slate
            SELECTION = 0x4228,  -- Slate selection
        },
        -- Tokyo: Tokyo Night inspired
        tokyo = {
            CYAN = 0x7DDF,       -- Light blue (#7AA2F7)
            GREEN = 0x9FEC,      -- Teal green (#9ECE6A)
            ORANGE = 0xFD60,     -- Orange (#FF9E64)
            RED = 0xF98B,        -- Red (#F7768E)
            YELLOW = 0xE7A6,     -- Yellow (#E0AF68)
            TEXT = 0xC618,       -- Light gray (#C0CAF5)
            TEXT_DIM = 0x5ACB,   -- Comment gray (#565F89)
            DARK_GRAY = 0x1926,  -- Dark blue (#1A1B26)
            SELECTION = 0x3186,  -- Selection
        },
        -- Emerald: Rich greens
        emerald = {
            CYAN = 0x5FEC,       -- Bright emerald
            GREEN = 0x3F06,      -- Deep emerald
            ORANGE = 0xFE40,     -- Gold
            RED = 0xD906,        -- Coral red
            YELLOW = 0xCF40,     -- Yellow-green
            TEXT = 0x9FF3,       -- Light green text
            TEXT_DIM = 0x3E88,   -- Dim green
            DARK_GRAY = 0x1904,  -- Dark forest
            SELECTION = 0x2EC5,  -- Green selection
        },

        -- ===== LIGHT THEMES =====

        -- Paper: Warm cream/sepia (light)
        paper = {
            is_light = true,
            BACKGROUND = 0xFED6,  -- Warm cream (#FFF8E7)
            PATTERN = 0xE6B4,     -- Light tan pattern
            CYAN = 0x4A69,       -- Blue-gray
            GREEN = 0x4C85,      -- Olive green
            ORANGE = 0xC3E0,     -- Brown
            RED = 0xB8C3,        -- Muted red
            YELLOW = 0xC580,     -- Tan
            TEXT = 0x39E7,       -- Dark brown-gray
            TEXT_DIM = 0x7BCF,   -- Medium gray
            DARK_GRAY = 0xE6F4,  -- Light gray (for cards)
            SELECTION = 0xD6B4,  -- Light tan selection
        },
        -- Daylight: Bright white with blue (light)
        daylight = {
            is_light = true,
            BACKGROUND = 0xFFFF,  -- Pure white
            PATTERN = 0xDEFB,     -- Light gray pattern
            CYAN = 0x2D7F,       -- Bright blue
            GREEN = 0x2E8B,      -- Green
            ORANGE = 0xFC60,     -- Orange
            RED = 0xF800,        -- Red
            YELLOW = 0xFE00,     -- Amber
            TEXT = 0x2104,       -- Near black
            TEXT_DIM = 0x738E,   -- Medium gray
            DARK_GRAY = 0xE71C,  -- Very light gray
            SELECTION = 0xB5F6,  -- Light blue selection
        },
        -- Latte: Coffee/cream theme (light)
        latte = {
            is_light = true,
            BACKGROUND = 0xEF5D,  -- Warm off-white (#EDD8C5)
            PATTERN = 0xD69A,     -- Light brown pattern
            CYAN = 0x3C7F,       -- Teal
            GREEN = 0x4586,      -- Sage green
            ORANGE = 0xC3A0,     -- Coffee brown
            RED = 0xC186,        -- Muted red
            YELLOW = 0xCE00,     -- Caramel
            TEXT = 0x4208,       -- Dark brown
            TEXT_DIM = 0x8410,   -- Medium brown-gray
            DARK_GRAY = 0xDEDB,  -- Light cream
            SELECTION = 0xC618,  -- Latte selection
        },
        -- Mint: Light green/white (light)
        mint = {
            is_light = true,
            BACKGROUND = 0xE7FC,  -- Mint white (#E8FFF0)
            PATTERN = 0xCF5A,     -- Light mint pattern
            CYAN = 0x2D8D,       -- Teal
            GREEN = 0x2E69,      -- Forest green
            ORANGE = 0xD400,     -- Orange-brown
            RED = 0xC186,        -- Muted red
            YELLOW = 0x95E0,     -- Yellow-green
            TEXT = 0x2945,       -- Dark green-gray
            TEXT_DIM = 0x6B8D,   -- Medium gray-green
            DARK_GRAY = 0xD71C,  -- Very light green-gray
            SELECTION = 0xB7F5,  -- Light mint selection
        },
        -- Lavender: Light purple (light)
        lavender = {
            is_light = true,
            BACKGROUND = 0xF79E,  -- Lavender white (#F5F0FF)
            PATTERN = 0xD69B,     -- Light purple pattern
            CYAN = 0x897F,       -- Purple-blue
            GREEN = 0x6E0C,      -- Muted green
            ORANGE = 0xD44F,     -- Muted orange
            RED = 0xC967,        -- Muted pink-red
            YELLOW = 0xBE2D,     -- Muted yellow
            TEXT = 0x4A69,       -- Dark purple-gray
            TEXT_DIM = 0x8410,   -- Medium gray
            DARK_GRAY = 0xEF5D,  -- Very light purple
            SELECTION = 0xC59F,  -- Light purple selection
        },
        -- Peach: Light orange/pink (light)
        peach = {
            is_light = true,
            BACKGROUND = 0xFEB7,  -- Peach white (#FFF0E8)
            PATTERN = 0xE634,     -- Light peach pattern
            CYAN = 0xFC92,       -- Coral pink
            GREEN = 0x5D88,      -- Sage
            ORANGE = 0xFB80,     -- Orange
            RED = 0xF8A7,        -- Coral
            YELLOW = 0xFE40,     -- Peach
            TEXT = 0x4A49,       -- Dark warm gray
            TEXT_DIM = 0x9CD3,   -- Medium warm gray
            DARK_GRAY = 0xF71C,  -- Very light peach
            SELECTION = 0xFDF6,  -- Light coral selection
        },
    },

    -- Custom wallpaper tint color (RGB565, nil = use theme default)
    custom_wallpaper_tint = nil,

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

    -- Load custom wallpaper tint (-1 means auto/nil)
    local tint = get_pref("wallpaper_tint", -1)
    tint = tonumber(tint) or -1  -- Ensure it's a number
    if tint >= 0 then
        ThemeManager.custom_wallpaper_tint = tint
    else
        ThemeManager.custom_wallpaper_tint = nil
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
        -- Base colors
        BLACK = base.BLACK,
        WHITE = base.WHITE,
        BLUE = base.BLUE,
        LIGHT_GRAY = base.LIGHT_GRAY,

        -- Theme-aware colors
        CYAN = palette.CYAN,
        GREEN = palette.GREEN,
        ORANGE = palette.ORANGE,
        RED = palette.RED,
        YELLOW = palette.YELLOW,
        TEXT = palette.TEXT,
        TEXT_DIM = palette.TEXT_DIM,
        DARK_GRAY = palette.DARK_GRAY,
        SELECTION = palette.SELECTION,

        -- Semantic aliases
        BACKGROUND = bg_color,
        FOREGROUND = palette.TEXT,
        HIGHLIGHT = palette.CYAN,
        BORDER = palette.TEXT_DIM,
        ERROR = palette.RED,
        WARNING = palette.YELLOW,
        SUCCESS = palette.GREEN,

        -- Theme metadata
        is_light = palette.is_light or false,
        PATTERN = palette.PATTERN,
    }
end

-- Check if current theme is light
function ThemeManager.is_light_theme()
    local palette = ThemeManager.COLOR_PALETTES[ThemeManager.current_color_theme]
    return palette and palette.is_light or false
end

-- Get wallpaper pattern color (custom tint overrides theme default)
function ThemeManager.get_pattern_color()
    if ThemeManager.custom_wallpaper_tint then
        return ThemeManager.custom_wallpaper_tint
    end

    local palette = ThemeManager.COLOR_PALETTES[ThemeManager.current_color_theme]
    if palette and palette.PATTERN then
        return palette.PATTERN
    end

    -- Default pattern colors based on light/dark
    if palette and palette.is_light then
        return 0xDEFB  -- Light gray for light themes
    else
        return 0x1082  -- Dark gray for dark themes
    end
end

-- Set custom wallpaper tint color (nil to use theme default)
function ThemeManager.set_wallpaper_tint(color)
    ThemeManager.custom_wallpaper_tint = color
    if tdeck.storage and tdeck.storage.set_pref then
        if color then
            tdeck.storage.set_pref("wallpaper_tint", color)
        else
            tdeck.storage.set_pref("wallpaper_tint", -1)  -- -1 means nil/auto
        end
    end
    if _G.ScreenManager then
        _G.ScreenManager.invalidate()
    end
end

-- Get custom wallpaper tint (nil if using theme default)
function ThemeManager.get_wallpaper_tint()
    return ThemeManager.custom_wallpaper_tint
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

-- Draw wallpaper background using primitives
function ThemeManager.draw_background(display)
    local w = display.width
    local h = display.height
    local pattern = ThemeManager.current_wallpaper

    -- Get background color from theme (light themes have light backgrounds)
    local theme_colors = ThemeManager.get_colors()
    local bg = theme_colors.BACKGROUND or display.colors.BLACK

    -- Get pattern color (custom tint or theme default)
    local c = ThemeManager.get_pattern_color()

    -- Fill with background color
    display.fill_rect(0, 0, w, h, bg)

    if pattern == "grid" then
        -- Grid pattern: subtle grid lines
        local sp = 16
        for x = 0, w, sp do
            display.fill_rect(x, 0, 1, h, c)
        end
        for y = 0, h, sp do
            display.fill_rect(0, y, w, 1, c)
        end

    elseif pattern == "dots" then
        -- Sparse dots pattern
        local sp = 12
        for y = sp, h, sp do
            for x = sp, w, sp do
                display.fill_rect(x, y, 1, 1, c)
            end
        end

    elseif pattern == "dense" then
        -- Dense dots pattern
        local sp = 6
        for y = sp, h, sp do
            for x = sp, w, sp do
                display.fill_rect(x, y, 1, 1, c)
            end
        end

    elseif pattern == "hlines" then
        -- Horizontal lines
        local sp = 8
        for y = 0, h, sp do
            display.fill_rect(0, y, w, 1, c)
        end

    elseif pattern == "vlines" then
        -- Vertical lines
        local sp = 8
        for x = 0, w, sp do
            display.fill_rect(x, 0, 1, h, c)
        end

    elseif pattern == "diag" then
        -- Diagonal lines (top-left to bottom-right)
        local sp = 10
        for i = -h, w + h, sp do
            for j = 0, math.min(w, h) do
                local x = i + j
                local y = j
                if x >= 0 and x < w and y < h then
                    display.fill_rect(x, y, 1, 1, c)
                end
            end
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
